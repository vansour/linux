#!/usr/bin/env bash
# ============================================================
# 模块: 系统信息
# id: system
#
# 全部只读，不做任何修改。
# ============================================================

# ------------------------------------------------------------
# 取数辅助
# ------------------------------------------------------------

# 运行时长（秒 → 「3天2小时15分」）
_uptime_human() {
    local s
    if [[ -r /proc/uptime ]]; then
        read -r s _ < /proc/uptime
        s="${s%%.*}"
    else
        return 1
    fi
    local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
    local out=''
    (( d > 0 )) && out="${d}天"
    (( h > 0 )) && out="${out}${h}小时"
    printf '%s%s分' "$out" "$m"
}

# 开机时刻
_boot_time() {
    if have_cmd uptime; then
        uptime -s 2>/dev/null && return
    fi
    local s
    [[ -r /proc/uptime ]] || return 1
    read -r s _ < /proc/uptime
    date -d "@$(( $(date +%s) - ${s%%.*} ))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# 1/5/15 分钟负载
_load_avg() {
    local l1 l5 l15 _rest
    [[ -r /proc/loadavg ]] || return 1
    read -r l1 l5 l15 _rest < /proc/loadavg
    printf '%s / %s / %s' "$l1" "$l5" "$l15"
}

_virt_type() {
    if have_cmd systemd-detect-virt; then
        local v
        v="$(systemd-detect-virt 2>/dev/null)"
        [[ "$v" == "none" ]] && v="物理机"
        printf '%s' "${v:-未知}"
    else
        printf '未知'
    fi
}

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------
_cpu_model() {
    local m
    m="$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
    [[ -z "$m" ]] && m="$(grep -m1 -E '^Hardware|^cpu model' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^[[:space:]]*//')"
    printf '%s' "${m:-未知}"
}

# 物理核数（按 physical id + core id 去重）/ 逻辑核数
_cpu_cores() {
    local logical physical
    logical="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$logical" || "$logical" == 0 ]] && logical="$(nproc 2>/dev/null || echo 0)"

    physical="$(awk -F: '
        /^physical id/ { gsub(/[^0-9]/, "", $2); pid = $2 }
        /^core id/     { gsub(/[^0-9]/, "", $2); seen[pid ":" $2] = 1 }
        END { n = 0; for (k in seen) n++; print n }
    ' /proc/cpuinfo 2>/dev/null)"
    [[ -z "$physical" || "$physical" == 0 ]] && physical="$logical"

    # 输出「物理核 逻辑核」两个字段，供调用方 read 消费
    printf '%s %s\n' "$physical" "$logical"
}

# /proc/stat 第一行累计的 (总时间, 空闲时间)
_cpu_jiffies() {
    local line f total=0 idle=0 n=0
    [[ -r /proc/stat ]] || return 1
    read -r line < /proc/stat
    line="${line#cpu}"
    for f in $line; do
        total=$(( total + f ))
        n=$(( n + 1 ))
        # 第 4、5 列是 idle 与 iowait，都算「没干活」
        (( n == 4 || n == 5 )) && idle=$(( idle + f ))
    done
    # 结尾必须有换行：read 读到 EOF 而没见到分隔符时会返回非零
    printf '%s %s\n' "$total" "$idle"
}

# 采样一次算占用率（/proc/stat 是累计值，必须取两次差值）
_cpu_usage() {
    local t1 i1 t2 i2
    read -r t1 i1 < <(_cpu_jiffies) || return 1
    sleep 0.5
    read -r t2 i2 < <(_cpu_jiffies) || return 1

    local dt=$(( t2 - t1 )) di=$(( i2 - i1 ))
    (( dt <= 0 )) && { printf '?'; return; }
    awk -v dt="$dt" -v di="$di" 'BEGIN{ printf "%.1f", (1 - di / dt) * 100 }'
}

# ------------------------------------------------------------
# 内存
# ------------------------------------------------------------
# /proc/meminfo 单位是 kB
_meminfo() {
    awk -v k="$1:" '$1 == k { print $2; exit }' /proc/meminfo 2>/dev/null
}

_human_kb() {
    awk -v k="${1:-0}" 'BEGIN{
        if      (k >= 1073741824) printf "%.1f TB", k / 1073741824;
        else if (k >= 1048576)    printf "%.1f GB", k / 1048576;
        else if (k >= 1024)       printf "%.0f MB", k / 1024;
        else                      printf "%.0f KB", k;
    }'
}

# ------------------------------------------------------------
# 颜色：按百分比
# ------------------------------------------------------------
_pct_color() {
    local p="${1%\%}"
    [[ "$p" =~ ^[0-9]+$ ]] || { printf '%s' "$C_RESET"; return; }
    if   (( p >= 90 )); then printf '%s' "$C_BRED"
    elif (( p >= 70 )); then printf '%s' "$C_BYELLOW"
    else                     printf '%s' "$C_GREEN"
    fi
}

