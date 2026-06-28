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

# ─── 功能函数 ───

# ─── 功能 1：开启 BBR + fq + ECN + bpftune ───

# 返回 0=通过, 1=失败
func_enable_bbr_stage1_clean() {
    msg_bold "阶段一：清空现有拥塞控制配置"
    echo ""

    # 清空 /etc/sysctl.d/ 下的 BBR 相关文件
    local cleaned=0
    if [[ -f "$BBR_CONF" ]]; then
        msg_info "删除现有配置文件: $BBR_CONF"
        rm -f "$BBR_CONF"
        cleaned=1
    fi

    # 扫描 sysctl.d 下所有 .conf，注释拥塞控制相关行
    local files=()
    [[ -f /etc/sysctl.conf ]] && files+=("/etc/sysctl.conf")
    if [[ -d "$SYSTCLD_DIR" ]]; then
        while IFS= read -r -d '' f; do
            files+=("$f")
        done < <(find "$SYSTCLD_DIR" -name '*.conf' -type f -print0 2>/dev/null || true)
    fi

    local targets=("net.core.default_qdisc" "net.ipv4.tcp_congestion_control" "net.ipv4.tcp_ecn")
    for f in "${files[@]}"; do
        [[ ! -f "$f" ]] && continue
        backup_file "$f"
        local modified=0
        for key in "${targets[@]}"; do
            if grep -qE "^\s*${key}\s*=" "$f" 2>/dev/null; then
                sed -i "s|^\\(\\s*${key}\\s*=\\)|# \\1|" "$f"
                msg_info "已注释 $f 中的 $key"
                modified=1
            fi
        done
        [[ $modified -eq 1 ]] && cleaned=1
    done

    # 重置当前内核参数
    msg_info "将当前拥塞控制重置为系统默认..."
    # 先尝试卸载可能已加载的非 BBR 模块并回退
    local modules_to_unload=("tcp_westwood" "tcp_htcp" "tcp_cdg" "tcp_vegas" "tcp_yeah" "tcp_bic" "tcp_highspeed" "tcp_scalable")
    for mod in "${modules_to_unload[@]}"; do
        if lsmod | grep -q "^${mod} "; then
            rmmod "$mod" 2>/dev/null || true
            msg_info "已卸载模块: $mod"
        fi
    done

    msg_ok "清空完成"
    return 0
}

func_enable_bbr_stage2_apply() {
    msg_bold "阶段二：写入新配置"
    echo ""

    # 检查内核版本
    local kver
    kver=$(uname -r | cut -d. -f1,2)
    local major minor
    major=$(echo "$kver" | cut -d. -f1)
    minor=$(echo "$kver" | cut -d. -f2)
    if [[ "$major" -lt 4 ]] || { [[ "$major" -eq 4 ]] && [[ "$minor" -lt 9 ]]; }; then
        msg_err "内核版本 $(uname -r) < 4.9，不支持 BBR。请升级内核后重试。"
        return 1
    fi

    # 加载 BBR 模块
    if ! modprobe tcp_bbr 2>/dev/null; then
        msg_err "无法加载 tcp_bbr 模块。请确认内核已编译 BBR 支持 (CONFIG_TCP_CONG_BBR=m 或 y)"
        return 1
    fi
    msg_ok "tcp_bbr 模块已加载"

    # 写入配置文件
    cat > "$BBR_CONF" <<'EOF'
# BBR + fq + ECN — 由 sysctl-helper 配置
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_ecn = 1
EOF
    msg_info "已写入 $BBR_CONF"

    # 即时生效
    sysctl -p "$BBR_CONF" >/dev/null 2>&1
    msg_ok "配置已即时生效"
    return 0
}

