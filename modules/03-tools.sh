#!/usr/bin/env bash
# ============================================================
# 模块: 常用工具
# id: tools
#
# 一律使用各软件厂商的官方源，不走发行版自带仓库、不走第三方镜像。
# 厂商提供官方一键脚本的用脚本，没有的走官方 apt 源手动配置：
#   Docker     → get.docker.com 官方脚本
#   Speedtest  → packagecloud 官方脚本（Ookla 指定的方式）
#   gh         → cli.github.com 官方源
#   nginx 主线 → nginx.org 官方源
# ============================================================

APT_KEYRINGS_DIR="${APT_KEYRINGS_DIR:-/etc/apt/keyrings}"
APT_SOURCES_DIR="${APT_SOURCES_DIR:-/etc/apt/sources.list.d}"
# nginx.org 官方文档用的是这个路径（不是 /etc/apt/keyrings）
NGINX_KEYRING="${NGINX_KEYRING:-/usr/share/keyrings/nginx-archive-keyring.gpg}"

# ------------------------------------------------------------
# 通用辅助
# ------------------------------------------------------------
_tool_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

_tool_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null
}

# 下载并安装 apt 签名密钥
#   $1 = URL
#   $2 = 目标路径
#   $3 = 传 "armor" 表示下载的是 ASCII 装甲公钥，需要 gpg --dearmor
#
# apt 的 signed-by 只认二进制 keyring，ASCII 装甲必须转换，
# 否则会报 "does not contain a valid OpenPGP public key"。
_apt_key_install() {
    local url="$1" dest="$2" armor="${3:-}"
    local tmp

    tmp="$(mktemp)"
    log_info "下载密钥: $url"
    if ! curl -fsSL --max-time 60 "$url" -o "$tmp"; then
        log_err "密钥下载失败"
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_err "密钥内容为空"
        rm -f "$tmp"
        return 1
    fi

    mkdir -p "$(dirname "$dest")" || { rm -f "$tmp"; return 1; }

    if [[ "$armor" == "armor" ]]; then
        if ! gpg --dearmor <"$tmp" >"$dest" 2>/dev/null; then
            log_err "密钥格式转换失败，可能不是有效的 ASCII PGP 公钥"
            rm -f "$tmp" "$dest"
            return 1
        fi
    else
        install -m 0644 "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
    fi
    chmod 0644 "$dest" 2>/dev/null

    rm -f "$tmp"
    log_ok "密钥已安装: $dest"
    return 0
}

# 写入 apt 源文件
_apt_repo_install() {
    local file="$1" line="$2"
    mkdir -p "$(dirname "$file")" || return 1
    if ! printf '%s\n' "$line" >"$file"; then
        log_err "写入源文件失败: $file"
        return 1
    fi
    log_ok "源已添加: $file"
    return 0
}

# 下载并执行厂商提供的官方安装脚本。
# 先落盘再执行，而不是 curl | sh —— 这样能检查下载是否成功、
# 内容是否为空，执行失败也能拿到真实退出码。
_run_official_script() {
    local url="$1"
    local tmp rc=0

    tmp="$(mktemp)"
    log_info "下载官方脚本: $url"
    if ! curl -fsSL --max-time 120 "$url" -o "$tmp"; then
        log_err "脚本下载失败"
        rm -f "$tmp"
        return 1
    fi
    if [[ ! -s "$tmp" ]]; then
        log_err "脚本内容为空"
        rm -f "$tmp"
        return 1
    fi
    if ! head -c 64 "$tmp" | grep -qE '^#!|^#'; then
        log_err "下载的内容不像 shell 脚本，已中止"
        rm -f "$tmp"
        return 1
    fi

    log_info "执行中（输出可能较长）..."
    sh "$tmp" || rc=$?
    rm -f "$tmp"

    if (( rc != 0 )); then
        log_err "官方脚本以退出码 $rc 结束"
        return 1
    fi
    return 0
}

