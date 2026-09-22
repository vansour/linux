#!/usr/bin/env bash
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
