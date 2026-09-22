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
UI_MENU_WIDTH=${UI_MENU_WIDTH:-0}

# ------------------------------------------------------------
# 宽度计算：中日韩字符占 2 列，其余占 1 列
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

# 成功 / 失败 / 提示行
ui_kv() {
    local k="$1" v="$2"
    printf '  %s%-14s%s %s\n' "$C_DIM" "$k" "$C_RESET" "$v"
}

# ------------------------------------------------------------
# 菜单
#   ui_menu <标题> <选项数组名> [返回项文案]
#   选项文案格式支持 "标题|说明"，说明以暗色显示
#   结果写入全局 UI_CHOICE (0 起下标)，选了返回项则为 -1
# ------------------------------------------------------------
ui_menu() {
    local title="$1" arr_name="$2" back_label="${3:-← 返回}"
    local -n _items="$arr_name"
    local count=${#_items[@]}
    local i label desc w cols col_w rows r c idx

    UI_CHOICE=-1
    [[ "$count" -gt 0 ]] || { log_warn "菜单无可用选项"; return 1; }

    ui_title "$title"

    w=$(term_width)
    if (( w >= 66 )); then cols=2; else cols=1; fi
    col_w=$(( (w - 4) / cols ))
    rows=$(( (count + cols - 1) / cols ))

    for (( r=0; r<rows; r++ )); do
        printf ' '
        for (( c=0; c<cols; c++ )); do
            idx=$(( c * rows + r ))
            if (( idx < count )); then
                label="${_items[idx]%%|*}"
                desc="${_items[idx]#*|}"
                [[ "$desc" == "${_items[idx]}" ]] && desc=""
                local cell
                cell="$(printf '%s%2d)%s %s' "$C_BCYAN" $(( idx + 1 )) "$C_RESET" "$label")"
                if [[ -n "$desc" ]]; then
                    cell="$cell ${C_DIM}${desc}${C_RESET}"
                fi
                printf '%s' "$(_pad_right "$cell" "$col_w")"
            else
                printf '%*s' "$col_w" ''
            fi
        done
        printf '\n'
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
# ============================================================

# ---- 叶子动作（每个功能一个函数） ----
sys_overview() {
    not_implemented          # TODO: 主机名/发行版/内核/运行时长/负载
    module_end
}

sys_resource() {
    not_implemented          # TODO: CPU 型号核心数 / 内存 / Swap
    module_end
}

sys_disk() {
    not_implemented          # TODO: 磁盘分区与 inode 使用率
    module_end
}

sys_network_iface() {
    not_implemented          # TODO: 网卡/IP/网关/DNS
    module_end
}

# ---- 模块入口（主菜单点进来执行这个） ----
menu_system() {
    local items=(
        "系统概览|主机名 / 发行版 / 内核 / 运行时长"
        "CPU 内存|型号 / 核心数 / 占用"
        "磁盘空间|分区 / 使用率 / inode"
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
# ============================================================

tools_basic() {
    not_implemented          # TODO: 批量安装常用命令行工具
    module_end
}

tools_docker() {
    not_implemented          # TODO: 安装 Docker + 可选换源
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
        "基础工具|vim curl wget git htop 等"
        "Docker|安装 Docker 与 Compose"
        "Shell 环境|zsh / oh-my-zsh"
        "运维面板|常用面板一键安装"
    )
    local fns=(tools_basic tools_docker tools_shell tools_bt)
    run_submenu "常用工具" items fns
}

register_module "tools" "常用工具" "menu_tools" "常用软件一键安装"


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
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-dns.conf"
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
            have_cmd systemctl && systemctl restart systemd-resolved 2>/dev/null
            ;;

        resolvconf)
            have_cmd resolvconf && resolvconf -d "linux-toolkit" 2>/dev/null
            ;;

        *)
            local real="$RESOLV_CONF"
            [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
            printf '%s' "${DNS_SNAP_RESOLV:-}" >"$real" 2>/dev/null
            ;;
    esac
}

# 记录现场（存内存，不落备份文件）
_dns_snapshot() {
    local mech="$1"
    if [[ -e "$RESOLVED_DROPIN" ]]; then
        DNS_SNAP_DROPIN_EXISTED=1
        DNS_SNAP_DROPIN_CONTENT="$(cat "$RESOLVED_DROPIN" 2>/dev/null)"
    else
        DNS_SNAP_DROPIN_EXISTED=''
        DNS_SNAP_DROPIN_CONTENT=''
    fi
    DNS_SNAP_RESOLV="$(cat "$RESOLV_CONF" 2>/dev/null || true)"
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
        "DNS 设置|Cloudflare / Google / 腾讯 / 阿里"
        "IP 配置|静态 IP / DHCP"
        "代理设置|系统级 / 终端代理"
        "连通测试|延迟 / 测速"
    )
    local fns=(net_dns net_ip_config net_proxy net_connectivity)
    run_submenu "网络设置" items fns
}

register_module "network" "网络设置" "menu_network" "DNS / IP / 代理"


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
            --log)        shift; LOG_FILE="${1:-}" ;;
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
    if (( BASH_VERSINFO[0] < 4 )); then
        printf '需要 bash 4.0 以上版本，当前为 %s\n' "$BASH_VERSION" >&2
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
            printf '  %2d) %-16s %s\n' $(( i + 1 )) "${MAIN_ITEMS[i]%%|*}" "${MAIN_ITEMS[i]#*|}"
        done
        exit 0
    fi

    menu_main
}

main "$@"