# ============================================================
# Docker —— 官方一键脚本
# ============================================================
tools_docker() {
    require_root

    module_begin "安装 Docker"
    ui_kv "安装方式" "官方一键脚本"
    ui_kv "脚本地址" "https://get.docker.com"
    if _tool_installed docker-ce; then
        ui_kv "当前版本" "$(_tool_version docker-ce)"
    else
        ui_kv "当前版本" "未安装"
    fi

    ui_section "说明"
    printf '  %s该脚本会添加 Docker 官方源并安装：%s\n' "$C_DIM" "$C_RESET"
    printf '  %sdocker-ce / containerd.io / buildx / compose 插件%s\n' "$C_DIM" "$C_RESET"
    printf '\n'
    log_warn "Docker 官方脚本自述「not recommended for production environments」，"
    log_warn "生产环境更推荐手动配置官方源后安装。此处按你的要求使用一键脚本。"

    printf '\n'
    if ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    if _tool_installed docker-ce; then
        if ! confirm "已装版本 $(_tool_version docker-ce)，继续会执行升级。继续?" n; then
            log_info "已取消。"
            module_end
            return 0
        fi
    fi

    if ! _run_official_script "https://get.docker.com"; then
        log_err "Docker 安装失败。"
        log_info "可手动执行查看详情: curl -fsSL https://get.docker.com | sh"
        module_end
        return 1
    fi

    # 脚本在部分情况下只加源不装包，这里补一刀
    if ! _tool_installed docker-ce; then
        log_info "脚本未完成安装，尝试从官方源安装 ..."
        pkg_refresh || true
        pkg_install docker-ce docker-ce-cli containerd.io || true
    fi

    ui_section "验证"
    if have_cmd docker; then
        log_ok "已安装: $(docker --version 2>/dev/null)"
        if have_cmd systemctl && systemctl is-active --quiet docker 2>/dev/null; then
            log_ok "docker 服务运行中"
        else
            log_warn "docker 服务未运行，可执行: systemctl enable --now docker"
        fi
    else
        log_err "安装后未找到 docker 命令，请检查上面的输出。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# GitHub CLI (gh) —— 官方源
# ============================================================
tools_gh() {
    require_root

    local keyring="$APT_KEYRINGS_DIR/githubcli-archive-keyring.gpg"
    local list="$APT_SOURCES_DIR/github-cli.list"
    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

    module_begin "安装 GitHub CLI"
    ui_kv "安装方式" "官方 apt 源"
    ui_kv "仓库" "https://cli.github.com/packages"
    ui_kv "密钥" "$keyring"
    if _tool_installed gh; then
        ui_kv "当前版本" "$(_tool_version gh)"
    else
        ui_kv "当前版本" "未安装"
    fi

    printf '\n'
    if _tool_installed gh && ! confirm "gh 已安装，继续会升级。继续?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi
    if ! _tool_installed gh && ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    _apt_key_install "https://cli.github.com/packages/githubcli-archive-keyring.gpg" "$keyring" \
        || { module_end; return 1; }
    # 这个 key 是二进制格式，不需要 dearmor
    _apt_repo_install "$list" \
        "deb [arch=$arch signed-by=$keyring] https://cli.github.com/packages stable main" \
        || { module_end; return 1; }

    pkg_refresh || true
    if ! pkg_install gh; then
        log_err "gh 安装失败。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd gh; then
        log_ok "已安装: $(gh --version 2>/dev/null | head -1)"
    else
        log_err "安装后未找到 gh 命令。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# nginx 主线版 —— nginx.org 官方源
# ============================================================
tools_nginx() {
    require_root

    local keyring="$NGINX_KEYRING"
    local list="$APT_SOURCES_DIR/nginx.list"
    local codename="${DISTRO_CODENAME:-}"

    if [[ -z "$codename" ]] && have_cmd lsb_release; then
        codename="$(lsb_release -sc 2>/dev/null)"
    fi
    if [[ -z "$codename" ]]; then
        module_begin "安装 nginx 主线版"
        log_err "无法确定系统代号，已中止。"
        module_end
        return 1
    fi

    module_begin "安装 nginx 主线版"
    ui_kv "安装方式" "nginx.org 官方源"
    ui_kv "仓库" "http://nginx.org/packages/mainline/debian"
    ui_kv "系统代号" "$codename"
    ui_kv "密钥" "$keyring"

    if _tool_installed nginx; then
        ui_kv "当前版本" "$(_tool_version nginx)"
    else
        ui_kv "当前版本" "未安装"
    fi

    # nginx.org 的包名也叫 nginx，会顶掉发行版自带的那个，
    # 两者配置文件布局不同，直接覆盖容易留下不一致的配置。
    if _tool_installed nginx && ! _tool_version nginx | grep -q '~'; then
        printf '\n'
        log_warn "检测到已安装的可能是发行版自带的 nginx（版本 $(_tool_version nginx)）。"
        log_warn "nginx.org 的包会替换它，且配置目录布局不同。"
        log_info "更稳妥的做法是先备份并卸载: apt-get purge nginx nginx-common"
    fi

    printf '\n'
    if ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    # nginx.org 发布的是 ASCII 装甲公钥，必须 dearmor
    _apt_key_install "https://nginx.org/keys/nginx_signing.key" "$keyring" armor \
        || { module_end; return 1; }
    _apt_repo_install "$list" \
        "deb [signed-by=$keyring] http://nginx.org/packages/mainline/debian $codename nginx" \
        || { module_end; return 1; }

    pkg_refresh || true
    if ! pkg_install nginx; then
        log_err "nginx 安装失败。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd nginx; then
        log_ok "已安装: $(nginx -v 2>&1)"
        local ver
        ver="$(_tool_version nginx)"
        if [[ "$ver" == *"~"* ]]; then
            log_ok "来源确认: nginx.org 官方源（版本号含 ~${codename}）"
        else
            log_warn "版本号 $ver 不像 nginx.org 的包，请确认来源。"
        fi
    else
        log_err "安装后未找到 nginx 命令。"
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# Speedtest CLI —— Ookla 官方源
# ============================================================
tools_speedtest() {
    require_root

    local script_url="https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh"

    module_begin "安装 Speedtest CLI"
    ui_kv "安装方式" "官方源（packagecloud 脚本）"
    ui_kv "脚本地址" "$script_url"
    if _tool_installed speedtest; then
        ui_kv "当前版本" "$(_tool_version speedtest)"
    else
        ui_kv "当前版本" "未安装"
    fi

    ui_section "说明"
    printf '  %s该脚本仅添加 Ookla 官方源并安装签名密钥，%s\n' "$C_DIM" "$C_RESET"
    printf '  %s之后从这里安装 speedtest 包。%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认安装?" n; then
        log_info "已取消。"
        module_end
        return 0
    fi

    if ! _run_official_script "$script_url"; then
        log_err "添加官方源失败。"
        module_end
        return 1
    fi

    pkg_refresh || true
    if ! pkg_install speedtest; then
        log_err "speedtest 安装失败。"
        log_info "注意：包名是 speedtest（Ookla 官方），不是 Debian 的 speedtest-cli。"
        module_end
        return 1
    fi

    ui_section "验证"
    if have_cmd speedtest; then
        log_ok "已安装: $(speedtest --version 2>/dev/null | head -1)"
    else
        log_err "安装后未找到 speedtest 命令。"
        module_end
        return 1
    fi

    module_end
}

# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
tools_basic() {
    not_implemented          # TODO: 批量安装常用命令行工具
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
        "Docker|官方一键脚本，含 compose 插件"
        "GitHub CLI|官方源安装 gh"
        "nginx 主线版|nginx.org 官方源"
        "Speedtest|Ookla 官方源"
        "基础工具|vim curl wget git htop 等"
        "Shell 环境|zsh / oh-my-zsh"
        "运维面板|常用面板一键安装"
    )
    local fns=(tools_docker tools_gh tools_nginx tools_speedtest tools_basic tools_shell tools_bt)
    run_submenu "常用工具" items fns
}

register_module "tools" "常用工具" "menu_tools" "Docker / gh / nginx / 测速"