# ============================================================
# 1) 系统概览
# ============================================================
sys_overview() {
    ui_section "主机"
    ui_kv "主机名" "${HOSTNAME_SHORT:-$(uname -n)}"
    ui_kv "运行时长" "$(_uptime_human 2>/dev/null || echo 未知)"
    ui_kv "启动时间" "$(_boot_time 2>/dev/null || echo 未知)"
    ui_kv "负载" "$(_load_avg 2>/dev/null || echo 未知)   (1/5/15 分钟)"

    ui_section "系统"
    ui_kv "发行版" "${DISTRO_NAME}${DISTRO_VERSION:+ $DISTRO_VERSION}"
    ui_kv "代号" "${DISTRO_CODENAME:-未知}"
    ui_kv "内核" "$KERNEL"
    ui_kv "架构" "$ARCH"
    ui_kv "虚拟化" "$(_virt_type)"

    ui_section "时间"
    ui_kv "系统时间" "$(date '+%Y-%m-%d %H:%M:%S')"
    ui_kv "时区" "$(date '+%Z %z')"

    module_end
}

# ============================================================
# 2) CPU 与内存
# ============================================================
sys_resource() {
    local physical logical
    read -r physical logical < <(_cpu_cores)

    ui_section "CPU"
    ui_kv "型号" "$(_cpu_model)"
    ui_kv "核心" "${physical} 物理 / ${logical} 逻辑"
    printf '  %s%s%s %s%%%s   %s(采样 0.5 秒)%s\n' \
        "$C_DIM" "$(_pad_right "占用" 14)" "$C_RESET" \
        "$(_cpu_usage 2>/dev/null || echo '?')" "$C_RESET" "$C_DIM" "$C_RESET"

    local total avail used pct
    total="$(_meminfo MemTotal)"
    avail="$(_meminfo MemAvailable)"
    if [[ -n "$total" && -n "$avail" ]]; then
        used=$(( total - avail ))
        pct=$(( total > 0 ? used * 100 / total : 0 ))
        ui_section "内存"
        ui_kv "总量" "$(_human_kb "$total")"
        printf '  %s%s%s %s%s%s (%s%%)\n' \
            "$C_DIM" "$(_pad_right "已用" 14)" "$C_RESET" \
            "$(_pct_color "$pct")" "$(_human_kb "$used")" "$C_RESET" "$pct"
        ui_kv "可用" "$(_human_kb "$avail")"
    else
        ui_section "内存"
        printf '  %s读不到 /proc/meminfo%s\n' "$C_DIM" "$C_RESET"
    fi

    local stotal sfree
    stotal="$(_meminfo SwapTotal)"
    sfree="$(_meminfo SwapFree)"
    ui_section "Swap"
    if [[ -z "$stotal" || "$stotal" == 0 ]]; then
        printf '  %s未启用%s\n' "$C_DIM" "$C_RESET"
    else
        local sused=$(( stotal - sfree ))
        local spct=$(( stotal > 0 ? sused * 100 / stotal : 0 ))
        ui_kv "总量" "$(_human_kb "$stotal")"
        printf '  %s%s%s %s%s%s (%s%%)\n' \
            "$C_DIM" "$(_pad_right "已用" 14)" "$C_RESET" \
            "$(_pct_color "$spct")" "$(_human_kb "$sused")" "$C_RESET" "$spct"
    fi

    module_end
}

# ============================================================
# 3) 磁盘空间
# ============================================================
# 只看真实文件系统，过滤 tmpfs/devtmpfs 这类内存盘
_DF_EXCLUDES=(-x tmpfs -x devtmpfs -x squashfs -x efivarfs -x ramfs -x overlay)

