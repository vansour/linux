#!/usr/bin/env bash
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
