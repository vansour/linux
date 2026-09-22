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

    # 同上，供 read 消费
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
    local d dev state addrs

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

# 下载并执行厂商提供的官方安装脚本。
# 先落盘再执行，而不是 curl | sh —— 这样能检查下载是否成功、
# 内容是否为空，执行失败也能拿到真实退出码。
_run_official_script() {
    local url="$1"
    local tmp rc=0

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

    log_info "执行中（输出可能较长）..."
    sh "$tmp" || rc=$?
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
    if ! confirm "确认安装?" n; then
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
        module_begin "关闭 DoT"
        ui_kv "实现方式" "$(_dot_backend_label "$backend")"
        printf '\n'
        if ! confirm "确认关闭 DoT，恢复明文 DNS?" n; then
            log_info "已取消。"
            module_end
            return 0
        fi

        rm -f "$RESOLVED_DROPIN"
        if have_cmd systemctl; then
            systemctl restart systemd-resolved 2>/dev/null || true
        fi

        # 恢复成普通 DNS（取第一个服务商的明文地址）
        local real="$RESOLV_CONF"
        [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
        {
            printf '# 由 Linux 一键配置脚本生成\n'
            local ip
            for ip in ${DNS_IPS[0]}; do printf 'nameserver %s\n' "$ip"; done
        } >"$real"

        log_ok "DoT 已关闭，DNS 恢复为明文 ${DNS_IPS[0]}"
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
        _net_rollback
        module_end
        return 1
    fi

    # ---- 生效并验证 ----
    ui_section "加载并验证"
    sysctl --system >/dev/null 2>&1 || true

    if _net_verify "$BBR_BUF" "$ipv6"; then
        log_ok "网络优化已生效。"
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
