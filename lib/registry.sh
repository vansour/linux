#!/usr/bin/env bash
# ============================================================
# registry.sh - 模块注册表 & 主菜单
# ============================================================

MODULE_IDS=()
MODULE_TITLES=()
MODULE_DESCS=()
MODULE_HANDLERS=()
MODULE_FAMILIES=()      # 支持的发行版家族，空 = 全部支持

# ------------------------------------------------------------
# register_module <id> <标题> <处理函数> [说明] [适用家族]
#   id        唯一标识，kebab-case
#   标题      主菜单显示文案
#   处理函数  模块入口函数名
#   说明      主菜单上的灰色小字，可省略
#   适用家族  空格分隔，如 "debian rhel"；省略或空 = 所有发行版
#
# 在 modules/*.sh 顶层调用，载入时自动注册。
# ------------------------------------------------------------
register_module() {
    local id="$1" title="$2" handler="$3" desc="${4:-}" families="${5:-}"

    local i
    for (( i=0; i<${#MODULE_IDS[@]}; i++ )); do
        if [[ "${MODULE_IDS[i]}" == "$id" ]]; then
            log_warn "模块 id 重复，已忽略: $id"
            return 1
        fi
    done

    MODULE_IDS+=("$id")
    MODULE_TITLES+=("$title")
    MODULE_DESCS+=("$desc")
    MODULE_HANDLERS+=("$handler")
    MODULE_FAMILIES+=("$families")
}

# 当前发行版是否支持该模块
_module_supported() {
    local families="${MODULE_FAMILIES[$1]}"
    [[ -z "$families" ]] && return 0
    local f
    for f in $families; do
        [[ "$f" == "$DISTRO_FAMILY" ]] && return 0
    done
    return 1
}

# ------------------------------------------------------------
# 载入 modules/ 下所有模块（按文件名排序）
# ------------------------------------------------------------
load_modules() {
    local dir="$1" f n=0
    shopt -s nullglob
    for f in "$dir"/*.sh; do
        # shellcheck source=/dev/null
        if ! . "$f"; then
            log_err "模块载入失败: $(basename "$f")"
        else
            n=$(( n + 1 ))
        fi
    done
    shopt -u nullglob
    log_debug "已载入 $n 个模块文件，注册 ${#MODULE_IDS[@]} 个功能"
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------
build_main_menu() {
    MAIN_ITEMS=()
    MAIN_HANDLERS=()
    local i
    for (( i=0; i<${#MODULE_IDS[@]}; i++ )); do
        if _module_supported "$i"; then
            MAIN_ITEMS+=("${MODULE_TITLES[i]}|${MODULE_DESCS[i]}")
            MAIN_HANDLERS+=("${MODULE_HANDLERS[i]}")
        fi
    done
}

menu_main() {
    local fn rc
    while true; do
        ui_screen

        if (( ${#MAIN_ITEMS[@]} == 0 )); then
            log_warn "当前没有任何已注册的功能模块。"
            pause
            return 0
        fi

        ui_menu "主菜单" MAIN_ITEMS "退出脚本"
        (( UI_CHOICE < 0 )) && { ui_clear; printf '\n%s再见 👋%s\n\n' "$C_BCYAN" "$C_RESET"; return 0; }

        fn="${MAIN_HANDLERS[UI_CHOICE]}"
        if ! declare -F "$fn" >/dev/null; then
            log_err "处理函数未定义: $fn"
            pause
            continue
        fi

        ui_screen
        "$fn"
        rc=$?

        if (( rc != 0 )); then
            ui_screen
            log_warn "「${MAIN_ITEMS[UI_CHOICE]%%|*}」执行出错，返回码 $rc"
            pause
        fi
    done
}
