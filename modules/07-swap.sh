#!/usr/bin/env bash
# ============================================================
# 模块: Swap 管理
# id: swap
#
# 只管理「文件形式」的 swap（/swapfile 这类），不碰 swap 分区和 zram：
# 分区牵涉分区表和镜像自带的安排，删错的代价太大。删除会一次清掉所有
# 文件形式的 swap，范围仍可明确识别 —— /proc/swaps 里以 / 开头的条目
# 加上管理路径本身，逐个在预览里列出来；fstab 只动首字段正好是这些
# 路径、第三字段是 swap 的行。
#
# 重建走「先建新、再换旧」：新文件全部就绪之后才动旧的，中途失败把旧
# 文件换回来即可，不会留下「旧的删了、新的没建成」的空窗。
# ============================================================

SWAP_FILE="${SWAP_FILE:-/swapfile}"
SWAP_SWAPPINESS="${SWAP_SWAPPINESS:-10}"
SWAP_SYSCTL_CONF="${SWAP_SYSCTL_CONF:-/etc/sysctl.d/99-linux-toolkit-swap.conf}"
SWAP_FSTAB="${SWAP_FSTAB:-/etc/fstab}"
SWAP_KERNEL_SWAPPINESS=60      # vm.swappiness 的内核默认值，删除时用它还原

# ============================================================
# 取数
# ============================================================
_swap_mem_mb() {
    local kb
    kb="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo 2>/dev/null)"
    [[ "$kb" =~ ^[0-9]+$ ]] && (( kb >= 2048 )) || return 1
    printf '%s' "$(( kb / 1024 ))"
}

# 默认大小 = 内存容量 - 1MB
_swap_default_mb() {
    local mem
    mem="$(_swap_mem_mb)" || return 1
    printf '%s' "$(( mem - 1 ))"
}

# "1024" / "512M" / "8G" → MB
_swap_parse_mb() {
    local s="${1//[[:space:]]/}" n unit
    [[ "$s" =~ ^([0-9]+)([MmGg]?)$ ]] || return 1
    n="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2],,}"
    if [[ "$unit" == "g" ]]; then
        (( n >= 1 && n <= 4096 )) || return 1
        n=$(( n * 1024 ))
    else
        (( n >= 1 && n <= 1048576 )) || return 1
    fi
    printf '%s' "$n"
}

_swap_human_mb() {
    awk -v m="${1:-0}" 'BEGIN{
        if      (m >= 1048576) printf "%.1f TB", m / 1048576;
        else if (m >= 1024)    printf "%.1f GB", m / 1024;
        else                   printf "%d MB", m;
    }'
}

_swap_human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if      (k >= 1048576) printf "%.1f GB", k / 1048576;
        else if (k >= 1024)    printf "%.0f MB", k / 1024;
        else                   printf "%.0f KB", k;
    }'
}

# /proc/swaps 里文件形式的 swap。分区和 zram 都以 /dev/ 开头，天然被排除。
_swap_active_files() {
    awk 'NR > 1 && $1 ~ /^\// && $1 !~ /^\/dev\// { print $1 }' /proc/swaps 2>/dev/null
}

_swap_active_all() {
    awk 'NR > 1 { print $1 }' /proc/swaps 2>/dev/null
}

_swap_is_active() {
    local path="$1"
    awk -v p="$path" 'NR > 1 && $1 == p { f = 1 } END { exit !f }' /proc/swaps 2>/dev/null
}

# 文件大小（MB）；不存在或读不到返回非 0
_swap_file_mb() {
    local path="$1" bytes
    [[ -f "$path" ]] || return 1
    bytes="$(stat -c %s "$path" 2>/dev/null)" || return 1
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$(( bytes / 1048576 ))"
}

# fstab 里指向该文件的条目（行号 + 原文）。
# 按字段比对而不是子串匹配 —— 否则 /swapfile2 会被 /swapfile 带出来。
_swap_fstab_lines() {
    local path="$1"
    [[ -r "$SWAP_FSTAB" ]] || return 0
    awk -v p="$path" '$1 == p && $3 == "swap" { printf "%d\t%s\n", NR, $0 }' "$SWAP_FSTAB"
}

