#!/usr/bin/env bash
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