sys_disk() {
    local fs size used avail pct mnt

    ui_section "容量"
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "挂载点" 22)" "$(_pad_right "容量" 10)" \
            "$(_pad_right "已用" 10)" "$(_pad_right "可用" 10)" "使用率")" "$C_RESET"

    if ! df -hP "${_DF_EXCLUDES[@]}" >/dev/null 2>&1; then
        printf '  %sdf 不可用%s\n' "$C_DIM" "$C_RESET"
        module_end
        return 0
    fi

    while read -r fs size used avail pct mnt; do
        [[ "$fs" == "Filesystem" ]] && continue
        printf '  %s %s %s %s %s%s%s\n' \
            "$(_pad_right "$mnt" 22)" "$(_pad_right "$size" 10)" \
            "$(_pad_right "$used" 10)" "$(_pad_right "$avail" 10)" \
            "$(_pct_color "$pct")" "$(_pad_right "$pct" 5)" "$C_RESET"
    done < <(df -hP "${_DF_EXCLUDES[@]}" 2>/dev/null)

    ui_section "inode"
    printf '  %s%s%s\n' "$C_DIM" \
        "$(printf '%s %s %s %s %s' \
            "$(_pad_right "挂载点" 22)" "$(_pad_right "总量" 10)" \
            "$(_pad_right "已用" 10)" "$(_pad_right "可用" 10)" "使用率")" "$C_RESET"

    while read -r fs total used free pct mnt; do
        [[ "$fs" == "Filesystem" ]] && continue
        printf '  %s %s %s %s %s%s%s\n' \
            "$(_pad_right "$mnt" 22)" "$(_pad_right "$total" 10)" \
            "$(_pad_right "$used" 10)" "$(_pad_right "$free" 10)" \
            "$(_pct_color "$pct")" "$(_pad_right "$pct" 5)" "$C_RESET"
    done < <(df -iP "${_DF_EXCLUDES[@]}" 2>/dev/null)

    printf '\n  %s已过滤 tmpfs / devtmpfs / overlay 等非真实文件系统%s\n' "$C_DIM" "$C_RESET"
    module_end
}

# ============================================================
# 4) 网络接口
# ============================================================
sys_network_iface() {
    local d dev addrs

    ui_section "网卡"
    if ! have_cmd ip; then
        ui_kv "IP 地址" "$(hostname -I 2>/dev/null || echo 未知)"
        printf '  %s未安装 iproute2，无法列出各网卡明细%s\n' "$C_DIM" "$C_RESET"
    else
        for d in /sys/class/net/*; do
            [[ -e "$d" ]] || continue
            dev="$(basename "$d")"

            # 看 flags 的 IFF_UP 位，不看 operstate ——
            # 回环口 lo 的 operstate 恒为 "unknown"，用它判断会误显示成未知状态
            local flags state_colored
            flags="$(cat "$d/flags" 2>/dev/null || echo 0)"
            if (( flags & 1 )); then
                state_colored="${C_GREEN}up${C_RESET}"
            else
                state_colored="${C_DIM}down${C_RESET}"
            fi

            addrs="$(ip -o addr show dev "$dev" 2>/dev/null \
                     | awk '{ print $3 " " $4 }' | tr '\n' ' ')"
            addrs="${addrs% }"
            [[ -z "$addrs" ]] && addrs="${C_DIM}(无地址)${C_RESET}"

            printf '  %s%s%s %s  %s\n' \
                "$C_BCYAN" "$(_pad_right "$dev" 14)" "$C_RESET" "$state_colored" "$addrs"
        done
    fi

    ui_section "默认路由"
    if have_cmd ip; then
        local routes
        routes="$(ip route show default 2>/dev/null)"
        if [[ -n "$routes" ]]; then
            printf '%s\n' "$routes" | while IFS= read -r r; do
                printf '  %s\n' "$r"
            done
        else
            printf '  %s无默认路由%s\n' "$C_DIM" "$C_RESET"
        fi
    else
        printf '  %s需要 iproute2%s\n' "$C_DIM" "$C_RESET"
    fi

    ui_section "DNS"
    # 就地取默认值，不依赖其它模块定义的 RESOLV_CONF ——
    # 模块之间不该互相依赖，单独加载本模块时那个变量是空的
    local resolv="${RESOLV_CONF:-/etc/resolv.conf}"
    local ns
    ns="$(grep -E '^\s*nameserver\s+' "$resolv" 2>/dev/null | awk '{print $2}')"
    if [[ -n "$ns" ]]; then
        printf '%s\n' "$ns" | while IFS= read -r s; do printf '  %s\n' "$s"; done
        if [[ -L "$resolv" ]]; then
            printf '  %s%s → %s%s\n' "$C_DIM" "$resolv" "$(readlink -f "$resolv" 2>/dev/null)" "$C_RESET"
        fi
    else
        printf '  %s未配置%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n  %s公网 IP 请直接看网卡地址；本功能不会发起任何外部请求。%s\n' "$C_DIM" "$C_RESET"
    module_end
}

# ---- 模块入口 ----
menu_system() {
    local items=(
        "系统概览|主机名 / 发行版 / 内核 / 运行时长"
        "CPU 内存|型号 / 核心数 / 占用 / Swap"
        "磁盘空间|分区容量与 inode 使用率"
        "网络接口|网卡 / IP / 网关 / DNS"
    )
    local fns=(sys_overview sys_resource sys_disk sys_network_iface)
    run_submenu "系统信息" items fns
}

register_module "system" "系统信息" "menu_system" "查看系统状态"
