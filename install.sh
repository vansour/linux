#!/usr/bin/env bash
# ============================================================
#  Linux 一键配置脚本  v0.0.1  —— 单文件版（自动生成，请勿直接编辑）
#
#  不写入生成时间：产物需完全可复现，否则 pre-commit 钩子
#  每次重建都会产生无意义的 diff。构建时间看 git log。
#  源码改动请编辑 main.sh / lib/ / modules/，然后运行 bash build.sh
# ============================================================
SINGLE_FILE=1
SELF_NAME="install.sh"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 lib/core.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# core.sh - 核心基础库
# 颜色 / 日志 / 系统探测 / 包管理抽象 / 通用工具
# ============================================================

# ------------------------------------------------------------
# 颜色
# ------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_MAGENTA=$'\033[35m'
    C_CYAN=$'\033[36m'
    C_WHITE=$'\033[37m'
    C_BRED=$'\033[1;31m'
    C_BGREEN=$'\033[1;32m'
    C_BYELLOW=$'\033[1;33m'
    C_BBLUE=$'\033[1;34m'
    C_BCYAN=$'\033[1;36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' \
    C_BLUE='' C_MAGENTA='' C_CYAN='' C_WHITE='' C_BRED='' C_BGREEN='' \
    C_BYELLOW='' C_BBLUE='' C_BCYAN=''
fi

# ------------------------------------------------------------
# 日志
# ------------------------------------------------------------
LOG_LEVEL="${LOG_LEVEL:-info}"   # debug|info|warn|error
LOG_FILE="${LOG_FILE:-/var/log/linux-toolkit.log}"

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log_write() {
    # 尽量写日志文件，失败静默忽略（非 root 或目录不可写时）
    [[ -n "$LOG_FILE" ]] || return 0
    printf '[%s] [%-5s] %s\n' "$(_ts)" "$1" "$2" >>"$LOG_FILE" 2>/dev/null || true
}

log_debug() { [[ "$LOG_LEVEL" == "debug" ]] || return 0; printf '%s[·]%s %s\n' "$C_DIM" "$C_RESET" "$*"; _log_write DEBUG "$*"; }
log_info()  { printf '%s[i]%s %s\n' "$C_CYAN" "$C_RESET" "$*"; _log_write INFO "$*"; }
log_ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; _log_write OK "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; _log_write WARN "$*"; }
log_err()   { printf '%s[✗]%s %s\n' "$C_BRED" "$C_RESET" "$*" >&2; _log_write ERROR "$*"; }
die()       { log_err "$*"; exit 1; }

# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------
# 保证 charmap 是 UTF-8
#
# 显示宽度计算依赖 locale：在 C / POSIX locale 下 bash 的 ${#str} 与
# ${str:i:1} 都按字节走，一个汉字会被算成 3 列而不是 2 列，两列菜单
# 的补白随之算错、整体错位。LC_ALL=C sudo bash install.sh 就会踩到。
#
# 优先只改 LC_CTYPE：不动 LC_MESSAGES，程序输出的语言不受影响。
# LC_ALL 一旦被设成非 UTF-8 就会盖掉 LC_CTYPE，这时只能连它一起改。
# C.utf8 是部分发行版的拼法，两个都试一遍。
# ------------------------------------------------------------
_ensure_utf8_locale() {
    have_cmd locale || return 0
    [[ "$(locale charmap 2>/dev/null)" == "UTF-8" ]] && return 0

    local cand
    for cand in C.UTF-8 C.utf8; do
        if [[ -z "${LC_ALL:-}" ]] \
           && [[ "$(LC_CTYPE="$cand" locale charmap 2>/dev/null)" == "UTF-8" ]]; then
            export LC_CTYPE="$cand"
            return 0
        fi
        if [[ "$(LC_ALL="$cand" locale charmap 2>/dev/null)" == "UTF-8" ]]; then
            export LC_ALL="$cand"
            return 0
        fi
    done
    return 1
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

# is_tty: stdin 是终端才允许交互
is_tty() { [[ -t 0 ]]; }

# 能否打开控制终端。/dev/tty 的 -r 权限位测不准，必须实际打开一次才算数
can_open_tty() { { true </dev/tty; } 2>/dev/null; }

# ------------------------------------------------------------
# 统一交互读取入口
#   终端直接运行     → 读 stdin
#   curl ... | bash  → bash 正用 stdin 读脚本，这里改从 /dev/tty 读键盘
# ------------------------------------------------------------
ui_read() {
    # ${__var?} 表示「必须传参」：这里 __var 存的是目标变量名，属于有意为之的动态取名
    local __var="$1"
    if [[ -t 0 ]]; then
        read -r "${__var?}"
    elif can_open_tty; then
        read -r "${__var?}" </dev/tty
    else
        read -r "${__var?}"
    fi
}

require_root() {
    if ! is_root; then
        die "此操作需要 root 权限，请使用 sudo 重新运行。"
    fi
}

# 执行命令并记录到日志（失败返回非 0，由调用方决定如何处理）
run_cmd() {
    log_debug "执行: $*"
    "$@"
}

# 执行命令，失败直接中止
run_or_die() {
    if ! run_cmd "$@"; then
        die "命令执行失败: $*"
    fi
}

# ------------------------------------------------------------
# 系统探测
# ------------------------------------------------------------
detect_system() {
    DISTRO_ID="unknown"; DISTRO_NAME="Unknown"; DISTRO_VERSION=""
    DISTRO_CODENAME=""; DISTRO_FAMILY="unknown"

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${NAME:-$DISTRO_ID}"
        DISTRO_VERSION="${VERSION_ID:-}"
        DISTRO_CODENAME="${VERSION_CODENAME:-${VERSION_CODENAME_OVERRIDE:-}}"
    elif have_cmd lsb_release; then
        DISTRO_ID="$(lsb_release -si 2>/dev/null | tr '[:upper:]' '[:lower:]')"
        DISTRO_NAME="$(lsb_release -sd 2>/dev/null)"
        DISTRO_VERSION="$(lsb_release -sr 2>/dev/null)"
    fi

    # 归入发行版家族，包管理逻辑按家族走
    case "$DISTRO_ID" in
        debian|ubuntu|raspbian|linuxmint|kali|armbian|deepin|uos|devuan)
            DISTRO_FAMILY="debian" ;;
        rhel|centos|fedora|rocky|almalinux|ol|anolis|openeuler|kylin|tencentos)
            DISTRO_FAMILY="rhel" ;;
        arch|manjaro|endeavouros|garuda)
            DISTRO_FAMILY="arch" ;;
        alpine)
            DISTRO_FAMILY="alpine" ;;
        opensuse*|sles|sled)
            DISTRO_FAMILY="suse" ;;
        *)
            DISTRO_FAMILY="unknown" ;;
    esac

    ARCH="$(uname -m)"
    KERNEL="$(uname -r)"
    HOSTNAME_SHORT="$(uname -n)"
}

# ------------------------------------------------------------
# 包管理抽象（后续功能模块直接调用，无需关心发行版）
# ------------------------------------------------------------
pkg_refresh() {
    case "$DISTRO_FAMILY" in
        debian) run_cmd apt-get update -qq ;;
        rhel)   run_cmd dnf makecache -q 2>/dev/null || run_cmd yum makecache -q ;;
        arch)   run_cmd pacman -Sy --noconfirm ;;
        alpine) run_cmd apk update ;;
        suse)   run_cmd zypper --non-interactive refresh ;;
        *)      log_warn "未知发行版家族，跳过软件源刷新"; return 1 ;;
    esac
}

pkg_install() {
    (($#)) || return 0
    case "$DISTRO_FAMILY" in
        debian) run_cmd apt-get install -y --no-install-recommends "$@" ;;
        rhel)   run_cmd dnf install -y "$@" 2>/dev/null || run_cmd yum install -y "$@" ;;
        arch)   run_cmd pacman -S --noconfirm --needed "$@" ;;
        alpine) run_cmd apk add --no-cache "$@" ;;
        suse)   run_cmd zypper --non-interactive install "$@" ;;
        *)      log_err "不支持自动安装，请手动安装: $*"; return 1 ;;
    esac
}

# 确保命令存在，不存在则自动安装（需要时由模块调用）
ensure_pkg() {
    local cmd="$1"; shift
    have_cmd "$cmd" && return 0
    log_info "缺少 $cmd，正在安装依赖..."
    pkg_install "$@" || return 1
    have_cmd "$cmd"
}

# ------------------------------------------------------------
# 交互
# ------------------------------------------------------------
# confirm "是否继续?" [默认y|n]
confirm() {
    local prompt="$1" default="${2:-n}" reply hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf '%s%s%s %s ' "$C_BYELLOW" "$prompt" "$C_RESET" "$hint"
        ui_read reply || { printf '\n'; return 1; }
        reply="${reply:-$default}"
        case "$reply" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *) printf '%s输入无效，请输入 y 或 n%s\n' "$C_RED" "$C_RESET" ;;
        esac
    done
}

# ask "提示" [默认值]  -> 结果存入 REPLY
ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "$default" ]]; then
        printf '%s%s%s [%s]: ' "$C_BCYAN" "$prompt" "$C_RESET" "$default"
    else
        printf '%s%s%s: ' "$C_BCYAN" "$prompt" "$C_RESET"
    fi
    ui_read REPLY || { printf '\n'; return 1; }
    [[ -n "$default" ]] && REPLY="${REPLY:-$default}"
    return 0
}

# 任意键继续
pause() {
    local msg="${1:-按回车键继续...}"
    printf '\n%s%s%s' "$C_DIM" "$msg" "$C_RESET"
    ui_read _ || true
    printf '\n'
}


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 lib/ui.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# ui.sh - 界面渲染库
# 中英文混排宽度计算 / 边框 / 菜单 / 分页标题
# ============================================================

APP_NAME="${APP_NAME:-Linux 一键配置脚本}"
APP_VERSION="${APP_VERSION:-0.0.1}"

# 边框字符
BOX_TL='╔' BOX_TR='╗' BOX_BL='╚' BOX_BR='╝'
BOX_H='═'  BOX_V='║'  BOX_ML='╠' BOX_MR='╣'
BOX_L='─'  BOX_DOT='·'

UI_CHOICE=-1          # ui_menu 的返回值：选项下标(0起)，-1 表示返回/退出

# ------------------------------------------------------------
# 宽度计算：中日韩字符占 2 列，其余占 1 列
#
# 依赖 UTF-8 charmap —— C locale 下 ${#str} 和 ${str:i:1} 按字节走，
# 汉字会计成 3 列。启动时由 core.sh 的 _ensure_utf8_locale 兜住。
# ------------------------------------------------------------
_str_width() {
    local str="$1" width=0 i ch code n
    # 先去掉 ANSI 转义序列，避免颜色码被计入宽度
    str="$(printf '%s' "$str" | sed $'s/\033\\[[0-9;]*m//g')"
    n=${#str}
    for (( i=0; i<n; i++ )); do
        ch="${str:i:1}"
        printf -v code '%d' "'$ch" 2>/dev/null || code=0
        if (( code >= 0x1100 )) && (( \
               ( code >= 0x1100 && code <= 0x115F ) ||
               code == 0x2329 || code == 0x232A ||
               ( code >= 0x2E80 && code <= 0xA4CF && code != 0x303F ) ||
               ( code >= 0xAC00 && code <= 0xD7A3 ) ||
               ( code >= 0xF900 && code <= 0xFAFF ) ||
               ( code >= 0xFE10 && code <= 0xFE19 ) ||
               ( code >= 0xFE30 && code <= 0xFE6F ) ||
               ( code >= 0xFF00 && code <= 0xFF60 ) ||
               ( code >= 0xFFE0 && code <= 0xFFE6 ) ||
               ( code >= 0x1F300 && code <= 0x1F9FF ) ||
               ( code >= 0x20000 && code <= 0x3FFFD ) )); then
            width=$(( width + 2 ))
        else
            width=$(( width + 1 ))
        fi
    done
    printf '%s' "$width"
}

# 右填充空格到指定显示宽度
_pad_right() {
    local str="$1" target="$2" w
    w=$(_str_width "$str")
    printf '%s' "$str"
    (( w < target )) && printf '%*s' $(( target - w )) ''
    return 0
}

# 居中（左右各补空格）
_pad_center() {
    local str="$1" target="$2" w left right
    w=$(_str_width "$str")
    if (( w >= target )); then printf '%s' "$str"; return 0; fi
    left=$(( (target - w) / 2 ))
    right=$(( target - w - left ))
    printf '%*s%s%*s' "$left" '' "$str" "$right" ''
}

# ------------------------------------------------------------
# 终端信息
# ------------------------------------------------------------
term_width() {
    local w="${COLUMNS:-0}"
    (( w > 0 )) || w="$(tput cols 2>/dev/null || echo 80)"
    (( w >= 46 )) || w=46
    (( w <= 100 )) || w=100
    printf '%s' "$w"
}

ui_clear() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    else
        printf '\n'
    fi
}

# 清屏 + 横幅（不含分节标题，菜单页用这个）
ui_screen() {
    ui_clear
    ui_banner
}

# ------------------------------------------------------------
# 顶部横幅
# ------------------------------------------------------------
ui_banner() {
    local w inner title line1 line2
    w=$(term_width)
    inner=$(( w - 2 ))                      # 两个 ║ 各占 1 列，其余为内容宽度

    title="$APP_NAME  v$APP_VERSION"
    line1="${DISTRO_NAME}${DISTRO_VERSION:+ $DISTRO_VERSION}  |  $ARCH  |  ${DISTRO_FAMILY}"
    if is_root; then
        line2="权限: root ✓"
    else
        line2="权限: 普通用户 (${USER:-?}) — 部分功能不可用"
    fi

    printf '\n'
    printf '%s%s%s\n' "$C_BCYAN" "${BOX_TL}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_TR}" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_center "$C_BOLD$title$C_RESET" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s\n' "$C_BCYAN" "${BOX_ML}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_MR}" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_right " $line1" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_right " $line2" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s\n\n' "$C_BCYAN" "${BOX_BL}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_BR}" "$C_RESET"
}

_repeat() {
    local ch="$1" n="$2" out=''
    (( n > 0 )) || { printf ''; return 0; }
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
}