func_enable_bbr_stage3_verify() {
    msg_bold "阶段三：验证配置生效"
    echo ""

    local all_ok=1

    local cc_val
    cc_val=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [[ "$cc_val" == "bbr" ]]; then
        msg_ok "拥塞控制算法: bbr"
    else
        msg_err "拥塞控制算法: $cc_val (预期: bbr)"
        all_ok=0
    fi

    local qdisc_val
    qdisc_val=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    if [[ "$qdisc_val" == "fq" ]]; then
        msg_ok "默认 qdisc: fq"
    else
        msg_err "默认 qdisc: $qdisc_val (预期: fq)"
        all_ok=0
    fi

    local ecn_val
    ecn_val=$(sysctl -n net.ipv4.tcp_ecn 2>/dev/null || echo "unknown")
    if [[ "$ecn_val" == "1" ]]; then
        msg_ok "TCP ECN: 1 (已启用)"
    else
        msg_err "TCP ECN: $ecn_val (预期: 1)"
        all_ok=0
    fi

    # 检查活跃连接中是否有 bbr
    local bbr_conns
    bbr_conns=$(ss -ti 2>/dev/null | grep -c 'bbr' || echo "0")
    if [[ "$bbr_conns" -gt 0 ]]; then
        msg_ok "检测到 $bbr_conns 个活跃连接使用 BBR"
    else
        msg_info "未检测到活跃 BBR 连接（可能无对外连接，新连接将使用 BBR）"
    fi

    if [[ $all_ok -eq 1 ]]; then
        msg_ok "全部验证通过 ✓"
    else
        msg_warn "部分验证未通过，请检查上方输出"
    fi
    return $all_ok
}

func_enable_bbr_stage4_bpftune() {
    msg_bold "阶段四：安装 bpftune"
    echo ""

    # 检查是否已安装
    if command -v bpftune &>/dev/null; then
        msg_ok "bpftune 已安装: $(command -v bpftune)"
    else
        msg_info "正在安装 bpftune..."
        if apt update -qq 2>/dev/null && apt install -y bpftune 2>/dev/null; then
            msg_ok "bpftune 通过 apt 安装成功"
        else
            msg_info "apt 不可用或未收录，尝试从 GitHub Releases 下载..."
            local latest_deb
            latest_deb=$(curl -s "https://api.github.com/repos/oracle-samples/bpftune/releases/latest" 2>/dev/null \
                | grep -oP '"browser_download_url":\s*"\K[^"]+\.deb' | head -1)
            if [[ -n "$latest_deb" ]]; then
                local tmp_deb="/tmp/bpftune_latest.deb"
                msg_info "下载: $latest_deb"
                if curl -sL -o "$tmp_deb" "$latest_deb"; then
                    dpkg -i "$tmp_deb" && apt install -f -y 2>/dev/null
                    rm -f "$tmp_deb"
                    msg_ok "bpftune .deb 安装完成"
                else
                    msg_err "下载失败"
                    msg_warn "请手动安装: https://github.com/oracle-samples/bpftune/releases"
                    return 1
                fi
            else
                msg_err "未找到 bpftune release 的 .deb 文件"
                msg_warn "请手动安装: https://github.com/oracle-samples/bpftune/releases"
                return 1
            fi
        fi
    fi

    # 启用并启动服务
    if systemctl enable --now bpftune 2>/dev/null; then
        msg_ok "bpftune 服务已启用并启动"
    else
        msg_warn "bpftune 服务启用失败，尝试手动启动..."
        systemctl start bpftune 2>/dev/null || msg_err "无法启动 bpftune 服务"
    fi

    # 验证
    if systemctl is-active --quiet bpftune 2>/dev/null; then
        msg_ok "bpftune 运行中 ✓"
    else
        msg_warn "bpftune 未在运行，请检查 systemctl status bpftune"
    fi
}

func_enable_bbr() {
    echo ""
    msg_bold "══════════ 功能 1：开启 BBR + fq + ECN + bpftune ══════════"
    echo ""

    msg_info "此操作将:"
    echo "  1. 清空所有现有拥塞控制配置"
    echo "  2. 写入 BBR + fq + ECN 配置"
    echo "  3. 验证配置生效"
    echo "  4. 安装并启用 bpftune"
    echo ""

    confirm "是否继续？" || { msg_info "已取消"; return; }

    func_enable_bbr_stage1_clean || { msg_err "阶段一失败"; return; }
    echo ""
    func_enable_bbr_stage2_apply || { msg_err "阶段二失败"; return; }
    echo ""
    func_enable_bbr_stage3_verify || { msg_warn "阶段三有警告"; }
    echo ""
    func_enable_bbr_stage4_bpftune || { msg_warn "阶段四有警告"; }

    echo ""
    msg_ok "功能 1 执行完毕。"
}

