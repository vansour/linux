#!/usr/bin/env bash
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