# ------------------------------------------------------------
# 页面 / 分节标题
# ------------------------------------------------------------
ui_title() {
    local text="$1" w line
    w=$(term_width)
    line="$(_repeat "$BOX_L" "$(( w - 2 ))")"
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    printf ' %s%s%s\n' "$C_BOLD$C_BBLUE" "$text" "$C_RESET"
    printf '%s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

ui_section() {
    printf '\n%s▎%s %s%s%s\n' "$C_BBLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
}

# 键值行。
# 不能用 printf 的 %-14s 补齐 —— 它按字符数算，中文是双宽字符，
# 「管理方式」(4字/8列) 和「当前 DNS」(6字/8列) 会被补成不同宽度。
# 必须按显示宽度补空格才对得齐。
ui_kv() {
    local k="$1" v="$2" width="${3:-14}"
    printf '  %s%s%s %s\n' "$C_DIM" "$(_pad_right "$k" "$width")" "$C_RESET" "$v"
}

# ------------------------------------------------------------
# 菜单
#   ui_menu <标题> <选项数组名> [返回项文案]
#   选项文案格式支持 "标题|说明"，说明以暗色显示
#   结果写入全局 UI_CHOICE (0 起下标)，选了返回项则为 -1
#
# 一律单列，一项一行。双列要在固定列宽里塞下中英混排的「标题 + 说明」，
# 说明稍长就会撑破列宽把右边一列顶歪（80 列终端下必然发生），
# 宽度算错时还会整体错位 —— 单列没有这个约束。
# ------------------------------------------------------------
ui_menu() {
    local title="$1" arr_name="$2" back_label="${3:-← 返回}"
    local -n _items="$arr_name"
    local count=${#_items[@]}
    local i label desc cell

    UI_CHOICE=-1
    [[ "$count" -gt 0 ]] || { log_warn "菜单无可用选项"; return 1; }

    ui_title "$title"

    for (( i=0; i<count; i++ )); do
        label="${_items[i]%%|*}"
        desc="${_items[i]#*|}"
        [[ "$desc" == "${_items[i]}" ]] && desc=""
        cell="$(printf '%s%2d)%s %s' "$C_BCYAN" $(( i + 1 )) "$C_RESET" "$label")"
        if [[ -n "$desc" ]]; then
            cell="$cell ${C_DIM}${desc}${C_RESET}"
        fi
        printf ' %s\n' "$cell"
    done

    printf ' %s%2d)%s %s%s%s\n\n' "$C_DIM" 0 "$C_RESET" "$C_DIM" "$back_label" "$C_RESET"

    local choice
    while true; do
        printf '%s请输入选项%s %s[0-%d]%s: ' "$C_BYELLOW" "$C_RESET" "$C_DIM" "$count" "$C_RESET"
        ui_read choice || { printf '\n'; UI_CHOICE=-1; return 0; }

        if [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]]; then
            UI_CHOICE=-1; return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            UI_CHOICE=$(( choice - 1 )); return 0
        fi
        printf '%s无效输入，请重新选择。%s\n' "$C_RED" "$C_RESET"
    done
}


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 lib/module.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# module.sh - 模块开发辅助
# 写功能模块时只需要用到这里的几个函数
# ============================================================

# module_begin <标题>  —— 进入一个功能页：清屏 + 横幅 + 分节标题
module_begin() {
    ui_screen
    ui_title "$1"
}

# module_end [提示语] —— 功能页结束，等待按键返回菜单
# 叶子动作（干完就回菜单的那种）结尾必须调用，否则输出会一闪而过
module_end() {
    pause "${1:-按回车键返回...}"
}

# ------------------------------------------------------------
# run_submenu <标题> <选项数组名> <函数数组名>
#
# 逐项对应：选项数组第 N 项 => 函数数组第 N 项
# 选项文案支持 "标题|说明" 形式，说明以灰色显示
#
# 约定：
#   - 叶子动作函数内部自己调用 module_end 暂停
#   - 嵌套子菜单函数内部直接再调 run_submenu，不要暂停
# ------------------------------------------------------------
run_submenu() {
    local title="$1" items_ref="$2" fns_ref="$3"
    local -n _items="$items_ref"
    local -n _fns="$fns_ref"
    local fn

    if (( ${#_items[@]} != ${#_fns[@]} )); then
        log_err "菜单配置错误：选项数(${#_items[@]}) 与 函数数(${#_fns[@]}) 不一致"
        pause
        return 1
    fi

    if (( ${#_items[@]} == 0 )); then
        module_begin "$title"
        log_warn "此分类下暂无功能。"
        module_end
        return 0
    fi

    while true; do
        ui_screen
        ui_menu "$title" "$items_ref" "← 返回上级"
        (( UI_CHOICE < 0 )) && return 0

        fn="${_fns[UI_CHOICE]}"
        local label="${_items[UI_CHOICE]%%|*}"

        module_begin "$label"
        if declare -F "$fn" >/dev/null; then
            "$fn"
            local rc=$?
            if (( rc != 0 )); then
                log_warn "「$label」返回码 $rc"
                module_end
            fi
        else
            log_err "功能尚未实现或函数未定义: $fn"
            module_end
        fi
    done
}

# ------------------------------------------------------------
# 占位函数：功能还没写时挂在这里，界面能跑通
# ------------------------------------------------------------
not_implemented() {
    log_warn "该功能尚未实现，等需求确认后再补。"
}


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 lib/registry.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# registry.sh - 模块注册表 & 主菜单
# ============================================================

MODULE_IDS=()
MODULE_TITLES=()
MODULE_DESCS=()
MODULE_HANDLERS=()
MODULE_FAMILIES=()      # 支持的发行版家族，空 = 全部支持

# ------------------------------------------------------------
# register_module <id> <标题> <处理函数> [说明] [适用家族]
#   id        唯一标识，kebab-case
#   标题      主菜单显示文案
#   处理函数  模块入口函数名
#   说明      主菜单上的灰色小字，可省略
#   适用家族  空格分隔，如 "debian rhel"；省略或空 = 所有发行版
#
# 在 modules/*.sh 顶层调用，载入时自动注册。
# ------------------------------------------------------------
register_module() {
    local id="$1" title="$2" handler="$3" desc="${4:-}" families="${5:-}"

    local i
    for (( i=0; i<${#MODULE_IDS[@]}; i++ )); do
        if [[ "${MODULE_IDS[i]}" == "$id" ]]; then
            log_warn "模块 id 重复，已忽略: $id"
            return 1
        fi
    done

    MODULE_IDS+=("$id")
    MODULE_TITLES+=("$title")
    MODULE_DESCS+=("$desc")
    MODULE_HANDLERS+=("$handler")
    MODULE_FAMILIES+=("$families")
}

# 当前发行版是否支持该模块
_module_supported() {
    local families="${MODULE_FAMILIES[$1]}"
    [[ -z "$families" ]] && return 0
    local f
    for f in $families; do
        [[ "$f" == "$DISTRO_FAMILY" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# 载入 modules/ 下所有模块（按文件名排序）
# ------------------------------------------------------------
load_modules() {
    local dir="$1" f n=0
    shopt -s nullglob
    for f in "$dir"/*.sh; do
        # shellcheck source=/dev/null
        if ! . "$f"; then
            log_err "模块载入失败: $(basename "$f")"
        else
            n=$(( n + 1 ))
        fi
    done
    shopt -u nullglob
    log_debug "已载入 $n 个模块文件，注册 ${#MODULE_IDS[@]} 个功能"
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------
build_main_menu() {
    MAIN_ITEMS=()
    MAIN_HANDLERS=()
    local i
    for (( i=0; i<${#MODULE_IDS[@]}; i++ )); do
        if _module_supported "$i"; then
            MAIN_ITEMS+=("${MODULE_TITLES[i]}|${MODULE_DESCS[i]}")
            MAIN_HANDLERS+=("${MODULE_HANDLERS[i]}")
        fi
    done
}

menu_main() {
    local fn rc
    while true; do
        ui_screen

        if (( ${#MAIN_ITEMS[@]} == 0 )); then
            log_warn "当前没有任何已注册的功能模块。"
            pause
            return 0
        fi

        ui_menu "主菜单" MAIN_ITEMS "退出脚本"
        (( UI_CHOICE < 0 )) && { ui_clear; printf '\n%s再见 👋%s\n\n' "$C_BCYAN" "$C_RESET"; return 0; }

        fn="${MAIN_HANDLERS[UI_CHOICE]}"
        if ! declare -F "$fn" >/dev/null; then
            log_err "处理函数未定义: $fn"
            pause
            continue
        fi

        ui_screen
        "$fn"
        rc=$?

        if (( rc != 0 )); then
            ui_screen
            log_warn "「${MAIN_ITEMS[UI_CHOICE]%%|*}」执行出错，返回码 $rc"
            pause
        fi
    done
}


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/01-system.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 系统信息
# id: system
#
# 全部只读，不做任何修改。
# ============================================================

# ------------------------------------------------------------
# 取数辅助
# ------------------------------------------------------------

# 运行时长（秒 → 「3天2小时15分」）
_uptime_human() {
    local s
    if [[ -r /proc/uptime ]]; then
        read -r s _ < /proc/uptime
        s="${s%%.*}"
    else
        return 1
    fi
    local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
    local out=''
    (( d > 0 )) && out="${d}天"
    (( h > 0 )) && out="${out}${h}小时"
    printf '%s%s分' "$out" "$m"
}

# 开机时刻
_boot_time() {
    if have_cmd uptime; then
        uptime -s 2>/dev/null && return
    fi
    local s
    [[ -r /proc/uptime ]] || return 1
    read -r s _ < /proc/uptime
    date -d "@$(( $(date +%s) - ${s%%.*} ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# 1/5/15 分钟负载
_load_avg() {
    local l1 l5 l15 _rest
    [[ -r /proc/loadavg ]] || return 1
    read -r l1 l5 l15 _rest < /proc/loadavg
    printf '%s / %s / %s' "$l1" "$l5" "$l15"
}

_virt_type() {
    if have_cmd systemd-detect-virt; then
        local v
        v="$(systemd-detect-virt 2>/dev/null)"
        [[ "$v" == "none" ]] && v="物理机"
        printf '%s' "${v:-未知}"
    else
        printf '未知'
    fi
}

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------
_cpu_model() {
    local m
    m="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
    [[ -z "$m" ]] && m="$(grep -m1 -E '^Hardware|^cpu model' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
    printf '%s' "${m:-未知}"
}

# 物理核数（按 physical id + core id 去重）/ 逻辑核数
_cpu_cores() {
    local logical physical
    logical="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$logical" || "$logical" == 0 ]] && logical="$(nproc 2>/dev/null || echo 0)"

    physical="$(awk -F: '
        /^physical id/ { gsub(/[^0-9]/, "", $2); pid = $2 }
        /^core id/     { gsub(/[^0-9]/, "", $2); seen[pid ":" $2] = 1 }
        END { n = 0; for (k in seen) n++; print n }
    ' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$physical" || "$physical" == 0 ]] && physical="$logical"

    # 输出「物理核 逻辑核」两个字段，供调用方 read 消费
    printf '%s %s\n' "$physical" "$logical"
}

# /proc/stat 第一行累计的 (总时间, 空闲时间)
_cpu_jiffies() {
    local line f total=0 idle=0 n=0
    [[ -r /proc/stat ]] || return 1
    read -r line < /proc/stat
    line="${line#cpu}"
    for f in $line; do
        total=$(( total + f ))
        n=$(( n + 1 ))
        # 第 4、5 列是 idle 与 iowait，都算「没干活」
        (( n == 4 || n == 5 )) && idle=$(( idle + f ))
    done
    # 结尾必须有换行：read 读到 EOF 而没见到分隔符时会返回非零
    printf '%s %s\n' "$total" "$idle"
}

# 采样一次算占用率（/proc/stat 是累计值，必须取两次差值）
_cpu_usage() {
    local t1 i1 t2 i2
    read -r t1 i1 < <(_cpu_jiffies) || return 1
    sleep 0.5
    read -r t2 i2 < <(_cpu_jiffies) || return 1

    local dt=$(( t2 - t1 )) di=$(( i2 - i1 ))
    (( dt <= 0 )) && { printf '?'; return; }
    awk -v dt="$dt" -v di="$di" 'BEGIN{ printf "%.1f", (1 - di / dt) * 100 }'
}

# ------------------------------------------------------------
# 内存
# ------------------------------------------------------------
# /proc/meminfo 单位是 kB
_meminfo() {
    awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo 2>/dev/null
}

_human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if      (k >= 1073741824) printf "%.1f TB", k / 1073741824;
        else if (k >= 1048576)    printf "%.1f GB", k / 1048576;
        else if (k >= 1024)       printf "%.0f MB", k / 1024;
        else                      printf "%.0f KB", k;
    }'
}

# ------------------------------------------------------------
# 颜色：按百分比
# ------------------------------------------------------------
_pct_color() {
    local p="${1%\%}"
    [[ "$p" =~ ^[0-9]+$ ]] || { printf '%s' "$C_RESET"; return; }
    if   (( p >= 90 )); then printf '%s' "$C_BRED"
    elif (( p >= 70 )); then printf '%s' "$C_BYELLOW"
    else                     printf '%s' "$C_GREEN"
    fi
}

# ============================================================
# 1) 系统概览
# ============================================================
sys_overview() {
    ui_section "主机"
    ui_kv "主机名" "${HOSTNAME_SHORT:-$(uname -n)}"
    ui_kv "运行时长" "$(_uptime_human 2>/dev/null || echo 未知)"
    ui_kv "启动时间" "$(_boot_time 2>/dev/null || echo 未知)"
    ui_kv "负载" "$(_load_avg 2>/dev/null || echo 未知)   (1/5/15 分钟)"

    ui_section "系统"
    ui_kv "发行版" "${DISTRO_NAME}${DISTRO_VERSION:+ $DISTRO_VERSION}"
    ui_kv "代号" "${DISTRO_CODENAME:-未知}"
    ui_kv "内核" "$KERNEL"
    ui_kv "架构" "$ARCH"
    ui_kv "虚拟化" "$(_virt_type)"

    ui_section "时间"
    ui_kv "系统时间" "$(date '+%Y-%m-%d %H:%M:%S')"
    ui_kv "时区" "$(date '+%Z %z')"

    module_end
}

# ============================================================
# 2) CPU 与内存
# ============================================================
sys_resource() {
    local physical logical
    read -r physical logical < <(_cpu_cores)

    ui_section "CPU"
    ui_kv "型号" "$(_cpu_model)"
    ui_kv "核心" "${physical} 物理 / ${logical} 逻辑"
    printf '  %s%s%s %s%%%s   %s(采样 0.5 秒)%s\n' \
        "$C_DIM" "$(_pad_right "占用" 14)" "$C_RESET" \
        "$(_cpu_usage 2>/dev/null || echo '?')" "$C_RESET" "$C_DIM" "$C_RESET"

    local total avail used pct
    total="$(_meminfo MemTotal)"
    avail="$(_meminfo MemAvailable)"
    if [[ -n "$total" && -n "$avail" ]]; then
        used=$(( total - avail ))
        pct=$(( total > 0 ? used * 100 / total : 0 ))
        ui_section "内存"
        ui_kv "总量" "$(_human_kb "$total")"
        printf '  %s%s%s %s%s%s (%s%%)\n' \
            "$C_DIM" "$(_pad_right "已用" 14)" "$C_RESET" \
            "$(_pct_color "$pct")" "$(_human_kb "$used")" "$C_RESET" "$pct"
        ui_kv "可用" "$(_human_kb "$avail")"
    else
        ui_section "内存"
        printf '  %s读不到 /proc/meminfo%s\n' "$C_DIM" "$C_RESET"
    fi

    local stotal sfree
    stotal="$(_meminfo SwapTotal)"
    sfree="$(_meminfo SwapFree)"
    ui_section "Swap"
    if [[ -z "$stotal" || "$stotal" == 0 ]]; then
        printf '  %s未启用%s\n' "$C_DIM" "$C_RESET"
    else
        local sused=$(( stotal - sfree ))
        local spct=$(( stotal > 0 ? sused * 100 / stotal : 0 ))
        ui_kv "总量" "$(_human_kb "$stotal")"
        printf '  %s%s%s %s%s%s (%s%%)\n' \
            "$C_DIM" "$(_pad_right "已用" 14)" "$C_RESET" \
            "$(_pct_color "$spct")" "$(_human_kb "$sused")" "$C_RESET" "$spct"
    fi

    module_end
}

# ============================================================
# 3) 磁盘空间
# ============================================================
# 只看真实文件系统，过滤 tmpfs/devtmpfs 这类内存盘
_DF_EXCLUDES=(-x tmpfs -x devtmpfs -x squashfs -x efivarfs -x ramfs -x overlay)

sys_disk() {
    local fs size used avail pct mnt

    ui_section "容量"
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "挂载点" 22)" "$(_pad_right "容量" 10)" \
            "$(_pad_right "已用" 10)" "$(_pad_right "可用" 10)" "使用率")" "$C_RESET"

    if ! df -hP "${_DF_EXCLUDES[@]}" >/dev/null 2>&1; then
        printf '  %sdf 不可用%s\n' "$C_DIM" "$C_RESET"
        module_end
        return 0
    fi

    while read -r fs size used avail pct mnt; do
        [[ "$fs" == "Filesystem" ]] && continue
        printf '  %s %s %s %s %s%s%s\n' \
            "$(_pad_right "$mnt" 22)" "$(_pad_right "$size" 10)" \
            "$(_pad_right "$used" 10)" "$(_pad_right "$avail" 10)" \
            "$(_pct_color "$pct")" "$(_pad_right "$pct" 5)" "$C_RESET"
    done < <(df -hP "${_DF_EXCLUDES[@]}" 2>/dev/null)

    ui_section "inode"
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "挂载点" 22)" "$(_pad_right "总量" 10)" \
            "$(_pad_right "已用" 10)" "$(_pad_right "可用" 10)" "使用率")" "$C_RESET"

    while read -r fs total used free pct mnt; do
        [[ "$fs" == "Filesystem" ]] && continue
        printf '  %s %s %s %s %s%s%s\n' \
            "$(_pad_right "$mnt" 22)" "$(_pad_right "$total" 10)" \
            "$(_pad_right "$used" 10)" "$(_pad_right "$free" 10)" \
            "$(_pct_color "$pct")" "$(_pad_right "$pct" 5)" "$C_RESET"
    done < <(df -iP "${_DF_EXCLUDES[@]}" 2>/dev/null)

    printf '\n  %s已过滤 tmpfs / devtmpfs / overlay 等非真实文件系统%s\n' "$C_DIM" "$C_RESET"
    module_end
}

# ============================================================
# 4) 网络接口
# ============================================================
sys_network_iface() {
    local d dev addrs

    ui_section "网卡"
    if ! have_cmd ip; then
        ui_kv "IP 地址" "$(hostname -I 2>/dev/null || echo 未知)"
        printf '  %s未安装 iproute2，无法列出各网卡明细%s\n' "$C_DIM" "$C_RESET"
    else
        for d in /sys/class/net/*; do
            [[ -e "$d" ]] || continue
            dev="$(basename "$d")"

            # 看 flags 的 IFF_UP 位，不看 operstate ——
            # 回环口 lo 的 operstate 恒为 "unknown"，用它判断会误显示成未知状态
            local flags state_colored
            flags="$(cat "$d/flags" 2>/dev/null || echo 0)"
            if (( flags & 1 )); then
                state_colored="${C_GREEN}up${C_RESET}"
            else
                state_colored="${C_DIM}down${C_RESET}"
            fi

            addrs="$(ip -o addr show dev "$dev" 2>/dev/null \
                     | awk '{ print $3 " " $4 }' | tr '\n' ' ')"
            addrs="${addrs% }"
            [[ -z "$addrs" ]] && addrs="${C_DIM}(无地址)${C_RESET}"

            printf '  %s%s%s %s  %s\n' \
                "$C_BCYAN" "$(_pad_right "$dev" 14)" "$C_RESET" "$state_colored" "$addrs"
        done
    fi

    ui_section "默认路由"
    if have_cmd ip; then
        local routes
        routes="$(ip route show default 2>/dev/null)"
        if [[ -n "$routes" ]]; then
            printf '%s\n' "$routes" | while IFS= read -r r; do
                printf '  %s\n' "$r"
            done
        else
            printf '  %s无默认路由%s\n' "$C_DIM" "$C_RESET"
        fi
    else
        printf '  %s需要 iproute2%s\n' "$C_DIM" "$C_RESET"
    fi

    ui_section "DNS"
    # 就地取默认值，不依赖其它模块定义的 RESOLV_CONF ——
    # 模块之间不该互相依赖，单独加载本模块时那个变量是空的
    local resolv="${RESOLV_CONF:-/etc/resolv.conf}"
    local ns
    ns="$(grep -E '^\s*nameserver\s+' "$resolv" 2>/dev/null | awk '{print $2}')"
    if [[ -n "$ns" ]]; then
        printf '%s\n' "$ns" | while IFS= read -r s; do printf '  %s\n' "$s"; done
        if [[ -L "$resolv" ]]; then
            printf '  %s%s → %s%s\n' "$C_DIM" "$resolv" "$(readlink -f "$resolv" 2>/dev/null)" "$C_RESET"
        fi
    else
        printf '  %s未配置%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n  %s公网 IP 请直接看网卡地址；本功能不会发起任何外部请求。%s\n' "$C_DIM" "$C_RESET"
    module_end
}

# ---- 模块入口 ----
menu_system() {
    local items=(
        "系统概览|主机名 / 发行版 / 内核 / 运行时长"
        "CPU 内存|型号 / 核心数 / 占用 / Swap"
        "磁盘空间|分区容量与 inode 使用率"
        "网络接口|网卡 / IP / 网关 / DNS"
    )
    local fns=(sys_overview sys_resource sys_disk sys_network_iface)
    run_submenu "系统信息" items fns
}

register_module "system" "系统信息" "menu_system" "查看系统状态"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/02-update.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 系统更新
# id: update
# ============================================================

# ------------------------------------------------------------
# Debian 镜像源定义（统一走 http）
# 三个数组下标一一对应
# ------------------------------------------------------------
MIRROR_NAMES=(
    "Debian 官方源"
    "中科大 USTC"
    "清华 TUNA"
)
MIRROR_DEB=(
    "http://deb.debian.org/debian"
    "http://mirrors.ustc.edu.cn/debian"
    "http://mirrors.tuna.tsinghua.edu.cn/debian"
)
MIRROR_SEC=(
    "http://deb.debian.org/debian-security"
    "http://mirrors.ustc.edu.cn/debian-security"
    "http://mirrors.tuna.tsinghua.edu.cn/debian-security"
)

# apt 配置目录。留出变量是为了能在 chroot / 容器 / 测试里改指向
APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt}"
APT_KEYRING="${APT_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
DEBIAN_SOURCES_FILE="$APT_CONF_DIR/sources.list.d/debian.sources"
DEBIAN_SOURCES_LIST="$APT_CONF_DIR/sources.list"

# 组件列表（Debian 12+ 的 non-free-firmware 必须带上，否则装不了固件）
DEB_COMPONENTS="main contrib non-free non-free-firmware"

# ------------------------------------------------------------
# 确定系统代号（trixie / bookworm / ...）
# ------------------------------------------------------------
_debian_codename() {
    local c="${DISTRO_CODENAME:-}"

    if [[ -z "$c" ]] && have_cmd lsb_release; then
        c="$(lsb_release -sc 2>/dev/null)"
    fi

    # 兜底：从现有源文件里推断（取第一个 Suite，去掉 -updates/-security 等后缀）
    if [[ -z "$c" ]]; then
        local f
        while IFS= read -r f; do
            c="$(grep -hE '^(deb |Suites:)' "$f" 2>/dev/null | head -1 \
                 | sed -E 's/^deb .* ([a-z]+)(-security|-updates|-backports)? .*/\1/; s/^Suites:[[:space:]]*//; s/[[:space:]].*//')"
            [[ -n "$c" ]] && break
        done < <(_list_debian_source_files)
    fi

    printf '%s' "$c"
}

# ------------------------------------------------------------
# 识别「Debian 镜像源文件」—— 这是删除范围的判定依据
#
# 只认 URI 路径直接挂在 /debian 或 /debian-security 下的源，
# 因此下面这些第三方源会被正确放过：
#   https://download.docker.com/linux/debian   (路径是 /linux/debian)
#   https://packagecloud.io/ookla/.../debian   (路径不以 /debian 开头)
#   https://cli.github.com/packages            (跟 debian 无关)
# ------------------------------------------------------------
_is_debian_mirror_file() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
        | grep -qE '://[^/[:space:]]+/debian(-security)?([/[:space:]]|$)'
}

# 列出所有需要删除的 Debian 镜像源文件
_list_debian_source_files() {
    local f

    if [[ -e "$DEBIAN_SOURCES_LIST" ]]; then
        # 是镜像源，或者干脆是个空壳（没有任何生效行）都一并清掉
        if [[ ! -s "$DEBIAN_SOURCES_LIST" ]] \
           || ! grep -qvE '^[[:space:]]*(#|$)' "$DEBIAN_SOURCES_LIST" 2>/dev/null \
           || _is_debian_mirror_file "$DEBIAN_SOURCES_LIST"; then
            printf '%s\n' "$DEBIAN_SOURCES_LIST"
        fi
    fi

    shopt -s nullglob
    for f in "$APT_CONF_DIR"/sources.list.d/*.list "$APT_CONF_DIR"/sources.list.d/*.sources; do
        _is_debian_mirror_file "$f" && printf '%s\n' "$f"
    done
    shopt -u nullglob
}

# ------------------------------------------------------------
# 生成 debian.sources 内容
# ------------------------------------------------------------
_render_debian_sources() {
    local idx="$1" codename="$2"
    local deb="${MIRROR_DEB[idx]}" sec="${MIRROR_SEC[idx]}"
    local suites="$codename $codename-updates $codename-backports"
    local sec_suite="$codename-security"

    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$deb" "$suites" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$deb" "$suites" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$sec" "$sec_suite" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
        "$sec" "$sec_suite" "$DEB_COMPONENTS" "$APT_KEYRING"
}

# ------------------------------------------------------------
# 在沙箱里试抓新源，确认可用后才动真格
#
# 这里有几个 apt 的坑，每一条踩过都会让验证变成「验证空气」：
#   1) 候选文件必须放进一个目录、由 Dir::Etc::sourceparts 指过去。
#      Dir::Etc::sourcelist 只按一行式 .list 解析，喂 deb822 内容会直接报
#      "Type 'Types:' is not known"，根本走不到网络。
#   2) sourceparts 与 sourcelist 都要隔离掉系统现有的源，否则验证的是
#      系统原来的源，不是我们要换的这个。
#   3) --error-on=any 必须加。apt 默认把拉取失败当警告，退出码仍是 0。
#   4) 必须出现 Get:/Hit: 行。apt 空跑（一个源都没读到）同样返回 0。
#
# 全程只写临时目录，不碰 /var/lib/apt/lists。
# ------------------------------------------------------------
_validate_sources() {
    local candidate="$1"
    local tmp out rc

    if [[ "$candidate" != /* ]]; then
        printf '内部错误: 待验证的源文件必须用绝对路径\n'
        return 1
    fi

    tmp="$(mktemp -d)"
    mkdir -p "$tmp/parts" "$tmp/lists/partial"
    # 文件名固定：apt 从目录里按 *.sources 读取，名字本身不影响解析
    cp "$candidate" "$tmp/parts/debian.sources"

    out="$(apt-get update \
        -o Dir::Etc::sourcelist="-" \
        -o Dir::Etc::sourceparts="$tmp/parts" \
        -o Dir::State::Lists="$tmp/lists" \
        -o APT::Get::List-Cleanup=0 \
        -o Acquire::http::Timeout=15 \
        -o Acquire::Retries=1 \
        --error-on=any 2>&1)"
    rc=$?
    rm -rf "$tmp"

    if (( rc != 0 )); then
        printf '%s\n' "$out"
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qE '^(Get|Hit):'; then
        printf '%s\n' "$out"
        printf '没有任何仓库被实际拉取，无法确认源可用\n'
        return 1
    fi
    if printf '%s\n' "$out" | grep -qE '^Err'; then
        printf '%s\n' "$out"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
deb_mirror_switch() {
    # 只支持 Debian 本体：Ubuntu 等衍生版包结构不同，套用会炸
    if [[ "${DISTRO_ID:-}" != "debian" ]]; then
        module_begin "更换镜像源"
        log_err "此功能仅支持 Debian，当前系统是 $DISTRO_NAME。"
        log_info "衍生版（Ubuntu 等）的仓库结构与 Debian 不同，套用会破坏 apt。"
        module_end
        return 1
    fi

    require_root

    local codename
    codename="$(_debian_codename)"
    if [[ -z "$codename" ]]; then
        module_begin "更换镜像源"
        log_err "无法确定系统代号（codename），已中止。"
        log_info "可手动确认 /etc/os-release 里的 VERSION_CODENAME。"
        module_end
        return 1
    fi

    # ---- 选镜像 ----
    local items=() i
    for (( i=0; i<${#MIRROR_NAMES[@]}; i++ )); do
        items+=("${MIRROR_NAMES[i]}|${MIRROR_DEB[i]}")
    done

    module_begin "更换镜像源"
    ui_kv "系统" "$DISTRO_NAME $DISTRO_VERSION"
    ui_kv "代号" "$codename"
    ui_kv "目标文件" "$DEBIAN_SOURCES_FILE"
    ui_menu "选择镜像源" items "← 放弃更换"
    (( UI_CHOICE < 0 )) && return 0
    local idx=$UI_CHOICE

    # ---- 列出待删除文件 ----
    local victims=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && victims+=("$f")
    done < <(_list_debian_source_files)

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "镜像源"
    ui_kv "已选" "${MIRROR_NAMES[idx]}"
    ui_kv "主仓库" "${MIRROR_DEB[idx]}"
    ui_kv "安全仓库" "${MIRROR_SEC[idx]}"

    ui_section "将要删除"
    if (( ${#victims[@]} == 0 )); then
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    else
        for f in "${victims[@]}"; do
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$f"
        done
    fi
    printf '  %s未列出的文件（docker / gh / pgdg 等第三方源）一律保留%s\n' "$C_DIM" "$C_RESET"

    ui_section "将要写入 $DEBIAN_SOURCES_FILE"
    _render_debian_sources "$idx" "$codename" | sed 's/^/  /'

    printf '\n'
    log_warn "此操作不可撤销，且不会备份原文件。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 先验证，通过了才动真格 ----
    module_begin "验证新镜像源"
    log_info "正在沙箱中试抓 ${MIRROR_NAMES[idx]} ..."

    local candidate rc=0
    candidate="$(mktemp /tmp/debian.sources.XXXXXX)"
    _render_debian_sources "$idx" "$codename" >"$candidate"

    if _validate_sources "$candidate"; then
        log_ok "镜像源可用，验证通过。"
    else
        rc=1
        log_err "新镜像源验证失败，未修改任何文件。"
        log_info "原源配置保持不变，系统仍可正常使用。"
    fi

    if (( rc != 0 )); then
        rm -f "$candidate"
        module_end
        return 1
    fi

    # ---- 执行 ----
    ui_section "执行变更"
    local f
    for f in "${victims[@]}"; do
        if rm -f "$f"; then
            log_ok "已删除 $f"
        else
            log_err "删除失败: $f"
            rc=1
        fi
    done

    mkdir -p "$(dirname "$DEBIAN_SOURCES_FILE")"
    if install -m 0644 "$candidate" "$DEBIAN_SOURCES_FILE"; then
        log_ok "已写入 $DEBIAN_SOURCES_FILE"
    else
        log_err "写入失败: $DEBIAN_SOURCES_FILE"
        rc=1
    fi
    rm -f "$candidate"

    if (( rc != 0 )); then
        log_err "变更未完全成功，请检查上面的错误。"
        module_end
        return 1
    fi

    # ---- 刷新 ----
    ui_section "刷新软件源"
    if pkg_refresh; then
        log_ok "软件源已切换到「${MIRROR_NAMES[idx]}」。"
    else
        log_warn "apt-get update 失败，请手动检查 $DEBIAN_SOURCES_FILE"
    fi

    module_end
}

# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
upd_refresh() {
    not_implemented          # TODO: 刷新软件源缓存
    module_end
}

upd_upgrade() {
    not_implemented          # TODO: 升级已安装软件包
    module_end
}

upd_clean() {
    not_implemented          # TODO: 清理无用依赖与缓存
    module_end
}

menu_update() {
    local items=(
        "更换镜像源|Debian 官方 / 中科大 / 清华"
        "刷新缓存|update"
        "升级软件包|upgrade"
        "清理缓存|autoremove / clean"
    )
    local fns=(deb_mirror_switch upd_refresh upd_upgrade upd_clean)
    run_submenu "系统更新" items fns
}

register_module "update" "系统更新" "menu_update" "镜像源 / 升级 / 清理"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/03-tools.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 常用工具
# id: tools
#
# 一律使用各软件厂商的官方源，不走发行版自带仓库、不走第三方镜像。
# 厂商提供官方一键脚本的用脚本，没有的走官方 apt 源手动配置：
#   Docker     → get.docker.com 官方脚本
#   Speedtest  → packagecloud 官方脚本（Ookla 指定的方式）
#   gh         → cli.github.com 官方源
#   nginx 主线 → nginx.org 官方源
# ============================================================

APT_KEYRINGS_DIR="${APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
# nginx.org 官方文档用的是这个路径（不是 /etc/apt/keyrings）
NGINX_KEYRING="${NGINX_KEYRING:-/usr/share/keyrings/nginx-archive-keyring.gpg}"

# ------------------------------------------------------------
# 通用辅助
# ------------------------------------------------------------
_tool_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

_tool_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# 下载并安装 apt 签名密钥
#   $1 = URL
#   $2 = 目标路径
#   $3 = 传 "armor" 表示下载的是 ASCII 装甲公钥，需要 gpg --dearmor
#
# apt 的 signed-by 只认二进制 keyring，ASCII 装甲必须转换，
# 否则会报 "does not contain a valid OpenPGP public key"。
_apt_key_install() {
    local url="$1" dest="$2" armor="${3:-}"
    local tmp

    tmp="$(mktemp)"
    log_info "下载密钥: $url"
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
        log_err "密钥下载失败"
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_err "密钥内容为空"
        rm -f "$tmp"
        return 1
    fi

    mkdir -p "$(dirname "$dest")" || { rm -f "$tmp"; return 1; }

    if [[ "$armor" == "armor" ]]; then
        if ! gpg --dearmor <"$tmp" >"$dest" 2>/dev/null; then
            log_err "密钥格式转换失败，可能不是有效的 ASCII PGP 公钥"
            rm -f "$tmp" "$dest"
            return 1
        fi
    else
        install -m 0644 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    fi
    chmod 0644 "$dest" 2>/dev/null

    rm -f "$tmp"
    log_ok "密钥已安装: $dest"
    return 0
}

# 写入 apt 源文件
_apt_repo_install() {
    local file="$1" line="$2"
    mkdir -p "$(dirname "$file")" || return 1
    if ! printf '%s\n' "$line" >"$file"; then
        log_err "写入源文件失败: $file"
        return 1
    fi
    log_ok "源已添加: $file"
    return 0
}

# 按脚本自己声明的 shebang 选解释器。
#
# 不能一律用 sh：Debian 的 /bin/sh 是 dash，而厂商脚本基本都是 bash 脚本
# （packagecloud 的脚本第 60 行是 [[ ( -z "$os" ) && ( -z "$dist" ) ]]，
# dash 直接报 "Syntax error: word unexpected"）。厂商给出的安装命令也都是
# curl ... | sudo bash，跟着 shebang 走才和它们一致。
#
# 认不出 shebang、或解释器不在时退回 sh。
_script_interpreter() {
    local file="$1" line rest interp parts

    IFS= read -r line <"$file" 2>/dev/null || true
    [[ "$line" == '#!'* ]] || { printf 'sh'; return; }

    rest="${line#\#!}"
    rest="${rest#"${rest%%[![:space:]]*}"}"     # 去掉 #! 之后的前导空白
    read -ra parts <<<"$rest"
    interp="${parts[0]:-}"

    # #!/usr/bin/env bash → 取 env 后面的那个命令名
    if [[ "${interp##*/}" == "env" && ${#parts[@]} -gt 1 ]]; then
        interp="${parts[1]}"
    fi

    if [[ "$interp" == /* ]]; then
        [[ -x "$interp" ]] && { printf '%s' "$interp"; return; }
    elif [[ -n "$interp" ]] && have_cmd "$interp"; then
        printf '%s' "$interp"
        return
    fi

    printf 'sh'
}

# 下载并执行厂商提供的官方安装脚本。
# 先落盘再执行，而不是 curl | sh —— 这样能检查下载是否成功、
# 内容是否为空，执行失败也能拿到真实退出码。
_run_official_script() {
    local url="$1"
    local tmp rc=0 interp

    tmp="$(mktemp)"
    log_info "下载官方脚本: $url"
    if ! curl -fsSL --max-time 120 "$url" -o "$tmp"; then
        log_err "脚本下载失败"
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_err "脚本内容为空"
        rm -f "$tmp"
        return 1
    fi
    if ! head -c 64 "$tmp" | grep -qE '^#!|^#'; then
        log_err "下载的内容不像 shell 脚本，已中止"
        rm -f "$tmp"
        return 1
    fi

    interp="$(_script_interpreter "$tmp")"
    log_info "执行中（解释器 ${interp##*/}，输出可能较长）..."
    "$interp" "$tmp" || rc=$?
    rm -f "$tmp"

    if (( rc != 0 )); then
        log_err "官方脚本以退出码 $rc 结束"
        return 1
    fi
    return 0
}

# ============================================================
# Docker —— 官方一键脚本
# ============================================================
tools_docker() {
    require_root

    module_begin "安装 Docker"
    ui_kv "安装方式" "官方一键脚本"
    ui_kv "脚本地址" "https://get.docker.com"
    if _tool_installed docker-ce; then
        ui_kv "当前版本" "$(_tool_version docker-ce)"
    else
        ui_kv "当前版本" "未安装"
    fi

    ui_section "说明"
    printf '  %s该脚本会添加 Docker 官方源并安装：%s\n' "$C_DIM" "$C_RESET"
    printf '  %sdocker-ce / containerd.io / buildx / compose 插件%s\n' "$C_DIM" "$C_RESET"
    printf '\n'
    log_warn "Docker 官方脚本自述「not recommended for production environments」，"
    log_warn "生产环境更推荐手动配置官方源后安装。此处按你的要求使用一键脚本。"

    printf '\n'
    if ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    if _tool_installed docker-ce; then
        if ! confirm "已装版本 $(_tool_version docker-ce)，继续会执行升级。继续?" n; then
            log_info "已取消。"
            module_end
            return 0
        fi
    fi

    if ! _run_official_script "https://get.docker.com"; then
        log_err "Docker 安装失败。"
        log_info "可手动执行查看详情: curl -fsSL https://get.docker.com | sh"
        module_end
        return 1
    fi

    # 脚本在部分情况下只加源不装包，这里补一刀
    if ! _tool_installed docker-ce; then
        log_info "脚本未完成安装，尝试从官方源安装 ..."
        pkg_refresh || true
        pkg_install docker-ce docker-ce-cli containerd.io || true
    fi

    ui_section "验证"
    if have_cmd docker; then
        log_ok "已安装: $(docker --version 2>/dev/null)"
        if have_cmd systemctl && systemctl is-active --quiet docker 2>/dev/null; then
            log_ok "docker 服务运行中"
        else
            log_warn "docker 服务未运行，可执行: systemctl enable --now docker"
        fi
    else
        log_err "安装后未找到 docker 命令，请检查上面的输出。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# GitHub CLI (gh) —— 官方源
# ============================================================
tools_gh() {
    require_root

    local keyring="$APT_KEYRINGS_DIR/githubcli-archive-keyring.gpg"
    local list="$APT_SOURCES_DIR/github-cli.list"
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

    module_begin "安装 GitHub CLI"
    ui_kv "安装方式" "官方 apt 源"
    ui_kv "仓库" "https://cli.github.com/packages"
    ui_kv "密钥" "$keyring"
    if _tool_installed gh; then
        ui_kv "当前版本" "$(_tool_version gh)"
    else
        ui_kv "当前版本" "未安装"
    fi

    printf '\n'
    if _tool_installed gh && ! confirm "gh 已安装，继续会升级。继续?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi
    if ! _tool_installed gh && ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    _apt_key_install "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "$keyring" \
        || { module_end; return 1; }
    # 这个 key 是二进制格式，不需要 dearmor
    _apt_repo_install "$list" \
        "deb [arch=$arch signed-by=$keyring] https://cli.github.com/packages stable main" \
        || { module_end; return 1; }

    pkg_refresh || true
    if ! pkg_install gh; then
        log_err "gh 安装失败。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd gh; then
        log_ok "已安装: $(gh --version 2>/dev/null | head -1)"
    else
        log_err "安装后未找到 gh 命令。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# nginx 主线版 —— nginx.org 官方源
# ============================================================
tools_nginx() {
    require_root

    local keyring="$NGINX_KEYRING"
    local list="$APT_SOURCES_DIR/nginx.list"
    local codename="${DISTRO_CODENAME:-}"

    if [[ -z "$codename" ]] && have_cmd lsb_release; then
        codename="$(lsb_release -sc 2>/dev/null)"
    fi
    if [[ -z "$codename" ]]; then
        module_begin "安装 nginx 主线版"
        log_err "无法确定系统代号，已中止。"
        module_end
        return 1
    fi

    module_begin "安装 nginx 主线版"
    ui_kv "安装方式" "nginx.org 官方源"
    ui_kv "仓库" "http://nginx.org/packages/mainline/debian"
    ui_kv "系统代号" "$codename"
    ui_kv "密钥" "$keyring"

    if _tool_installed nginx; then
        ui_kv "当前版本" "$(_tool_version nginx)"
    else
        ui_kv "当前版本" "未安装"
    fi

    # nginx.org 的包名也叫 nginx，会顶掉发行版自带的那个，
    # 两者配置文件布局不同，直接覆盖容易留下不一致的配置。
    if _tool_installed nginx && ! _tool_version nginx | grep -q '~'; then
        printf '\n'
        log_warn "检测到已安装的可能是发行版自带的 nginx（版本 $(_tool_version nginx)）。"
        log_warn "nginx.org 的包会替换它，且配置目录布局不同。"
        log_info "更稳妥的做法是先备份并卸载: apt-get purge nginx nginx-common"
    fi

    printf '\n'
    if ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    # nginx.org 发布的是 ASCII 装甲公钥，必须 dearmor
    _apt_key_install "https://nginx.org/keys/nginx_signing.key" "$keyring" armor \
        || { module_end; return 1; }
    _apt_repo_install "$list" \
        "deb [signed-by=$keyring] http://nginx.org/packages/mainline/debian $codename nginx" \
        || { module_end; return 1; }

    pkg_refresh || true
    if ! pkg_install nginx; then
        log_err "nginx 安装失败。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd nginx; then
        log_ok "已安装: $(nginx -v 2>&1)"
        local ver
        ver="$(_tool_version nginx)"
        if [[ "$ver" == *"~"* ]]; then
            log_ok "来源确认: nginx.org 官方源（版本号含 ~${codename}）"
        else
            log_warn "版本号 $ver 不像 nginx.org 的包，请确认来源。"
        fi
    else
        log_err "安装后未找到 nginx 命令。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# Speedtest CLI —— Ookla 官方源
# ============================================================
tools_speedtest() {
    require_root

    local script_url="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"

    module_begin "安装 Speedtest CLI"
    ui_kv "安装方式" "官方源（packagecloud 脚本）"
    ui_kv "脚本地址" "$script_url"
    if _tool_installed speedtest; then
        ui_kv "当前版本" "$(_tool_version speedtest)"
    else
        ui_kv "当前版本" "未安装"
    fi

    ui_section "说明"
    printf '  %s该脚本仅添加 Ookla 官方源并安装签名密钥，%s\n' "$C_DIM" "$C_RESET"
    printf '  %s之后从这里安装 speedtest 包。%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if _tool_installed speedtest \
       && ! confirm "speedtest 已安装，继续会重新添加官方源并升级。继续?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi
    if ! _tool_installed speedtest && ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    if ! _run_official_script "$script_url"; then
        log_err "添加官方源失败。"
        module_end
        return 1
    fi

    pkg_refresh || true
    if ! pkg_install speedtest; then
        log_err "speedtest 安装失败。"
        log_info "注意：包名是 speedtest（Ookla 官方），不是 Debian 的 speedtest-cli。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd speedtest; then
        log_ok "已安装: $(speedtest --version 2>/dev/null | head -1)"
    else
        log_err "安装后未找到 speedtest 命令。"
        module_end
        return 1
    fi

    module_end
}

# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
tools_basic() {
    not_implemented          # TODO: 批量安装常用命令行工具
    module_end
}

tools_shell() {
    not_implemented          # TODO: zsh / oh-my-zsh / 美化
    module_end
}

tools_bt() {
    not_implemented          # TODO: 面板 / 运维面板安装
    module_end
}

menu_tools() {
    local items=(
        "Docker|官方一键脚本，含 compose 插件"
        "GitHub CLI|官方源安装 gh"
        "nginx 主线版|nginx.org 官方源"
        "Speedtest|Ookla 官方源"
        "基础工具|vim curl wget git htop 等"
        "Shell 环境|zsh / oh-my-zsh"
        "运维面板|常用面板一键安装"
    )
    local fns=(tools_docker tools_gh tools_nginx tools_speedtest tools_basic tools_shell tools_bt)
    run_submenu "常用工具" items fns
}

register_module "tools" "常用工具" "menu_tools" "Docker / gh / nginx / 测速"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/04-network.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 网络设置
# id: network
# ============================================================

# ------------------------------------------------------------
# DNS 服务商（主 + 备用）
# 三家国内两家国外，每个都配了同厂备用地址 —— 只写一个
# nameserver 等于单点故障，主挂了就整体不可用。
# ------------------------------------------------------------
DNS_NAMES=(
    "Cloudflare"
    "Google"
    "DNSPod 腾讯"
    "AliDNS 阿里"
)
DNS_IPS=(
    "1.1.1.1 1.0.0.1"
    "8.8.8.8 8.8.4.4"
    "119.29.29.29 119.28.28.28"
    "223.5.5.5 223.6.6.6"
)
DNS_NOTES=(
    "境外 · 隐私优先"
    "境外 · 老牌稳定"
    "境内 · 腾讯"
    "境内 · 阿里"
)

RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
# 普通 DNS 与 DoT 共用同一个 drop-in：两者都在配置 systemd-resolved，
# 拆成两个文件的话，切回普通 DNS 时旧的 DoT 文件还在，DNSOverTLS=yes
# 会继续生效 —— 以为关了其实没关。
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-linux-toolkit.conf"
DNS_PROBE_NAME="${DNS_PROBE_NAME:-example.com}"

# ============================================================
# 探测
# ============================================================

# 直接问指定 DNS 服务器能否解析
#   0 = 可用   1 = 不可用   2 = 系统上没有查询工具，无法判断
#
# 这里对 nslookup 同时看退出码和输出文本：nslookup 有 bind / busybox 等多个
# 实现，退出码语义不完全一致，而失败信息（timed out / SERVFAIL 等）一定会
# 出现在输出里。以输出为准更稳，不依赖某个实现的具体返回码。
_dns_probe_server() {
    local server="$1" out rc

    if have_cmd dig; then
        # dig +short 成功时直接打印解析结果，失败时为空
        out="$(dig +short +time=3 +tries=1 "@$server" "$DNS_PROBE_NAME" A 2>&1)" && rc=0 || rc=$?
        (( rc == 0 )) && [[ -n "$out" ]] && return 0
        return 1
    fi

    if have_cmd host; then
        out="$(host -W 3 "$DNS_PROBE_NAME" "$server" 2>&1)" && rc=0 || rc=$?
        (( rc == 0 )) && printf '%s' "$out" | grep -q 'has address' && return 0
        return 1
    fi

    if have_cmd nslookup; then
        out="$(nslookup "$DNS_PROBE_NAME" "$server" 2>&1)"
    elif have_cmd busybox; then
        out="$(busybox nslookup "$DNS_PROBE_NAME" "$server" 2>&1)"
    else
        return 2
    fi

    if printf '%s' "$out" | grep -qiE 'timed out|no servers could be reached|SERVFAIL|REFUSED|NXDOMAIN|can.t find'; then
        return 1
    fi
    printf '%s' "$out" | grep -q 'Non-authoritative answer' && return 0
    return 1
}

# 系统解析器（走 /etc/resolv.conf 那条链路）能否解析
_dns_probe_system() {
    getent hosts "$DNS_PROBE_NAME" >/dev/null 2>&1
}

# ------------------------------------------------------------
# 判断谁在管 DNS 解析
#
# 关键不是「装了哪个软件」，而是「/etc/resolv.conf 实际指向什么」——
# 那才是解析器真正读的东西。
#   resolved   → 指向 systemd-resolved 的 stub，得配 resolved
#   resolvconf → 指向 resolvconf 的运行时文件，直接写会被覆盖
#   direct     → 普通文件，自己就是权威，直接写
# ------------------------------------------------------------
_dns_mechanism() {
    if [[ -L "$RESOLV_CONF" ]]; then
        local target
        target="$(readlink -f "$RESOLV_CONF" 2>/dev/null || true)"
        case "$target" in
            */systemd/resolve/*) printf 'resolved'; return ;;
            */resolvconf/*)      printf 'resolvconf'; return ;;
        esac
    fi
    printf 'direct'
}

_dns_mechanism_label() {
    case "$1" in
        resolved)   printf 'systemd-resolved（写 drop-in 配置）' ;;
        resolvconf) printf 'resolvconf（通过 resolvconf 命令）' ;;
        *)          printf '直接写 %s' "$RESOLV_CONF" ;;
    esac
}

# 当前生效的 nameserver，用于预览和回滚
_dns_current() {
    grep -E '^\s*nameserver\s+' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' '
}

# ============================================================
# 应用 / 回滚
# ============================================================

# 把配置写进去。$1 = 机制，$2 = "ip ip"
_dns_apply() {
    local mech="$1" ips="$2" ip

    case "$mech" in
        resolved)
            mkdir -p "$(dirname "$RESOLVED_DROPIN")"
            {
                printf '# 由 Linux 一键配置脚本生成\n'
                printf '[Resolve]\n'
                printf 'DNS=%s\n' "$ips"
            } >"$RESOLVED_DROPIN" || return 1

            if have_cmd systemctl; then
                systemctl restart systemd-resolved 2>/dev/null || {
                    log_err "重启 systemd-resolved 失败"
                    return 1
                }
                # 给它一点时间把 stub 配置铺开
                local i
                for (( i=0; i<10; i++ )); do
                    _dns_probe_system && break
                    sleep 0.3
                done
            fi
            ;;

        resolvconf)
            # 走 resolvconf 注册，直接写 /etc/resolv.conf 会被它覆盖
            local records=''
            for ip in $ips; do
                records+="nameserver $ip"$'\n'
            done
            if have_cmd resolvconf; then
                printf '%s' "$records" | resolvconf -a "linux-toolkit" 2>/dev/null || return 1
            else
                log_err "resolv.conf 由 resolvconf 管理，但找不到 resolvconf 命令"
                return 1
            fi
            ;;

        *)
            # 先解析符号链接，避免把链接本身覆盖掉
            local real="$RESOLV_CONF"
            [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
            {
                printf '# 由 Linux 一键配置脚本生成\n'
                for ip in $ips; do
                    printf 'nameserver %s\n' "$ip"
                done
            } >"$real" || return 1
            ;;
    esac
    return 0
}

# 回滚。调用前先用 _dns_snapshot 存过现场
_dns_rollback() {
    local mech="$1"

    case "$mech" in
        resolved)
            if [[ -n "${DNS_SNAP_DROPIN_EXISTED:-}" ]]; then
                printf '%s' "${DNS_SNAP_DROPIN_CONTENT:-}" >"$RESOLVED_DROPIN"
            else
                rm -f "$RESOLVED_DROPIN"
            fi
            if have_cmd systemctl; then
                systemctl restart systemd-resolved 2>/dev/null || true
            fi
            ;;

        resolvconf)
            if have_cmd resolvconf; then
                resolvconf -d "linux-toolkit" 2>/dev/null || true
            fi
            ;;

        *)
            local real="$RESOLV_CONF"
            [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
            printf '%s' "${DNS_SNAP_RESOLV:-}" >"$real" 2>/dev/null
            ;;
    esac
}

# $(cat) 会吃掉结尾换行，用哨兵字符保住原样，还原前再摘掉
# 记录现场（存内存，不落备份文件）
_dns_snapshot() {
    local mech="$1"
    if [[ -e "$RESOLVED_DROPIN" ]]; then
        DNS_SNAP_DROPIN_EXISTED=1
        DNS_SNAP_DROPIN_CONTENT="$(cat "$RESOLVED_DROPIN" 2>/dev/null; printf x)"
        DNS_SNAP_DROPIN_CONTENT="${DNS_SNAP_DROPIN_CONTENT%x}"
    else
        DNS_SNAP_DROPIN_EXISTED=''
        DNS_SNAP_DROPIN_CONTENT=''
    fi
    DNS_SNAP_RESOLV="$(cat "$RESOLV_CONF" 2>/dev/null || true; printf x)"
    DNS_SNAP_RESOLV="${DNS_SNAP_RESOLV%x}"
}

# ============================================================
# 主流程
# ============================================================
net_dns() {
    require_root

    local mech
    mech="$(_dns_mechanism)"

    local items=() i
    for (( i=0; i<${#DNS_NAMES[@]}; i++ )); do
        items+=("${DNS_NAMES[i]}|${DNS_NOTES[i]}")
    done

    module_begin "DNS 设置"
    ui_kv "管理方式" "$(_dns_mechanism_label "$mech")"
    ui_kv "当前 DNS" "$(_dns_current)"
    ui_menu "选择 DNS" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0
    local idx=$UI_CHOICE

    local ips="${DNS_IPS[idx]}"

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将使用的 DNS"
    local ip
    for ip in $ips; do
        printf '  %s%s%s\n' "$C_BCYAN" "$ip" "$C_RESET"
    done
    ui_kv "服务商" "${DNS_NAMES[idx]}"

    ui_section "变更前"
    ui_kv "当前 DNS" "$(_dns_current)"
    ui_kv "写入目标" "$(_dns_mechanism_label "$mech")"

    printf '\n'
    if ! confirm "确认修改?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 改之前先确认这些 DNS 服务器是活的 ----
    module_begin "验证 DNS 服务器"
    local unreachable=() need_probe=0 probe_rc=0
    for ip in $ips; do
        _dns_probe_server "$ip"; probe_rc=$?
        case "$probe_rc" in
            0) log_ok "$ip 响应正常" ;;
            2) need_probe=1; break ;;
            *) log_warn "$ip 无响应"; unreachable+=("$ip") ;;
        esac
    done

    if (( need_probe )); then
        log_info "系统未装 dig/nslookup/host，跳过直连探测，改由应用后验证。"
    elif (( ${#unreachable[@]} > 0 )); then
        log_warn "以下 DNS 无响应: ${unreachable[*]}"
        if ! confirm "仍要继续吗?" n; then
            log_info "已取消，未做任何修改。"
            module_end
            return 0
        fi
    fi

    # ---- 应用 ----
    module_begin "应用配置"
    _dns_snapshot "$mech"

    if ! _dns_apply "$mech" "$ips"; then
        log_err "写入配置失败，正在回滚..."
        _dns_rollback "$mech"
        module_end
        return 1
    fi
    log_ok "配置已写入"

    # ---- 验证：解析不通就自动回滚 ----
    ui_section "验证解析"
    local ok=0
    for (( i=0; i<8; i++ )); do
        if _dns_probe_system; then ok=1; break; fi
        sleep 0.5
    done

    if (( ok )); then
        log_ok "解析正常，DNS 已切换到「${DNS_NAMES[idx]}」。"
        if (( ${#unreachable[@]} > 0 )); then
            log_warn "注意: ${unreachable[*]} 之前无响应，建议观察一段时间。"
        fi
    else
        log_err "切换后无法解析域名，正在自动回滚..."
        _dns_rollback "$mech"
        if _dns_probe_system; then
            log_ok "已恢复到变更前的配置，系统解析正常。"
        else
            log_err "回滚后仍无法解析，请手动检查 $RESOLV_CONF"
        fi
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# DoT（DNS over TLS，853 端口）
#
# 注意 DoT 端点未必等于普通 DNS 的地址：DNSPod 的普通 DNS 是
# 119.29.29.29，但 DoT 只在 dot.pub（1.12.12.12 / 120.53.53.53）上提供。
# 所以这里单列一张表，下标与 DNS_NAMES 对应。
# ============================================================
DOT_IPS=(
    "1.1.1.1 1.0.0.1"
    "8.8.8.8 8.8.4.4"
    "1.12.12.12 120.53.53.53"
    "223.5.5.5 223.6.6.6"
)
DOT_SNI=(
    "cloudflare-dns.com"
    "dns.google"
    "dot.pub"
    "dns.alidns.com"
)


# ------------------------------------------------------------
# 检查 DoT 端点的 853 端口
#   0 = 可用   1 = 不可用   2 = 无 openssl，无法检查
#
# 只测 TCP 连通不够 —— 那只能证明端口开着。这里做完整 TLS 握手并
# 用 -verify_hostname 校验证书主机名，否则「加密 DNS」可能是连着
# 一个冒名服务器，加密毫无意义。
# ------------------------------------------------------------
_dot_check() {
    local ip="$1" sni="$2"
    have_cmd openssl || return 2
    timeout 12 openssl s_client \
        -connect "$ip:853" \
        -servername "$sni" \
        -verify_hostname "$sni" \
        -verify_return_error </dev/null 2>&1 \
        | grep -q 'Verify return code: 0 (ok)'
}

# ------------------------------------------------------------
# 后端：只用 systemd-resolved
#
# 比过 stubby：后者要装 7 个包共 3.4MB，还多一个常驻守护进程；
# systemd-resolved 只多装 1 个包（916KB，依赖 systemd/libc/libssl/dbus
# 基本都已存在），配置就是一个 drop-in，诊断靠 resolvectl。
#
# 代价是它必须在 systemd 上跑。非 systemd 系统（Alpine / Devuan / 部分
# 容器）DoT 直接不可用 —— 这里明确告知，不做静默降级。
# ------------------------------------------------------------
_dot_backend() {
    if [[ ! -d /run/systemd/system ]] || ! have_cmd systemctl; then
        printf 'unsupported'
    elif have_cmd resolvectl; then
        printf 'resolved'          # 已装，零安装
    else
        printf 'resolved-install'  # 没装但能装
    fi
}

_dot_backend_label() {
    case "$1" in
        resolved)         printf 'systemd-resolved（已安装，零安装）' ;;
        resolved-install) printf 'systemd-resolved（将自动安装，约 916KB）' ;;
        *)                printf '不可用' ;;
    esac
}

# 当前是否已启用 DoT
_dot_is_enabled() {
    [[ -s "$RESOLVED_DROPIN" ]] \
        && grep -qE '^\s*DNSOverTLS\s*=\s*yes' "$RESOLVED_DROPIN" 2>/dev/null
}

# ------------------------------------------------------------
# 应用
# ------------------------------------------------------------
_dot_apply_resolved() {
    local idx="$1" ip dns_list=''

    # Debian 默认不装 systemd-resolved，需要时补上
    if ! have_cmd resolvectl; then
        log_info "安装 systemd-resolved ..."
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install systemd-resolved; then
            log_err "systemd-resolved 安装失败"
            return 1
        fi
        if ! have_cmd resolvectl; then
            log_err "安装后仍找不到 resolvectl，无法继续"
            return 1
        fi
        DOT_INSTALLED_RESOLVED=1
    fi

    for ip in ${DOT_IPS[idx]}; do
        # IP#主机名 让 resolved 用该主机名校验证书
        dns_list+="${ip}#${DOT_SNI[idx]} "
    done

    mkdir -p "$(dirname "$RESOLVED_DROPIN")" || return 1
    {
        printf '# 由 Linux 一键配置脚本生成\n'
        printf '[Resolve]\n'
        printf 'DNS=%s\n' "${dns_list% }"
        printf 'DNSOverTLS=yes\n'
    } >"$RESOLVED_DROPIN" || return 1

    # 用 enable + restart，不要用 enable --now：
    # 包安装过程很可能已经带着默认配置把服务拉起来了，而 --now 对已经在跑
    # 的服务不会重启，刚写的 drop-in 就加载不进去。
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    if ! systemctl restart systemd-resolved 2>/dev/null; then
        log_err "重启 systemd-resolved 失败"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 回滚
# ------------------------------------------------------------
_dot_rollback() {
    # 先撤掉我们的 drop-in
    if [[ -n "${DOT_SNAP_DROPIN_EXISTED:-}" ]]; then
        printf '%s' "${DOT_SNAP_DROPIN_CONTENT:-}" >"$RESOLVED_DROPIN" 2>/dev/null
    else
        rm -f "$RESOLVED_DROPIN"
    fi

    if [[ -n "${DOT_INSTALLED_RESOLVED:-}" ]]; then
        # systemd-resolved 是本次装上的：停掉，并把 /etc/resolv.conf 还原成
        # 普通文件。装包时它的 postinst 会把 resolv.conf 换成指向 stub 的
        # 符号链接，不还原的话系统解析路径就永久改变了。
        if have_cmd systemctl; then
            systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        fi
        rm -f "$RESOLV_CONF"
        printf '%s' "${DOT_SNAP_RESOLV:-}" >"$RESOLV_CONF" 2>/dev/null
    else
        # 本来就有的，重启一下让它回到旧配置即可
        if have_cmd systemctl; then
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

_dot_snapshot() {
    DOT_INSTALLED_RESOLVED=''

    if [[ -e "$RESOLVED_DROPIN" ]]; then
        DOT_SNAP_DROPIN_EXISTED=1
        DOT_SNAP_DROPIN_CONTENT="$(cat "$RESOLVED_DROPIN" 2>/dev/null; printf x)"
        DOT_SNAP_DROPIN_CONTENT="${DOT_SNAP_DROPIN_CONTENT%x}"
    else
        DOT_SNAP_DROPIN_EXISTED=''
        DOT_SNAP_DROPIN_CONTENT=''
    fi

    DOT_SNAP_RESOLV="$(cat "$RESOLV_CONF" 2>/dev/null || true; printf x)"
    DOT_SNAP_RESOLV="${DOT_SNAP_RESOLV%x}"
}

# ============================================================
# DoT 主流程
# ============================================================
net_dot() {
    require_root

    local backend
    backend="$(_dot_backend)"

    # 非 systemd 系统上不做静默降级：直接讲清楚为什么不可用
    if [[ "$backend" == "unsupported" ]]; then
        module_begin "DoT 加密 DNS"
        log_err "当前系统不支持 DoT：本功能依赖 systemd-resolved。"
        log_info "未检出 systemd（/run/systemd/system 不存在）。"
        log_info "非 systemd 系统（Alpine / Devuan / 部分容器）请用 stubby 等专用 DoT 转发器。"
        module_end
        return 1
    fi

    local items=() i
    for (( i=0; i<${#DNS_NAMES[@]}; i++ )); do
        items+=("启用 ${DNS_NAMES[i]}|${DOT_SNI[i]}")
    done
    items+=("关闭 DoT|恢复为普通明文 DNS")

    module_begin "DoT 加密 DNS"
    ui_kv "实现方式" "$(_dot_backend_label "$backend")"
    if _dot_is_enabled; then
        ui_kv "当前状态" "已启用"
    else
        ui_kv "当前状态" "未启用"
    fi
    ui_menu "DNS over TLS（853 端口）" items "← 返回上级"
    (( UI_CHOICE < 0 )) && return 0
    local choice=$UI_CHOICE

    # ---- 关闭 DoT ----
    if (( choice == ${#DNS_NAMES[@]} )); then
        local mech
        mech="$(_dns_mechanism)"

        module_begin "关闭 DoT"
        ui_kv "实现方式" "$(_dot_backend_label "$backend")"
        ui_kv "DNS 管理方式" "$(_dns_mechanism_label "$mech")"
        ui_kv "关闭后 DNS" "${DNS_IPS[0]}（明文）"
        printf '\n'
        if ! confirm "确认关闭 DoT，恢复明文 DNS?" n; then
            log_info "已取消。"
            module_end
            return 0
        fi

        # 恢复明文 DNS 必须走机制分发：resolved 场景下 /etc/resolv.conf 是
        # 指向它自己生成的 stub 的符号链接，往里写 nameserver 会被立刻重写
        # 成 127.0.0.53，真正决定上游的是 drop-in。绕开机制直接写文件，
        # 等于写完就被丢弃，对外却报告「已恢复为明文 DNS」。
        #
        # 两套快照都要存：_dot_* 管 drop-in，_dns_* 管 resolv.conf 那条链路，
        # 它们覆盖的文件不同，缺一个回滚就不完整。
        _dot_snapshot
        _dns_snapshot "$mech"

        module_begin "关闭 DoT"
        rm -f "$RESOLVED_DROPIN"

        if ! _dns_apply "$mech" "${DNS_IPS[0]}"; then
            log_err "恢复明文 DNS 失败，正在回滚..."
            _dot_rollback
            _dns_rollback "$mech"
            module_end
            return 1
        fi

        ui_section "验证解析"
        local ok=0
        for (( i=0; i<10; i++ )); do
            _dns_probe_system && { ok=1; break; }
            sleep 0.5
        done

        if (( ok )); then
            log_ok "DoT 已关闭，DNS 恢复为明文 ${DNS_IPS[0]}。"
        else
            log_err "关闭后无法解析域名，正在恢复到关闭前的状态..."
            _dot_rollback
            _dns_rollback "$mech"
            if _dns_probe_system; then
                log_ok "已回到关闭前的配置，DoT 仍然可用。"
            else
                log_err "回滚后仍无法解析，请手动检查 $RESOLV_CONF 与 $RESOLVED_DROPIN"
            fi
            module_end
            return 1
        fi

        module_end
        return 0
    fi

    local idx=$choice
    local dot_ips="${DOT_IPS[idx]}" sni="${DOT_SNI[idx]}"

    # ---- 预览 ----
    module_begin "确认启用 DoT"
    ui_section "加密上游"
    ui_kv "服务商" "${DNS_NAMES[idx]}"
    ui_kv "端点" "$dot_ips"
    ui_kv "证书主机名" "$sni"
    ui_kv "实现方式" "$(_dot_backend_label "$backend")"

    ui_section "检查 853 端口"
    local ip reachable=() failed=() rc need_skip=0
    for ip in $dot_ips; do
        _dot_check "$ip" "$sni"; rc=$?
        case "$rc" in
            0) log_ok "$ip:853 握手通过（证书主机名已校验）"; reachable+=("$ip") ;;
            2) need_skip=1; break ;;
            *) log_warn "$ip:853 不可用"; failed+=("$ip") ;;
        esac
    done

    if (( need_skip )); then
        log_warn "系统没有 openssl，无法检查 853 端口。"
        if ! confirm "跳过检查直接启用?" n; then
            log_info "已取消，未做任何修改。"
            module_end
            return 0
        fi
    elif (( ${#reachable[@]} == 0 )); then
        log_err "所有 DoT 端点都不可用，已中止。"
        log_info "可能是网络封锁了 853 端口（部分运营商/防火墙会拦）。"
        module_end
        return 1
    elif (( ${#failed[@]} > 0 )); then
        log_warn "部分端点不可用: ${failed[*]}（将只使用可用的部分）"
    fi

    printf '\n'
    if ! confirm "确认启用 DoT?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 应用 ----
    module_begin "启用 DoT"
    _dot_snapshot

    if ! _dot_apply_resolved "$idx"; then
        log_err "启用失败，正在回滚..."
        _dot_rollback
        module_end
        return 1
    fi
    log_ok "配置已写入"

    # ---- 验证 ----
    ui_section "验证解析"
    local ok=0
    for (( i=0; i<10; i++ )); do
        if _dns_probe_system; then ok=1; break; fi
        sleep 0.5
    done

    if (( ok )); then
        log_ok "DoT 已启用，「${DNS_NAMES[idx]}」的查询全程加密。"
        log_info "验证加密生效: resolvectl status | grep DNSOverTLS"
        log_info "查看详情: resolvectl status"
    else
        log_err "启用后无法解析域名，正在自动回滚..."
        _dot_rollback
        if _dns_probe_system; then
            log_ok "已恢复到启用前的配置，系统解析正常。"
        else
            log_err "回滚后仍无法解析，请手动检查 $RESOLV_CONF"
        fi
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# 网络优化 —— 全新部署
#
# 按「全新部署」的语义做：把 $SYSCTL_D 下所有网络配置清空，重新生成一份
# 完整配置（BBR + fq、按带宽延迟算的缓冲区、高并发参数、IPv6 开关）。
#
# 不做备份。配置由本脚本独占管理，改动前请自己确认清楚。
# ============================================================
NET_CONF="${NET_CONF:-/etc/sysctl.d/99-linux-toolkit-network.conf}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"
SYSCTL_D="${SYSCTL_D:-/etc/sysctl.d}"

# 本脚本管理的全部参数。用于处理 /etc/sysctl.conf ——
# 那个文件不能整个删（可能还存着与本功能无关的设置），
# 只能把它里面命中这些参数的行注释掉。
NET_MANAGED_PARAMS=(
    net.ipv4.tcp_congestion_control net.core.default_qdisc
    net.core.rmem_max net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.core.somaxconn net.core.netdev_max_backlog
    net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_tw_reuse
    net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing
    net.ipv4.tcp_syncookies net.ipv4.tcp_fin_timeout
    fs.file-max
    net.ipv6.conf.all.disable_ipv6
    net.ipv6.conf.default.disable_ipv6
)

_bbr_in_list() {
    local needle="$1"; shift
    local p
    for p in "$@"; do [[ "$p" == "$needle" ]] && return 0; done
    return 1
}

# 待删除清单：$SYSCTL_D 下所有 .conf。
# README.sysctl 之类不带 .conf 的不算配置文件，且由 procps 包提供，
# 删掉只会让 dpkg 报文件缺失，所以不在范围内。
_net_list_conflicts() {
    local f
    shopt -s nullglob
    for f in "$SYSCTL_D"/*.conf; do
        printf '%s\n' "$f"
    done
    shopt -u nullglob
}

# /etc/sysctl.conf 里命中受管参数的行号。
# 实测这个文件的优先级高于 sysctl.d/，不处理会直接盖掉新配置。
_net_list_sysctl_conf_lines() {
    local line key stripped n=0
    [[ -r "$SYSCTL_CONF" ]] || return 0
    while IFS= read -r line; do
        n=$(( n + 1 ))
        stripped="${line%%#*}"
        stripped="$(printf '%s' "$stripped" | tr -d '[:space:]')"
        [[ -z "$stripped" ]] && continue
        key="${stripped%%=*}"
        [[ "$key" == "$stripped" ]] && continue
        if _bbr_in_list "$key" "${NET_MANAGED_PARAMS[@]}"; then
            printf '%s\n' "$n"
        fi
    done <"$SYSCTL_CONF"
}

# ------------------------------------------------------------
# 内核支持
# ------------------------------------------------------------
_bbr_supported() {
    # 内容形如 "reno cubic bbr"，按空白拆成数组逐个比对
    local avail=()
    read -ra avail < /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
    _bbr_in_list bbr ${avail[@]+"${avail[@]}"}
}

_bbr_ensure_module() {
    _bbr_supported && return 0

    have_cmd modprobe || return 1
    modprobe tcp_bbr 2>/dev/null || true
    _bbr_supported && {
        # 内核模块形式的需要开机自动加载
        if [[ -d /etc/modules-load.d ]]; then
            printf 'tcp_bbr\n' >/etc/modules-load.d/bbr.conf 2>/dev/null || true
            BBR_WROTE_MODULES_LOAD=1
        fi
        return 0
    }
    return 1
}

# ------------------------------------------------------------
# 按带宽和延迟算参数
#
# BDP（带宽延迟积，字节）= 带宽(Mbps) × 延迟(ms) × 125
#   推导: Mbps → 字节/秒 是 ×1e6/8 = ×125000；ms → 秒 是 ÷1000；
#         合起来 ×125。这个值就是「填满管道需要多少数据在途」。
# 套接字缓冲区必须 ≥ BDP，否则接收窗口会成为吞吐瓶颈。
# ------------------------------------------------------------
_bbr_calc() {
    local bw="$1" rtt="$2"

    local bdp=$(( bw * rtt * 125 ))
    (( bdp < 212992 ))    && bdp=212992        # 地板：不低于内核默认 rmem_max
    (( bdp > 536870912 )) && bdp=536870912     # 天花板：512MB，避免离谱值

    BBR_BUF="$bdp"

    # tcp_rmem/tcp_wmem 中间那列是初始值，取缓冲的 1/4
    local def=$(( bdp / 4 ))
    (( def < 87380 ))   && def=87380
    (( def > 4194304 )) && def=4194304
    BBR_DEF="$def"

    # 网卡收包队列随带宽线性放宽（纯上限，不预分配内存）
    local nback=$(( bw * 64 ))
    (( nback < 1000 ))   && nback=1000
    (( nback > 300000 )) && nback=300000
    BBR_NETDEV_BACKLOG="$nback"

    # fs.file-max 只升不降 —— 有些系统的现值是内核上限哨兵
    # （9223372036854775807），写小等于把限制调窄了
    local cur
    cur="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
    local fmax=1048576
    (( cur > fmax )) && fmax=$cur
    BBR_FILEMAX="$fmax"

    BBR_BDP_RAW=$(( bw * rtt * 125 ))
}

# $3 = IPv6 取值：1 禁用 / 0 启用
_bbr_render() {
    local bw="$1" rtt="$2" ipv6="$3"

    cat <<EOF
# 由 Linux 一键配置脚本生成，请勿手工编辑
# 依据: 带宽 ${bw} Mbps，延迟 ${rtt} ms
# BDP = ${bw} × ${rtt} × 125 = ${BBR_BDP_RAW} 字节（未截断值）

# ---- 拥塞控制 ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 缓冲区（按 BDP 计算，${BBR_BUF} 字节）----
net.core.rmem_max = ${BBR_BUF}
net.core.wmem_max = ${BBR_BUF}
net.ipv4.tcp_rmem = 4096 ${BBR_DEF} ${BBR_BUF}
net.ipv4.tcp_wmem = 4096 ${BBR_DEF} ${BBR_BUF}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_mtu_probing = 1

# ---- 高并发 ----
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = ${BBR_NETDEV_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_fastopen = 3
fs.file-max = ${BBR_FILEMAX}

# ---- IPv6（$([[ "$ipv6" == 1 ]] && echo 已禁用 || echo 已启用)）----
# 只通过这两个 sysctl 设置，不写内核命令行（ipv6.disable=1 那种做法要重启）。
# 因此只对之后新起的连接与新接口生效，已有的 IPv6 地址不会立刻消失。
net.ipv6.conf.all.disable_ipv6 = ${ipv6}
net.ipv6.conf.default.disable_ipv6 = ${ipv6}
EOF
}

# ------------------------------------------------------------
# 应用 / 验证 / 回滚
# ------------------------------------------------------------

# 现场备份到临时目录。
# 不用「变量存内容」的写法：$(cat file) 会吃掉结尾换行，写回时无法还原成
# 原样（md5 对不上）。cp -a 才是字节级保真。
_net_snapshot() {
    NET_SNAP_DIR="$(mktemp -d)"
    local f

    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        cp -a "$f" "$NET_SNAP_DIR/$(basename "$f")" 2>/dev/null || true
    done < <(_net_list_conflicts)

    # 这两个用固定名，不放同一层，避免与上面的 basename 撞名
    [[ -e "$SYSCTL_CONF" ]] && cp -a "$SYSCTL_CONF" "$NET_SNAP_DIR/_sysctl_conf" 2>/dev/null
    [[ -e "$NET_CONF" ]]    && cp -a "$NET_CONF"    "$NET_SNAP_DIR/_ours" 2>/dev/null
    return 0
}

_net_rollback() {
    local f

    [[ -n "${NET_SNAP_DIR:-}" && -d "$NET_SNAP_DIR" ]] || return 0

    # 还原被删掉的配置文件
    shopt -s nullglob
    for f in "$NET_SNAP_DIR"/*.conf; do
        cp -a "$f" "$SYSCTL_D/$(basename "$f")" 2>/dev/null || true
    done
    shopt -u nullglob

    # 还原 /etc/sysctl.conf
    [[ -e "$NET_SNAP_DIR/_sysctl_conf" ]] \
        && cp -a "$NET_SNAP_DIR/_sysctl_conf" "$SYSCTL_CONF" 2>/dev/null

    # 还原我们自己的文件（本来没有就删掉）
    if [[ -e "$NET_SNAP_DIR/_ours" ]]; then
        cp -a "$NET_SNAP_DIR/_ours" "$NET_CONF" 2>/dev/null
    else
        rm -f "$NET_CONF"
    fi

    if [[ -n "${BBR_WROTE_MODULES_LOAD:-}" ]]; then
        rm -f /etc/modules-load.d/bbr.conf
    fi

    rm -rf "$NET_SNAP_DIR"
    NET_SNAP_DIR=''

    sysctl --system >/dev/null 2>&1 || true
    return 0
}

# ------------------------------------------------------------
# 中断保护
#
# 全新部署的执行窗口是「快照 → 删光 sysctl.d → 写新配置 → 加载 → 验证」。
# 中途被 Ctrl-C 或 SSH 断线打断时，回滚代码根本轮不到执行：配置已经删了，
# 快照还躺在没人知道路径的 /tmp 目录里。所以在这个窗口内挂信号处理，
# 收到信号先还原现场再退出。
#
# 快照还没建立时（_net_rollback 会自行判空返回）触发也是安全的。
# ------------------------------------------------------------
_net_arm_trap() {
    trap '_net_on_interrupt' INT TERM HUP
}

_net_disarm_trap() {
    trap - INT TERM HUP
}

_net_on_interrupt() {
    printf '\n'
    log_warn "收到中断信号，正在还原网络配置..."
    _net_rollback
    log_info "已恢复到变更前的配置。"
    exit 130
}

_net_verify() {
    local expect_buf="$1" expect_ipv6="$2"
    local cc qd rm wm v6

    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    rm="$(sysctl -n net.core.rmem_max 2>/dev/null)"
    wm="$(sysctl -n net.core.wmem_max 2>/dev/null)"
    v6="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"

    [[ "$cc" == "bbr" ]] || { printf '拥塞控制算法未生效: 期望 bbr，实际 %s\n' "$cc"; return 1; }
    [[ "$qd" == "fq" ]]  || { printf '队列规则未生效: 期望 fq，实际 %s\n' "$qd"; return 1; }
    [[ "$rm" == "$expect_buf" ]] || { printf 'rmem_max 未生效: 期望 %s，实际 %s\n' "$expect_buf" "$rm"; return 1; }
    [[ "$wm" == "$expect_buf" ]] || { printf 'wmem_max 未生效: 期望 %s，实际 %s\n' "$expect_buf" "$wm"; return 1; }
    [[ "$v6" == "$expect_ipv6" ]] || { printf 'IPv6 设置未生效: 期望 disable_ipv6=%s，实际 %s\n' "$expect_ipv6" "$v6"; return 1; }
    return 0
}

# ============================================================
# 网络优化（原 BBR 大类，扩展为网络配置大类）
# ============================================================
net_optimize() {
    local items=(
        "全新部署|清空网络配置后重建：BBR + fq + 调优 + 并发 + IPv6"
        "IPv6 开关|单独启用或禁用 IPv6，不动其它配置"
    )
    local fns=(net_deploy net_ipv6_toggle)
    run_submenu "网络优化" items fns
}

# ============================================================
# 全新部署
# ============================================================
net_deploy() {
    require_root

    module_begin "网络优化 · 全新部署"
    if ! _bbr_supported; then
        log_warn "当前内核未提供 bbr，尝试加载内核模块 ..."
        if ! _bbr_ensure_module; then
            log_err "内核不支持 BBR（需要 4.9 以上且已编译 tcp_bbr）。"
            log_info "当前可用算法: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
            module_end
            return 1
        fi
        log_ok "已加载 tcp_bbr 模块"
    fi
    ui_kv "内核" "$KERNEL"
    ui_kv "当前算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    ui_kv "当前队列规则" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    ui_kv "当前 IPv6" "$([[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == 1 ]] && echo 已禁用 || echo 已启用)"
    printf '\n'
    pause

    # ---- 采集输入 ----
    module_begin "全新部署 · 参数"
    printf '  %s带宽和延迟用来计算 BDP（带宽延迟积），决定缓冲区大小。%s\n' "$C_DIM" "$C_RESET"
    printf '  %s填错会导致缓冲区过大浪费内存或过小跑不满带宽。%s\n\n' "$C_DIM" "$C_RESET"

    local bw rtt
    while true; do
        ask "服务器带宽 (Mbps)" "${NET_INPUT_BW:-}"
        bw="$REPLY"
        [[ "$bw" =~ ^[0-9]+$ ]] && (( bw >= 1 && bw <= 100000 )) && break
        log_warn "请输入 1-100000 之间的整数（Mbps）"
    done
    while true; do
        ask "网络延迟 (ms)" "${NET_INPUT_RTT:-}"
        rtt="$REPLY"
        [[ "$rtt" =~ ^[0-9]+$ ]] && (( rtt >= 1 && rtt <= 5000 )) && break
        log_warn "请输入 1-5000 之间的整数（毫秒）"
    done

    # ---- IPv6 选择 ----
    local v6_items=("启用 IPv6|保持默认，不禁止 IPv6" "禁用 IPv6|关闭 IPv6 协议栈")
    ui_menu "IPv6 设置" v6_items "← 放弃部署"
    (( UI_CHOICE < 0 )) && return 0
    local ipv6=$(( UI_CHOICE == 1 ? 1 : 0 ))

    _bbr_calc "$bw" "$rtt"

    # ---- 列出将被清空的配置 ----
    local victims=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && victims+=("$f")
    done < <(_net_list_conflicts)

    local conf_lines=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && conf_lines+=("$n")
    done < <(_net_list_sysctl_conf_lines)

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "计算依据"
    ui_kv "带宽" "${bw} Mbps"
    ui_kv "延迟" "${rtt} ms"
    ui_kv "BDP" "${BBR_BDP_RAW} 字节"
    ui_kv "缓冲区" "${BBR_BUF} 字节 ($(awk -v b="$BBR_BUF" 'BEGIN{printf "%.1f MB", b/1048576}'))"
    ui_kv "IPv6" "$([[ "$ipv6" == 1 ]] && echo 禁用 || echo 启用)"

    ui_section "将要删除（$SYSCTL_D 下全部配置）"
    if (( ${#victims[@]} == 0 )); then
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    else
        for f in "${victims[@]}"; do
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$f"
        done
    fi

    if (( ${#conf_lines[@]} > 0 )); then
        printf '\n'
        ui_section "$SYSCTL_CONF 中将被注释的行"
        for n in "${conf_lines[@]}"; do
            printf '  %s#%s %s\n' "$C_YELLOW" "$n" "$(sed -n "${n}p" "$SYSCTL_CONF")"
        done
        printf '  %s该文件优先级高于 sysctl.d/，不处理会直接盖掉新配置。%s\n' "$C_DIM" "$C_RESET"
        printf '  %s不能整个删除：里面可能还有与本功能无关的设置。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '  %s不带 .conf 的文件（如 README.sysctl）不属于配置文件，不在删除范围。%s\n' "$C_DIM" "$C_RESET"

    ui_section "将要写入 $NET_CONF"
    _bbr_render "$bw" "$rtt" "$ipv6" | sed 's/^/  /'

    printf '\n'
    log_warn "全新部署：上述配置将被清空重建，不做备份，不可撤销。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 应用 ----
    module_begin "应用配置"
    _net_snapshot
    _net_arm_trap      # 从这里开始删改配置，直到验证结束都要防中断

    local f n
    for f in "${victims[@]}"; do
        if rm -f "$f"; then log_ok "已删除 $f"; else log_err "删除失败: $f"; fi
    done

    if (( ${#conf_lines[@]} > 0 )); then
        local tmp
        tmp="$(mktemp)"
        awk -v lines="${conf_lines[*]}" '
            BEGIN { n = split(lines, a, " "); for (i=1;i<=n;i++) skip[a[i]] = 1 }
            skip[NR] { printf "# [linux-toolkit] 被网络配置覆盖: %s\n", $0; next }
            { print }
        ' "$SYSCTL_CONF" >"$tmp" && install -m 0644 "$tmp" "$SYSCTL_CONF"
        rm -f "$tmp"
        log_ok "已注释 $SYSCTL_CONF 中 ${#conf_lines[@]} 行冲突设置"
    fi

    mkdir -p "$(dirname "$NET_CONF")"
    if _bbr_render "$bw" "$rtt" "$ipv6" >"$NET_CONF"; then
        log_ok "已写入 $NET_CONF"
    else
        log_err "写入失败，正在回滚..."
        _net_disarm_trap
        _net_rollback
        module_end
        return 1
    fi

    # ---- 生效并验证 ----
    ui_section "加载并验证"
    sysctl --system >/dev/null 2>&1 || true

    if _net_verify "$BBR_BUF" "$ipv6"; then
        log_ok "网络优化已生效。"
        _net_disarm_trap
        rm -rf "${NET_SNAP_DIR:-}"      # 已生效，现场快照不再需要
        NET_SNAP_DIR=''

        ui_section "当前状态"
        ui_kv "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"
        ui_kv "队列规则" "$(sysctl -n net.core.default_qdisc)"
        ui_kv "rmem_max" "$(sysctl -n net.core.rmem_max)"
        ui_kv "wmem_max" "$(sysctl -n net.core.wmem_max)"
        ui_kv "somaxconn" "$(sysctl -n net.core.somaxconn)"
        ui_kv "netdev_backlog" "$(sysctl -n net.core.netdev_max_backlog)"
        ui_kv "IPv6" "$([[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]] && echo 已禁用 || echo 已启用)"
        log_info "已建立的连接沿用旧算法，新建连接才走 BBR。"
    else
        log_err "验证未通过，正在回滚..."
        _net_disarm_trap
        _net_rollback
        log_warn "回滚后请手动检查: sysctl -n net.ipv4.tcp_congestion_control"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# IPv6 开关（单独使用，不动其它配置）
# ============================================================
net_ipv6_toggle() {
    require_root

    local cur
    cur="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 0)"
    local cur_label
    [[ "$cur" == 1 ]] && cur_label="已禁用" || cur_label="已启用"

    local items=(
        "启用 IPv6|关闭 IPv6 协议栈限制"
        "禁用 IPv6|开启 IPv6 协议栈限制"
    )

    module_begin "IPv6 开关"
    ui_kv "当前状态" "$cur_label"
    ui_kv "配置文件" "$NET_CONF"
    ui_menu "选择操作" items "← 返回上级"
    (( UI_CHOICE < 0 )) && return 0

    local target=$(( UI_CHOICE == 1 ? 1 : 0 ))
    local label
    [[ "$target" == 1 ]] && label="禁用" || label="启用"

    if [[ "$target" == "$cur" ]]; then
        log_info "IPv6 当前就是「${label}」状态，无需改动。"
        module_end
        return 0
    fi

    module_begin "确认"
    ui_kv "当前" "$cur_label"
    ui_kv "将变为" "$([[ "$target" == 1 ]] && echo 已禁用 || echo 已启用)"
    ui_kv "写入" "$NET_CONF"
    printf '\n'
    if ! confirm "确认${label} IPv6?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # 改这一个文件里的 IPv6 两行。文件不存在就新建一份只含 IPv6 的。
    local base="$NET_CONF"
    if [[ -e "$base" ]]; then
        local tmp
        tmp="$(mktemp)"
        # 去掉旧的 IPv6 两行，其余原样保留
        grep -vE '^[[:space:]]*net\.ipv6\.conf\.(all|default)\.disable_ipv6' "$base" >"$tmp" || true
        {
            printf '\n# ---- IPv6（由脚本更新）----\n'
            printf 'net.ipv6.conf.all.disable_ipv6 = %s\n' "$target"
            printf 'net.ipv6.conf.default.disable_ipv6 = %s\n' "$target"
        } >>"$tmp"
        install -m 0644 "$tmp" "$base"
        rm -f "$tmp"
    else
        mkdir -p "$(dirname "$base")"
        {
            printf '# 由 Linux 一键配置脚本生成\n'
            printf '# 仅含 IPv6 设置。完整部署请用「网络优化 → 全新部署」。\n\n'
            printf 'net.ipv6.conf.all.disable_ipv6 = %s\n' "$target"
            printf 'net.ipv6.conf.default.disable_ipv6 = %s\n' "$target"
        } >"$base"
    fi

    sysctl --system >/dev/null 2>&1 || true
    local now
    now="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)"

    if [[ "$now" == "$target" ]]; then
        log_ok "IPv6 已${label}。"
        log_info "仅对新连接与新接口生效；已有 IPv6 地址不会立刻消失。"
    else
        log_err "设置未生效（当前值 $now），可能有更高优先级的配置覆盖了它。"
        log_info "检查: sysctl -n net.ipv6.conf.all.disable_ipv6"
        module_end
        return 1
    fi

    module_end
}
# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
net_ip_config() {
    not_implemented          # TODO: 静态 IP / DHCP 配置
    module_end
}

net_proxy() {
    not_implemented          # TODO: 系统代理 / 环境变量代理
    module_end
}

net_connectivity() {
    not_implemented          # TODO: 连通性测试 / 测速
    module_end
}

menu_network() {
    local items=(
        "网络优化|BBR + fq / 调优 / 并发 / IPv6 全新部署"
        "DNS 设置|Cloudflare / Google / 腾讯 / 阿里"
        "DoT 加密 DNS|DNS over TLS，检查 853 端口"
        "IP 配置|静态 IP / DHCP"
        "代理设置|系统级 / 终端代理"
        "连通测试|延迟 / 测速"
    )
    local fns=(net_optimize net_dns net_dot net_ip_config net_proxy net_connectivity)
    run_submenu "网络设置" items fns
}

register_module "network" "网络设置" "menu_network" "优化 / DNS / DoT / 代理"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/05-user.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 用户管理
# id: user
# ============================================================

usr_create() {
    not_implemented          # TODO: 新建用户 / 设置密码 / sudo 权限
    module_end
}

usr_sshkey() {
    not_implemented          # TODO: 导入公钥 / 生成密钥对
    module_end
}

usr_ssh_harden() {
    not_implemented          # TODO: 改端口 / 禁 root 登录 / 禁密码登录
    module_end
}

usr_passwd_policy() {
    not_implemented          # TODO: 密码策略 / 登录失败锁定
    module_end
}

menu_user() {
    local items=(
        "创建用户|新建 / 授权 sudo"
        "SSH 密钥|导入公钥 / 生成密钥"
        "SSH 加固|端口 / 禁止 root 登录"
        "密码策略|复杂度 / 失败锁定"
    )
    local fns=(usr_create usr_sshkey usr_ssh_harden usr_passwd_policy)
    run_submenu "用户管理" items fns
}

register_module "user" "用户管理" "menu_user" "用户 / SSH / 权限"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/06-service.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 服务管理
# id: service
# ============================================================

svc_list() {
    not_implemented          # TODO: 列出运行中/已启用的服务
    module_end
}

svc_control() {
    not_implemented          # TODO: 启动/停止/重启/开机自启
    module_end
}

svc_logs() {
    not_implemented          # TODO: 查看服务日志 journalctl
    module_end
}

svc_timer() {
    not_implemented          # TODO: 定时任务 crontab / systemd timer
    module_end
}

menu_service() {
    local items=(
        "服务列表|运行中 / 已启用"
        "服务控制|启停 / 重启 / 自启"
        "查看日志|journalctl"
        "定时任务|cron / systemd timer"
    )
    local fns=(svc_list svc_control svc_logs svc_timer)
    run_submenu "服务管理" items fns
}

register_module "service" "服务管理" "menu_service" "systemd 服务 / 定时任务"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/07-swap.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: Swap 管理
# id: swap
#
# 只管理「文件形式」的 swap（/swapfile 这类），不碰 swap 分区和 zram：
# 分区牵涉分区表和镜像自带的安排，删错的代价太大。删除会一次清掉所有
# 文件形式的 swap，范围仍可明确识别 —— /proc/swaps 里以 / 开头的条目
# 加上管理路径本身，逐个在预览里列出来；fstab 只动首字段正好是这些
# 路径、第三字段是 swap 的行。
#
# 重建走「先建新、再换旧」：新文件全部就绪之后才动旧的，中途失败把旧
# 文件换回来即可，不会留下「旧的删了、新的没建成」的空窗。
# ============================================================

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SWAPPINESS="${SWAP_SWAPPINESS:-10}"
SWAP_SYSCTL_CONF="${SWAP_SYSCTL_CONF:-/etc/sysctl.d/99-linux-toolkit-swap.conf}"
SWAP_FSTAB="${SWAP_FSTAB:-/etc/fstab}"
SWAP_KERNEL_SWAPPINESS=60      # vm.swappiness 的内核默认值，删除时用它还原

# ============================================================
# 取数
# ============================================================
_swap_mem_mb() {
    local kb
    kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
    [[ "$kb" =~ ^[0-9]+$ ]] && (( kb >= 2048 )) || return 1
    printf '%s' "$(( kb / 1024 ))"
}

# 默认大小 = 内存容量 - 1MB
_swap_default_mb() {
    local mem
    mem="$(_swap_mem_mb)" || return 1
    printf '%s' "$(( mem - 1 ))"
}

# "1024" / "512M" / "8G" → MB
_swap_parse_mb() {
    local s="${1//[[:space:]]/}" n unit
    [[ "$s" =~ ^([0-9]+)([MmGg]?)$ ]] || return 1
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    if [[ "$unit" == "g" ]]; then
        (( n >= 1 && n <= 4096 )) || return 1
        n=$(( n * 1024 ))
    else
        (( n >= 1 && n <= 1048576 )) || return 1
    fi
    printf '%s' "$n"
}

_swap_human_mb() {
    awk -v m="${1:-0}" 'BEGIN{
        if      (m >= 1048576) printf "%.1f TB", m / 1048576;
        else if (m >= 1024)    printf "%.1f GB", m / 1024;
        else                   printf "%d MB", m;
    }'
}

_swap_human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if      (k >= 1048576) printf "%.1f GB", k / 1048576;
        else if (k >= 1024)    printf "%.0f MB", k / 1024;
        else                   printf "%.0f KB", k;
    }'
}

# 大小标签：MB 值放前面，人类可读形式放括号里。
# 只写「31.3 GB」会和「物理内存 32100 MB」串味 —— 减 1MB 在 GB 的
# 精度下根本看不出来，容易被读成「少了 1GB」。MB 是精确值，放前面。
_swap_size_label() {
    local mb="$1" h
    h="$(_swap_human_mb "$mb")"
    if [[ "$h" == "${mb} MB" ]]; then
        printf '%s' "$h"
    else
        printf '%s MB  (%s)' "$mb" "$h"
    fi
}

# /proc/swaps 里文件形式的 swap。分区和 zram 都以 /dev/ 开头，天然被排除。
_swap_active_files() {
    awk 'NR > 1 && $1 ~ /^\// && $1 !~ /^\/dev\// { print $1 }' /proc/swaps 2>/dev/null
}

_swap_active_all() {
    awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null
}

_swap_is_active() {
    local path="$1"
    awk -v p="$path" 'NR > 1 && $1 == p { f = 1 } END { exit !f }' /proc/swaps 2>/dev/null
}

# 文件大小（MB）；不存在或读不到返回非 0
_swap_file_mb() {
    local path="$1" bytes
    [[ -f "$path" ]] || return 1
    bytes="$(stat -c %s "$path" 2>/dev/null)" || return 1
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$(( bytes / 1048576 ))"
}

# fstab 里指向该文件的条目（行号 + 原文）。
# 按字段比对而不是子串匹配 —— 否则 /swapfile2 会被 /swapfile 带出来。
_swap_fstab_lines() {
    local path="$1"
    [[ -r "$SWAP_FSTAB" ]] || return 0
    awk -v p="$path" '$1 == p && $3 == "swap" { printf "%d\t%s\n", NR, $0 }' "$SWAP_FSTAB"
}

# 目标目录可能还不存在（要现建），这时 stat / df 都会失败，
# 于是向上找到第一个存在的祖先 —— 新建的目录必然和它同处一个文件系统。
_swap_existing_dir() {
    local dir="$1"
    while [[ -n "$dir" && ! -d "$dir" ]]; do
        dir="$(dirname "$dir")"
    done
    [[ -d "$dir" ]] || return 1
    printf '%s' "$dir"
}

_swap_free_mb() {
    local dir
    dir="$(_swap_existing_dir "$1")" || return 1
    df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

_swap_fs_type() {
    local dir
    dir="$(_swap_existing_dir "$1")" || { printf '未知'; return; }
    stat -f -c %T "$dir" 2>/dev/null || printf '未知'
}

# ------------------------------------------------------------
# 展示
# ------------------------------------------------------------
_swap_show_table() {
    local name type size used prio
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "名称" 26)" "$(_pad_right "类型" 8)" \
            "$(_pad_right "大小" 10)" "$(_pad_right "已用" 10)" "优先级")" "$C_RESET"
    while read -r name type size used prio; do
        [[ "$name" == "Filename" ]] && continue
        printf '  %s %s %s %s %s\n' \
            "$(_pad_right "$name" 26)" "$(_pad_right "$type" 8)" \
            "$(_pad_right "$(_swap_human_kb "$size")" 10)" \
            "$(_pad_right "$(_swap_human_kb "$used")" 10)" "${prio:--}"
    done < /proc/swaps
}

# ------------------------------------------------------------
# 变更
# ------------------------------------------------------------
# 创建交换文件。fallocate 最快，失败时退回 dd 实写。
# 目标文件系统不支持换页文件时（tmpfs）这里会失败，由调用方先做预检。
_swap_create_file() {
    local path="$1" mb="$2"
    if have_cmd fallocate && fallocate -l "${mb}M" "$path" 2>/dev/null; then
        return 0
    fi
    log_debug "fallocate 失败，改用 dd 实写 $path"
    have_cmd dd || return 1
    dd if=/dev/zero of="$path" bs=1M count="$mb" 2>/dev/null || return 1
    return 0
}

# 删掉指向该文件的 fstab 行
_swap_fstab_clean() {
    local path="$1" tmp
    [[ -n "$(_swap_fstab_lines "$path")" ]] || return 0
    tmp="$(mktemp)" || return 1
    if awk -v p="$path" '!($1 == p && $3 == "swap")' "$SWAP_FSTAB" >"$tmp"; then
        if install -m 0644 "$tmp" "$SWAP_FSTAB"; then
            rm -f "$tmp"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

_swap_write_sysctl() {
    mkdir -p "$(dirname "$SWAP_SYSCTL_CONF")" || return 1
    {
        printf '# 由 Linux 一键配置脚本生成\n'
        printf 'vm.swappiness = %s\n' "$SWAP_SWAPPINESS"
    } >"$SWAP_SYSCTL_CONF"
}

# 配置现场：fstab / swappiness 整份存内存，不落备份文件。
# $(cat) 会吃掉结尾换行，用哨兵字符保住原样，还原前再摘掉。
_swap_snapshot_config() {
    SWAP_SNAP_FSTAB_EXISTED=''
    SWAP_SNAP_FSTAB=''
    if [[ -e "$SWAP_FSTAB" ]]; then
        SWAP_SNAP_FSTAB_EXISTED=1
        SWAP_SNAP_FSTAB="$(cat "$SWAP_FSTAB" 2>/dev/null; printf x)"
        SWAP_SNAP_FSTAB="${SWAP_SNAP_FSTAB%x}"
    fi

    SWAP_SNAP_SYSCTL_EXISTED=''
    SWAP_SNAP_SYSCTL=''
    if [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        SWAP_SNAP_SYSCTL_EXISTED=1
        SWAP_SNAP_SYSCTL="$(cat "$SWAP_SYSCTL_CONF" 2>/dev/null; printf x)"
        SWAP_SNAP_SYSCTL="${SWAP_SNAP_SYSCTL%x}"
    fi

    SWAP_SNAP_SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null)"
}

# 单个文件的现场。删除流程要按文件恢复，所以启用状态单独记。
_swap_snapshot() {
    local path="$1"
    SWAP_SNAP_WAS_ACTIVE=''
    _swap_is_active "$path" && SWAP_SNAP_WAS_ACTIVE=1
    _swap_snapshot_config
}

# 回滚：撤掉新启用的 swap，把换下来的旧文件换回去，还原 fstab 与 swappiness
_swap_rollback() {
    local path="$1"

    _swap_is_active "$path" && swapoff "$path" 2>/dev/null

    if [[ -e "${path}.old" ]]; then
        rm -f "$path"
        if mv "${path}.old" "$path" 2>/dev/null; then
            if [[ -n "${SWAP_SNAP_WAS_ACTIVE:-}" ]]; then
                swapon "$path" 2>/dev/null || true
            fi
        fi
    else
        rm -f "$path"
    fi
    rm -f "${path}.new"

    if [[ -n "${SWAP_SNAP_FSTAB_EXISTED:-}" ]]; then
        printf '%s' "${SWAP_SNAP_FSTAB:-}" >"$SWAP_FSTAB" 2>/dev/null
    fi

    if [[ -n "${SWAP_SNAP_SYSCTL_EXISTED:-}" ]]; then
        printf '%s' "${SWAP_SNAP_SYSCTL:-}" >"$SWAP_SYSCTL_CONF" 2>/dev/null
    else
        rm -f "$SWAP_SYSCTL_CONF"
    fi

    if [[ -n "${SWAP_SNAP_SWAPPINESS:-}" ]]; then
        sysctl -q -w "vm.swappiness=${SWAP_SNAP_SWAPPINESS}" 2>/dev/null || true
    fi

    return 0
}

# 关闭并删除文件。返回非 0 表示文件没删掉。
_swap_teardown() {
    local path="$1"

    if _swap_is_active "$path"; then
        if swapoff "$path" 2>/dev/null; then
            log_ok "已关闭 $path"
        else
            log_err "swapoff $path 失败"
            return 1
        fi
    else
        log_info "$path 当前未启用，跳过 swapoff"
    fi

    [[ -e "$path" ]] || return 0
    if rm -f "$path"; then
        log_ok "已删除 $path"
        return 0
    fi
    log_err "删除失败: $path"
    return 1
}

# 验证：文件已生效且大小对得上。不通过则输出原因。
_swap_verify() {
    local path="$1" expect_mb="$2" got
    _swap_is_active "$path" || { printf '%s 没有出现在 /proc/swaps 里' "$path"; return 1; }
    got="$(_swap_file_mb "$path")"
    [[ "$got" == "$expect_mb" ]] || { printf '文件大小不符：期望 %s MB，实际 %s' "$expect_mb" "${got:-未知}"; return 1; }
    return 0
}

# ============================================================
# 1) 状态查看
# ============================================================
swap_status() {
    local mem default_mb fsize lines f
    local others=()

    ui_section "内存"
    if mem="$(_swap_mem_mb)"; then
        ui_kv "物理内存" "${mem} MB"
    else
        ui_kv "物理内存" "读不到"
    fi
    if default_mb="$(_swap_default_mb)"; then
        ui_kv "建议大小" "${default_mb} MB  (内存 ${mem} MB − 1 MB)"
    fi

    ui_section "当前生效的 Swap"
    if [[ -n "$(_swap_active_all)" ]]; then
        _swap_show_table
    else
        printf '  %s未启用任何 swap%s\n' "$C_DIM" "$C_RESET"
    fi

    ui_section "Swappiness"
    ui_kv "当前值" "$(sysctl -n vm.swappiness 2>/dev/null || echo 未知)"
    if [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        ui_kv "本脚本配置" "$SWAP_SYSCTL_CONF"
    else
        ui_kv "本脚本配置" "未写入"
    fi

    ui_section "本模块管理的文件"
    ui_kv "路径" "$SWAP_FILE"
    if fsize="$(_swap_file_mb "$SWAP_FILE")"; then
        ui_kv "文件" "存在，$(_swap_size_label "$fsize")"
    else
        ui_kv "文件" "不存在"
    fi
    if _swap_is_active "$SWAP_FILE"; then
        ui_kv "状态" "已启用"
    else
        ui_kv "状态" "未启用"
    fi

    lines="$(_swap_fstab_lines "$SWAP_FILE")"
    ui_section "$SWAP_FSTAB"
    if [[ -n "$lines" ]]; then
        while IFS=$'\t' read -r n text; do
            printf '  %s#%-4s%s %s\n' "$C_YELLOW" "$n" "$C_RESET" "$text"
        done <<<"$lines"
    else
        printf '  %s没有指向 %s 的条目%s\n' "$C_DIM" "$SWAP_FILE" "$C_RESET"
    fi

    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "$SWAP_FILE" ]] && others+=("$f")
    done < <(_swap_active_files)
    if (( ${#others[@]} > 0 )); then
        ui_section "其它 swap 文件（不由本模块管理）"
        for f in "${others[@]}"; do printf '  %s\n' "$f"; done
    fi

    printf '\n  %s删除会一次清掉所有文件形式的 swap（上面列出的），分区与 zram 不在处理范围。%s\n' \
        "$C_DIM" "$C_RESET"
    module_end
}

# ============================================================
# 2) 添加 / 重建
# ============================================================
swap_add() {
    require_root

    local mem default_mb size_mb dir fs_dir fs_type free_mb
    if ! mem="$(_swap_mem_mb)"; then
        module_begin "添加 / 重建 Swap"
        log_err "读不到 /proc/meminfo 里的 MemTotal，算不出默认大小。"
        module_end
        return 1
    fi
    default_mb="$(_swap_default_mb)"
    dir="$(dirname "$SWAP_FILE")"
    fs_dir="$(_swap_existing_dir "$dir")"

    # ---- 预检：目标位置能不能放 swap 文件 ----
    # tmpfs / ramfs 上内核直接拒绝 swapon（EINVAL），而且把 swap 放在内存盘
    # 上本身就没有意义。与其让用户撞一个看不懂的报错，不如在这里说清楚。
    fs_type="$(_swap_fs_type "$dir")"
    case "$fs_type" in
        tmpfs|ramfs)
            module_begin "添加 / 重建 Swap"
            log_err "$dir 在 $fs_type 上（内存盘），不能放 swap 文件。"
            log_info "内核会直接拒绝 swapon，而且把 swap 放在内存盘上等于没加。"
            log_info "把 SWAP_FILE 指到真实磁盘，例如 /swapfile。"
            module_end
            return 1
            ;;
    esac

    # ---- 输入 ----
    module_begin "添加 / 重建 Swap"
    ui_kv "目标文件" "$SWAP_FILE"
    ui_kv "物理内存" "${mem} MB"
    ui_kv "默认大小" "${default_mb} MB  (内存 ${mem} MB − 1 MB)"
    if _swap_is_active "$SWAP_FILE"; then
        ui_kv "当前状态" "已启用，将被关闭并重建"
    elif [[ -f "$SWAP_FILE" ]]; then
        ui_kv "当前状态" "文件在但未启用，将被删除并重建"
    else
        ui_kv "当前状态" "不存在，将新建"
    fi
    printf '\n  %s%s%s\n\n' "$C_DIM" "已存在的一律删除重建，不做原地扩容。" "$C_RESET"

    while true; do
        if ! ask "Swap 大小（回车用默认，可写 512M / 8G）" "${default_mb}M"; then
            log_info "输入中断，已取消。"
            module_end
            return 0
        fi
        if size_mb="$(_swap_parse_mb "$REPLY")"; then
            break
        fi
        log_warn "格式不对：填整数 MB（如 1024），或带单位（如 512M / 8G）"
    done

    free_mb="$(_swap_free_mb "$dir")"

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将创建"
    ui_kv "文件" "$SWAP_FILE"
    ui_kv "大小" "$(_swap_size_label "$size_mb")"
    ui_kv "swappiness" "$SWAP_SWAPPINESS"
    ui_kv "配置" "$SWAP_SYSCTL_CONF"
    ui_kv "fstab" "$SWAP_FILE none swap sw 0 0"

    ui_section "将删除"
    if [[ -f "$SWAP_FILE" ]]; then
        if _swap_is_active "$SWAP_FILE"; then
            printf '  %s-%s %s（%s，当前已启用，先 swapoff）\n' \
                "$C_RED" "$C_RESET" "$SWAP_FILE" "$(_swap_human_mb "$(_swap_file_mb "$SWAP_FILE")")"
        else
            printf '  %s-%s %s（%s）\n' \
                "$C_RED" "$C_RESET" "$SWAP_FILE" "$(_swap_human_mb "$(_swap_file_mb "$SWAP_FILE")")"
        fi
    else
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    fi

    local lines
    lines="$(_swap_fstab_lines "$SWAP_FILE")"
    if [[ -n "$lines" ]]; then
        while IFS=$'\t' read -r n text; do
            printf '  %s-%s %s 第 %s 行: %s\n' "$C_RED" "$C_RESET" "$SWAP_FSTAB" "$n" "$text"
        done <<<"$lines"
    fi
    [[ -e "${SWAP_FILE}.new" ]] && printf '  %s-%s %s.new（上次中断留下的）\n' "$C_RED" "$C_RESET" "$SWAP_FILE"
    [[ -e "${SWAP_FILE}.old" ]] && printf '  %s-%s %s.old（上次中断留下的）\n' "$C_RED" "$C_RESET" "$SWAP_FILE"

    local others=() f
    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "$SWAP_FILE" ]] && others+=("$f")
    done < <(_swap_active_all)
    if (( ${#others[@]} > 0 )); then
        ui_section "不在本次范围（一律保留）"
        for f in "${others[@]}"; do printf '  %s\n' "$f"; done
        printf '  %s本功能只重建 %s，其它 swap 请用「删除」单独处理。%s\n' "$C_DIM" "$SWAP_FILE" "$C_RESET"
    fi

    ui_section "磁盘空间"
    ui_kv "文件系统" "$fs_type"
    if [[ ! -d "$dir" ]]; then
        ui_kv "目标目录" "$dir（将创建）"
    fi
    ui_kv "${fs_dir:-?} 可用" "$(_swap_human_mb "${free_mb:-0}")"
    printf '  %s新文件先建好再替换旧文件，所以旧文件占的空间此刻还没释放。%s\n' "$C_DIM" "$C_RESET"

    if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < size_mb )); then
        printf '\n'
        log_err "空间不足：需要 ${size_mb} MB，可用 ${free_mb} MB。未做任何修改。"
        module_end
        return 1
    fi
    case "$fs_type" in
        btrfs|zfs)
            printf '\n'
            log_warn "$fs_type 上的 swap 文件需要额外设置（btrfs 要先关 COW），swapon 可能失败。"
            log_warn "失败会自动回滚，不会留下半成品。"
            ;;
    esac

    printf '\n'
    log_warn "旧 swap 文件会被删除且不可恢复（是删除重建，不是扩容）。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    local new_file="${SWAP_FILE}.new" old_file="${SWAP_FILE}.old"

    # 上一轮中断留下的残骸，先清掉（是我们的命名，且已在预览里列出）
    rm -f "$new_file" "$old_file"
    mkdir -p "$dir" || {
        log_err "创建目录 $dir 失败。"
        module_end
        return 1
    }

    # 先建新文件：这一步出问题，系统上什么都还没动
    ui_section "创建新文件"
    if ! _swap_create_file "$new_file" "$size_mb"; then
        log_err "创建 $new_file 失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    if ! chmod 600 "$new_file"; then
        log_err "设置权限失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    # swapon 会拒绝 0600 以外权限的文件，所以上面那步不能省
    if ! mkswap "$new_file" >/dev/null 2>&1; then
        log_err "mkswap 失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    log_ok "新文件已就绪：$new_file（$(_swap_size_label "$size_mb")）"

    # 到这里才开始动现有的：旧文件改名留作回滚，而不是直接删
    _swap_snapshot "$SWAP_FILE"
    ui_section "替换"
    if _swap_is_active "$SWAP_FILE"; then
        if ! swapoff "$SWAP_FILE" 2>/dev/null; then
            log_err "swapoff $SWAP_FILE 失败，未做替换。"
            rm -f "$new_file"
            module_end
            return 1
        fi
        log_ok "已关闭旧的 swap"
    fi
    [[ -e "$SWAP_FILE" ]] && mv "$SWAP_FILE" "$old_file"
    if ! mv "$new_file" "$SWAP_FILE"; then
        log_err "替换失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi

    ui_section "写入配置"
    local fstab_ok=1
    _swap_fstab_clean "$SWAP_FILE" || fstab_ok=0
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>"$SWAP_FSTAB" || fstab_ok=0
    if (( ! fstab_ok )); then
        log_err "更新 $SWAP_FSTAB 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi
    log_ok "已写入 $SWAP_FSTAB"

    if ! _swap_write_sysctl; then
        log_err "写入 $SWAP_SYSCTL_CONF 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi
    log_ok "已写入 $SWAP_SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true

    ui_section "启用并验证"
    if ! swapon "$SWAP_FILE" 2>/dev/null; then
        log_err "swapon $SWAP_FILE 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        log_info "已恢复到变更前的状态，旧的 swap 文件仍在原处。"
        module_end
        return 1
    fi

    local why
    if ! why="$(_swap_verify "$SWAP_FILE" "$size_mb")"; then
        log_err "验证未通过（$why），正在回滚..."
        _swap_rollback "$SWAP_FILE"
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi

    log_ok "swap 已启用并验证通过。"
    rm -f "$old_file"        # 新文件确认可用，旧文件这时才真正删掉

    local sw
    sw="$(sysctl -n vm.swappiness 2>/dev/null)"
    if [[ "$sw" == "$SWAP_SWAPPINESS" ]]; then
        log_ok "vm.swappiness = $sw"
    else
        log_warn "vm.swappiness 实际是 ${sw:-未知}，不是 $SWAP_SWAPPINESS —— 有更高优先级的配置盖住了它。"
        log_info "排查: sysctl -n vm.swappiness; grep -rn swappiness /etc/sysctl.conf /etc/sysctl.d/"
    fi

    ui_section "当前状态"
    _swap_show_table
    log_info "重启后由 $SWAP_FSTAB 自动启用。"
    module_end
}

# ============================================================
# 3) 删除 —— 一次清掉所有文件形式的 swap
#
# 仍然是「明确识别的目标」：候选来自 /proc/swaps 里文件形式的条目，
# 加上管理路径本身，逐个在预览里列出来。分区和 zram 永不入选。
# ============================================================
swap_remove() {
    require_root

    local candidates=() f c
    while IFS= read -r f; do
        [[ -n "$f" ]] && candidates+=("$f")
    done < <(_swap_active_files)

    # 管理路径即使没启用也要能删（可能只是掉了 swapon，或只剩 fstab 条目）
    if [[ -f "$SWAP_FILE" ]] || [[ -n "$(_swap_fstab_lines "$SWAP_FILE")" ]] || _swap_is_active "$SWAP_FILE"; then
        local dup=0
        for f in ${candidates[@]+"${candidates[@]}"}; do
            [[ "$f" == "$SWAP_FILE" ]] && dup=1
        done
        (( dup )) || candidates+=("$SWAP_FILE")
    fi

    module_begin "删除 Swap"
    if (( ${#candidates[@]} == 0 )); then
        if [[ -n "$(_swap_active_all)" ]]; then
            log_warn "没有可删除的 swap 文件（本功能只处理文件形式的 swap）。"
            log_info "检测到的都是分区或 zram，请用其它工具处理："
            _swap_show_table
        else
            log_info "系统上没有任何正在使用的 swap，也没有 $SWAP_FILE。"
        fi
        module_end
        return 0
    fi

    # 逐个记下当前是否在跑：失败时要按文件恢复
    local active_flags=() i
    for c in "${candidates[@]}"; do
        if _swap_is_active "$c"; then
            active_flags+=("1")
        else
            active_flags+=("")
        fi
    done

    # 删完之后还剩什么 swap。分区 / zram 不入选，所以这里剩下的都是要保留的。
    local remaining=() in_list
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        in_list=0
        for c in "${candidates[@]}"; do
            [[ "$c" == "$f" ]] && in_list=1
        done
        (( in_list )) || remaining+=("$f")
    done < <(_swap_active_all)

    # 文件形式的 swap 清完、且不剩别的 swap 时，swappiness 配置才一起收走；
    # 若还剩分区 swap，它仍然受 swappiness 影响，配置得留着。
    local drop_sysctl=0
    if (( ${#remaining[@]} == 0 )) && [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        drop_sysctl=1
    fi

    # ---- 预览 ----
    module_begin "确认删除"
    ui_section "将要删除（${#candidates[@]} 个文件形式的 swap）"
    local total_mb=0 sz
    for i in "${!candidates[@]}"; do
        c="${candidates[i]}"
        if sz="$(_swap_file_mb "$c")"; then
            total_mb=$(( total_mb + sz ))
            if [[ -n "${active_flags[i]}" ]]; then
                printf '  %s-%s %s（%s，启用中，先 swapoff）\n' \
                    "$C_RED" "$C_RESET" "$c" "$(_swap_size_label "$sz")"
            else
                printf '  %s-%s %s（%s，未启用）\n' \
                    "$C_RED" "$C_RESET" "$c" "$(_swap_size_label "$sz")"
            fi
        else
            printf '  %s-%s %s（文件不存在，只清理配置）\n' "$C_RED" "$C_RESET" "$c"
        fi
    done
    (( total_mb > 0 )) && printf '  %s合计 %s%s\n' "$C_DIM" "$(_swap_size_label "$total_mb")" "$C_RESET"

    local lines any_fstab=0
    for c in "${candidates[@]}"; do
        lines="$(_swap_fstab_lines "$c")"
        [[ -n "$lines" ]] && any_fstab=1
    done
    if (( any_fstab )); then
        ui_section "$SWAP_FSTAB 中将移除的条目"
        for c in "${candidates[@]}"; do
            lines="$(_swap_fstab_lines "$c")"
            [[ -n "$lines" ]] || continue
            while IFS=$'\t' read -r n text; do
                printf '  %s-%s 第 %s 行: %s\n' "$C_RED" "$C_RESET" "$n" "$text"
            done <<<"$lines"
        done
    fi

    if (( drop_sysctl )); then
        printf '  %s-%s %s（并把 swappiness 还原为内核默认 %s）\n' \
            "$C_RED" "$C_RESET" "$SWAP_SYSCTL_CONF" "$SWAP_KERNEL_SWAPPINESS"
    elif [[ -e "$SWAP_SYSCTL_CONF" ]] && (( ${#remaining[@]} > 0 )); then
        printf '\n  %s%s 保留：删完还剩 swap（%s），它仍然受 swappiness 影响。%s\n' \
            "$C_DIM" "$SWAP_SYSCTL_CONF" "${remaining[*]}" "$C_RESET"
    fi

    if (( ${#remaining[@]} > 0 )); then
        ui_section "不在删除范围（保留）"
        for f in "${remaining[@]}"; do printf '  %s\n' "$f"; done
        printf '  %s分区与 zram 不归本功能管。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    log_warn "删除后文件内容无法恢复。"
    if ! confirm "确认删除这 ${#candidates[@]} 个 swap 文件?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    _swap_snapshot_config
    local ok_n=0 bad_n=0 fail=0
    for i in "${!candidates[@]}"; do
        c="${candidates[i]}"
        if _swap_teardown "$c"; then
            ok_n=$(( ok_n + 1 ))
        else
            bad_n=$(( bad_n + 1 ))
            fail=1
            # 关掉了却没删掉的话，把 swap 重新启起来，别留半截状态
            if [[ -n "${active_flags[i]}" ]] && [[ -e "$c" ]]; then
                swapon "$c" 2>/dev/null || true
                log_warn "已把 $c 重新启用，状态与删除前一致。"
            fi
        fi
        if ! _swap_fstab_clean "$c"; then
            log_err "清理 $SWAP_FSTAB 中指向 $c 的条目失败，请手动删除。"
            fail=1
        fi
    done

    if (( drop_sysctl )); then
        rm -f "$SWAP_SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1 || true
        local sw
        sw="$(sysctl -n vm.swappiness 2>/dev/null)"
        # 配置删了，内核里的当前值不会自己变回去。
        # 若没有别的配置接管，显式恢复成内核默认值。
        if [[ "$sw" == "$SWAP_SWAPPINESS" ]]; then
            sysctl -q -w "vm.swappiness=$SWAP_KERNEL_SWAPPINESS" 2>/dev/null || true
            sw="$(sysctl -n vm.swappiness 2>/dev/null)"
        fi
        log_ok "已移除 swappiness 配置，当前 vm.swappiness = ${sw:-未知}"
    fi

    ui_section "验证"
    for c in "${candidates[@]}"; do
        if _swap_is_active "$c"; then
            log_err "$c 仍在 /proc/swaps 里"
            fail=1
        fi
        if [[ -e "$c" ]]; then
            log_err "$c 文件仍然存在"
            fail=1
        fi
        if [[ -n "$(_swap_fstab_lines "$c")" ]]; then
            log_err "$SWAP_FSTAB 里还有指向 $c 的条目"
            fail=1
        fi
    done

    if (( fail )); then
        log_warn "有 $bad_n 个未能完整删除，请按上面的提示处理。"
        module_end
        return 1
    fi

    log_ok "已删除 ${ok_n} 个 swap 文件，fstab 与 swappiness 均已清理。"

    ui_section "当前状态"
    if [[ -n "$(_swap_active_all)" ]]; then
        _swap_show_table
    else
        printf '  %s已无 swap%s\n' "$C_DIM" "$C_RESET"
    fi
    module_end
}

# ---- 模块入口 ----
menu_swap() {
    local items=(
        "状态查看|swap 用量 / swappiness / fstab"
        "添加 / 重建|默认内存-1MB，已存在则删除重建"
        "删除|一次清掉所有文件形式的 swap"
    )
    local fns=(swap_status swap_add swap_remove)
    run_submenu "Swap 管理" items fns
}

register_module "swap" "Swap 管理" "menu_swap" "添加 / 删除 / swappiness"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 modules/08-time.sh
# ════════════════════════════════════════════════════════════
# ============================================================
# 模块: 时间与时区
# id: time
#
# 两件事：把系统时区设对（改的是「怎么看时间」），把系统时钟校准
# （改的是「时间本身」）。两者失败模式完全不同，所以流程也分开：
# 时区走「验证 → 预览 → 快照 → 原子替换 → 验证 → 失败回滚」，
# NTP 只动开关不碰时钟，「立即校时」单独确认。
#
# 只动 /etc/localtime 与 /etc/timezone 两个文件；硬件时钟与 /etc/adjtime
# 一律不碰（唯一例外是下面 _time_rtc_is_local 命中时，会先把后果讲清楚）。
#
# 时区名必须先验证通过才允许写入。这不是洁癖：TZ 指向坏文件时 date 不会
# 报错，而是静默按 UTC 走 —— 等于悄悄把系统时间搞错，比报错难查得多。
# ============================================================

TIME_LOCALTIME="${TIME_LOCALTIME:-/etc/localtime}"
TIME_TZFILE="${TIME_TZFILE:-/etc/timezone}"
TIME_ZONEINFO="${TIME_ZONEINFO:-/usr/share/zoneinfo}"
TIME_SYNC_WAIT="${TIME_SYNC_WAIT:-15}"      # 等首次同步的上限（秒）

# ============================================================
# 探测
# ============================================================

# timedatectl 装了不等于能用：非 systemd 的系统上它照样装得上，
# 一跑就报 "System has not been booted with systemd as init system"。
# 所以不能用 have_cmd 判断，要真跑一次 —— 见 _time_td_get。
_time_have_systemd() {
    [[ -d /run/systemd/system ]] && have_cmd timedatectl
}

# 取 timedatectl 属性，取不到返回非 0。
# --value 是 systemd 230 之后才有的，老版本退回解析 "Prop=值"。
_time_td_get() {
    local prop="$1" out
    _time_have_systemd || return 1
    if out="$(timedatectl show -p "$prop" --value 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
    fi
    out="$(timedatectl show -p "$prop" 2>/dev/null)" || return 1
    printf '%s' "${out#*=}"
}

# /etc/localtime 的形态：symlink | copy | missing
_time_localtime_kind() {
    if [[ -L "$TIME_LOCALTIME" ]]; then
        printf 'symlink'
    elif [[ -f "$TIME_LOCALTIME" ]]; then
        printf 'copy'
    else
        printf 'missing'
    fi
}

# /etc/localtime 是不是挂进来的（-v /etc/localtime:/etc/localtime:ro 很常见）。
# 有挂载行就说明容器里改它等于改宿主机，且重建即失效。
# 没命中要返回非 0 —— awk 无匹配时是「空输出 + 退出码 0」，
# 光看退出码会把「不是挂载点」误判成挂载点。
_time_localtime_mountinfo() {
    local line=''
    [[ -r /proc/self/mountinfo ]] || return 1
    line="$(awk -v p="$TIME_LOCALTIME" '$5 == p { print $0; exit }' /proc/self/mountinfo)"
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# 当前时区名。取不到返回非 0（输出为空）。
#
# 三条独立来源依次尝试，任何一条能用就返回：
#   timedatectl   —— systemd 下最权威，且它自己已按 verify_timezone 校过
#   /etc/localtime 符号链接
#   /etc/timezone —— Debian 系的老式纯文本记录，可能是陈旧的
#
# 注意 timedatectl 在 /etc/localtime 是「普通文件副本」时输出空串
# （它内部 readlink 拿不到名字，没有扫描 zoneinfo 的兜底），
# 所以不能因为它返回空就断定没有时区。
_time_tz_current() {
    local tz='' target

    if _time_have_systemd; then
        tz="$(_time_td_get Timezone)"
        [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    fi

    if [[ -L "$TIME_LOCALTIME" ]]; then
        # 先 readlink（不解析）拿到原始目标：readlink -f 在副本文件上会
        # 原样吐出 /etc/localtime，拿它当名字来源是错的
        target="$(readlink "$TIME_LOCALTIME" 2>/dev/null)"
        case "$target" in
            "${TIME_ZONEINFO}/"*) printf '%s' "${target#"${TIME_ZONEINFO}/"}"; return 0 ;;
            "../usr/share/zoneinfo/"*) printf '%s' "${target#../usr/share/zoneinfo/}"; return 0 ;;
        esac
    fi

    if [[ -r "$TIME_TZFILE" ]]; then
        tz="$(head -n1 "$TIME_TZFILE" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    fi

    return 1
}

# 名字是从哪来的 —— 状态页要分开显示各来源，不能揉成一行。
# 各来源不一致时，合并显示正是误诊的根源。
_time_tz_source_label() {
    if _time_have_systemd && [[ -n "$(_time_td_get Timezone)" ]]; then
        printf 'timedatectl（systemd 管理）'
        return 0
    fi
    case "$(_time_localtime_kind)" in
        symlink) printf '%s 符号链接' "$TIME_LOCALTIME" ;;
        copy)    printf '%s 普通文件（时区副本，读不出名字）' "$TIME_LOCALTIME" ;;
        *)       printf '未知' ;;
    esac
}

# ============================================================
# 校验
#
# 四道门，任一不过即拒。前三道对应用户输入的错误类型，
# 第四道挡住「存在但内容不是时区」的文件。
# ============================================================

# 头四字节是不是 TZif（tzfile 的魔数）。
# zoneinfo 顶层躺着 leapseconds 这类纯文本文件，光看存在性会放它过去。
#
# 用 read -n 4 而不是 head -c 4：后者每个文件 fork 一次，浏览全部时区时
# 要校验四百多个文件，实测 1.3 秒，进菜单前会明显卡一下；read 是内建，
# 同样这批文件 0.016 秒。两者对真实/伪造 tzfile 的判定完全一致。
_time_tz_is_tzfile() {
    local magic=''
    IFS= read -r -n 4 magic <"$1" 2>/dev/null
    [[ "$magic" == "TZif" ]]
}

_time_tz_valid() {
    local tz="$1" f

    [[ -n "$tz" ]] || return 1

    # 门 1：字符集与分段。与 systemd verify_timezone() 的字符集一致
    # （多一个 -），保证我们放行的名字 timedatectl 也一定认。
    # 禁掉 '.' 是关键：既堵死 ../../etc/passwd 这类穿越，又顺带排除
    # zoneinfo 下的 zone.tab / tzdata.zi 等元数据 —— 实测真实时区名
    # 没有一个是带点的。
    [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1

    # 门 2：已知的陷阱名，逐个挡住（这些都能通过门 1 和门 3）：
    #   localtime    /usr/share/zoneinfo/localtime 是指回 /etc/localtime 的
    #                链接，装上去就成了符号链接自我循环
    #   posixrules   软链到 America/New_York，用户会莫名其妙拿到纽约时间
    #   Factory      合法 TZif 但不属于任何地区，缩写只会是 -00
    #   right/*      带闰秒，比 UTC 快约 27 秒 —— Debian 上没有，
    #                RHEL/Arch 的 zoneinfo 里有，属于发布后才暴露的坑
    #   posix/*      同一时区的副本，没有理由选它
    case "$tz" in
        localtime|posixrules|Factory) return 1 ;;
        right/*|posix/*)              return 1 ;;
    esac

    # 门 3：必须真实存在且是普通文件（跟随符号链接）。挡掉 'Asia'
    # 这种只写了目录名的输入，也挡掉失效链接。
    f="$TIME_ZONEINFO/$tz"
    [[ -f "$f" ]] || return 1

    # 门 4：内容得真是时区数据
    _time_tz_is_tzfile "$f"
}

# 无效时给一句有指向性的说明，省得用户对着「无效」两个字猜
_time_tz_hint() {
    local tz="$1" head
    local f="$TIME_ZONEINFO/$tz"
    if [[ "$tz" == *..* ]]; then
        log_info "时区名里不允许出现 .."
        return 0
    fi
    head="${tz%%/*}"
    if [[ -d "$TIME_ZONEINFO/$tz" ]]; then
        log_info "$tz 是个目录，请写到具体城市，例如 $(_time_tz_suggest "$tz")"
    elif [[ -f "$f" ]]; then
        log_info "$f 不是时区数据文件，换个名字试试"
    elif [[ -d "$TIME_ZONEINFO/$head" ]]; then
        log_info "提示: ls $TIME_ZONEINFO/$head 可以看到该地区下有哪些城市"
    elif [[ ! -d "$TIME_ZONEINFO" ]]; then
        log_info "$TIME_ZONEINFO 不存在，需要先安装 tzdata"
    fi
    return 0
}

# 目录名 → 该目录下第一个真实时区，只用作提示
_time_tz_suggest() {
    local dir="$TIME_ZONEINFO/$1" f
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*; do
            [[ -f "$f" ]] || continue
            _time_tz_is_tzfile "$f" || continue
            printf '%s/%s' "$1" "$(basename "$f")"
            return 0
        done
    fi
    printf '%s/城市名' "$1"
}

# 偏移与缩写。必须现算 —— Etc/GMT+8 是 POSIX 反向记法（实际 -0800），
# 夏令时也会让写死的值出错。
_time_tz_offset() { TZ="$1" date '+%z' 2>/dev/null; }

_time_tz_label() {
    local tz="$1" abbr off
    abbr="$(TZ="$tz" date '+%Z' 2>/dev/null)"
    off="$(_time_tz_offset "$tz")"
    if [[ -n "$off" ]]; then
        printf '%s (%s, %s)' "$tz" "${abbr:-?}" "$off"
    else
        printf '%s' "$tz"
    fi
}

# 硬件时钟是否按本地时间走（/etc/adjtime 第三行是 LOCAL）。
# 命中时改时区会连带改变 RTC 数值的含义，重启后系统时钟会跳 ——
# 这是本功能里唯一会真正动到时钟的操作，必须单独提示。
_time_rtc_is_local() {
    local f=/etc/adjtime
    if [[ -r "$f" ]]; then
        [[ "$(sed -n '3p' "$f" 2>/dev/null)" == "LOCAL" ]] && return 0
    fi
    if _time_have_systemd; then
        [[ "$(_time_td_get LocalRTC)" == "yes" ]] && return 0
    fi
    return 1
}

# ============================================================
# 写入 / 回滚
# ============================================================

# 原子替换符号链接：先在旁边建好，再一次 rename 到位。
# 不用 ln -sfn —— 那是先删后建，中间那一瞬间 /etc/localtime 不存在，
# 此刻读时间的进程会看到 UTC。
_time_tz_link() {
    local target="$1" link="$2" tmp

    # 目标是目录时 mv 会「移进去」而不是替换。GNU 的 -T 能避免，
    # busybox（Alpine）没有 -T，所以在这里先挡一道。
    [[ -d "$link" ]] && return 1

    tmp="${link}.tmp.$$"
    rm -f "$tmp"
    ln -s "$target" "$tmp" 2>/dev/null || return 1

    if mv -T "$tmp" "$link" 2>/dev/null; then
        return 0
    fi
    # 老 coreutils / busybox 的 mv 没有 -T，退回两步式（窗口极短）
    rm -f "$tmp"
    rm -f "$link" && ln -s "$target" "$link"
}

# /etc/timezone 是 Debian 系的约定文件，dpkg-reconfigure tzdata 会读它
# 并把 /etc/localtime 按它重写 —— 只改链接不改它，下次 apt 升级 tzdata
# 时区可能被悄悄改回去。其它发行版没人读这个文件，就不凭空造一个。
_time_tz_write_tzfile() {
    local tz="$1" tmp
    case "$DISTRO_FAMILY" in
        debian) ;;
        *) [[ -e "$TIME_TZFILE" ]] || return 0 ;;
    esac
    tmp="${TIME_TZFILE}.tmp.$$"
    printf '%s\n' "$tz" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$TIME_TZFILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_time_tz_apply() {
    local tz="$1"

    # 有 systemd 就交给 timedatectl 管 /etc/localtime：绕过它手工改
    # 会让它的状态和磁盘对不上。
    if _time_have_systemd; then
        if timedatectl set-timezone "$tz" 2>/dev/null; then
            # 但 timedatectl 不碰 /etc/timezone —— 实测 systemd 257 上
            # 文件已存在也不更新，会留下陈旧内容。而 Debian 的 tzdata
            # postinst 与 dpkg-reconfigure tzdata 恰恰读它，于是下一次
            # apt 升级 tzdata 就可能把用户刚设好的时区改回去。所以补齐。
            _time_tz_write_tzfile "$tz" \
                || log_warn "更新 $TIME_TZFILE 失败；时区本身已生效，但升级 tzdata 时可能被改回去"
            return 0
        fi
        log_warn "timedatectl set-timezone 失败，改用直接写文件的方式"
    fi

    _time_tz_link "$TIME_ZONEINFO/$tz" "$TIME_LOCALTIME" || {
        log_err "写入 $TIME_LOCALTIME 失败"
        return 1
    }
    _time_tz_write_tzfile "$tz" || {
        log_err "写入 $TIME_TZFILE 失败"
        return 1
    }
    return 0
}

# 记录现场。
#
# /etc/localtime 是二进制 tzfile，含 NUL 字节，$(cat) 那种存内存的写法
# （07-swap 的 fstab、04-network 的 resolv.conf 用的）会把它毁掉，还原时
# 就得到一个损坏的文件。所以按字节复制到临时目录 —— 和 _net_snapshot 一样。
# cp -a 还有个好处：符号链接按链接复制，相对目标的相对性天然保持。
_time_tz_snapshot() {
    TIME_SNAP_DIR=''
    TIME_SNAP_KIND=''
    TIME_SNAP_TZ_EXISTED=''

    TIME_SNAP_DIR="$(mktemp -d 2>/dev/null)" || return 1

    TIME_SNAP_KIND="$(_time_localtime_kind)"
    if [[ "$TIME_SNAP_KIND" != "missing" ]]; then
        cp -a "$TIME_LOCALTIME" "$TIME_SNAP_DIR/localtime" 2>/dev/null || return 1
    fi

    if [[ -e "$TIME_TZFILE" ]]; then
        TIME_SNAP_TZ_EXISTED=1
        cp -a "$TIME_TZFILE" "$TIME_SNAP_DIR/timezone" 2>/dev/null || return 1
    fi
    return 0
}

_time_tz_snapshot_cleanup() {
    [[ -n "${TIME_SNAP_DIR:-}" && -d "${TIME_SNAP_DIR:-}" ]] && rm -rf "$TIME_SNAP_DIR"
    TIME_SNAP_DIR=''
    return 0
}

_time_tz_rollback() {
    local old="${TIME_SNAP_OLD_TZ:-}"

    # 原时区名有效且 systemd 在管，就交回 timedatectl 还原 ——
    # 它同时管着 /etc/localtime 和 /etc/timezone，手工改容易留下不一致
    if [[ -n "$old" ]] && _time_have_systemd && _time_tz_valid "$old"; then
        if timedatectl set-timezone "$old" 2>/dev/null; then
            _time_tz_snapshot_cleanup
            return 0
        fi
    fi

    [[ -n "${TIME_SNAP_DIR:-}" && -d "${TIME_SNAP_DIR:-}" ]] || return 0

    if [[ -n "${TIME_SNAP_KIND:-}" && "${TIME_SNAP_KIND}" != "missing" ]]; then
        rm -f "$TIME_LOCALTIME"
        cp -a "$TIME_SNAP_DIR/localtime" "$TIME_LOCALTIME" 2>/dev/null || true
    else
        rm -f "$TIME_LOCALTIME"
    fi

    if [[ -n "${TIME_SNAP_TZ_EXISTED:-}" ]]; then
        cp -a "$TIME_SNAP_DIR/timezone" "$TIME_TZFILE" 2>/dev/null || true
    else
        rm -f "$TIME_TZFILE"      # 原本没有就得删掉，不能留个空文件
    fi

    _time_tz_snapshot_cleanup
    return 0
}

# 写入后验证。不通过则输出原因。
#
# 不能用 TZ="$tz" date 判断好坏 —— 名字无效时它会静默退回 +0000 而不报错。
# 所以只断言两件能直接检验的事：链接身份、内容是真正的 tzfile。
#
# 曾经这里还有第三条「unset TZ 的 date 与 TZ=$tz 的 date 结果应当一致」。
# 去掉了：它读的是全局 /etc/localtime 而不是本模块的 TIME_LOCALTIME，
# 换路径就没法测；而且前两条已经蕴含了它（链接正好指向那个文件，两边
# 读的就是同一个 tzfile），它只能带来夏令时临界点上跨秒的误报。
_time_tz_verify() {
    local tz="$1" want
    want="$TIME_ZONEINFO/$tz"

    [[ -L "$TIME_LOCALTIME" ]] || { printf '不是符号链接'; return 1; }
    [[ "$(readlink -f "$TIME_LOCALTIME" 2>/dev/null)" == "$want" ]] \
        || { printf '链接指向别处'; return 1; }
    _time_tz_is_tzfile "$TIME_LOCALTIME" || { printf '不是 TZif 文件'; return 1; }
    return 0
}

# ============================================================
# NTP 探测
# ============================================================

# 单元文件在不在盘上（判断「装没装」，不看是否在跑）。
# 不能用 have_cmd：systemd-timesyncd 的二进制在 /usr/lib/systemd/ 下，
# 不在 PATH 里。也正因为先查单元文件，Arch 上 timesyncd 随 systemd 包
# 自带的情况自然被识别为「已安装」，不会去装一个不存在的包。
_time_unit_installed() {
    local u="$1" d
    for d in /etc/systemd/system /run/systemd/system \
             /usr/lib/systemd/system /lib/systemd/system; do
        [[ -f "$d/$u.service" ]] && return 0
    done
    return 1
}

_time_ntp_unit() {
    local u
    for u in systemd-timesyncd chronyd ntpd; do
        _time_unit_installed "$u" && { printf '%s' "$u"; return 0; }
    done
    return 1
}

_time_ntp_active() {
    have_cmd systemctl || return 1
    systemctl is-active --quiet "$1.service" 2>/dev/null
}

# 需要装的包名；已经有校时服务了就输出空串
_time_ntp_pkg() {
    _time_ntp_unit >/dev/null && return 0
    case "$DISTRO_FAMILY" in
        debian) printf 'systemd-timesyncd' ;;   # 单包，且直接被 timedatectl 接管
        rhel)   printf 'systemd-timesyncd' ;;   # RHEL9+/Fedora 有，老版本装不上会退 chrony
        *)      printf 'chrony' ;;
    esac
    return 0
}

# 等首次同步，最多 TIME_SYNC_WAIT 秒。
# 用循环计数而不是 date +%s 算截止时间 —— 这个功能的全部意义就是时钟
# 可能被步进，拿一个正在被改的时钟去算超时是不靠谱的。
_time_ntp_wait_sync() {
    local i
    (( TIME_SYNC_WAIT > 0 )) || return 1
    for (( i=0; i<TIME_SYNC_WAIT; i++ )); do
        [[ "$(_time_td_get NTPSynchronized)" == "yes" ]] && { printf '\n'; return 0; }
        printf '.'
        sleep 1
    done
    printf '\n'
    return 1
}

# ============================================================
# NTP 服务器配置
#
# 三套实现的写法完全不同：
#   systemd-timesyncd  写 /etc/systemd/timesyncd.conf.d/ 下的 drop-in，
#                      发行版自带的 timesyncd.conf 一字不动（那个文件自己的
#                      注释就推荐用 drop-in）
#   chrony / ntpd      在主配置里维护一个带标记的块
#
# 两者都只新增，不改动用户原有的行：chrony 与 ntpd 会在多个源之间自动挑
# 可达的，所以保留原有的 pool / server 不会冲突，也省得去猜哪一行能动。
# 撤销就是删掉我们写的那一份（drop-in 文件，或标记块）。
# ============================================================

TIME_TIMESYNCD_DROPIN="${TIME_TIMESYNCD_DROPIN:-/etc/systemd/timesyncd.conf.d/99-linux-toolkit.conf}"
TIME_CHRONY_CONF_DEB="${TIME_CHRONY_CONF_DEB:-/etc/chrony/chrony.conf}"
TIME_CHRONY_CONF_ALT="${TIME_CHRONY_CONF_ALT:-/etc/chrony.conf}"
TIME_NTPD_CONF="${TIME_NTPD_CONF:-/etc/ntp.conf}"

TIME_BLOCK_BEGIN='# >>> linux-toolkit ntp servers >>>'
TIME_BLOCK_END='# <<< linux-toolkit ntp servers <<<'

# 备选服务器。国内可达性优先，国际的放后面。
NTP_SERVER_LIST=(
    "ntp.aliyun.com"
    "ntp.tencent.com"
    "cn.pool.ntp.org"
    "cn.ntp.org.cn"
    "ntp.ntsc.ac.cn"
    "time.cloudflare.com"
    "pool.ntp.org"
)
NTP_SERVER_NOTE=(
    "阿里云"
    "腾讯云"
    "NTP Pool 中国"
    "国家授时中心"
    "国家授时中心 NTSC"
    "Cloudflare"
    "国际 NTP Pool"
)

# 当前在用的校时实现。systemd 单元优先，其次按命令找 ——
# Alpine 这类没有 systemd 单元，只有命令。
_time_ntp_impl() {
    local u=''
    u="$(_time_ntp_unit || true)"
    [[ -n "$u" ]] && { printf '%s' "$u"; return 0; }
    if have_cmd chronyd; then printf 'chronyd'; return 0; fi
    if have_cmd systemd-timesyncd; then printf 'systemd-timesyncd'; return 0; fi
    if have_cmd ntpd; then printf 'ntpd'; return 0; fi
    return 1
}

# 该实现要写的配置文件
_time_ntp_conf() {
    case "$1" in
        systemd-timesyncd) printf '%s' "$TIME_TIMESYNCD_DROPIN" ;;
        chronyd)
            if [[ -e "$TIME_CHRONY_CONF_DEB" ]]; then
                printf '%s' "$TIME_CHRONY_CONF_DEB"
            else
                printf '%s' "$TIME_CHRONY_CONF_ALT"
            fi
            ;;
        ntpd) printf '%s' "$TIME_NTPD_CONF" ;;
        *)    return 1 ;;
    esac
}

# 配置里当前的服务器（每行一个）
_time_ntp_servers_current() {
    local conf=''
    case "$1" in
        systemd-timesyncd)
            [[ -r "$TIME_TIMESYNCD_DROPIN" ]] || return 0
            awk -F= '/^NTP=/ { print $2 }' "$TIME_TIMESYNCD_DROPIN"
            ;;
        chronyd)
            conf="$(_time_ntp_conf chronyd)"
            [[ -r "$conf" ]] || return 0
            awk '$1 == "server" || $1 == "pool" { print $2 }' "$conf"
            ;;
        ntpd)
            [[ -r "$TIME_NTPD_CONF" ]] || return 0
            awk '$1 == "server" { print $2 }' "$TIME_NTPD_CONF"
            ;;
    esac
}

# 探测服务器是否真的应答：ok / nodns / noresp / unprobe
#
# 只查 DNS 不够 —— 名字能解析不代表 UDP 123 通得过，等配置写完才发现
# 连不上等于白改。这里真发一个 NTP 客户端请求过去看应答。
#
# 关键：48 字节必须一次 write 出去。UDP 面向报文，用
# `{ printf '\x1b'; head -c 47 /dev/zero; } >&3` 这种写法会分成两次
# write，变成 1 字节 + 47 字节两个无效包，服务器看都不看，于是所有
# 服务器都「无应答」—— 这个坑实测踩过。
_time_probe_ntp() {
    local host="$1" resp

    have_cmd timeout || { printf 'unprobe'; return 0; }

    if have_cmd getent && ! getent hosts "$host" >/dev/null 2>&1; then
        printf 'nodns'
        return 0
    fi

    exec 3<>"/dev/udp/$host/123" 2>/dev/null || { printf 'nodns'; return 0; }
    printf '\x1b\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' >&3 2>/dev/null
    resp="$(timeout 4 dd bs=48 count=1 <&3 2>/dev/null | od -An -tx1 | head -1)"
    exec 3<&- 2>/dev/null

    [[ -n "$resp" ]] && printf 'ok' || printf 'noresp'
}

# 把服务器写进配置。只新增，不动用户原有的行；重复执行不会累积。
_time_ntp_servers_write() {
    local impl="$1" servers="$2" conf='' tmp='' mode='' s=''

    if [[ "$impl" == "systemd-timesyncd" ]]; then
        mkdir -p "$(dirname "$TIME_TIMESYNCD_DROPIN")" || return 1
        printf '[Time]\nNTP=%s\n' "$servers" >"$TIME_TIMESYNCD_DROPIN" || return 1
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")" || return 1
    tmp="$(mktemp)" || return 1

    # 先摘掉上次写的块，再追加新的
    if [[ -r "$conf" ]]; then
        awk -v b="$TIME_BLOCK_BEGIN" -v e="$TIME_BLOCK_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip
        ' "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }
    fi
    {
        printf '%s\n' "$TIME_BLOCK_BEGIN"
        for s in $servers; do printf 'server %s iburst\n' "$s"; done
        printf '%s\n' "$TIME_BLOCK_END"
    } >>"$tmp" || { rm -f "$tmp"; return 1; }

    if [[ -e "$conf" ]]; then
        mode="$(stat -c %a "$conf" 2>/dev/null || echo 644)"
        install -m "$mode" "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    else
        install -m 0644 "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
    return 0
}

# 撤掉本工具写的配置，回到发行版默认
_time_ntp_servers_clear() {
    local impl="$1" conf='' tmp='' mode=''

    if [[ "$impl" == "systemd-timesyncd" ]]; then
        rm -f "$TIME_TIMESYNCD_DROPIN"
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")" || return 1
    [[ -r "$conf" ]] || return 0
    grep -qF -- "$TIME_BLOCK_BEGIN" "$conf" || return 0   # 没有我们的块，什么都不用做

    tmp="$(mktemp)" || return 1
    awk -v b="$TIME_BLOCK_BEGIN" -v e="$TIME_BLOCK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }

    mode="$(stat -c %a "$conf" 2>/dev/null || echo 644)"
    install -m "$mode" "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    # 摘掉我们的块之后一个字都不剩，说明这个文件本来就是为它建的，
    # 一并删掉，避免留一个空配置文件让人困惑（注释行也算内容，会保留）
    if ! grep -qvE '^[[:space:]]*$' "$conf" 2>/dev/null; then
        rm -f "$conf"
    fi
    return 0
}

_time_ntp_conf_snapshot() {
    local conf
    TIME_SRV_SNAP_DIR=''
    TIME_SRV_SNAP_EXISTED=''
    TIME_SRV_CONF="$(_time_ntp_conf "$1")" || return 1
    conf="$TIME_SRV_CONF"

    TIME_SRV_SNAP_DIR="$(mktemp -d 2>/dev/null)" || return 1
    if [[ -e "$conf" ]]; then
        TIME_SRV_SNAP_EXISTED=1
        cp -a "$conf" "$TIME_SRV_SNAP_DIR/conf" 2>/dev/null || return 1
    fi
    return 0
}

_time_ntp_conf_snapshot_cleanup() {
    [[ -n "${TIME_SRV_SNAP_DIR:-}" && -d "${TIME_SRV_SNAP_DIR:-}" ]] && rm -rf "$TIME_SRV_SNAP_DIR"
    TIME_SRV_SNAP_DIR=''
    return 0
}

_time_ntp_conf_rollback() {
    [[ -n "${TIME_SRV_SNAP_DIR:-}" && -d "${TIME_SRV_SNAP_DIR:-}" ]] || return 0
    if [[ -n "${TIME_SRV_SNAP_EXISTED:-}" ]]; then
        cp -a "$TIME_SRV_SNAP_DIR/conf" "$TIME_SRV_CONF" 2>/dev/null || true
    else
        rm -f "$TIME_SRV_CONF"      # 原本没有就得删掉，不能留个我们建的文件
    fi
    _time_ntp_conf_snapshot_cleanup
    return 0
}

# 写完后确认服务器真的进了生效配置。
# timesyncd 用 systemd-analyze cat-config 看合并后的结果 —— 这能证明
# drop-in 的路径与写法都被认了，而不只是「文件写出去了」。
_time_ntp_servers_verify() {
    local impl="$1" servers="$2" conf='' eff='' s=''

    if [[ "$impl" == "systemd-timesyncd" ]] && have_cmd systemd-analyze; then
        if eff="$(systemd-analyze cat-config systemd/timesyncd.conf 2>/dev/null)" && [[ -n "$eff" ]]; then
            for s in $servers; do
                [[ "$eff" == *"$s"* ]] || { printf '生效配置里没有 %s' "$s"; return 1; }
            done
            return 0
        fi
    fi

    conf="$(_time_ntp_conf "$impl")"
    [[ -r "$conf" ]] || { printf '%s 读不到' "$conf"; return 1; }
    for s in $servers; do
        grep -qF -- "$s" "$conf" || { printf '配置里没有 %s' "$s"; return 1; }
    done
    return 0
}

# 让新配置生效：重启校时服务，并等它真的连上其中一个服务器
_time_ntp_reload() {
    local impl="$1" servers="$2" srv='' i s=''

    case "$impl" in
        systemd-timesyncd)
            _time_have_systemd || return 0
            [[ "$(_time_td_get NTP)" == "yes" ]] || {
                log_info "NTP 自动校时当前是关闭的，配置已写入，等开启后生效。"
                return 0
            }
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || {
                log_warn "重启 systemd-timesyncd 失败，配置已写入但可能未生效。"
                return 0
            }
            # 没指定服务器（恢复默认的场景）就只确认服务起来了 ——
            # 不去等它连上谁，否则会白白等满超时再报一句吓人的假警报
            if [[ -z "${servers// /}" ]]; then
                log_ok "服务已重启，已回到发行版默认服务器。"
                return 0
            fi
            for (( i=0; i<10; i++ )); do
                srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
                for s in $servers; do
                    [[ "$srv" == *"$s"* ]] && { log_ok "已连上 $srv"; return 0; }
                done
                sleep 1
            done
            log_warn "服务已重启，但 10 秒内没看到它连上指定的服务器。"
            log_info "可能是出站 UDP 123 不通，稍后可用「状态查看」再看。"
            ;;
        *)
            # chrony / ntpd 走各自的 init
            if have_cmd systemctl && _time_have_systemd; then
                systemctl restart "$impl" >/dev/null 2>&1 && log_ok "已重启 $impl"
            elif have_cmd rc-service; then
                rc-service "$impl" restart >/dev/null 2>&1 && log_ok "已重启 $impl"
            elif have_cmd service; then
                service "$impl" restart >/dev/null 2>&1 && log_ok "已重启 $impl"
            else
                log_info "没找到可用的服务管理命令，请手动重启 $impl 让配置生效。"
            fi
            ;;
    esac
    return 0
}

# 恢复发行版默认
_time_ntp_server_restore() {
    local impl="$1" conf=''

    conf="$(_time_ntp_conf "$impl")"

    module_begin "恢复默认校时服务器"
    ui_section "将删除"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        if [[ -e "$TIME_TIMESYNCD_DROPIN" ]]; then
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$TIME_TIMESYNCD_DROPIN"
        else
            printf '  %s本工具没有写过配置，无需删除%s\n' "$C_DIM" "$C_RESET"
            module_end
            return 0
        fi
    else
        if [[ -r "$conf" ]] && grep -qF -- "$TIME_BLOCK_BEGIN" "$conf"; then
            printf '  %s-%s %s 中本工具写的那一段（标记之间）\n' "$C_RED" "$C_RESET" "$conf"
            printf '  %s  用户原有的 pool / server 行一律保留%s\n' "$C_DIM" "$C_RESET"
        else
            printf '  %s本工具没有写过配置，无需删除%s\n' "$C_DIM" "$C_RESET"
            module_end
            return 0
        fi
    fi

    ui_section "不受影响"
    printf '  %s发行版自带的配置文件、其它服务器配置一律不动%s\n' "$C_DIM" "$C_RESET"
    printf '  %s校时服务本身不卸载、不停止%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认恢复默认?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if ! _time_ntp_conf_snapshot "$impl"; then
        log_err "无法备份现有配置，为安全起见不做修改。"
        module_end
        return 1
    fi
    if ! _time_ntp_servers_clear "$impl"; then
        log_err "删除失败，正在回滚..."
        _time_ntp_conf_rollback
        module_end
        return 1
    fi
    _time_ntp_conf_snapshot_cleanup
    log_ok "已恢复发行版默认。"
    _time_ntp_reload "$impl" ""
    module_end
}

# ============================================================
# 设置 NTP 服务器
# ============================================================
time_ntp_server() {
    require_root

    local impl='' conf='' cur='' i s='' servers='' custom_idx=0
    local items=() srv='' mode=''
    local ok_n=0 bad_n=0 unres_n=0 bad_list='' unres_list=''

    module_begin "设置 NTP 服务器"

    if ! impl="$(_time_ntp_impl)"; then
        log_warn "系统里没有安装任何校时服务，暂时无处可写。"
        log_info "请先执行「开启自动校时」装一个（那里会说明装的是哪个），再回来设置服务器。"
        module_end
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")"
    cur="$(_time_ntp_servers_current "$impl" | tr '\n' ' ')"
    cur="${cur% }"

    ui_section "当前状态"
    ui_kv "校时实现" "$impl"
    ui_kv "配置文件" "$conf"
    if [[ -n "$cur" ]]; then
        ui_kv "当前服务器" "$cur"
    else
        ui_kv "当前服务器" "本工具未配置过"
    fi
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
        [[ -n "$srv" ]] && ui_kv "正在使用" "$srv"
    fi

    for (( i=0; i<${#NTP_SERVER_LIST[@]}; i++ )); do
        items+=("${NTP_SERVER_LIST[i]}|${NTP_SERVER_NOTE[i]}")
    done
    custom_idx=${#items[@]}
    items+=("手动输入地址|可填多个，空格分隔")
    items+=("恢复默认|删掉本工具写的配置")

    ui_menu "选择 NTP 服务器" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0

    if (( UI_CHOICE == custom_idx + 1 )); then
        _time_ntp_server_restore "$impl"
        return $?
    fi

    if (( UI_CHOICE == custom_idx )); then
        module_begin "手动输入 NTP 服务器"
        printf '  %s可填多个，用空格分隔。例: ntp.aliyun.com ntp.tencent.com%s\n\n' "$C_DIM" "$C_RESET"
        while true; do
            if ! ask "服务器地址（直接回车放弃）" ""; then
                log_info "输入中断，已取消。"
                return 0
            fi
            servers="${REPLY//,/ }"
            [[ -n "${servers// /}" ]] || { log_info "未输入，已取消。"; return 0; }

            # 逐个体检。只允许主机名 / IPv4 的字符集 —— 地址要拼进配置文件，
            # 放行任意字符等于让用户能往配置里注任意内容
            local bad=''
            for s in $servers; do
                [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || { bad="$s"; break; }
            done
            if [[ -n "$bad" ]]; then
                log_warn "「$bad」不是合法的服务器地址（只允许字母、数字与 . _ -）"
                continue
            fi
            break
        done
    else
        servers="${NTP_SERVER_LIST[UI_CHOICE]}"
    fi

    # ---- 探测：真发 NTP 请求，不只看 DNS ----
    module_begin "探测服务器"
    for s in $servers; do
        case "$(_time_probe_ntp "$s")" in
            ok)      log_ok "$s 应答正常"; ok_n=$(( ok_n + 1 )) ;;
            nodns)   log_err "$s 解析不了（域名可能写错）"; bad_n=$(( bad_n + 1 )); bad_list+="$s " ;;
            noresp)  log_warn "$s 无应答（UDP 123 可能不通）"; unres_n=$(( unres_n + 1 )); unres_list+="$s " ;;
            *)       log_info "本机无法探测，跳过"; unres_n=$(( unres_n + 1 )); unres_list+="$s " ;;
        esac
    done

    if (( bad_n > 0 )); then
        log_err "有地址解析不了，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将写入"
    ui_kv "配置文件" "$conf"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        ui_kv "形式" "drop-in 文件（发行版自带的 timesyncd.conf 不动）"
        printf '  %s[Time]%s\n' "$C_DIM" "$C_RESET"
        printf '  %sNTP=%s%s\n' "$C_BCYAN" "$servers" "$C_RESET"
    else
        ui_kv "形式" "在配置文件末尾追加一个带标记的块"
        for s in $servers; do
            printf '  %s+%s server %s iburst\n' "$C_GREEN" "$C_RESET" "$s"
        done
    fi

    ui_section "不会改动"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        printf '  %s发行版自带的 /etc/systemd/timesyncd.conf 一字不动%s\n' "$C_DIM" "$C_RESET"
    else
        printf '  %s已有的 pool / server 行一律保留 —— %s 会在多个源之间自动挑可达的%s\n' \
            "$C_DIM" "$impl" "$C_RESET"
        printf '  %s只动标记块之内的内容%s\n' "$C_DIM" "$C_RESET"
    fi
    printf '  %s时区、NTP 开关状态、软件包一律不动%s\n' "$C_DIM" "$C_RESET"

    ui_section "将备份（仅失败回滚用，成功后删除）"
    if [[ -e "$conf" ]]; then
        ui_kv "$conf" "整份复制到临时目录"
    else
        printf '  %s%s 不存在，将新建（回滚时会删掉它）%s\n' "$C_DIM" "$conf" "$C_RESET"
    fi

    if (( unres_n > 0 )); then
        printf '\n'
        log_warn "以下服务器没有应答: ${unres_list% }"
        log_info "可能只是 UDP 123 出站被挡。仍可写入，但同步未必能成。"
    fi

    printf '\n'
    if ! confirm "确认写入?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    if ! _time_ntp_conf_snapshot "$impl"; then
        log_err "无法备份现有配置，为安全起见不做任何修改。"
        _time_ntp_conf_snapshot_cleanup
        module_end
        return 1
    fi

    if ! _time_ntp_servers_write "$impl" "$servers"; then
        log_err "写入失败，正在回滚..."
        _time_ntp_conf_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "已写入 $conf"

    # ---- 验证 ----
    if ! mode="$(_time_ntp_servers_verify "$impl" "$servers")"; then
        log_err "验证未通过（$mode），正在回滚..."
        _time_ntp_conf_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "生效配置中已包含所选服务器"

    _time_ntp_conf_snapshot_cleanup
    _time_ntp_reload "$impl" "$servers"

    ui_section "设置后"
    ui_kv "配置文件" "$conf"
    ui_kv "服务器" "$servers"
    module_end
}

# ============================================================
# 1) 状态查看（只读）
# ============================================================
time_status() {
    local tz kind

    ui_section "当前时间"
    # 本进程若带着 TZ 环境变量，date 显示的是 TZ 的结果而不是系统时区 ——
    # 这正是「改了时区却没生效」最常见的误诊来源，先把它摆出来
    if [[ -n "${TZ:-}" ]]; then
        ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')  ${C_YELLOW}← 受环境变量 TZ=$TZ 影响${C_RESET}"
    else
        ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    ui_kv "时间戳" "$(date +%s)"

    ui_section "时区"
    if tz="$(_time_tz_current)"; then
        ui_kv "时区" "$(_time_tz_label "$tz")"
    else
        ui_kv "时区" "读不出名字"
    fi
    ui_kv "来源" "$(_time_tz_source_label)"

    kind="$(_time_localtime_kind)"
    case "$kind" in
        symlink)
            ui_kv "$TIME_LOCALTIME" "符号链接 → $(readlink "$TIME_LOCALTIME" 2>/dev/null)"
            [[ -e "$TIME_LOCALTIME" ]] || printf '  %s但链接已失效（date 会静默按 UTC 走）%s\n' \
                "$C_YELLOW" "$C_RESET"
            ;;
        copy)
            ui_kv "$TIME_LOCALTIME" "普通文件（$(stat -c %s "$TIME_LOCALTIME" 2>/dev/null || echo '?') 字节的时区副本）"
            ;;
        *)
            ui_kv "$TIME_LOCALTIME" "不存在（等同 UTC）"
            ;;
    esac

    if [[ -r "$TIME_TZFILE" ]]; then
        ui_kv "$TIME_TZFILE" "$(head -n1 "$TIME_TZFILE" 2>/dev/null)"
    else
        ui_kv "$TIME_TZFILE" "不存在"
    fi

    if [[ -n "${tz:-}" ]] && ! _time_tz_valid "$tz"; then
        printf '  %s时区名 %s 在 %s 下没有对应的时区文件，这个时区可能已失效%s\n' \
            "$C_YELLOW" "$tz" "$TIME_ZONEINFO" "$C_RESET"
    fi

    ui_section "自动校时"
    local impl='' srv='' srvlist=''
    impl="$(_time_ntp_impl || true)"

    if _time_have_systemd; then
        if [[ -n "$impl" ]]; then
            if _time_ntp_active "$impl"; then
                ui_kv "校时服务" "$impl（运行中）"
            else
                ui_kv "校时服务" "$impl（未运行）"
            fi
        else
            ui_kv "校时服务" "未安装"
        fi
        ui_kv "NTP 已启用" "$(_time_td_get NTP)"
        ui_kv "已同步" "$(_time_td_get NTPSynchronized)"
        ui_kv "可启用 NTP" "$(_time_td_get CanNTP)"
        ui_kv "RTC 走本地时间" "$(_time_td_get LocalRTC)"
    else
        ui_kv "systemd" "未运行（timedatectl 不可用）"
        ui_kv "校时服务" "${impl:-未安装}"
    fi

    if [[ -n "$impl" ]]; then
        srvlist="$(_time_ntp_servers_current "$impl" | tr '\n' ' ')"
        srvlist="${srvlist% }"
        if [[ -n "$srvlist" ]]; then
            ui_kv "已配服务器" "$srvlist"
        else
            ui_kv "已配服务器" "本工具未配置过（用发行版默认）"
        fi
        if _time_have_systemd; then
            srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
            [[ -n "$srv" ]] && ui_kv "正在使用" "$srv"
        fi
    fi

    ui_section "时区数据库"
    if [[ -d "$TIME_ZONEINFO" ]]; then
        ui_kv "目录" "$TIME_ZONEINFO"
        ui_kv "时区文件" "$(find -L "$TIME_ZONEINFO" -type f 2>/dev/null | wc -l | tr -d ' ') 个"
    else
        ui_kv "目录" "$TIME_ZONEINFO（不存在，需要安装 tzdata）"
    fi

    module_end
}

# ============================================================
# 2) 设置时区
# ============================================================

# 常用时区。偏移不写死，选择时用 TZ=<zone> date 现算。
TIME_ZONE_LIST=(
    "Asia/Shanghai" "Asia/Urumqi" "Asia/Hong_Kong" "Asia/Taipei"
    "Asia/Tokyo" "Asia/Seoul" "Asia/Singapore" "Asia/Bangkok"
    "Asia/Kolkata" "Asia/Dubai"
    "Europe/London" "Europe/Paris" "Europe/Moscow"
    "America/New_York" "America/Los_Angeles"
    "UTC"
)
TIME_ZONE_NOTE=(
    "中国标准时间" "中国新疆时间" "香港" "台北"
    "日本" "韩国" "新加坡" "泰国"
    "印度" "阿联酋"
    "英国" "中欧" "俄罗斯（莫斯科）"
    "美国东部" "美国西部"
    "协调世界时"
)

# 确认并切换时区。调用前调用方已画好界面。
_time_tz_change() {
    local tz="$1" cur='' now after

    module_begin "切换时区"

    # ---- 1. 验证：不过就一个文件都不动 ----
    # 返回 0 而不是 1：这是处理得了的输入错误，不是故障。返回非 0 会让
    # run_submenu 再补一句「返回码 1」并二次暂停，反而把话说糊了。
    if ! _time_tz_valid "$tz"; then
        log_err "「$tz」不是有效的时区名，未做任何修改。"
        _time_tz_hint "$tz"
        module_end
        return 0
    fi

    cur="$(_time_tz_current || true)"
    if [[ "$tz" == "$cur" ]]; then
        log_info "当前时区已经是 $tz，无需修改。"
        module_end
        return 0
    fi

    # ---- 2. 预览 ----
    module_begin "确认变更"
    ui_section "时区"
    if [[ -n "$cur" ]]; then
        ui_kv "当前" "$(_time_tz_label "$cur")"
    else
        ui_kv "当前" "读不出名字"
    fi
    ui_kv "改为" "$(_time_tz_label "$tz")"

    ui_section "将写入"
    if _time_have_systemd; then
        ui_kv "方式" "timedatectl set-timezone"
    else
        ui_kv "方式" "直接写文件（未运行 systemd）"
    fi
    ui_kv "$TIME_LOCALTIME" "符号链接 → $TIME_ZONEINFO/$tz"
    ui_kv "$TIME_TZFILE" "$tz"

    ui_section "将备份（仅失败回滚用，成功后删除）"
    case "$(_time_localtime_kind)" in
        symlink) ui_kv "$TIME_LOCALTIME" "记下链接目标 → $(readlink "$TIME_LOCALTIME" 2>/dev/null)" ;;
        copy)    ui_kv "$TIME_LOCALTIME" "整份复制到临时目录（二进制，不能存内存）" ;;
        *)       printf '  %s%s 不存在，无需备份%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET" ;;
    esac
    if [[ -e "$TIME_TZFILE" ]]; then
        ui_kv "$TIME_TZFILE" "整份复制到临时目录"
    else
        printf '  %s%s 不存在，无需备份（回滚时会删掉它）%s\n' "$C_DIM" "$TIME_TZFILE" "$C_RESET"
    fi

    ui_section "不受影响"
    printf '  %s不会删除或清空任何目录，不卸载任何软件包%s\n' "$C_DIM" "$C_RESET"
    if _time_rtc_is_local; then
        printf '\n'
        log_warn "硬件时钟当前按「本地时间」解释（/etc/adjtime 为 LOCAL，或 LocalRTC=yes）。"
        log_warn "这种配置下改时区会连带改变 RTC 数值的含义，重启后系统时钟可能跳变。"
        log_info "建议先执行: timedatectl set-local-rtc 0（把硬件时钟改回 UTC）"
    else
        printf '  %s硬件时钟与 /etc/adjtime 一律不动%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    if ! confirm "确认切换时区?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 3. 执行 ----
    module_begin "执行变更"

    if _time_localtime_mountinfo >/dev/null; then
        # 容器里 -v /etc/localtime:/etc/localtime 很常见：改它等于改宿主机
        log_err "$TIME_LOCALTIME 是被挂载进来的，容器内改它等于改宿主机的时区。"
        log_info "请在宿主机上设置时区，或用 -e TZ=Asia/Shanghai 给容器单独指定。"
        module_end
        return 1
    fi

    TIME_SNAP_OLD_TZ="$cur"
    if ! _time_tz_snapshot; then
        log_err "无法备份现有配置，为安全起见不做任何修改。"
        _time_tz_snapshot_cleanup
        module_end
        return 1
    fi

    if ! _time_tz_apply "$tz"; then
        log_err "写入失败，正在回滚..."
        _time_tz_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "已写入"

    # ---- 4. 验证 ----
    if ! now="$(_time_tz_verify "$tz")"; then
        log_err "验证未通过（$now），正在回滚..."
        _time_tz_rollback
        after="$(_time_tz_current || true)"
        if [[ "$after" == "$cur" ]]; then
            log_ok "已恢复到变更前的时区 ${cur:-（无）}。"
        else
            log_err "回滚后读到 ${after:-未知}，请手动检查 $TIME_LOCALTIME"
        fi
        module_end
        return 1
    fi

    _time_tz_snapshot_cleanup
    log_ok "时区已切换为 $tz"

    ui_section "当前时间"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '\n  %s若某个程序自带 TZ 环境变量，它仍按自己的时区走，不受这里影响。%s\n' \
        "$C_DIM" "$C_RESET"
    module_end
}

# ------------------------------------------------------------
# 浏览全部时区
#
# zoneinfo 下光文件名就有四百多个（America 一个地区 157 个），
# 平铺成一个菜单既列不下也没法看，所以按地区分组 + 分页。
# ------------------------------------------------------------

# 终端行数，用来定分页大小。取不到就按 24 行算。
_time_term_rows() {
    local r="${LINES:-0}"
    (( r > 0 )) || r="$(tput lines 2>/dev/null || echo 24)"
    [[ "$r" =~ ^[0-9]+$ ]] || r=24
    (( r >= 12 )) || r=12
    printf '%s' "$r"
}

# 地区名 → 中文标签。空串代表顶层那些不属于任何地区的时区。
_time_zone_region_label() {
    case "$1" in
        "")         printf '其它' ;;
        Africa)     printf '非洲' ;;
        America)    printf '美洲' ;;
        Antarctica) printf '南极洲' ;;
        Arctic)     printf '北极' ;;
        Asia)       printf '亚洲' ;;
        Atlantic)   printf '大西洋' ;;
        Australia)  printf '澳大利亚' ;;
        Etc)        printf 'Etc（固定偏移）' ;;
        Europe)     printf '欧洲' ;;
        Indian)     printf '印度洋' ;;
        Pacific)    printf '太平洋' ;;
        US|Canada|Brazil|Chile|Mexico)
                    printf '%s（旧式别名）' "$1" ;;
        *)          printf '%s' "$1" ;;
    esac
}

# 某地区下真正可用的时区，每行一个（已按名字排序）。
# 地区名为空 = 顶层散装时区（UTC / GMT 这些）。
_time_zone_list_region() {
    local base f
    if [[ -z "$1" ]]; then
        base="$TIME_ZONEINFO"
        find -L "$base" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r f; do
            f="${f#"$TIME_ZONEINFO"/}"
            _time_tz_valid "$f" && printf '%s\n' "$f"
        done
        return 0
    fi

    base="$TIME_ZONEINFO/$1"
    [[ -d "$base" ]] || return 0
    # 递归：America 底下还有 Argentina / Indiana / Kentucky / North_Dakota 一层
    find -L "$base" -type f 2>/dev/null | sort | while IFS= read -r f; do
        f="${f#"$TIME_ZONEINFO"/}"
        _time_tz_valid "$f" && printf '%s\n' "$f"
    done
    return 0
}

_time_zone_count_region() {
    _time_zone_list_region "$1" | wc -l | tr -d ' '
}

# 全部地区（含用空串表示的顶层）。空的地区由调用方按数量过滤掉。
_time_zone_regions() {
    local d
    for d in "$TIME_ZONEINFO"/*/; do
        [[ -d "$d" ]] || continue
        printf '%s\n' "$(basename "$d")"
    done
    printf '\n'      # 顶层散装
    return 0
}

# 分页菜单。选中把下标写进 UI_CHOICE，放弃写 -1。
#
# 不用 ui_menu：它一次把所有选项铺完，一百多项会直接冲掉整个回滚缓冲，
# 用户得拿终端回滚当翻页用。这里按终端高度算每页条数，n/p 翻页、q 放弃。
_time_menu_paged() {
    local title="$1" arr_ref="$2"
    local -n _pg="$arr_ref"
    local total=${#_pg[@]}
    local per rows pages page=0 i start end choice err=''

    rows="$(_time_term_rows)"
    per=$(( rows - 16 ))          # 减掉横幅、标题、翻页提示与输入提示占的行
    (( per >= 8 ))  || per=8
    (( per <= 40 )) || per=40

    pages=$(( (total + per - 1) / per ))
    (( pages >= 1 )) || pages=1

    UI_CHOICE=-1
    while true; do
        ui_screen
        ui_title "$title（第 $(( page + 1 ))/$pages 页 · 共 $total 项）"
        # 每次都重画屏幕，报错得画在重画之后，否则会被清掉看不见
        [[ -n "$err" ]] && { printf ' %s%s%s\n\n' "$C_RED" "$err" "$C_RESET"; err=''; }

        start=$(( page * per ))
        end=$(( start + per ))
        (( end <= total )) || end=$total
        for (( i=start; i<end; i++ )); do
            printf ' %s%3d)%s %s\n' "$C_BCYAN" $(( i + 1 )) "$C_RESET" "${_pg[i]}"
        done

        printf '\n '
        (( page > 0 ))        && printf '%sn)%s 上一页  ' "$C_DIM" "$C_RESET"
        (( page < pages - 1 )) && printf '%sp)%s 下一页  ' "$C_DIM" "$C_RESET"
        printf '%sq)%s 放弃\n\n' "$C_DIM" "$C_RESET"

        printf '%s请输入序号%s %s[1-%d]%s: ' "$C_BYELLOW" "$C_RESET" "$C_DIM" "$total" "$C_RESET"
        ui_read choice || { printf '\n'; UI_CHOICE=-1; return 0; }

        case "$choice" in
            q|Q) UI_CHOICE=-1; return 0 ;;
            n|N) (( page < pages - 1 )) && page=$(( page + 1 )); continue ;;
            p|P) (( page > 0 )) && page=$(( page - 1 )); continue ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            UI_CHOICE=$(( choice - 1 ))
            return 0
        fi
        err="无效输入，请输入序号或用 n / p / q"
    done
}

# 按地区浏览全部时区。选中的时区名写进 TIME_PICKED_TZ，空串表示放弃。
#
# 结果走全局变量而不是 stdout：这个函数要画好几屏界面，那些输出也在
# stdout 上，用 tz="$(_time_zone_browse)" 接结果会把界面文字一起接走，
# 于是「时区名」变成一整屏菜单，验证必然不过。
_time_zone_browse() {
    local regions=() items=() zones=() r n='' tz=''

    TIME_PICKED_TZ=''

    while IFS= read -r r; do
        n="$(_time_zone_count_region "$r")"
        (( n > 0 )) || continue
        regions+=("$r")
        items+=("$(_time_zone_region_label "$r")|$n 个")
    done < <(_time_zone_regions)

    module_begin "全部时区"
    if (( ${#regions[@]} == 0 )); then
        log_warn "$TIME_ZONEINFO 下没有找到可用的时区，可能需要安装 tzdata。"
        module_end
        return 0
    fi

    ui_menu "选择地区" items "← 返回"
    (( UI_CHOICE < 0 )) && return 0
    r="${regions[UI_CHOICE]}"

    while IFS= read -r tz; do
        [[ -n "$tz" ]] && zones+=("$tz")
    done < <(_time_zone_list_region "$r")
    (( ${#zones[@]} > 0 )) || return 0

    _time_menu_paged "时区 · $(_time_zone_region_label "$r")" zones || return 0
    (( UI_CHOICE >= 0 )) || return 0
    TIME_PICKED_TZ="${zones[UI_CHOICE]}"
    return 0
}

time_set_tz() {
    require_root

    local i tz='' items=() zones=() custom_idx=0 browse_idx=0 cur=''

    cur="$(_time_tz_current || true)"

    # 表里编的时区理论上都在，但精简过的 tzdata 可能缺 —— 缺的不进菜单，
    # 所以要用 zones 另存一份，保证下标与菜单项严格对应
    for (( i=0; i<${#TIME_ZONE_LIST[@]}; i++ )); do
        tz="${TIME_ZONE_LIST[i]}"
        _time_tz_valid "$tz" || continue
        zones+=("$tz")
        items+=("$tz|${TIME_ZONE_NOTE[i]}  UTC$(_time_tz_offset "$tz")")
    done
    browse_idx=${#zones[@]}
    items+=("按地区浏览全部时区|按地区分组，分页显示")
    custom_idx=$(( browse_idx + 1 ))
    items+=("手动输入时区名|如 America/New_York、Europe/Berlin")

    module_begin "设置时区"
    if [[ -n "$cur" ]]; then
        ui_kv "当前时区" "$(_time_tz_label "$cur")"
    else
        ui_kv "当前时区" "读不出名字"
    fi
    if [[ ! -d "$TIME_ZONEINFO" ]]; then
        log_warn "$TIME_ZONEINFO 不存在，需要先安装 tzdata 才能设置时区。"
        module_end
        return 1
    fi

    ui_menu "选择时区" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0

    if (( UI_CHOICE == browse_idx )); then
        _time_zone_browse
        tz="$TIME_PICKED_TZ"
        [[ -n "$tz" ]] || return 0
    elif (( UI_CHOICE == custom_idx )); then
        module_begin "手动输入时区名"
        printf '  %s时区名形如 地区/城市，可用 ls %s/地区 查看%s\n\n' \
            "$C_DIM" "$TIME_ZONEINFO" "$C_RESET"
        while true; do
            if ! ask "时区名（直接回车放弃）" ""; then
                log_info "输入中断，已取消。"
                return 0
            fi
            tz="${REPLY//[[:space:]]/}"
            if [[ -z "$tz" ]]; then
                log_info "未输入，已取消。"
                return 0
            fi
            if _time_tz_valid "$tz"; then
                break
            fi
            log_warn "「$tz」不是有效的时区名"
            _time_tz_hint "$tz"
        done
    else
        tz="${zones[UI_CHOICE]}"
    fi

    _time_tz_change "$tz"
}

# ============================================================
# 3) 开启自动校时
# ============================================================
time_ntp_on() {
    require_root

    module_begin "开启自动校时"

    if ! _time_have_systemd; then
        _time_ntp_on_nosystemd
        return $?
    fi

    local unit='' pkg='' ntp='' can=''
    unit="$(_time_ntp_unit || true)"
    ntp="$(_time_td_get NTP)"
    can="$(_time_td_get CanNTP)"

    ui_section "当前状态"
    if [[ -n "$unit" ]]; then
        if _time_ntp_active "$unit"; then
            ui_kv "校时服务" "$unit（运行中）"
        else
            ui_kv "校时服务" "$unit（未运行）"
        fi
    else
        ui_kv "校时服务" "未安装"
    fi
    ui_kv "NTP 已启用" "$ntp"
    ui_kv "已同步" "$(_time_td_get NTPSynchronized)"

    if [[ "$ntp" == "yes" ]]; then
        log_info "NTP 自动校时已经是开启状态，无需重复开启。"
        module_end
        return 0
    fi

    # CanNTP 就是 timedated 判断「有没有可用的校时服务」的那个条件，
    # 为 no 时直接调 set-ntp 只会拿到 "NTP not supported" 这句没用的报错
    if [[ -z "$unit" ]]; then
        pkg="$(_time_ntp_pkg)"
    elif [[ "$can" != "yes" ]]; then
        log_warn "已有 $unit 但系统报告 NTP 不可启用，仍尝试直接启用服务。"
    fi

    ui_section "将执行"
    if [[ -n "$pkg" ]]; then
        printf '  %s+%s 安装软件包 %s%s%s 并刷新软件源缓存\n' \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$pkg" "$C_RESET"
    fi
    printf '  %s*%s 启用并启动校时服务\n' "$C_GREEN" "$C_RESET"
    printf '  %s*%s 打开 NTP 自动校时开关\n' "$C_GREEN" "$C_RESET"

    ui_section "不受影响"
    printf '  %s系统时区与 %s 一律不动%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"
    printf '  %s只新增依赖，不卸载任何已有软件%s\n' "$C_DIM" "$C_RESET"
    printf '\n  %s首次同步可能需要十几秒；出站 UDP 123 被挡时无法同步。%s\n' \
        "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    if [[ -n "$pkg" ]]; then
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install "$pkg"; then
            log_warn "$pkg 安装失败，改试 chrony ..."
            pkg='chrony'
            if ! pkg_install "$pkg"; then
                log_err "systemd-timesyncd 与 chrony 都装不上，请手动安装后重试。"
                module_end
                return 1
            fi
        fi
        unit="$(_time_ntp_unit || true)"
        if [[ -z "$unit" ]]; then
            log_err "软件包装上了但找不到校时服务单元，请手动检查。"
            module_end
            return 1
        fi
        log_ok "已安装 $pkg（服务单元 $unit）"
    fi

    # timedated 在自己启动时就把「系统里有哪些校时服务」查好并缓存了，
    # 之后新装的包它并不知道。实测（systemd 257）：装完 systemd-timesyncd，
    # 单元已 enabled+active，CanNTP 却仍是 no，set-ntp true 直接返回
    # "NTP not supported"；重启 systemd-timedated 后立刻变 yes 并成功。
    # 不处理这条，「缺服务 → 装一个 → 启用」这个最常见的场景就会
    # 「装成功了但启用失败」，还得用户重启机器才能好。
    if [[ -n "$unit" && "$can" != "yes" ]]; then
        log_info "让 systemd 重新识别校时服务（重启 systemd-timedated）"
        systemctl restart systemd-timedated >/dev/null 2>&1 || true
        can="$(_time_td_get CanNTP)"
        log_debug "刷新后 CanNTP=$can"
    fi

    if ! timedatectl set-ntp true 2>/dev/null; then
        log_warn "timedatectl set-ntp 失败，改用直接启用服务..."
        if ! systemctl enable --now "$unit.service" >/dev/null 2>&1; then
            log_err "启用 $unit 失败。"
            log_info "排查: systemctl status $unit.service"
            module_end
            return 1
        fi
    fi

    # ---- 验证 ----
    local i
    for (( i=0; i<10; i++ )); do
        ntp="$(_time_td_get NTP)"
        [[ "$ntp" == "yes" ]] && break
        sleep 0.5
    done
    if [[ "$ntp" != "yes" ]]; then
        log_err "启用后 NTP 状态仍是 ${ntp:-未知}，未生效。"
        log_info "排查: systemctl status $unit.service; journalctl -u $unit.service -n 30"
        module_end
        return 1
    fi
    log_ok "NTP 自动校时已启用（$unit）"

    printf '\n  %s等待首次同步（最多 %s 秒）' "$C_DIM" "$TIME_SYNC_WAIT"
    if _time_ntp_wait_sync; then
        log_ok "系统时钟已同步。"
    else
        # 不因为首次同步慢就回滚 —— 开 NTP 是配置变更，生效是异步的
        log_warn "等待 ${TIME_SYNC_WAIT} 秒仍未同步，这不代表失败。"
        log_info "常见原因: 出站 UDP 123 被防火墙挡住、网络不通、或首次同步尚未完成。"
        log_info "稍后可再看: timedatectl show -p NTPSynchronized"
    fi

    local srv
    srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
    [[ -n "$srv" ]] && ui_kv "同步服务器" "$srv"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    module_end
}

# 没有 systemd 的系统（Alpine/Devuan）：用 chrony + 系统自带 init
_time_ntp_on_nosystemd() {
    local pkg='chrony' need_install=0 ran=0

    have_cmd chronyd || need_install=1

    ui_section "当前状态"
    ui_kv "systemd" "未运行"
    if have_cmd chronyd; then
        ui_kv "chronyd" "已安装"
    else
        ui_kv "chronyd" "未安装"
    fi

    ui_section "将执行"
    if (( need_install )); then
        printf '  %s+%s 安装软件包 %s\n' "$C_GREEN" "$C_RESET" "$pkg"
    fi
    printf '  %s*%s 启动 chronyd 并设为开机自启\n' "$C_GREEN" "$C_RESET"

    ui_section "不受影响"
    printf '  %s系统时区与 %s 一律不动%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"

    printf '\n'
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if (( need_install )); then
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install "$pkg"; then
            log_err "安装 $pkg 失败。"
            module_end
            return 1
        fi
    fi

    if have_cmd rc-update; then
        rc-update add chronyd default >/dev/null 2>&1 || log_warn "rc-update 设置自启失败"
        ran=1
    elif have_cmd update-rc.d; then
        update-rc.d chronyd defaults >/dev/null 2>&1 || log_warn "update-rc.d 设置自启失败"
        ran=1
    fi

    if have_cmd rc-service; then
        rc-service chronyd start >/dev/null 2>&1 || { log_err "启动 chronyd 失败。"; module_end; return 1; }
        ran=1
    elif have_cmd service; then
        service chronyd start >/dev/null 2>&1 || { log_err "启动 chronyd 失败。"; module_end; return 1; }
        ran=1
    fi

    if (( ! ran )); then
        log_warn "没找到可用的服务管理命令，chronyd 已安装但未启动。"
        log_info "请手动启动: rc-service chronyd start 或 service chronyd start"
        module_end
        return 1
    fi

    log_ok "chronyd 已启动并设为开机自启。"
    _time_chrony_offset
    module_end
    return 0
}

# chrony 量到的系统时钟偏移，能取到就打印一行（取不到就什么也不说）
_time_chrony_offset() {
    local off=''
    have_cmd chronyc || return 0
    off="$(chronyc tracking 2>/dev/null | awk -F': *' '/^System time/ { print $2 }')"
    [[ -n "$off" ]] && ui_kv "系统时钟偏移" "$off"
    return 0
}

# ============================================================
# 4) 关闭自动校时
# ============================================================
time_ntp_off() {
    require_root

    module_begin "关闭自动校时"

    local unit='' ntp='' i

    if ! _time_have_systemd; then
        _time_ntp_off_nosystemd
        return $?
    fi

    unit="$(_time_ntp_unit || true)"
    ntp="$(_time_td_get NTP)"

    ui_section "当前状态"
    ui_kv "NTP 已启用" "$ntp"
    ui_kv "校时服务" "${unit:-未安装}"

    if [[ "$ntp" != "yes" ]]; then
        log_info "NTP 自动校时本来就是关闭的，无需操作。"
        module_end
        return 0
    fi

    ui_section "将执行"
    printf '  %s-%s 停用并禁止开机自启校时服务\n' "$C_RED" "$C_RESET"
    printf '  %s-%s 关闭 NTP 自动校时开关\n' "$C_RED" "$C_RESET"

    ui_section "不会做的事"
    printf '  %s不卸载任何软件包%s\n' "$C_DIM" "$C_RESET"
    printf '  %s不改系统时区、不动 %s%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"
    printf '  %s不修改系统时间（当前时间会保持，只是不再自动校正）%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认关闭自动校时?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    timedatectl set-ntp false 2>/dev/null || log_warn "timedatectl set-ntp false 失败，改用直接停用服务"

    for (( i=0; i<10; i++ )); do
        ntp="$(_time_td_get NTP)"
        [[ "$ntp" == "no" ]] && break
        sleep 0.5
    done

    if [[ "$ntp" == "no" ]]; then
        # set-ntp false 通常已经停了服务；这里再兜一次，确保没有残留的自启
        [[ -n "$unit" ]] && systemctl disable --now "$unit.service" >/dev/null 2>&1
        log_ok "NTP 自动校时已关闭，系统时间保持当前值不再自动校正。"
    else
        log_warn "NTP 状态仍是 ${ntp:-未知}，可能没关干净。"
        log_info "排查: systemctl status ${unit:-systemd-timesyncd}.service"
    fi

    module_end
}

_time_ntp_off_nosystemd() {
    local stopped=0

    ui_section "当前状态"
    ui_kv "systemd" "未运行"

    if ! have_cmd chronyd; then
        log_info "系统里没有 chronyd，无需操作。"
        module_end
        return 0
    fi

    ui_section "将执行"
    printf '  %s-%s 停止 chronyd 并取消开机自启\n' "$C_RED" "$C_RESET"
    ui_section "不会做的事"
    printf '  %s不卸载软件包，不改时区%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认关闭自动校时?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if have_cmd rc-service; then
        rc-service chronyd stop >/dev/null 2>&1 && stopped=1
        have_cmd rc-update && rc-update del chronyd default >/dev/null 2>&1
    elif have_cmd service; then
        service chronyd stop >/dev/null 2>&1 && stopped=1
    fi

    if (( stopped )); then
        log_ok "chronyd 已停止并取消开机自启。"
    else
        log_warn "未能确认 chronyd 已停止，请手动检查。"
    fi
    module_end
}

# ============================================================
# 5) 立即校时
#
# 只用系统里已经配置好的客户端，不自己编造 NTP 服务器地址 ——
# 客户端已经知道自己该找谁（chrony.conf / timesyncd.conf），
# 我们另报一个服务器反而可能是不通的地址。
# ============================================================
time_ntp_sync() {
    require_root

    module_begin "立即校时"

    local unit='' how='' ok=0 before after

    unit="$(_time_ntp_unit || true)"

    if have_cmd chronyc && have_cmd chronyd; then
        how="chronyc makestep（chrony 立即步进）"
    elif [[ "$unit" == "systemd-timesyncd" ]]; then
        how="重启 systemd-timesyncd 触发同步"
    fi

    ui_section "同步前"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"

    if [[ -z "$how" ]]; then
        ui_section "无可用的校时客户端"
        ui_kv "chronyc" "$(have_cmd chronyc && echo 有 || echo 无)"
        if [[ -n "$unit" ]]; then
            ui_kv "校时服务" "$unit（不支持立即同步）"
        else
            ui_kv "校时服务" "未安装"
        fi
        log_warn "没有可以立即触发同步的客户端。"
        log_info "请先执行「开启自动校时」装上校时服务，再回来用本功能。"
        module_end
        return 1
    fi

    ui_section "将执行"
    printf '  %s*%s %s\n' "$C_GREEN" "$C_RESET" "$how"

    ui_section "不受影响"
    printf '  %s时区、NTP 开关状态、软件包一律不动%s\n' "$C_DIM" "$C_RESET"
    if [[ "$unit" == "systemd-timesyncd" ]]; then
        printf '  %s注意: systemd-timesyncd 没有一次性同步模式，它按自己的节奏走，%s\n' \
            "$C_DIM" "$C_RESET"
        printf '  %s      这里只是重启它并等一段时间，不保证立刻完成。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    if ! confirm "确认立即校时?" y; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行校时"
    before="$(date +%s)"

    if have_cmd chronyc && have_cmd chronyd; then
        # 输出里有它实际量到的偏移，这是判断「真同步了还是没连上」的证据。
        # 先把输出收下来再判断退出码 —— 管道的退出码取的是最后一段
        # （sed 恒为 0），直接 if cmd | sed 会把失败当成成功。
        local out=''
        if out="$(chronyc makestep 2>&1)"; then
            ok=1
        else
            log_err "chronyc makestep 失败 —— 通常是 chronyd 没在跑。"
        fi
        [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  /'
    else
        if systemctl restart systemd-timesyncd >/dev/null 2>&1; then
            printf '  %s等待同步（最多 %s 秒）' "$C_DIM" "$TIME_SYNC_WAIT"
            if _time_ntp_wait_sync; then
                ok=1
            else
                log_warn "重启后 ${TIME_SYNC_WAIT} 秒内未见同步完成。"
                log_info "可能是出站 UDP 123 被挡、网络不通，或首次同步还在进行。"
            fi
        else
            log_err "重启 systemd-timesyncd 失败。"
        fi
    fi

    after="$(date +%s)"

    ui_section "同步后"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    ui_kv "本次耗时" "$(( after - before )) 秒"
    if _time_have_systemd; then
        ui_kv "已同步" "$(_time_td_get NTPSynchronized)"
    fi
    _time_chrony_offset

    printf '\n'
    if (( ok )); then
        log_ok "校时完成。"
    else
        log_warn "未确认同步成功，详见上面的说明。"
    fi

    module_end
    (( ok )) && return 0
    return 1
}

# ============================================================
# 模块入口
# ============================================================
menu_time() {
    local items=(
        "状态查看|时间 / 时区 / 校时服务状态，不做任何修改"
        "设置时区|常用列表或手动输入，改前预览确认"
        "开启自动校时|启用 NTP，缺少客户端时提示并安装"
        "关闭自动校时|停用 NTP 校时，不卸载软件包"
        "设置 NTP 服务器|自定义校时服务器，写前先探测可达性"
        "立即校时|用已配置的客户端强制同步一次"
    )
    local fns=(time_status time_set_tz time_ntp_on time_ntp_off time_ntp_server time_ntp_sync)
    run_submenu "时间与时区" items fns
}

register_module "time" "时间与时区" "menu_time" "时区设置 / NTP 自动校时"


# ════════════════════════════════════════════════════════════
#  ↓↓↓ 内联自 main.sh
# ════════════════════════════════════════════════════════════
# ============================================================
#  Linux 一键配置脚本 —— 入口
#  用法: sudo bash main.sh [选项]
# ============================================================

set -uo pipefail

# SINGLE_FILE=1 表示当前是 build.sh 打包出来的单文件版本：
# 库与模块都已内联，不再从磁盘加载，也不需要 lib/ 和 modules/ 目录。
SINGLE_FILE="${SINGLE_FILE:-0}"

APP_NAME="Linux 一键配置脚本"
APP_VERSION="0.0.1"
SELF_NAME="${SELF_NAME:-$(basename "${BASH_SOURCE[0]}")}"

# ------------------------------------------------------------
# 定位脚本目录（软链接 / 任意 cwd 都能正确解析）
# ------------------------------------------------------------
_resolve_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

if (( SINGLE_FILE )); then
    SCRIPT_DIR="$(pwd)"
else
    SCRIPT_DIR="$(_resolve_dir)"
fi
LIB_DIR="$SCRIPT_DIR/lib"
MODULES_DIR="$SCRIPT_DIR/modules"

# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------
NO_COLOR_OPT=0
LOG_LEVEL="info"

usage() {
    cat <<EOF
$APP_NAME  v$APP_VERSION

用法:
  sudo bash $SELF_NAME [选项]

一键运行（不需要下载多个文件）:
  bash <(curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh)
  curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh | sudo bash

选项:
  -h, --help        显示本帮助
  -V, --version     显示版本号
  -l, --list        列出所有已注册的功能模块后退出
  -d, --debug       输出调试日志
      --no-color    禁用彩色输出
      --log FILE    指定日志文件 (默认 /var/log/linux-toolkit.log)

环境变量:
  NO_COLOR=1        等同于 --no-color
  LOG_LEVEL=debug   等同于 --debug
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -V|--version) printf '%s\n' "$APP_VERSION"; exit 0 ;;
            -l|--list)    LIST_ONLY=1 ;;
            -d|--debug)   LOG_LEVEL="debug" ;;
            --no-color)   NO_COLOR_OPT=1; export NO_COLOR=1 ;;
            --log)
                # 必须检查缺值：不检查的话下面的 shift 会越界，
                # 而 LOG_FILE 变成空串等于静默关闭日志（_log_write 对空值直接返回），
                # 用户以为在记日志，实际什么都没记。
                shift
                if [[ -z "${1:-}" ]]; then
                    printf '选项 --log 需要一个文件路径参数\n\n' >&2
                    usage
                    exit 2
                fi
                LOG_FILE="$1"
                ;;
            *)            printf '未知参数: %s\n\n' "$1" >&2; usage; exit 2 ;;
        esac
        shift
    done
}
LIST_ONLY=0

# ------------------------------------------------------------
# 载入库
# ------------------------------------------------------------
load_libs() {
    # 单文件模式下 lib/ 已内联，无需加载
    (( SINGLE_FILE )) && return 0

    local f
    for f in core ui module registry; do
        local path="$LIB_DIR/$f.sh"
        if [[ ! -r "$path" ]]; then
            printf '致命错误: 缺少库文件 %s\n' "$path" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        . "$path"
    done
}

# ------------------------------------------------------------
# 前置检查
# ------------------------------------------------------------
preflight() {
    # 实际门槛是 4.3：ui_menu / run_submenu 用了 nameref（local -n），
    # 那是 bash 4.3 才有的特性。写着 4.0 会让 4.0~4.2 的系统通过检查后
    # 在打开菜单时才报错，不如在这里直接拦下。
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        printf '需要 bash 4.3 以上版本，当前为 %s\n' "$BASH_VERSION" >&2
        exit 1
    fi
    if (( ! SINGLE_FILE )) && [[ ! -d "$MODULES_DIR" ]]; then
        printf '致命错误: 缺少模块目录 %s\n' "$MODULES_DIR" >&2
        exit 1
    fi
    # 交互模式需要能拿到键盘：要么 stdin 是终端，要么能打开 /dev/tty
    # （后者覆盖 curl ... | bash 场景，此时 stdin 被 bash 占用读脚本）
    if (( ! LIST_ONLY )) && ! is_tty && ! can_open_tty; then
        printf '本脚本为交互式菜单，需要在终端中运行。\n' >&2
        exit 1
    fi
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    parse_args "$@"
    load_libs
    # 菜单对齐依赖 UTF-8 charmap，越早修正越好（--list 也要用）
    _ensure_utf8_locale || log_debug "无可用 UTF-8 locale，中文对齐可能不准"
    preflight

    detect_system
    # 单文件模式下模块已在载入时注册完毕，只需构造菜单
    (( SINGLE_FILE )) || load_modules "$MODULES_DIR"
    build_main_menu

    if (( LIST_ONLY )); then
        printf '%s v%s\n' "$APP_NAME" "$APP_VERSION"
        printf '系统: %s %s (%s / %s)\n' "$DISTRO_NAME" "$DISTRO_VERSION" "$DISTRO_FAMILY" "$ARCH"
        printf '已注册 %d 个模块:\n' "${#MAIN_ITEMS[@]}"
        local i
        for (( i=0; i<${#MAIN_ITEMS[@]}; i++ )); do
            # 用 _pad_right 而不是 printf 的 %-16s：后者按字符数补齐，
            # 汉字是双宽字符，标题长度一变说明列就错开
            printf '  %2d) %s %s\n' $(( i + 1 )) \
                "$(_pad_right "${MAIN_ITEMS[i]%%|*}" 16)" "${MAIN_ITEMS[i]#*|}"
        done
        exit 0
    fi

    menu_main
}

main "$@"
