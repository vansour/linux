#!/usr/bin/env bash
# ============================================================
# 模块: 系统更新
# id: update
# ============================================================

# ------------------------------------------------------------
# Debian 镜像源定义（统一走 http）
# 三个数组下标一一对应
# ------------------------------------------------------------
MIRROR_NAMES=(
    "Debian 官方源"
    "中科大 USTC"
    "清华 TUNA"
)
MIRROR_DEB=(
    "http://deb.debian.org/debian"
    "http://mirrors.ustc.edu.cn/debian"
    "http://mirrors.tuna.tsinghua.edu.cn/debian"
)
MIRROR_SEC=(
    "http://deb.debian.org/debian-security"
    "http://mirrors.ustc.edu.cn/debian-security"
    "http://mirrors.tuna.tsinghua.edu.cn/debian-security"
)

# apt 配置目录。留出变量是为了能在 chroot / 容器 / 测试里改指向
APT_CONF_DIR="${APT_CONF_DIR:-/etc/apt}"
APT_KEYRING="${APT_KEYRING:-/usr/share/keyrings/debian-archive-keyring.gpg}"
DEBIAN_SOURCES_FILE="$APT_CONF_DIR/sources.list.d/debian.sources"
DEBIAN_SOURCES_LIST="$APT_CONF_DIR/sources.list"

# 组件列表（Debian 12+ 的 non-free-firmware 必须带上，否则装不了固件）
DEB_COMPONENTS="main contrib non-free non-free-firmware"

# ------------------------------------------------------------
# 确定系统代号（trixie / bookworm / ...）
# ------------------------------------------------------------
_debian_codename() {
    local c="${DISTRO_CODENAME:-}"

    if [[ -z "$c" ]] && have_cmd lsb_release; then
        c="$(lsb_release -sc 2>/dev/null)"
    fi

    # 兜底：从现有源文件里推断（取第一个 Suite，去掉 -updates/-security 等后缀）
    if [[ -z "$c" ]]; then
        local f
        while IFS= read -r f; do
            c="$(grep -hE '^(deb |Suites:)' "$f" 2>/dev/null | head -1 \
                 | sed -E 's/^deb .* ([a-z]+)(-security|-updates|-backports)? .*/\1/; s/^Suites:[[:space:]]*//; s/[[:space:]].*//')"
            [[ -n "$c" ]] && break
        done < <(_list_debian_source_files)
    fi

    printf '%s' "$c"
}

# ------------------------------------------------------------
# 识别「Debian 镜像源文件」—— 这是删除范围的判定依据
#
# 只认 URI 路径直接挂在 /debian 或 /debian-security 下的源，
# 因此下面这些第三方源会被正确放过：
#   https://download.docker.com/linux/debian   (路径是 /linux/debian)
#   https://packagecloud.io/ookla/.../debian   (路径不以 /debian 开头)
#   https://cli.github.com/packages            (跟 debian 无关)
# ------------------------------------------------------------
_is_debian_mirror_file() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    grep -vE '^[[:space:]]*(#|$)' "$f" 2>/dev/null \
        | grep -qE '://[^/[:space:]]+/debian(-security)?([/[:space:]]|$)'
}

