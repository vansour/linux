#!/bin/bash
set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行！"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 检查系统版本
check_system() {
    if [[ ! -f /etc/debian_version ]]; then
        log_error "此脚本仅适用于Debian系统！"
        exit 1
    fi
    local debian_version=$(cat /etc/debian_version)
    log_info "检测到Debian版本: $debian_version"
}

# 创建新的sysctl配置 (安全覆盖模式)
create_sysctl_config() {
    local config_file="/etc/sysctl.d/99-custom-network.conf"
    log_info "正在生成网络优化配置至 ${config_file} ..."
    
    # 写入BBR和FQ核心配置 (去除了暴力的缓冲区调整)
    cat > "$config_file" << 'EOF'
# --- BBR & Queue Discipline ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- ECN (Explicit Congestion Notification) ---
net.ipv4.tcp_ecn = 1

# 关闭空闲后的慢启动，减少突发延迟
net.ipv4.tcp_slow_start_after_idle = 0
EOF
    
    log_success "基础网络优化参数已写入独立配置文件。"
}

# IPv6配置选择
configure_ipv6() {
    local config_file="/etc/sysctl.d/99-custom-network.conf"
    echo
    log_info "IPv6 配置选项："
    echo "1) 禁用 IPv6"
    echo "2) 启用 IPv6"
    echo "3) 跳过 IPv6 配置"
    
    while true; do
        read -p "请选择 IPv6 配置 [1-3]: " ipv6_choice
        case $ipv6_choice in
            1)
                log_info "配置禁用IPv6..."
                cat >> "$config_file" << 'EOF'

# --- IPv6 Configuration ---
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
                log_success "IPv6禁用配置已添加"
                break
                ;;
            2)
                log_info "配置启用IPv6..."
                cat >> "$config_file" << 'EOF'

# --- IPv6 Configuration ---
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
                log_success "IPv6启用配置已添加"
                break
                ;;
            3)
                log_info "跳过IPv6配置"
                break
                ;;
            *)
                log_error "无效选择，请输入1-3"
                ;;
        esac
    done
}

# 应用配置
apply_config() {
    local config_file="/etc/sysctl.d/99-custom-network.conf"
    log_info "应用新的sysctl配置..."
    
    # 仅加载我们刚才生成的独立文件，不干扰系统其他配置
    if sysctl -p "$config_file"; then
        log_success "网络配置已成功应用"
    else
        log_error "应用网络配置失败"
        return 1
    fi
    
    # 验证BBR是否启用
    log_info "验证BBR配置..."
    local current_qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")
    local current_congestion=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    
    if [[ "$current_qdisc" == "fq" ]] && [[ "$current_congestion" == "bbr" ]]; then
        log_success "BBR与FQ已成功启用!"
    else
        log_warning "BBR配置可能未完全生效，请检查内核版本(需 >= 4.9)。"
        log_info "当前队列调度器: $current_qdisc"
        log_info "当前拥塞控制算法: $current_congestion"
    fi
}

# 显示配置摘要
show_summary() {
    echo
    log_info "==================== 配置摘要 ===================="
    echo "✓ 独立优化文件：/etc/sysctl.d/99-custom-network.conf"
    echo "✓ 已启用 BBR 拥塞控制算法"
    echo "✓ 已启用 FQ 队列调度器"
    echo "✓ 已启用 ECN 显式拥塞通知"
    echo "=================================================="
    echo
}

# 主函数
main() {
    echo "=================================================="
    echo "      Debian BBR 安全优化脚本 (无损稳定版)"
    echo "=================================================="
    echo
    
    check_root
    check_system
    
    echo "此脚本将安全地执行以下操作："
    echo "1. 生成独立的网络配置文件 (/etc/sysctl.d/99-custom-network.conf)"
    echo "2. 开启 BBR、FQ 与 ECN 优化"
    echo "3. 交互式配置 IPv6 状态"
    echo "4. 加载配置并验证"
    echo
    
    read -p "是否继续? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "操作已取消"
        exit 0
    fi
    
    echo
    create_sysctl_config
    configure_ipv6
    apply_config
    show_summary
    
    log_success "安全优化完成！部分现存的 TCP 连接可能需要重启系统才能完全应用新规则。"
}

# 脚本入口
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