# ─── 功能 2：开启时间同步 (NTP) ───

func_enable_ntp() {
    echo ""
    msg_bold "══════════ 功能 2：开启时间同步 (NTP) ══════════"
    echo ""

    echo -e "${C_BLUE}当前时间同步状态:${C_RESET}"
    timedatectl status 2>/dev/null || true
    echo ""

    # 检测可用的 NTP 后端
    local use_timesyncd=0
    local use_chrony=0

    if systemctl list-unit-files systemd-timesyncd.service &>/dev/null; then
        use_timesyncd=1
        msg_info "检测到 systemd-timesyncd 可用（系统内置）"
    fi

    msg_info "此操作将:"
    echo "  - 启用 NTP 时间同步"
    if [[ $use_timesyncd -eq 1 ]]; then
        echo "  - 使用 systemd-timesyncd（系统内置）"
        echo "  - 配置 NTP 服务器: pool.ntp.org"
    else
        echo "  - 安装并使用 chrony"
    fi
    echo ""

    confirm "是否继续？" || { msg_info "已取消"; return; }

    if [[ $use_timesyncd -eq 1 ]]; then
        # 配置 NTP 服务器
        if [[ -f "$TIMESYNCD_CONF" ]]; then
            backup_file "$TIMESYNCD_CONF"
            # 取消注释并设置 NTP 服务器
            sed -i 's/^#\s*NTP=/NTP=/' "$TIMESYNCD_CONF"
            if ! grep -q '^NTP=.*pool.ntp.org' "$TIMESYNCD_CONF" 2>/dev/null; then
                # 替换已有的 NTP= 行
                if grep -q '^NTP=' "$TIMESYNCD_CONF" 2>/dev/null; then
                    sed -i 's/^NTP=.*/NTP=pool.ntp.org/' "$TIMESYNCD_CONF"
                else
                    echo "NTP=pool.ntp.org" >> "$TIMESYNCD_CONF"
                fi
            fi
        fi

        # 启用 NTP
        timedatectl set-ntp true 2>/dev/null || msg_warn "timedatectl set-ntp 失败，尝试手动操作"

        # 重启 timesyncd
        systemctl restart systemd-timesyncd 2>/dev/null || true
        systemctl enable systemd-timesyncd 2>/dev/null || true

        msg_ok "systemd-timesyncd 配置完成"
    else
        # 退化到 chrony
        msg_info "安装 chrony..."
        apt update -qq 2>/dev/null
        apt install -y chrony 2>/dev/null || { msg_err "chrony 安装失败"; return; }

        systemctl enable --now chrony 2>/dev/null || { msg_err "chrony 启动失败"; return; }
        msg_ok "chrony 安装并启动完成"
    fi

    echo ""
    msg_bold "验证当前时间同步状态:"
    timedatectl status 2>/dev/null || true

    # 检查 NTP 同步是否为 active
    local ntp_active
    ntp_active=$(timedatectl show -p NTP --value 2>/dev/null || echo "unknown")
    if [[ "$ntp_active" == "yes" ]]; then
        msg_ok "NTP 时间同步已启用 ✓"
    else
        msg_warn "NTP 状态: $ntp_active，请检查"
    fi

    echo ""
    msg_ok "功能 2 执行完毕。"
}

# ─── 功能 3：修改 SSH 端口 ───

