#!/usr/bin/env bash
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
