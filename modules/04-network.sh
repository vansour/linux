#!/usr/bin/env bash
# ============================================================
# 模块: 网络设置
# id: network
# ============================================================

net_ip_config() {
    not_implemented          # TODO: 静态 IP / DHCP 配置
    module_end
}

net_dns() {
    not_implemented          # TODO: 修改 DNS（含国内公共 DNS 预设）
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
        "IP 配置|静态 IP / DHCP"
        "DNS 设置|公共 DNS 一键切换"
        "代理设置|系统级 / 终端代理"
        "连通测试|延迟 / 测速"
    )
    local fns=(net_ip_config net_dns net_proxy net_connectivity)
    run_submenu "网络设置" items fns
}

register_module "network" "网络设置" "menu_network" "IP / DNS / 代理"
