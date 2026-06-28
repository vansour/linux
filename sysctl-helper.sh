#!/bin/bash

# sysctl-helper.sh — Linux 系统配置助手
# 纯 Bash，Debian/Ubuntu，需要 root 权限

set -euo pipefail

# ─── 颜色常量 ───
if [[ -t 1 ]]; then
    C_RESET='\033[0m'
    C_RED='\033[0;31m'
    C_GREEN='\033[0;32m'
    C_YELLOW='\033[0;33m'
    C_BLUE='\033[0;34m'
    C_BOLD='\033[1m'
else
    C_RESET='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_BOLD=''
fi

# ─── 常量路径 ───
readonly SYSTCLD_DIR="/etc/sysctl.d"
readonly BBR_CONF="/etc/sysctl.d/99-bbr.conf"
readonly SSHD_CONFIG="/etc/ssh/sshd_config"
readonly SSHD_CONFIG_D="/etc/ssh/sshd_config.d"
readonly TIMESYNCD_CONF="/etc/systemd/timesyncd.conf"
readonly BACKUP_SUFFIX=".bak.$(date +%Y%m%d-%H%M%S)"

# ─── 工具函数 ───

msg_ok()    { echo -e "${C_GREEN}[✓]${C_RESET} $*"; }
msg_warn()  { echo -e "${C_YELLOW}[!]${C_RESET} $*" >&2; }
msg_err()   { echo -e "${C_RED}[✗]${C_RESET} $*" >&2; }
msg_info()  { echo -e "${C_BLUE}[i]${C_RESET} $*"; }
msg_bold()  { echo -e "${C_BOLD}$*${C_RESET}"; }

confirm() {
    # 用法: confirm "提示信息"  → 用户输入 y/N，返回 0(yes) 或 1(no)
    local prompt="${1:-是否继续？}"
    local answer
    echo -ne "${C_YELLOW}${prompt} (y/N): ${C_RESET}"
    read -r answer
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

backup_file() {
    # 备份指定文件到 .bak.YYYYMMDD-HHMMSS
    local file="$1"
    if [[ -f "$file" ]]; then
        local dest="${file}${BACKUP_SUFFIX}"
        cp -a "$file" "$dest"
        msg_info "已备份: $file → $dest"
    else
        msg_info "文件不存在，跳过备份: $file"
    fi
}

backup_dir() {
    # 备份整个目录到 .bak.YYYYMMDD-HHMMSS
    local dir="$1"
    if [[ -d "$dir" ]]; then
        local dest="${dir}${BACKUP_SUFFIX}"
        cp -a "$dir" "$dest"
        msg_info "已备份: $dir → $dest"
    else
        msg_info "目录不存在，跳过备份: $dir"
    fi
}

check_root() {
    if [[ "${EUID:-$(id -u)}" != "0" ]]; then
        msg_err "此脚本必须以 root 用户运行。请使用 sudo bash $0"
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        msg_err "无法检测操作系统（/etc/os-release 不存在）"
        return 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    case "${ID,,}" in
        debian|ubuntu) return 0 ;;
        *)
            msg_err "不支持的操作系统: $ID。此脚本仅支持 Debian/Ubuntu。"
            return 1
            ;;
    esac
}

get_os_name() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        echo "${PRETTY_NAME:-$NAME $VERSION_ID}"
    else
        echo "Unknown"
    fi
}

detect_sshd_service() {
    # 在 Debian/Ubuntu 上 ssh 服务可能叫 ssh 或 sshd
    if systemctl is-active --quiet ssh 2>/dev/null; then
        echo "ssh"
    elif systemctl is-active --quiet sshd 2>/dev/null; then
        echo "sshd"
    elif systemctl list-unit-files | grep -q '^ssh\.service'; then
        echo "ssh"
    else
        echo "sshd"
    fi
}

# ─── 主菜单 ───

print_banner() {
    clear
    echo -e "${C_BOLD}${C_BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║       Linux 系统配置助手                 ║"
    echo "╠══════════════════════════════════════════╣"
    echo -e "║  检测系统: $(get_os_name)  ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${C_RESET}"
}

main_menu() {
    while true; do
        print_banner
        echo "  1. 开启 BBR + fq + ECN + bpftune"
        echo "  2. 开启时间同步 (NTP)"
        echo "  3. 修改 SSH 端口"
        echo "  4. 开启 root 密码登录"
        echo "  5. 删除 SSH 密钥，仅用密码登录"
        echo "  6. 查看当前状态"
        echo "  0. 退出"
        echo ""
        local choice
        echo -ne "${C_BOLD}请输入选项 [0-6]: ${C_RESET}"
        read -r choice
        echo ""

        case "$choice" in
            1) func_enable_bbr ;;
            2) func_enable_ntp ;;
            3) func_change_ssh_port ;;
            4) func_enable_root_login ;;
            5) func_remove_keys ;;
            6) func_show_status ;;
            0) msg_info "再见！"; exit 0 ;;
            *) msg_err "无效选项，请重试" ;&
        esac

        if [[ "$choice" =~ ^[1-6]$ ]]; then
            echo ""
            echo -ne "${C_BOLD}按 Enter 返回菜单...${C_RESET}"
            read -r
        fi
    done
}

main() {
    check_root
    check_os || exit 1
    main_menu
}

# 如果直接执行（非 source），则启动
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
