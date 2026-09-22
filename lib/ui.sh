#!/usr/bin/env bash
# ============================================================
# ui.sh - 界面渲染库
# 中英文混排宽度计算 / 边框 / 菜单 / 分页标题
# ============================================================

APP_NAME="${APP_NAME:-Linux 一键配置脚本}"
APP_VERSION="${APP_VERSION:-0.0.1}"

# 边框字符
BOX_TL='╔' BOX_TR='╗' BOX_BL='╚' BOX_BR='╝'
BOX_H='═'  BOX_V='║'  BOX_ML='╠' BOX_MR='╣'
BOX_L='─'  BOX_DOT='·'

UI_CHOICE=-1          # ui_menu 的返回值：选项下标(0起)，-1 表示返回/退出

# ------------------------------------------------------------
# 宽度计算：中日韩字符占 2 列，其余占 1 列
#
# 依赖 UTF-8 charmap —— C locale 下 ${#str} 和 ${str:i:1} 按字节走，
# 汉字会计成 3 列。启动时由 core.sh 的 _ensure_utf8_locale 兜住。
# ------------------------------------------------------------
_str_width() {
    local str="$1" width=0 i ch code n
    # 先去掉 ANSI 转义序列，避免颜色码被计入宽度
    str="$(printf '%s' "$str" | sed $'s/\033\\[[0-9;]*m//g')"
    n=${#str}
    for (( i=0; i<n; i++ )); do
        ch="${str:i:1}"
        printf -v code '%d' "'$ch" 2>/dev/null || code=0
        if (( code >= 0x1100 )) && (( \
               ( code >= 0x1100 && code <= 0x115F ) ||
               code == 0x2329 || code == 0x232A ||
               ( code >= 0x2E80 && code <= 0xA4CF && code != 0x303F ) ||
               ( code >= 0xAC00 && code <= 0xD7A3 ) ||
               ( code >= 0xF900 && code <= 0xFAFF ) ||
               ( code >= 0xFE10 && code <= 0xFE19 ) ||
               ( code >= 0xFE30 && code <= 0xFE6F ) ||
               ( code >= 0xFF00 && code <= 0xFF60 ) ||
               ( code >= 0xFFE0 && code <= 0xFFE6 ) ||
               ( code >= 0x1F300 && code <= 0x1F9FF ) ||
               ( code >= 0x20000 && code <= 0x3FFFD ) )); then
            width=$(( width + 2 ))
        else
            width=$(( width + 1 ))
        fi
    done
    printf '%s' "$width"
}

# 右填充空格到指定显示宽度
_pad_right() {
    local str="$1" target="$2" w
    w=$(_str_width "$str")
    printf '%s' "$str"
    (( w < target )) && printf '%*s' $(( target - w )) ''
    return 0
}

# 居中（左右各补空格）
_pad_center() {
    local str="$1" target="$2" w left right
    w=$(_str_width "$str")
    if (( w >= target )); then printf '%s' "$str"; return 0; fi
    left=$(( (target - w) / 2 ))
    right=$(( target - w - left ))
    printf '%*s%s%*s' "$left" '' "$str" "$right" ''
}

# ------------------------------------------------------------
# 终端信息
# ------------------------------------------------------------
term_width() {
    local w="${COLUMNS:-0}"
    (( w > 0 )) || w="$(tput cols 2>/dev/null || echo 80)"
    (( w >= 46 )) || w=46
    (( w <= 100 )) || w=100
    printf '%s' "$w"
}

ui_clear() {
    if [[ -t 1 ]]; then
        printf '\033[2J\033[H'
    else
        printf '\n'
    fi
}

# 清屏 + 横幅（不含分节标题，菜单页用这个）
ui_screen() {
    ui_clear
    ui_banner
}

# ------------------------------------------------------------
# 顶部横幅
# ------------------------------------------------------------
ui_banner() {
    local w inner title line1 line2
    w=$(term_width)
    inner=$(( w - 2 ))                      # 两个 ║ 各占 1 列，其余为内容宽度

    title="$APP_NAME  v$APP_VERSION"
    line1="${DISTRO_NAME}${DISTRO_VERSION:+ $DISTRO_VERSION}  |  $ARCH  |  ${DISTRO_FAMILY}"
    if is_root; then
        line2="权限: root ✓"
    else
        line2="权限: 普通用户 (${USER:-?}) — 部分功能不可用"
    fi

    printf '\n'
    printf '%s%s%s\n' "$C_BCYAN" "${BOX_TL}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_TR}" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_center "$C_BOLD$title$C_RESET" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s\n' "$C_BCYAN" "${BOX_ML}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_MR}" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_right " $line1" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s%s%s%s%s\n' "$C_BCYAN" "$BOX_V" "$C_RESET" \
        "$(_pad_right " $line2" "$inner")" "$C_BCYAN" "$BOX_V" "$C_RESET"
    printf '%s%s%s\n\n' "$C_BCYAN" "${BOX_BL}$(_repeat "$BOX_H" $(( w - 2 )))${BOX_BR}" "$C_RESET"
}

_repeat() {
    local ch="$1" n="$2" out=''
    (( n > 0 )) || { printf ''; return 0; }
    printf -v out '%*s' "$n" ''
    printf '%s' "${out// /$ch}"
}

# ------------------------------------------------------------
# 页面 / 分节标题
# ------------------------------------------------------------
ui_title() {
    local text="$1" w line
    w=$(term_width)
    line="$(_repeat "$BOX_L" "$(( w - 2 ))")"
    printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET"
    printf ' %s%s%s\n' "$C_BOLD$C_BBLUE" "$text" "$C_RESET"
    printf '%s%s%s\n\n' "$C_DIM" "$line" "$C_RESET"
}

ui_section() {
    printf '\n%s▎%s %s%s%s\n' "$C_BBLUE" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
}

# 键值行。
# 不能用 printf 的 %-14s 补齐 —— 它按字符数算，中文是双宽字符，
# 「管理方式」(4字/8列) 和「当前 DNS」(6字/8列) 会被补成不同宽度。
# 必须按显示宽度补空格才对得齐。
ui_kv() {
    local k="$1" v="$2" width="${3:-14}"
    printf '  %s%s%s %s\n' "$C_DIM" "$(_pad_right "$k" "$width")" "$C_RESET" "$v"
}

# ------------------------------------------------------------
# 菜单
#   ui_menu <标题> <选项数组名> [返回项文案]
#   选项文案格式支持 "标题|说明"，说明以暗色显示
#   结果写入全局 UI_CHOICE (0 起下标)，选了返回项则为 -1
#
# 一律单列，一项一行。双列要在固定列宽里塞下中英混排的「标题 + 说明」，
# 说明稍长就会撑破列宽把右边一列顶歪（80 列终端下必然发生），
# 宽度算错时还会整体错位 —— 单列没有这个约束。
# ------------------------------------------------------------
ui_menu() {
    local title="$1" arr_name="$2" back_label="${3:-← 返回}"
    local -n _items="$arr_name"
    local count=${#_items[@]}
    local i label desc cell

    UI_CHOICE=-1
    [[ "$count" -gt 0 ]] || { log_warn "菜单无可用选项"; return 1; }

    ui_title "$title"

    for (( i=0; i<count; i++ )); do
        label="${_items[i]%%|*}"
        desc="${_items[i]#*|}"
        [[ "$desc" == "${_items[i]}" ]] && desc=""
        cell="$(printf '%s%2d)%s %s' "$C_BCYAN" $(( i + 1 )) "$C_RESET" "$label")"
        if [[ -n "$desc" ]]; then
            cell="$cell ${C_DIM}${desc}${C_RESET}"
        fi
        printf ' %s\n' "$cell"
    done

    printf ' %s%2d)%s %s%s%s\n\n' "$C_DIM" 0 "$C_RESET" "$C_DIM" "$back_label" "$C_RESET"

    local choice
    while true; do
        printf '%s请输入选项%s %s[0-%d]%s: ' "$C_BYELLOW" "$C_RESET" "$C_DIM" "$count" "$C_RESET"
        ui_read choice || { printf '\n'; UI_CHOICE=-1; return 0; }

        if [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]]; then
            UI_CHOICE=-1; return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            UI_CHOICE=$(( choice - 1 )); return 0
        fi
        printf '%s无效输入，请重新选择。%s\n' "$C_RED" "$C_RESET"
    done
}