func_change_ssh_port() {
    echo ""
    msg_bold "══════════ 功能 3：修改 SSH 端口 ══════════"
    echo ""

    local sshd_svc
    sshd_svc=$(detect_sshd_service)
    msg_info "检测到 SSH 服务: $sshd_svc"

    # 显示当前端口
    echo ""
    echo -e "${C_BLUE}当前 SSH 监听端口:${C_RESET}"
    if command -v sshd &>/dev/null; then
        sshd -T 2>/dev/null | grep -E '^port ' || ss -tlnp 2>/dev/null | grep -E 'sshd?'
    else
        ss -tlnp 2>/dev/null | grep -E 'sshd?'
    fi
    echo ""

    # 读取新端口
    local new_port
    while true; do
        echo -ne "${C_BOLD}请输入新的 SSH 端口号 (1-65535): ${C_RESET}"
        read -r new_port
        if [[ "$new_port" =~ ^[0-9]+$ ]] && [[ "$new_port" -ge 1 ]] && [[ "$new_port" -le 65535 ]]; then
            break
        fi
        msg_err "无效端口: $new_port，请输入 1-65535 之间的数字。"
    done

    if [[ "$new_port" -lt 1024 ]]; then
        msg_warn "端口 $new_port 为保留端口 (<1024)，需 root 权限。SSH 以 root 运行，通常无影响。"
    fi

    msg_info "此操作将:"
    echo "  - 备份 $SSHD_CONFIG 及 $SSHD_CONFIG_D"
    echo "  - 将 SSH 端口修改为 $new_port"
    echo "  - 检查防火墙 (ufw) 并放行新端口"
    echo "  - 重启 $sshd_svc 服务"
    echo ""
    msg_warn "⚠  操作后请勿关闭当前 SSH 会话！先用新端口另开终端测试连接。"

    confirm "是否继续？" || { msg_info "已取消"; return; }

    # 备份
    backup_file "$SSHD_CONFIG"
    backup_dir "$SSHD_CONFIG_D"

    # 修改端口
    # 优先使用 sshd_config.d 中的覆盖配置
    local dropin="${SSHD_CONFIG_D}/99-sysctl-helper-port.conf"
    mkdir -p "$SSHD_CONFIG_D"
    cat > "$dropin" <<EOF
# SSH 端口 — 由 sysctl-helper 设置
Port $new_port
EOF
    msg_ok "已写入 $dropin (Port $new_port)"

    # 同时在主配置中修改以确保兼容
    if grep -qE '^\s*Port\s+' "$SSHD_CONFIG" 2>/dev/null; then
        sed -i "s|^\\s*Port\\s\\+.*|Port $new_port|" "$SSHD_CONFIG"
    elif grep -qE '^\s*#\s*Port\s+' "$SSHD_CONFIG" 2>/dev/null; then
        sed -i "s|^#\\s*Port\\s\\+.*|Port $new_port|" "$SSHD_CONFIG"
    else
        echo "Port $new_port" >> "$SSHD_CONFIG"
    fi
    msg_info "主配置 $SSHD_CONFIG 已更新 Port $new_port"

    # 防火墙处理
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
        msg_info "检测到 ufw 已启用"
        ufw allow "$new_port"/tcp 2>/dev/null && msg_ok "ufw 已放行 $new_port/tcp"
        confirm "是否删除旧端口 (22) 的 ufw 规则？" && {
            ufw delete allow 22/tcp 2>/dev/null && msg_info "已删除旧端口规则"
        }
    else
        msg_info "ufw 未启用或未安装，跳过防火墙配置"
    fi

    # 语法检查后重启
    if sshd -t 2>/dev/null; then
        msg_ok "sshd_config 语法检查通过"
        systemctl restart "$sshd_svc" 2>/dev/null || systemctl restart ssh 2>/dev/null || {
            msg_err "SSH 服务重启失败！请手动检查配置"
            return
        }
        msg_ok "$sshd_svc 服务已重启"
    else
        msg_err "sshd_config 语法检查失败！已保留备份文件，请手动修复后重启。"
        return
    fi

    echo ""
    msg_bold "新端口: $new_port"
    msg_warn "请立即另开终端测试: ssh -p $new_port $(whoami)@$(hostname -I | awk '{print $1}')"
    echo ""
    msg_ok "功能 3 执行完毕。"
}

# ─── 主菜单 ───

print_banner() {
    clear 2>/dev/null || true
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
            1) func_enable_bbr || msg_err "操作失败" ;;
            2) func_enable_ntp || msg_err "操作失败" ;;
            3) func_change_ssh_port || msg_err "操作失败" ;;
            4) func_enable_root_login || msg_err "操作失败" ;;
            5) func_remove_keys || msg_err "操作失败" ;;
            6) func_show_status || msg_err "操作失败" ;;
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