# 列出所有需要删除的 Debian 镜像源文件
_list_debian_source_files() {
    local f

    if [[ -e "$DEBIAN_SOURCES_LIST" ]]; then
        # 是镜像源，或者干脆是个空壳（没有任何生效行）都一并清掉
        if [[ ! -s "$DEBIAN_SOURCES_LIST" ]] \
           || ! grep -qvE '^[[:space:]]*(#|$)' "$DEBIAN_SOURCES_LIST" 2>/dev/null \
           || _is_debian_mirror_file "$DEBIAN_SOURCES_LIST"; then
            printf '%s\n' "$DEBIAN_SOURCES_LIST"
        fi
    fi

    shopt -s nullglob
    for f in "$APT_CONF_DIR"/sources.list.d/*.list "$APT_CONF_DIR"/sources.list.d/*.sources; do
        _is_debian_mirror_file "$f" && printf '%s\n' "$f"
    done
    shopt -u nullglob
}

# ------------------------------------------------------------
# 生成 debian.sources 内容
# ------------------------------------------------------------
_render_debian_sources() {
    local idx="$1" codename="$2"
    local deb="${MIRROR_DEB[idx]}" sec="${MIRROR_SEC[idx]}"
    local suites="$codename $codename-updates $codename-backports"
    local sec_suite="$codename-security"

    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$deb" "$suites" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$deb" "$suites" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n\n' \
        "$sec" "$sec_suite" "$DEB_COMPONENTS" "$APT_KEYRING"
    printf 'Types: deb-src\nURIs: %s\nSuites: %s\nComponents: %s\nSigned-By: %s\n' \
        "$sec" "$sec_suite" "$DEB_COMPONENTS" "$APT_KEYRING"
}

# ------------------------------------------------------------
# 在沙箱里试抓新源，确认可用后才动真格
#
# 这里有几个 apt 的坑，每一条踩过都会让验证变成「验证空气」：
#   1) 候选文件必须放进一个目录、由 Dir::Etc::sourceparts 指过去。
#      Dir::Etc::sourcelist 只按一行式 .list 解析，喂 deb822 内容会直接报
#      "Type 'Types:' is not known"，根本走不到网络。
#   2) sourceparts 与 sourcelist 都要隔离掉系统现有的源，否则验证的是
#      系统原来的源，不是我们要换的这个。
#   3) --error-on=any 必须加。apt 默认把拉取失败当警告，退出码仍是 0。
#   4) 必须出现 Get:/Hit: 行。apt 空跑（一个源都没读到）同样返回 0。
#
# 全程只写临时目录，不碰 /var/lib/apt/lists。
# ------------------------------------------------------------
_validate_sources() {
    local candidate="$1"
    local tmp out rc

    if [[ "$candidate" != /* ]]; then
        printf '内部错误: 待验证的源文件必须用绝对路径\n'
        return 1
    fi

    tmp="$(mktemp -d)"
    mkdir -p "$tmp/parts" "$tmp/lists/partial"
    # 文件名固定：apt 从目录里按 *.sources 读取，名字本身不影响解析
    cp "$candidate" "$tmp/parts/debian.sources"

    out="$(apt-get update \
        -o Dir::Etc::sourcelist="-" \
        -o Dir::Etc::sourceparts="$tmp/parts" \
        -o Dir::State::Lists="$tmp/lists" \
        -o APT::Get::List-Cleanup=0 \
        -o Acquire::http::Timeout=15 \
        -o Acquire::Retries=1 \
        --error-on=any 2>&1)"
    rc=$?
    rm -rf "$tmp"

    if (( rc != 0 )); then
        printf '%s\n' "$out"
        return 1
    fi
    if ! printf '%s\n' "$out" | grep -qE '^(Get|Hit):'; then
        printf '%s\n' "$out"
        printf '没有任何仓库被实际拉取，无法确认源可用\n'
        return 1
    fi
    if printf '%s\n' "$out" | grep -qE '^Err'; then
        printf '%s\n' "$out"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 主流程
# ------------------------------------------------------------
deb_mirror_switch() {
    # 只支持 Debian 本体：Ubuntu 等衍生版包结构不同，套用会炸
    if [[ "${DISTRO_ID:-}" != "debian" ]]; then
        module_begin "更换镜像源"
        log_err "此功能仅支持 Debian，当前系统是 $DISTRO_NAME。"
        log_info "衍生版（Ubuntu 等）的仓库结构与 Debian 不同，套用会破坏 apt。"
        module_end
        return 1
    fi

    require_root

    local codename
    codename="$(_debian_codename)"
    if [[ -z "$codename" ]]; then
        module_begin "更换镜像源"
        log_err "无法确定系统代号（codename），已中止。"
        log_info "可手动确认 /etc/os-release 里的 VERSION_CODENAME。"
        module_end
        return 1
    fi

    # ---- 选镜像 ----
    local items=() i
    for (( i=0; i<${#MIRROR_NAMES[@]}; i++ )); do
        items+=("${MIRROR_NAMES[i]}|${MIRROR_DEB[i]}")
    done

    module_begin "更换镜像源"
    ui_kv "系统" "$DISTRO_NAME $DISTRO_VERSION"
    ui_kv "代号" "$codename"
    ui_kv "目标文件" "$DEBIAN_SOURCES_FILE"
    ui_menu "选择镜像源" items "← 放弃更换"
    (( UI_CHOICE < 0 )) && return 0
    local idx=$UI_CHOICE

    # ---- 列出待删除文件 ----
    local victims=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && victims+=("$f")
    done < <(_list_debian_source_files)

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "镜像源"
    ui_kv "已选" "${MIRROR_NAMES[idx]}"
    ui_kv "主仓库" "${MIRROR_DEB[idx]}"
    ui_kv "安全仓库" "${MIRROR_SEC[idx]}"

    ui_section "将要删除"
    if (( ${#victims[@]} == 0 )); then
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    else
        for f in "${victims[@]}"; do
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$f"
        done
    fi
    printf '  %s未列出的文件（docker / gh / pgdg 等第三方源）一律保留%s\n' "$C_DIM" "$C_RESET"

    ui_section "将要写入 $DEBIAN_SOURCES_FILE"
    _render_debian_sources "$idx" "$codename" | sed 's/^/  /'

    printf '\n'
    log_warn "此操作不可撤销，且不会备份原文件。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 先验证，通过了才动真格 ----
    module_begin "验证新镜像源"
    log_info "正在沙箱中试抓 ${MIRROR_NAMES[idx]} ..."

    local candidate rc=0
    candidate="$(mktemp /tmp/debian.sources.XXXXXX)"
    _render_debian_sources "$idx" "$codename" >"$candidate"

    if _validate_sources "$candidate"; then
        log_ok "镜像源可用，验证通过。"
    else
        rc=1
        log_err "新镜像源验证失败，未修改任何文件。"
        log_info "原源配置保持不变，系统仍可正常使用。"
    fi

    if (( rc != 0 )); then
        rm -f "$candidate"
        module_end
        return 1
    fi

    # ---- 执行 ----
    ui_section "执行变更"
    local f
    for f in "${victims[@]}"; do
        if rm -f "$f"; then
            log_ok "已删除 $f"
        else
            log_err "删除失败: $f"
            rc=1
        fi
    done

    mkdir -p "$(dirname "$DEBIAN_SOURCES_FILE")"
    if install -m 0644 "$candidate" "$DEBIAN_SOURCES_FILE"; then
        log_ok "已写入 $DEBIAN_SOURCES_FILE"
    else
        log_err "写入失败: $DEBIAN_SOURCES_FILE"
        rc=1
    fi
    rm -f "$candidate"

    if (( rc != 0 )); then
        log_err "变更未完全成功，请检查上面的错误。"
        module_end
        return 1
    fi

    # ---- 刷新 ----
    ui_section "刷新软件源"
    if pkg_refresh; then
        log_ok "软件源已切换到「${MIRROR_NAMES[idx]}」。"
    else
        log_warn "apt-get update 失败，请手动检查 $DEBIAN_SOURCES_FILE"
    fi

    module_end
}

# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
upd_refresh() {
    not_implemented          # TODO: 刷新软件源缓存
    module_end
}

upd_upgrade() {
    not_implemented          # TODO: 升级已安装软件包
    module_end
}

upd_clean() {
    not_implemented          # TODO: 清理无用依赖与缓存
    module_end
}

menu_update() {
    local items=(
        "更换镜像源|Debian 官方 / 中科大 / 清华"
        "刷新缓存|update"
        "升级软件包|upgrade"
        "清理缓存|autoremove / clean"
    )
    local fns=(deb_mirror_switch upd_refresh upd_upgrade upd_clean)
    run_submenu "系统更新" items fns
}

register_module "update" "系统更新" "menu_update" "镜像源 / 升级 / 清理"
