#!/usr/bin/env bash
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