# 目标目录可能还不存在（要现建），这时 stat / df 都会失败，
# 于是向上找到第一个存在的祖先 —— 新建的目录必然和它同处一个文件系统。
_swap_existing_dir() {
    local dir="$1"
    while [[ -n "$dir" && ! -d "$dir" ]]; do
        dir="$(dirname "$dir")"
    done
    [[ -d "$dir" ]] || return 1
    printf '%s' "$dir"
}

_swap_free_mb() {
    local dir
    dir="$(_swap_existing_dir "$1")" || return 1
    df -Pk "$dir" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'
}

_swap_fs_type() {
    local dir
    dir="$(_swap_existing_dir "$1")" || { printf '未知'; return; }
    stat -f -c %T "$dir" 2>/dev/null || printf '未知'
}

# ------------------------------------------------------------
# 展示
# ------------------------------------------------------------
_swap_show_table() {
    local name type size used prio
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "名称" 26)" "$(_pad_right "类型" 8)" \
            "$(_pad_right "大小" 10)" "$(_pad_right "已用" 10)" "优先级")" "$C_RESET"
    while read -r name type size used prio; do
        [[ "$name" == "Filename" ]] && continue
        printf '  %s %s %s %s %s\n' \
            "$(_pad_right "$name" 26)" "$(_pad_right "$type" 8)" \
            "$(_pad_right "$(_swap_human_kb "$size")" 10)" \
            "$(_pad_right "$(_swap_human_kb "$used")" 10)" "${prio:--}"
    done < /proc/swaps
}

# ------------------------------------------------------------
# 变更
# ------------------------------------------------------------
# 创建交换文件。fallocate 最快，失败时退回 dd 实写。
# 目标文件系统不支持换页文件时（tmpfs）这里会失败，由调用方先做预检。
_swap_create_file() {
    local path="$1" mb="$2"
    if have_cmd fallocate && fallocate -l "${mb}M" "$path" 2>/dev/null; then
        return 0
    fi
    log_debug "fallocate 失败，改用 dd 实写 $path"
    have_cmd dd || return 1
    dd if=/dev/zero of="$path" bs=1M count="$mb" 2>/dev/null || return 1
    return 0
}

# 删掉指向该文件的 fstab 行
_swap_fstab_clean() {
    local path="$1" tmp
    [[ -n "$(_swap_fstab_lines "$path")" ]] || return 0
    tmp="$(mktemp)" || return 1
    if awk -v p="$path" '!($1 == p && $3 == "swap")' "$SWAP_FSTAB" >"$tmp"; then
        if install -m 0644 "$tmp" "$SWAP_FSTAB"; then
            rm -f "$tmp"
            return 0
        fi
    fi
    rm -f "$tmp"
    return 1
}

_swap_write_sysctl() {
    mkdir -p "$(dirname "$SWAP_SYSCTL_CONF")" || return 1
    {
        printf '# 由 Linux 一键配置脚本生成\n'
        printf 'vm.swappiness = %s\n' "$SWAP_SWAPPINESS"
    } >"$SWAP_SYSCTL_CONF"
}

