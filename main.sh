#!/usr/bin/env bash
# ============================================================
#  Linux 一键配置脚本 —— 入口
#  用法: sudo bash main.sh [选项]
# ============================================================

set -uo pipefail

# SINGLE_FILE=1 表示当前是 build.sh 打包出来的单文件版本：
# 库与模块都已内联，不再从磁盘加载，也不需要 lib/ 和 modules/ 目录。
SINGLE_FILE="${SINGLE_FILE:-0}"

APP_NAME="Linux 一键配置脚本"
APP_VERSION="0.0.1"
SELF_NAME="${SELF_NAME:-$(basename "${BASH_SOURCE[0]}")}"

# ------------------------------------------------------------
# 定位脚本目录（软链接 / 任意 cwd 都能正确解析）
# ------------------------------------------------------------
_resolve_dir() {
    local src="${BASH_SOURCE[0]}" dir
    while [[ -L "$src" ]]; do
        dir="$(cd -P "$(dirname "$src")" && pwd)"
        src="$(readlink "$src")"
        [[ "$src" != /* ]] && src="$dir/$src"
    done
    cd -P "$(dirname "$src")" && pwd
}

if (( SINGLE_FILE )); then
    SCRIPT_DIR="$(pwd)"
else
    SCRIPT_DIR="$(_resolve_dir)"
fi
LIB_DIR="$SCRIPT_DIR/lib"
MODULES_DIR="$SCRIPT_DIR/modules"

# ------------------------------------------------------------
# 参数解析
# ------------------------------------------------------------
NO_COLOR_OPT=0
LOG_LEVEL="info"

usage() {
    cat <<EOF
$APP_NAME  v$APP_VERSION

用法:
  sudo bash $SELF_NAME [选项]

一键运行（不需要下载多个文件）:
  bash <(curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh)
  curl -sL https://raw.githubusercontent.com/vansour/linux/main/install.sh | sudo bash

选项:
  -h, --help        显示本帮助
  -V, --version     显示版本号
  -l, --list        列出所有已注册的功能模块后退出
  -d, --debug       输出调试日志
      --no-color    禁用彩色输出
      --log FILE    指定日志文件 (默认 /var/log/linux-toolkit.log)

环境变量:
  NO_COLOR=1        等同于 --no-color
  LOG_LEVEL=debug   等同于 --debug
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -V|--version) printf '%s\n' "$APP_VERSION"; exit 0 ;;
            -l|--list)    LIST_ONLY=1 ;;
            -d|--debug)   LOG_LEVEL="debug" ;;
            --no-color)   NO_COLOR_OPT=1; export NO_COLOR=1 ;;
            --log)
                # 必须检查缺值：不检查的话下面的 shift 会越界，
                # 而 LOG_FILE 变成空串等于静默关闭日志（_log_write 对空值直接返回），
                # 用户以为在记日志，实际什么都没记。
                shift
                if [[ -z "${1:-}" ]]; then
                    printf '选项 --log 需要一个文件路径参数\n\n' >&2
                    usage
                    exit 2
                fi
                LOG_FILE="$1"
                ;;
            *)            printf '未知参数: %s\n\n' "$1" >&2; usage; exit 2 ;;
        esac
        shift
    done
}
LIST_ONLY=0

# ------------------------------------------------------------
# 载入库
# ------------------------------------------------------------
load_libs() {
    # 单文件模式下 lib/ 已内联，无需加载
    (( SINGLE_FILE )) && return 0

    local f
    for f in core ui module registry; do
        local path="$LIB_DIR/$f.sh"
        if [[ ! -r "$path" ]]; then
            printf '致命错误: 缺少库文件 %s\n' "$path" >&2
            exit 1
        fi
        # shellcheck source=/dev/null
        . "$path"
    done
}

# ------------------------------------------------------------
# 前置检查
# ------------------------------------------------------------
preflight() {
    # 实际门槛是 4.3：ui_menu / run_submenu 用了 nameref（local -n），
    # 那是 bash 4.3 才有的特性。写着 4.0 会让 4.0~4.2 的系统通过检查后
    # 在打开菜单时才报错，不如在这里直接拦下。
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
        printf '需要 bash 4.3 以上版本，当前为 %s\n' "$BASH_VERSION" >&2
        exit 1
    fi
    if (( ! SINGLE_FILE )) && [[ ! -d "$MODULES_DIR" ]]; then
        printf '致命错误: 缺少模块目录 %s\n' "$MODULES_DIR" >&2
        exit 1
    fi
    # 交互模式需要能拿到键盘：要么 stdin 是终端，要么能打开 /dev/tty
    # （后者覆盖 curl ... | bash 场景，此时 stdin 被 bash 占用读脚本）
    if (( ! LIST_ONLY )) && ! is_tty && ! can_open_tty; then
        printf '本脚本为交互式菜单，需要在终端中运行。\n' >&2
        exit 1
    fi
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
main() {
    parse_args "$@"
    load_libs
    # 菜单对齐依赖 UTF-8 charmap，越早修正越好（--list 也要用）
    _ensure_utf8_locale || log_debug "无可用 UTF-8 locale，中文对齐可能不准"
    preflight

    detect_system
    # 单文件模式下模块已在载入时注册完毕，只需构造菜单
    (( SINGLE_FILE )) || load_modules "$MODULES_DIR"
    build_main_menu

    if (( LIST_ONLY )); then
        printf '%s v%s\n' "$APP_NAME" "$APP_VERSION"
        printf '系统: %s %s (%s / %s)\n' "$DISTRO_NAME" "$DISTRO_VERSION" "$DISTRO_FAMILY" "$ARCH"
        printf '已注册 %d 个模块:\n' "${#MAIN_ITEMS[@]}"
        local i
        for (( i=0; i<${#MAIN_ITEMS[@]}; i++ )); do
            # 用 _pad_right 而不是 printf 的 %-16s：后者按字符数补齐，
            # 汉字是双宽字符，标题长度一变说明列就错开
            printf '  %2d) %s %s\n' $(( i + 1 )) \
                "$(_pad_right "${MAIN_ITEMS[i]%%|*}" 16)" "${MAIN_ITEMS[i]#*|}"
        done
        exit 0
    fi

    menu_main
}

main "$@"