# 配置现场：fstab / swappiness 整份存内存，不落备份文件。
# $(cat) 会吃掉结尾换行，用哨兵字符保住原样，还原前再摘掉。
_swap_snapshot_config() {
    SWAP_SNAP_FSTAB_EXISTED=''
    SWAP_SNAP_FSTAB=''
    if [[ -e "$SWAP_FSTAB" ]]; then
        SWAP_SNAP_FSTAB_EXISTED=1
        SWAP_SNAP_FSTAB="$(cat "$SWAP_FSTAB" 2>/dev/null; printf x)"
        SWAP_SNAP_FSTAB="${SWAP_SNAP_FSTAB%x}"
    fi

    SWAP_SNAP_SYSCTL_EXISTED=''
    SWAP_SNAP_SYSCTL=''
    if [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        SWAP_SNAP_SYSCTL_EXISTED=1
        SWAP_SNAP_SYSCTL="$(cat "$SWAP_SYSCTL_CONF" 2>/dev/null; printf x)"
        SWAP_SNAP_SYSCTL="${SWAP_SNAP_SYSCTL%x}"
    fi

    SWAP_SNAP_SWAPPINESS="$(sysctl -n vm.swappiness 2>/dev/null)"
}

# 单个文件的现场。删除流程要按文件恢复，所以启用状态单独记。
_swap_snapshot() {
    local path="$1"
    SWAP_SNAP_WAS_ACTIVE=''
    _swap_is_active "$path" && SWAP_SNAP_WAS_ACTIVE=1
    _swap_snapshot_config
}

# 回滚：撤掉新启用的 swap，把换下来的旧文件换回去，还原 fstab 与 swappiness
_swap_rollback() {
    local path="$1"

    _swap_is_active "$path" && swapoff "$path" 2>/dev/null

    if [[ -e "${path}.old" ]]; then
        rm -f "$path"
        if mv "${path}.old" "$path" 2>/dev/null; then
            if [[ -n "${SWAP_SNAP_WAS_ACTIVE:-}" ]]; then
                swapon "$path" 2>/dev/null || true
            fi
        fi
    else
        rm -f "$path"
    fi
    rm -f "${path}.new"

    if [[ -n "${SWAP_SNAP_FSTAB_EXISTED:-}" ]]; then
        printf '%s' "${SWAP_SNAP_FSTAB:-}" >"$SWAP_FSTAB" 2>/dev/null
    fi

    if [[ -n "${SWAP_SNAP_SYSCTL_EXISTED:-}" ]]; then
        printf '%s' "${SWAP_SNAP_SYSCTL:-}" >"$SWAP_SYSCTL_CONF" 2>/dev/null
    else
        rm -f "$SWAP_SYSCTL_CONF"
    fi

    if [[ -n "${SWAP_SNAP_SWAPPINESS:-}" ]]; then
        sysctl -q -w "vm.swappiness=${SWAP_SNAP_SWAPPINESS}" 2>/dev/null || true
    fi

    return 0
}

# 关闭并删除文件。返回非 0 表示文件没删掉。
_swap_teardown() {
    local path="$1"

    if _swap_is_active "$path"; then
        if swapoff "$path" 2>/dev/null; then
            log_ok "已关闭 $path"
        else
            log_err "swapoff $path 失败"
            return 1
        fi
    else
        log_info "$path 当前未启用，跳过 swapoff"
    fi

    [[ -e "$path" ]] || return 0
    if rm -f "$path"; then
        log_ok "已删除 $path"
        return 0
    fi
    log_err "删除失败: $path"
    return 1
}

# 验证：文件已生效且大小对得上。不通过则输出原因。
_swap_verify() {
    local path="$1" expect_mb="$2" got
    _swap_is_active "$path" || { printf '%s 没有出现在 /proc/swaps 里' "$path"; return 1; }
    got="$(_swap_file_mb "$path")"
    [[ "$got" == "$expect_mb" ]] || { printf '文件大小不符：期望 %s MB，实际 %s' "$expect_mb" "${got:-未知}"; return 1; }
    return 0
}

# ============================================================
# 1) 状态查看
# ============================================================
swap_status() {
    local mem default_mb fsize lines f
    local others=()

    ui_section "内存"
    if mem="$(_swap_mem_mb)"; then
        ui_kv "物理内存" "${mem} MB"
    else
        ui_kv "物理内存" "读不到"
    fi
    if default_mb="$(_swap_default_mb)"; then
        ui_kv "建议大小" "${default_mb} MB  (内存 - 1MB)"
    fi

    ui_section "当前生效的 Swap"
    if [[ -n "$(_swap_active_all)" ]]; then
        _swap_show_table
    else
        printf '  %s未启用任何 swap%s\n' "$C_DIM" "$C_RESET"
    fi

    ui_section "Swappiness"
    ui_kv "当前值" "$(sysctl -n vm.swappiness 2>/dev/null || echo 未知)"
    if [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        ui_kv "本脚本配置" "$SWAP_SYSCTL_CONF"
    else
        ui_kv "本脚本配置" "未写入"
    fi

    ui_section "本模块管理的文件"
    ui_kv "路径" "$SWAP_FILE"
    if fsize="$(_swap_file_mb "$SWAP_FILE")"; then
        ui_kv "文件" "存在，$(_swap_human_mb "$fsize")"
    else
        ui_kv "文件" "不存在"
    fi
    if _swap_is_active "$SWAP_FILE"; then
        ui_kv "状态" "已启用"
    else
        ui_kv "状态" "未启用"
    fi

    lines="$(_swap_fstab_lines "$SWAP_FILE")"
    ui_section "$SWAP_FSTAB"
    if [[ -n "$lines" ]]; then
        while IFS=$'\t' read -r n text; do
            printf '  %s#%-4s%s %s\n' "$C_YELLOW" "$n" "$C_RESET" "$text"
        done <<<"$lines"
    else
        printf '  %s没有指向 %s 的条目%s\n' "$C_DIM" "$SWAP_FILE" "$C_RESET"
    fi

    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "$SWAP_FILE" ]] && others+=("$f")
    done < <(_swap_active_files)
    if (( ${#others[@]} > 0 )); then
        ui_section "其它 swap 文件（不由本模块管理）"
        for f in "${others[@]}"; do printf '  %s\n' "$f"; done
    fi

    printf '\n  %s删除会一次清掉所有文件形式的 swap（上面列出的），分区与 zram 不在处理范围。%s\n' \
        "$C_DIM" "$C_RESET"
    module_end
}

# ============================================================
# 2) 添加 / 重建
# ============================================================
swap_add() {
    require_root

    local mem default_mb size_mb dir fs_dir fs_type free_mb
    if ! mem="$(_swap_mem_mb)"; then
        module_begin "添加 / 重建 Swap"
        log_err "读不到 /proc/meminfo 里的 MemTotal，算不出默认大小。"
        module_end
        return 1
    fi
    default_mb="$(_swap_default_mb)"
    dir="$(dirname "$SWAP_FILE")"
    fs_dir="$(_swap_existing_dir "$dir")"

    # ---- 预检：目标位置能不能放 swap 文件 ----
    # tmpfs / ramfs 上内核直接拒绝 swapon（EINVAL），而且把 swap 放在内存盘
    # 上本身就没有意义。与其让用户撞一个看不懂的报错，不如在这里说清楚。
    fs_type="$(_swap_fs_type "$dir")"
    case "$fs_type" in
        tmpfs|ramfs)
            module_begin "添加 / 重建 Swap"
            log_err "$dir 在 $fs_type 上（内存盘），不能放 swap 文件。"
            log_info "内核会直接拒绝 swapon，而且把 swap 放在内存盘上等于没加。"
            log_info "把 SWAP_FILE 指到真实磁盘，例如 /swapfile。"
            module_end
            return 1
            ;;
    esac

    # ---- 输入 ----
    module_begin "添加 / 重建 Swap"
    ui_kv "目标文件" "$SWAP_FILE"
    ui_kv "物理内存" "${mem} MB"
    ui_kv "默认大小" "${default_mb} MB  (内存 - 1MB)"
    if _swap_is_active "$SWAP_FILE"; then
        ui_kv "当前状态" "已启用，将被关闭并重建"
    elif [[ -f "$SWAP_FILE" ]]; then
        ui_kv "当前状态" "文件在但未启用，将被删除并重建"
    else
        ui_kv "当前状态" "不存在，将新建"
    fi
    printf '\n  %s%s%s\n\n' "$C_DIM" "已存在的一律删除重建，不做原地扩容。" "$C_RESET"

    while true; do
        if ! ask "Swap 大小（回车用默认，可写 512M / 8G）" "${default_mb}M"; then
            log_info "输入中断，已取消。"
            module_end
            return 0
        fi
        if size_mb="$(_swap_parse_mb "$REPLY")"; then
            break
        fi
        log_warn "格式不对：填整数 MB（如 1024），或带单位（如 512M / 8G）"
    done

    free_mb="$(_swap_free_mb "$dir")"

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将创建"
    ui_kv "文件" "$SWAP_FILE"
    ui_kv "大小" "$(_swap_human_mb "$size_mb")  (${size_mb} MB)"
    ui_kv "swappiness" "$SWAP_SWAPPINESS"
    ui_kv "配置" "$SWAP_SYSCTL_CONF"
    ui_kv "fstab" "$SWAP_FILE none swap sw 0 0"

    ui_section "将删除"
    if [[ -f "$SWAP_FILE" ]]; then
        if _swap_is_active "$SWAP_FILE"; then
            printf '  %s-%s %s（%s，当前已启用，先 swapoff）\n' \
                "$C_RED" "$C_RESET" "$SWAP_FILE" "$(_swap_human_mb "$(_swap_file_mb "$SWAP_FILE")")"
        else
            printf '  %s-%s %s（%s）\n' \
                "$C_RED" "$C_RESET" "$SWAP_FILE" "$(_swap_human_mb "$(_swap_file_mb "$SWAP_FILE")")"
        fi
    else
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    fi

    local lines
    lines="$(_swap_fstab_lines "$SWAP_FILE")"
    if [[ -n "$lines" ]]; then
        while IFS=$'\t' read -r n text; do
            printf '  %s-%s %s 第 %s 行: %s\n' "$C_RED" "$C_RESET" "$SWAP_FSTAB" "$n" "$text"
        done <<<"$lines"
    fi
    [[ -e "${SWAP_FILE}.new" ]] && printf '  %s-%s %s.new（上次中断留下的）\n' "$C_RED" "$C_RESET" "$SWAP_FILE"
    [[ -e "${SWAP_FILE}.old" ]] && printf '  %s-%s %s.old（上次中断留下的）\n' "$C_RED" "$C_RESET" "$SWAP_FILE"

    local others=() f
    while IFS= read -r f; do
        [[ -n "$f" && "$f" != "$SWAP_FILE" ]] && others+=("$f")
    done < <(_swap_active_all)
    if (( ${#others[@]} > 0 )); then
        ui_section "不在本次范围（一律保留）"
        for f in "${others[@]}"; do printf '  %s\n' "$f"; done
        printf '  %s本功能只重建 %s，其它 swap 请用「删除」单独处理。%s\n' "$C_DIM" "$SWAP_FILE" "$C_RESET"
    fi

    ui_section "磁盘空间"
    ui_kv "文件系统" "$fs_type"
    if [[ ! -d "$dir" ]]; then
        ui_kv "目标目录" "$dir（将创建）"
    fi
    ui_kv "${fs_dir:-?} 可用" "$(_swap_human_mb "${free_mb:-0}")"
    printf '  %s新文件先建好再替换旧文件，所以旧文件占的空间此刻还没释放。%s\n' "$C_DIM" "$C_RESET"

    if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < size_mb )); then
        printf '\n'
        log_err "空间不足：需要 ${size_mb} MB，可用 ${free_mb} MB。未做任何修改。"
        module_end
        return 1
    fi
    case "$fs_type" in
        btrfs|zfs)
            printf '\n'
            log_warn "$fs_type 上的 swap 文件需要额外设置（btrfs 要先关 COW），swapon 可能失败。"
            log_warn "失败会自动回滚，不会留下半成品。"
            ;;
    esac

    printf '\n'
    log_warn "旧 swap 文件会被删除且不可恢复（是删除重建，不是扩容）。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    local new_file="${SWAP_FILE}.new" old_file="${SWAP_FILE}.old"

    # 上一轮中断留下的残骸，先清掉（是我们的命名，且已在预览里列出）
    rm -f "$new_file" "$old_file"
    mkdir -p "$dir" || {
        log_err "创建目录 $dir 失败。"
        module_end
        return 1
    }

    # 先建新文件：这一步出问题，系统上什么都还没动
    ui_section "创建新文件"
    if ! _swap_create_file "$new_file" "$size_mb"; then
        log_err "创建 $new_file 失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    if ! chmod 600 "$new_file"; then
        log_err "设置权限失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    # swapon 会拒绝 0600 以外权限的文件，所以上面那步不能省
    if ! mkswap "$new_file" >/dev/null 2>&1; then
        log_err "mkswap 失败，现有配置未改动。"
        rm -f "$new_file"
        module_end
        return 1
    fi
    log_ok "新文件已就绪：$new_file（$(_swap_human_mb "$size_mb")）"

    # 到这里才开始动现有的：旧文件改名留作回滚，而不是直接删
    _swap_snapshot "$SWAP_FILE"
    ui_section "替换"
    if _swap_is_active "$SWAP_FILE"; then
        if ! swapoff "$SWAP_FILE" 2>/dev/null; then
            log_err "swapoff $SWAP_FILE 失败，未做替换。"
            rm -f "$new_file"
            module_end
            return 1
        fi
        log_ok "已关闭旧的 swap"
    fi
    [[ -e "$SWAP_FILE" ]] && mv "$SWAP_FILE" "$old_file"
    if ! mv "$new_file" "$SWAP_FILE"; then
        log_err "替换失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi

    ui_section "写入配置"
    local fstab_ok=1
    _swap_fstab_clean "$SWAP_FILE" || fstab_ok=0
    printf '%s none swap sw 0 0\n' "$SWAP_FILE" >>"$SWAP_FSTAB" || fstab_ok=0
    if (( ! fstab_ok )); then
        log_err "更新 $SWAP_FSTAB 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi
    log_ok "已写入 $SWAP_FSTAB"

    if ! _swap_write_sysctl; then
        log_err "写入 $SWAP_SYSCTL_CONF 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        module_end
        return 1
    fi
    log_ok "已写入 $SWAP_SYSCTL_CONF"
    sysctl --system >/dev/null 2>&1 || true

    ui_section "启用并验证"
    if ! swapon "$SWAP_FILE" 2>/dev/null; then
        log_err "swapon $SWAP_FILE 失败，正在回滚..."
        _swap_rollback "$SWAP_FILE"
        log_info "已恢复到变更前的状态，旧的 swap 文件仍在原处。"
        module_end
        return 1
    fi

    local why
    if ! why="$(_swap_verify "$SWAP_FILE" "$size_mb")"; then
        log_err "验证未通过（$why），正在回滚..."
        _swap_rollback "$SWAP_FILE"
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi

    log_ok "swap 已启用并验证通过。"
    rm -f "$old_file"        # 新文件确认可用，旧文件这时才真正删掉

    local sw
    sw="$(sysctl -n vm.swappiness 2>/dev/null)"
    if [[ "$sw" == "$SWAP_SWAPPINESS" ]]; then
        log_ok "vm.swappiness = $sw"
    else
        log_warn "vm.swappiness 实际是 ${sw:-未知}，不是 $SWAP_SWAPPINESS —— 有更高优先级的配置盖住了它。"
        log_info "排查: sysctl -n vm.swappiness; grep -rn swappiness /etc/sysctl.conf /etc/sysctl.d/"
    fi

    ui_section "当前状态"
    _swap_show_table
    log_info "重启后由 $SWAP_FSTAB 自动启用。"
    module_end
}

# ============================================================
# 3) 删除 —— 一次清掉所有文件形式的 swap
#
# 仍然是「明确识别的目标」：候选来自 /proc/swaps 里文件形式的条目，
# 加上管理路径本身，逐个在预览里列出来。分区和 zram 永不入选。
# ============================================================
swap_remove() {
    require_root

    local candidates=() f c
    while IFS= read -r f; do
        [[ -n "$f" ]] && candidates+=("$f")
    done < <(_swap_active_files)

    # 管理路径即使没启用也要能删（可能只是掉了 swapon，或只剩 fstab 条目）
    if [[ -f "$SWAP_FILE" ]] || [[ -n "$(_swap_fstab_lines "$SWAP_FILE")" ]] || _swap_is_active "$SWAP_FILE"; then
        local dup=0
        for f in ${candidates[@]+"${candidates[@]}"}; do
            [[ "$f" == "$SWAP_FILE" ]] && dup=1
        done
        (( dup )) || candidates+=("$SWAP_FILE")
    fi

    module_begin "删除 Swap"
    if (( ${#candidates[@]} == 0 )); then
        if [[ -n "$(_swap_active_all)" ]]; then
            log_warn "没有可删除的 swap 文件（本功能只处理文件形式的 swap）。"
            log_info "检测到的都是分区或 zram，请用其它工具处理："
            _swap_show_table
        else
            log_info "系统上没有任何正在使用的 swap，也没有 $SWAP_FILE。"
        fi
        module_end
        return 0
    fi

    # 逐个记下当前是否在跑：失败时要按文件恢复
    local active_flags=() i
    for c in "${candidates[@]}"; do
        if _swap_is_active "$c"; then
            active_flags+=("1")
        else
            active_flags+=("")
        fi
    done

    # 删完之后还剩什么 swap。分区 / zram 不入选，所以这里剩下的都是要保留的。
    local remaining=() in_list
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        in_list=0
        for c in "${candidates[@]}"; do
            [[ "$c" == "$f" ]] && in_list=1
        done
        (( in_list )) || remaining+=("$f")
    done < <(_swap_active_all)

    # 文件形式的 swap 清完、且不剩别的 swap 时，swappiness 配置才一起收走；
    # 若还剩分区 swap，它仍然受 swappiness 影响，配置得留着。
    local drop_sysctl=0
    if (( ${#remaining[@]} == 0 )) && [[ -e "$SWAP_SYSCTL_CONF" ]]; then
        drop_sysctl=1
    fi

    # ---- 预览 ----
    module_begin "确认删除"
    ui_section "将要删除（${#candidates[@]} 个文件形式的 swap）"
    local total_mb=0 sz
    for i in "${!candidates[@]}"; do
        c="${candidates[i]}"
        if sz="$(_swap_file_mb "$c")"; then
            total_mb=$(( total_mb + sz ))
            if [[ -n "${active_flags[i]}" ]]; then
                printf '  %s-%s %s（%s，启用中，先 swapoff）\n' \
                    "$C_RED" "$C_RESET" "$c" "$(_swap_human_mb "$sz")"
            else
                printf '  %s-%s %s（%s，未启用）\n' \
                    "$C_RED" "$C_RESET" "$c" "$(_swap_human_mb "$sz")"
            fi
        else
            printf '  %s-%s %s（文件不存在，只清理配置）\n' "$C_RED" "$C_RESET" "$c"
        fi
    done
    (( total_mb > 0 )) && printf '  %s合计 %s%s\n' "$C_DIM" "$(_swap_human_mb "$total_mb")" "$C_RESET"

    local lines any_fstab=0
    for c in "${candidates[@]}"; do
        lines="$(_swap_fstab_lines "$c")"
        [[ -n "$lines" ]] && any_fstab=1
    done
    if (( any_fstab )); then
        ui_section "$SWAP_FSTAB 中将移除的条目"
        for c in "${candidates[@]}"; do
            lines="$(_swap_fstab_lines "$c")"
            [[ -n "$lines" ]] || continue
            while IFS=$'\t' read -r n text; do
                printf '  %s-%s 第 %s 行: %s\n' "$C_RED" "$C_RESET" "$n" "$text"
            done <<<"$lines"
        done
    fi

    if (( drop_sysctl )); then
        printf '  %s-%s %s（并把 swappiness 还原为内核默认 %s）\n' \
            "$C_RED" "$C_RESET" "$SWAP_SYSCTL_CONF" "$SWAP_KERNEL_SWAPPINESS"
    elif [[ -e "$SWAP_SYSCTL_CONF" ]] && (( ${#remaining[@]} > 0 )); then
        printf '\n  %s%s 保留：删完还剩 swap（%s），它仍然受 swappiness 影响。%s\n' \
            "$C_DIM" "$SWAP_SYSCTL_CONF" "${remaining[*]}" "$C_RESET"
    fi

    if (( ${#remaining[@]} > 0 )); then
        ui_section "不在删除范围（保留）"
        for f in "${remaining[@]}"; do printf '  %s\n' "$f"; done
        printf '  %s分区与 zram 不归本功能管。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    log_warn "删除后文件内容无法恢复。"
    if ! confirm "确认删除这 ${#candidates[@]} 个 swap 文件?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    _swap_snapshot_config
    local ok_n=0 bad_n=0 fail=0
    for i in "${!candidates[@]}"; do
        c="${candidates[i]}"
        if _swap_teardown "$c"; then
            ok_n=$(( ok_n + 1 ))
        else
            bad_n=$(( bad_n + 1 ))
            fail=1
            # 关掉了却没删掉的话，把 swap 重新启起来，别留半截状态
            if [[ -n "${active_flags[i]}" ]] && [[ -e "$c" ]]; then
                swapon "$c" 2>/dev/null || true
                log_warn "已把 $c 重新启用，状态与删除前一致。"
            fi
        fi
        if ! _swap_fstab_clean "$c"; then
            log_err "清理 $SWAP_FSTAB 中指向 $c 的条目失败，请手动删除。"
            fail=1
        fi
    done

    if (( drop_sysctl )); then
        rm -f "$SWAP_SYSCTL_CONF"
        sysctl --system >/dev/null 2>&1 || true
        local sw
        sw="$(sysctl -n vm.swappiness 2>/dev/null)"
        # 配置删了，内核里的当前值不会自己变回去。
        # 若没有别的配置接管，显式恢复成内核默认值。
        if [[ "$sw" == "$SWAP_SWAPPINESS" ]]; then
            sysctl -q -w "vm.swappiness=$SWAP_KERNEL_SWAPPINESS" 2>/dev/null || true
            sw="$(sysctl -n vm.swappiness 2>/dev/null)"
        fi
        log_ok "已移除 swappiness 配置，当前 vm.swappiness = ${sw:-未知}"
    fi

    ui_section "验证"
    for c in "${candidates[@]}"; do
        if _swap_is_active "$c"; then
            log_err "$c 仍在 /proc/swaps 里"
            fail=1
        fi
        if [[ -e "$c" ]]; then
            log_err "$c 文件仍然存在"
            fail=1
        fi
        if [[ -n "$(_swap_fstab_lines "$c")" ]]; then
            log_err "$SWAP_FSTAB 里还有指向 $c 的条目"
            fail=1
        fi
    done

    if (( fail )); then
        log_warn "有 $bad_n 个未能完整删除，请按上面的提示处理。"
        module_end
        return 1
    fi

    log_ok "已删除 ${ok_n} 个 swap 文件，fstab 与 swappiness 均已清理。"

    ui_section "当前状态"
    if [[ -n "$(_swap_active_all)" ]]; then
        _swap_show_table
    else
        printf '  %s已无 swap%s\n' "$C_DIM" "$C_RESET"
    fi
    module_end
}

# ---- 模块入口 ----
menu_swap() {
    local items=(
        "状态查看|swap 用量 / swappiness / fstab"
        "添加 / 重建|默认内存-1MB，已存在则删除重建"
        "删除|一次清掉所有文件形式的 swap"
    )
    local fns=(swap_status swap_add swap_remove)
    run_submenu "Swap 管理" items fns
}

register_module "swap" "Swap 管理" "menu_swap" "添加 / 删除 / swappiness"
