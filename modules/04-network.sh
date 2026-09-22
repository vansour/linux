#!/usr/bin/env bash
# ============================================================
# 模块: 网络设置
# id: network
# ============================================================

# ------------------------------------------------------------
# DNS 服务商（主 + 备用）
# 三家国内两家国外，每个都配了同厂备用地址 —— 只写一个
# nameserver 等于单点故障，主挂了就整体不可用。
# ------------------------------------------------------------
DNS_NAMES=(
    "Cloudflare"
    "Google"
    "DNSPod 腾讯"
    "AliDNS 阿里"
)
DNS_IPS=(
    "1.1.1.1 1.0.0.1"
    "8.8.8.8 8.8.4.4"
    "119.29.29.29 119.28.28.28"
    "223.5.5.5 223.6.6.6"
)
DNS_NOTES=(
    "境外 · 隐私优先"
    "境外 · 老牌稳定"
    "境内 · 腾讯"
    "境内 · 阿里"
)

RESOLV_CONF="${RESOLV_CONF:-/etc/resolv.conf}"
# 普通 DNS 与 DoT 共用同一个 drop-in：两者都在配置 systemd-resolved，
# 拆成两个文件的话，切回普通 DNS 时旧的 DoT 文件还在，DNSOverTLS=yes
# 会继续生效 —— 以为关了其实没关。
RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/99-linux-toolkit.conf"
DNS_PROBE_NAME="${DNS_PROBE_NAME:-example.com}"

# ============================================================
# 探测
# ============================================================

# 直接问指定 DNS 服务器能否解析
#   0 = 可用   1 = 不可用   2 = 系统上没有查询工具，无法判断
#
# 这里对 nslookup 同时看退出码和输出文本：nslookup 有 bind / busybox 等多个
# 实现，退出码语义不完全一致，而失败信息（timed out / SERVFAIL 等）一定会
# 出现在输出里。以输出为准更稳，不依赖某个实现的具体返回码。
_dns_probe_server() {
    local server="$1" out rc

    if have_cmd dig; then
        # dig +short 成功时直接打印解析结果，失败时为空
        out="$(dig +short +time=3 +tries=1 "@$server" "$DNS_PROBE_NAME" A 2>&1)" && rc=0 || rc=$?
        (( rc == 0 )) && [[ -n "$out" ]] && return 0
        return 1
    fi

    if have_cmd host; then
        out="$(host -W 3 "$DNS_PROBE_NAME" "$server" 2>&1)" && rc=0 || rc=$?
        (( rc == 0 )) && printf '%s' "$out" | grep -q 'has address' && return 0
        return 1
    fi

    if have_cmd nslookup; then
        out="$(nslookup "$DNS_PROBE_NAME" "$server" 2>&1)"
    elif have_cmd busybox; then
        out="$(busybox nslookup "$DNS_PROBE_NAME" "$server" 2>&1)"
    else
        return 2
    fi

    if printf '%s' "$out" | grep -qiE 'timed out|no servers could be reached|SERVFAIL|REFUSED|NXDOMAIN|can.t find'; then
        return 1
    fi
    printf '%s' "$out" | grep -q 'Non-authoritative answer' && return 0
    return 1
}

# 系统解析器（走 /etc/resolv.conf 那条链路）能否解析
_dns_probe_system() {
    getent hosts "$DNS_PROBE_NAME" >/dev/null 2>&1
}

# ------------------------------------------------------------
# 判断谁在管 DNS 解析
#
# 关键不是「装了哪个软件」，而是「/etc/resolv.conf 实际指向什么」——
# 那才是解析器真正读的东西。
#   resolved   → 指向 systemd-resolved 的 stub，得配 resolved
#   resolvconf → 指向 resolvconf 的运行时文件，直接写会被覆盖
#   direct     → 普通文件，自己就是权威，直接写
# ------------------------------------------------------------
_dns_mechanism() {
    if [[ -L "$RESOLV_CONF" ]]; then
        local target
        target="$(readlink -f "$RESOLV_CONF" 2>/dev/null || true)"
        case "$target" in
            */systemd/resolve/*) printf 'resolved'; return ;;
            */resolvconf/*)      printf 'resolvconf'; return ;;
        esac
    fi
    printf 'direct'
}

_dns_mechanism_label() {
    case "$1" in
        resolved)   printf 'systemd-resolved（写 drop-in 配置）' ;;
        resolvconf) printf 'resolvconf（通过 resolvconf 命令）' ;;
        *)          printf '直接写 %s' "$RESOLV_CONF" ;;
    esac
}

# 当前生效的 nameserver，用于预览和回滚
_dns_current() {
    grep -E '^\s*nameserver\s+' "$RESOLV_CONF" 2>/dev/null | awk '{print $2}' | tr '\n' ' '
}

# ============================================================
# 应用 / 回滚
# ============================================================

# 把配置写进去。$1 = 机制，$2 = "ip ip"
_dns_apply() {
    local mech="$1" ips="$2" ip

    case "$mech" in
        resolved)
            mkdir -p "$(dirname "$RESOLVED_DROPIN")"
            {
                printf '# 由 Linux 一键配置脚本生成\n'
                printf '[Resolve]\n'
                printf 'DNS=%s\n' "$ips"
            } >"$RESOLVED_DROPIN" || return 1

            if have_cmd systemctl; then
                systemctl restart systemd-resolved 2>/dev/null || {
                    log_err "重启 systemd-resolved 失败"
                    return 1
                }
                # 给它一点时间把 stub 配置铺开
                local i
                for (( i=0; i<10; i++ )); do
                    _dns_probe_system && break
                    sleep 0.3
                done
            fi
            ;;

        resolvconf)
            # 走 resolvconf 注册，直接写 /etc/resolv.conf 会被它覆盖
            local records=''
            for ip in $ips; do
                records+="nameserver $ip"$'\n'
            done
            if have_cmd resolvconf; then
                printf '%s' "$records" | resolvconf -a "linux-toolkit" 2>/dev/null || return 1
            else
                log_err "resolv.conf 由 resolvconf 管理，但找不到 resolvconf 命令"
                return 1
            fi
            ;;

        *)
            # 先解析符号链接，避免把链接本身覆盖掉
            local real="$RESOLV_CONF"
            [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
            {
                printf '# 由 Linux 一键配置脚本生成\n'
                for ip in $ips; do
                    printf 'nameserver %s\n' "$ip"
                done
            } >"$real" || return 1
            ;;
    esac
    return 0
}

# 回滚。调用前先用 _dns_snapshot 存过现场
_dns_rollback() {
    local mech="$1"

    case "$mech" in
        resolved)
            if [[ -n "${DNS_SNAP_DROPIN_EXISTED:-}" ]]; then
                printf '%s' "${DNS_SNAP_DROPIN_CONTENT:-}" >"$RESOLVED_DROPIN"
            else
                rm -f "$RESOLVED_DROPIN"
            fi
            if have_cmd systemctl; then
                systemctl restart systemd-resolved 2>/dev/null || true
            fi
            ;;

        resolvconf)
            if have_cmd resolvconf; then
                resolvconf -d "linux-toolkit" 2>/dev/null || true
            fi
            ;;

        *)
            local real="$RESOLV_CONF"
            [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
            printf '%s' "${DNS_SNAP_RESOLV:-}" >"$real" 2>/dev/null
            ;;
    esac
}

# $(cat) 会吃掉结尾换行，用哨兵字符保住原样，还原前再摘掉
# 记录现场（存内存，不落备份文件）
_dns_snapshot() {
    local mech="$1"
    if [[ -e "$RESOLVED_DROPIN" ]]; then
        DNS_SNAP_DROPIN_EXISTED=1
        DNS_SNAP_DROPIN_CONTENT="$(cat "$RESOLVED_DROPIN" 2>/dev/null; printf x)"
        DNS_SNAP_DROPIN_CONTENT="${DNS_SNAP_DROPIN_CONTENT%x}"
    else
        DNS_SNAP_DROPIN_EXISTED=''
        DNS_SNAP_DROPIN_CONTENT=''
    fi
    DNS_SNAP_RESOLV="$(cat "$RESOLV_CONF" 2>/dev/null || true; printf x)"
    DNS_SNAP_RESOLV="${DNS_SNAP_RESOLV%x}"
}

# ============================================================
# 主流程
# ============================================================
net_dns() {
    require_root

    local mech
    mech="$(_dns_mechanism)"

    local items=() i
    for (( i=0; i<${#DNS_NAMES[@]}; i++ )); do
        items+=("${DNS_NAMES[i]}|${DNS_NOTES[i]}")
    done

    module_begin "DNS 设置"
    ui_kv "管理方式" "$(_dns_mechanism_label "$mech")"
    ui_kv "当前 DNS" "$(_dns_current)"
    ui_menu "选择 DNS" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0
    local idx=$UI_CHOICE

    local ips="${DNS_IPS[idx]}"

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将使用的 DNS"
    local ip
    for ip in $ips; do
        printf '  %s%s%s\n' "$C_BCYAN" "$ip" "$C_RESET"
    done
    ui_kv "服务商" "${DNS_NAMES[idx]}"

    ui_section "变更前"
    ui_kv "当前 DNS" "$(_dns_current)"
    ui_kv "写入目标" "$(_dns_mechanism_label "$mech")"

    printf '\n'
    if ! confirm "确认修改?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 改之前先确认这些 DNS 服务器是活的 ----
    module_begin "验证 DNS 服务器"
    local unreachable=() need_probe=0 probe_rc=0
    for ip in $ips; do
        _dns_probe_server "$ip"; probe_rc=$?
        case "$probe_rc" in
            0) log_ok "$ip 响应正常" ;;
            2) need_probe=1; break ;;
            *) log_warn "$ip 无响应"; unreachable+=("$ip") ;;
        esac
    done

    if (( need_probe )); then
        log_info "系统未装 dig/nslookup/host，跳过直连探测，改由应用后验证。"
    elif (( ${#unreachable[@]} > 0 )); then
        log_warn "以下 DNS 无响应: ${unreachable[*]}"
        if ! confirm "仍要继续吗?" n; then
            log_info "已取消，未做任何修改。"
            module_end
            return 0
        fi
    fi

    # ---- 应用 ----
    module_begin "应用配置"
    _dns_snapshot "$mech"

    if ! _dns_apply "$mech" "$ips"; then
        log_err "写入配置失败，正在回滚..."
        _dns_rollback "$mech"
        module_end
        return 1
    fi
    log_ok "配置已写入"

    # ---- 验证：解析不通就自动回滚 ----
    ui_section "验证解析"
    local ok=0
    for (( i=0; i<8; i++ )); do
        if _dns_probe_system; then ok=1; break; fi
        sleep 0.5
    done

    if (( ok )); then
        log_ok "解析正常，DNS 已切换到「${DNS_NAMES[idx]}」。"
        if (( ${#unreachable[@]} > 0 )); then
            log_warn "注意: ${unreachable[*]} 之前无响应，建议观察一段时间。"
        fi
    else
        log_err "切换后无法解析域名，正在自动回滚..."
        _dns_rollback "$mech"
        if _dns_probe_system; then
            log_ok "已恢复到变更前的配置，系统解析正常。"
        else
            log_err "回滚后仍无法解析，请手动检查 $RESOLV_CONF"
        fi
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# DoT（DNS over TLS，853 端口）
#
# 注意 DoT 端点未必等于普通 DNS 的地址：DNSPod 的普通 DNS 是
# 119.29.29.29，但 DoT 只在 dot.pub（1.12.12.12 / 120.53.53.53）上提供。
# 所以这里单列一张表，下标与 DNS_NAMES 对应。
# ============================================================
DOT_IPS=(
    "1.1.1.1 1.0.0.1"
    "8.8.8.8 8.8.4.4"
    "1.12.12.12 120.53.53.53"
    "223.5.5.5 223.6.6.6"
)
DOT_SNI=(
    "cloudflare-dns.com"
    "dns.google"
    "dot.pub"
    "dns.alidns.com"
)


# ------------------------------------------------------------
# 检查 DoT 端点的 853 端口
#   0 = 可用   1 = 不可用   2 = 无 openssl，无法检查
#
# 只测 TCP 连通不够 —— 那只能证明端口开着。这里做完整 TLS 握手并
# 用 -verify_hostname 校验证书主机名，否则「加密 DNS」可能是连着
# 一个冒名服务器，加密毫无意义。
# ------------------------------------------------------------
_dot_check() {
    local ip="$1" sni="$2"
    have_cmd openssl || return 2
    timeout 12 openssl s_client \
        -connect "$ip:853" \
        -servername "$sni" \
        -verify_hostname "$sni" \
        -verify_return_error </dev/null 2>&1 \
        | grep -q 'Verify return code: 0 (ok)'
}

# ------------------------------------------------------------
# 后端：只用 systemd-resolved
#
# 比过 stubby：后者要装 7 个包共 3.4MB，还多一个常驻守护进程；
# systemd-resolved 只多装 1 个包（916KB，依赖 systemd/libc/libssl/dbus
# 基本都已存在），配置就是一个 drop-in，诊断靠 resolvectl。
#
# 代价是它必须在 systemd 上跑。非 systemd 系统（Alpine / Devuan / 部分
# 容器）DoT 直接不可用 —— 这里明确告知，不做静默降级。
# ------------------------------------------------------------
_dot_backend() {
    if [[ ! -d /run/systemd/system ]] || ! have_cmd systemctl; then
        printf 'unsupported'
    elif have_cmd resolvectl; then
        printf 'resolved'          # 已装，零安装
    else
        printf 'resolved-install'  # 没装但能装
    fi
}

_dot_backend_label() {
    case "$1" in
        resolved)         printf 'systemd-resolved（已安装，零安装）' ;;
        resolved-install) printf 'systemd-resolved（将自动安装，约 916KB）' ;;
        *)                printf '不可用' ;;
    esac
}

# 当前是否已启用 DoT
_dot_is_enabled() {
    [[ -s "$RESOLVED_DROPIN" ]] \
        && grep -qE '^\s*DNSOverTLS\s*=\s*yes' "$RESOLVED_DROPIN" 2>/dev/null
}

# ------------------------------------------------------------
# 应用
# ------------------------------------------------------------
_dot_apply_resolved() {
    local idx="$1" ip dns_list=''

    # Debian 默认不装 systemd-resolved，需要时补上
    if ! have_cmd resolvectl; then
        log_info "安装 systemd-resolved ..."
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install systemd-resolved; then
            log_err "systemd-resolved 安装失败"
            return 1
        fi
        if ! have_cmd resolvectl; then
            log_err "安装后仍找不到 resolvectl，无法继续"
            return 1
        fi
        DOT_INSTALLED_RESOLVED=1
    fi

    for ip in ${DOT_IPS[idx]}; do
        # IP#主机名 让 resolved 用该主机名校验证书
        dns_list+="${ip}#${DOT_SNI[idx]} "
    done

    mkdir -p "$(dirname "$RESOLVED_DROPIN")" || return 1
    {
        printf '# 由 Linux 一键配置脚本生成\n'
        printf '[Resolve]\n'
        printf 'DNS=%s\n' "${dns_list% }"
        printf 'DNSOverTLS=yes\n'
    } >"$RESOLVED_DROPIN" || return 1

    # 用 enable + restart，不要用 enable --now：
    # 包安装过程很可能已经带着默认配置把服务拉起来了，而 --now 对已经在跑
    # 的服务不会重启，刚写的 drop-in 就加载不进去。
    systemctl enable systemd-resolved >/dev/null 2>&1 || true
    if ! systemctl restart systemd-resolved 2>/dev/null; then
        log_err "重启 systemd-resolved 失败"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# 回滚
# ------------------------------------------------------------
_dot_rollback() {
    # 先撤掉我们的 drop-in
    if [[ -n "${DOT_SNAP_DROPIN_EXISTED:-}" ]]; then
        printf '%s' "${DOT_SNAP_DROPIN_CONTENT:-}" >"$RESOLVED_DROPIN" 2>/dev/null
    else
        rm -f "$RESOLVED_DROPIN"
    fi

    if [[ -n "${DOT_INSTALLED_RESOLVED:-}" ]]; then
        # systemd-resolved 是本次装上的：停掉，并把 /etc/resolv.conf 还原成
        # 普通文件。装包时它的 postinst 会把 resolv.conf 换成指向 stub 的
        # 符号链接，不还原的话系统解析路径就永久改变了。
        if have_cmd systemctl; then
            systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
        fi
        rm -f "$RESOLV_CONF"
        printf '%s' "${DOT_SNAP_RESOLV:-}" >"$RESOLV_CONF" 2>/dev/null
    else
        # 本来就有的，重启一下让它回到旧配置即可
        if have_cmd systemctl; then
            systemctl restart systemd-resolved >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

_dot_snapshot() {
    DOT_INSTALLED_RESOLVED=''

    if [[ -e "$RESOLVED_DROPIN" ]]; then
        DOT_SNAP_DROPIN_EXISTED=1
        DOT_SNAP_DROPIN_CONTENT="$(cat "$RESOLVED_DROPIN" 2>/dev/null; printf x)"
        DOT_SNAP_DROPIN_CONTENT="${DOT_SNAP_DROPIN_CONTENT%x}"
    else
        DOT_SNAP_DROPIN_EXISTED=''
        DOT_SNAP_DROPIN_CONTENT=''
    fi

    DOT_SNAP_RESOLV="$(cat "$RESOLV_CONF" 2>/dev/null || true; printf x)"
    DOT_SNAP_RESOLV="${DOT_SNAP_RESOLV%x}"
}

# ============================================================
# DoT 主流程
# ============================================================
net_dot() {
    require_root

    local backend
    backend="$(_dot_backend)"

    # 非 systemd 系统上不做静默降级：直接讲清楚为什么不可用
    if [[ "$backend" == "unsupported" ]]; then
        module_begin "DoT 加密 DNS"
        log_err "当前系统不支持 DoT：本功能依赖 systemd-resolved。"
        log_info "未检出 systemd（/run/systemd/system 不存在）。"
        log_info "非 systemd 系统（Alpine / Devuan / 部分容器）请用 stubby 等专用 DoT 转发器。"
        module_end
        return 1
    fi

    local items=() i
    for (( i=0; i<${#DNS_NAMES[@]}; i++ )); do
        items+=("启用 ${DNS_NAMES[i]}|${DOT_SNI[i]}")
    done
    items+=("关闭 DoT|恢复为普通明文 DNS")

    module_begin "DoT 加密 DNS"
    ui_kv "实现方式" "$(_dot_backend_label "$backend")"
    if _dot_is_enabled; then
        ui_kv "当前状态" "已启用"
    else
        ui_kv "当前状态" "未启用"
    fi
    ui_menu "DNS over TLS（853 端口）" items "← 返回上级"
    (( UI_CHOICE < 0 )) && return 0
    local choice=$UI_CHOICE

    # ---- 关闭 DoT ----
    if (( choice == ${#DNS_NAMES[@]} )); then
        module_begin "关闭 DoT"
        ui_kv "实现方式" "$(_dot_backend_label "$backend")"
        printf '\n'
        if ! confirm "确认关闭 DoT，恢复明文 DNS?" n; then
            log_info "已取消。"
            module_end
            return 0
        fi

        rm -f "$RESOLVED_DROPIN"
        if have_cmd systemctl; then
            systemctl restart systemd-resolved 2>/dev/null || true
        fi

        # 恢复成普通 DNS（取第一个服务商的明文地址）
        local real="$RESOLV_CONF"
        [[ -L "$RESOLV_CONF" ]] && real="$(readlink -f "$RESOLV_CONF")"
        {
            printf '# 由 Linux 一键配置脚本生成\n'
            local ip
            for ip in ${DNS_IPS[0]}; do printf 'nameserver %s\n' "$ip"; done
        } >"$real"

        log_ok "DoT 已关闭，DNS 恢复为明文 ${DNS_IPS[0]}"
        module_end
        return 0
    fi

    local idx=$choice
    local dot_ips="${DOT_IPS[idx]}" sni="${DOT_SNI[idx]}"

    # ---- 预览 ----
    module_begin "确认启用 DoT"
    ui_section "加密上游"
    ui_kv "服务商" "${DNS_NAMES[idx]}"
    ui_kv "端点" "$dot_ips"
    ui_kv "证书主机名" "$sni"
    ui_kv "实现方式" "$(_dot_backend_label "$backend")"

    ui_section "检查 853 端口"
    local ip reachable=() failed=() rc need_skip=0
    for ip in $dot_ips; do
        _dot_check "$ip" "$sni"; rc=$?
        case "$rc" in
            0) log_ok "$ip:853 握手通过（证书主机名已校验）"; reachable+=("$ip") ;;
            2) need_skip=1; break ;;
            *) log_warn "$ip:853 不可用"; failed+=("$ip") ;;
        esac
    done

    if (( need_skip )); then
        log_warn "系统没有 openssl，无法检查 853 端口。"
        if ! confirm "跳过检查直接启用?" n; then
            log_info "已取消，未做任何修改。"
            module_end
            return 0
        fi
    elif (( ${#reachable[@]} == 0 )); then
        log_err "所有 DoT 端点都不可用，已中止。"
        log_info "可能是网络封锁了 853 端口（部分运营商/防火墙会拦）。"
        module_end
        return 1
    elif (( ${#failed[@]} > 0 )); then
        log_warn "部分端点不可用: ${failed[*]}（将只使用可用的部分）"
    fi

    printf '\n'
    if ! confirm "确认启用 DoT?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 应用 ----
    module_begin "启用 DoT"
    _dot_snapshot

    if ! _dot_apply_resolved "$idx"; then
        log_err "启用失败，正在回滚..."
        _dot_rollback
        module_end
        return 1
    fi
    log_ok "配置已写入"

    # ---- 验证 ----
    ui_section "验证解析"
    local ok=0
    for (( i=0; i<10; i++ )); do
        if _dns_probe_system; then ok=1; break; fi
        sleep 0.5
    done

    if (( ok )); then
        log_ok "DoT 已启用，「${DNS_NAMES[idx]}」的查询全程加密。"
        log_info "验证加密生效: resolvectl status | grep DNSOverTLS"
        log_info "查看详情: resolvectl status"
    else
        log_err "启用后无法解析域名，正在自动回滚..."
        _dot_rollback
        if _dns_probe_system; then
            log_ok "已恢复到启用前的配置，系统解析正常。"
        else
            log_err "回滚后仍无法解析，请手动检查 $RESOLV_CONF"
        fi
        module_end
        return 1
    fi

    module_end
}

# ============================================================
# BBR 加速
#
# 开 BBR + fq 拥塞控制，按用户给的「带宽 + 延迟」算 BDP 调缓冲区，
# 并做高并发相关优化。
# ============================================================
BBR_CONF="${BBR_CONF:-/etc/sysctl.d/99-linux-toolkit-bbr.conf}"
SYSCTL_CONF="${SYSCTL_CONF:-/etc/sysctl.conf}"
SYSCTL_D="${SYSCTL_D:-/etc/sysctl.d}"

# ------------------------------------------------------------
# 受管参数集合
#
# 分两档，用于判断「一个配置文件是不是网络调优文件」：
#   STRONG —— 只有性能调优才会写的参数，安全加固文件绝不会碰
#   WEAK   —— 调优和加固都可能写（tcp_syncookies 就同时出现在
#             Debian 的 10-network-security.conf 里）
#
# 判定规则：文件里所有生效的指令都在集合内，且至少有一条 STRONG，
# 才认定是调优文件。这样 10-network-security.conf（含 rp_filter 等
# 域外参数）会被完整保留，不会因为一个 tcp_syncookies 就被误删。
# ------------------------------------------------------------
BBR_STRONG_PARAMS=(
    net.ipv4.tcp_congestion_control net.core.default_qdisc
    net.core.rmem_max net.core.wmem_max
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem
    net.core.somaxconn net.core.netdev_max_backlog
    net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range
    net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle
    net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_tw_reuse
    net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing
)
BBR_WEAK_PARAMS=(
    net.ipv4.tcp_syncookies net.ipv4.tcp_fin_timeout
)

_bbr_in_list() {
    local needle="$1"; shift
    local p
    for p in "$@"; do [[ "$p" == "$needle" ]] && return 0; done
    return 1
}

# 该文件是否是可删除的网络调优配置
_bbr_is_tuning_file() {
    local f="$1" line key strong=0 count=0

    [[ -r "$f" ]] || return 1

    while IFS= read -r line; do
        line="${line%%#*}"                       # 去掉行尾注释
        line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        [[ "$key" == "$line" ]] && continue      # 没有等号，不是赋值

        if _bbr_in_list "$key" "${BBR_STRONG_PARAMS[@]}"; then
            strong=1
        elif ! _bbr_in_list "$key" "${BBR_WEAK_PARAMS[@]}"; then
            return 1                             # 出现域外参数 → 整个文件不碰
        fi
        count=$(( count + 1 ))
    done <"$f"

    (( count > 0 && strong == 1 ))
}

# 列出可删除的调优文件。包自带的文件一律跳过
_bbr_list_conflicts() {
    local f base
    shopt -s nullglob
    for f in "$SYSCTL_D"/*.conf; do
        _bbr_is_tuning_file "$f" || continue
        if dpkg -S "$f" >/dev/null 2>&1; then
            log_debug "跳过包自带文件: $f"
            continue
        fi
        printf '%s\n' "$f"
    done
    shopt -u nullglob
}

# /etc/sysctl.conf 里设置了受管参数的行的行号。
# 这个文件不能整个删（可能还存着别的设置），只能把这几行注释掉。
# 它的优先级高于 sysctl.d/，不处理会直接盖掉我们的配置。
_bbr_list_sysctl_conf_lines() {
    local line key n=0
    [[ -r "$SYSCTL_CONF" ]] || return 0
    while IFS= read -r line; do
        n=$(( n + 1 ))
        local stripped="${line%%#*}"
        stripped="$(printf '%s' "$stripped" | tr -d '[:space:]')"
        [[ -z "$stripped" ]] && continue
        key="${stripped%%=*}"
        [[ "$key" == "$stripped" ]] && continue
        if _bbr_in_list "$key" "${BBR_STRONG_PARAMS[@]}" \
           || _bbr_in_list "$key" "${BBR_WEAK_PARAMS[@]}"; then
            printf '%s\n' "$n"
        fi
    done <"$SYSCTL_CONF"
}

# ------------------------------------------------------------
# 内核支持
# ------------------------------------------------------------
_bbr_supported() {
    # 内容形如 "reno cubic bbr"，按空白拆成数组逐个比对
    local avail=()
    read -ra avail < /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null
    _bbr_in_list bbr ${avail[@]+"${avail[@]}"}
}

_bbr_ensure_module() {
    _bbr_supported && return 0

    have_cmd modprobe || return 1
    modprobe tcp_bbr 2>/dev/null || true
    _bbr_supported && {
        # 内核模块形式的需要开机自动加载
        if [[ -d /etc/modules-load.d ]]; then
            printf 'tcp_bbr\n' >/etc/modules-load.d/bbr.conf 2>/dev/null || true
            BBR_WROTE_MODULES_LOAD=1
        fi
        return 0
    }
    return 1
}

# ------------------------------------------------------------
# 按带宽和延迟算参数
#
# BDP（带宽延迟积，字节）= 带宽(Mbps) × 延迟(ms) × 125
#   推导: Mbps → 字节/秒 是 ×1e6/8 = ×125000；ms → 秒 是 ÷1000；
#         合起来 ×125。这个值就是「填满管道需要多少数据在途」。
# 套接字缓冲区必须 ≥ BDP，否则接收窗口会成为吞吐瓶颈。
# ------------------------------------------------------------
_bbr_calc() {
    local bw="$1" rtt="$2"

    local bdp=$(( bw * rtt * 125 ))
    (( bdp < 212992 ))    && bdp=212992        # 地板：不低于内核默认 rmem_max
    (( bdp > 536870912 )) && bdp=536870912     # 天花板：512MB，避免离谱值

    BBR_BUF="$bdp"

    # tcp_rmem/tcp_wmem 中间那列是初始值，取缓冲的 1/4
    local def=$(( bdp / 4 ))
    (( def < 87380 ))   && def=87380
    (( def > 4194304 )) && def=4194304
    BBR_DEF="$def"

    # 网卡收包队列随带宽线性放宽（纯上限，不预分配内存）
    local nback=$(( bw * 64 ))
    (( nback < 1000 ))   && nback=1000
    (( nback > 300000 )) && nback=300000
    BBR_NETDEV_BACKLOG="$nback"

    # fs.file-max 只升不降 —— 有些系统的现值是内核上限哨兵
    # （9223372036854775807），写小等于把限制调窄了
    local cur
    cur="$(sysctl -n fs.file-max 2>/dev/null || echo 0)"
    local fmax=1048576
    (( cur > fmax )) && fmax=$cur
    BBR_FILEMAX="$fmax"

    BBR_BDP_RAW=$(( bw * rtt * 125 ))
}

_bbr_render() {
    local bw="$1" rtt="$2"
    cat <<EOF
# 由 Linux 一键配置脚本生成，请勿手工编辑
# 依据: 带宽 ${bw} Mbps，延迟 ${rtt} ms
# BDP = ${bw} × ${rtt} × 125 = ${BBR_BDP_RAW} 字节（未截断值）

# ---- 拥塞控制 ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ---- 缓冲区（按 BDP 计算，${BBR_BUF} 字节）----
net.core.rmem_max = ${BBR_BUF}
net.core.wmem_max = ${BBR_BUF}
net.ipv4.tcp_rmem = 4096 ${BBR_DEF} ${BBR_BUF}
net.ipv4.tcp_wmem = 4096 ${BBR_DEF} ${BBR_BUF}
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_mtu_probing = 1

# ---- 高并发 ----
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = ${BBR_NETDEV_BACKLOG}
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_fastopen = 3
fs.file-max = ${BBR_FILEMAX}
EOF
}

# ------------------------------------------------------------
# 应用 / 验证 / 回滚
# ------------------------------------------------------------
# 现场备份到临时目录。
# 不用「变量存内容」的写法：$(cat file) 会吃掉结尾换行，写回时无法还原成
# 原样（md5 对不上）。cp -a 才是字节级保真。
_bbr_snapshot() {
    BBR_SNAP_DIR="$(mktemp -d)"
    local f

    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        cp -a "$f" "$BBR_SNAP_DIR/$(basename "$f")" 2>/dev/null || true
    done < <(_bbr_list_conflicts)

    # 这两个用固定名，不放同一层，避免与上面的 basename 撞名
    [[ -e "$SYSCTL_CONF" ]] && cp -a "$SYSCTL_CONF" "$BBR_SNAP_DIR/_sysctl_conf" 2>/dev/null
    [[ -e "$BBR_CONF" ]]    && cp -a "$BBR_CONF"    "$BBR_SNAP_DIR/_ours" 2>/dev/null
    return 0
}

_bbr_rollback() {
    local f

    [[ -n "${BBR_SNAP_DIR:-}" && -d "$BBR_SNAP_DIR" ]] || return 0

    # 还原被删掉的调优文件
    shopt -s nullglob
    for f in "$BBR_SNAP_DIR"/*.conf; do
        cp -a "$f" "$SYSCTL_D/$(basename "$f")" 2>/dev/null || true
    done
    shopt -u nullglob

    # 还原 /etc/sysctl.conf
    [[ -e "$BBR_SNAP_DIR/_sysctl_conf" ]] \
        && cp -a "$BBR_SNAP_DIR/_sysctl_conf" "$SYSCTL_CONF" 2>/dev/null

    # 还原我们自己的文件（本来没有就删掉）
    if [[ -e "$BBR_SNAP_DIR/_ours" ]]; then
        cp -a "$BBR_SNAP_DIR/_ours" "$BBR_CONF" 2>/dev/null
    else
        rm -f "$BBR_CONF"
    fi

    if [[ -n "${BBR_WROTE_MODULES_LOAD:-}" ]]; then
        rm -f /etc/modules-load.d/bbr.conf
    fi

    rm -rf "$BBR_SNAP_DIR"
    BBR_SNAP_DIR=''

    sysctl --system >/dev/null 2>&1 || true
    return 0
}

_bbr_verify() {
    local expect_buf="$1" expect_cc="$2" expect_qdisc="$3"
    local cc qd rm wm

    cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    qd="$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    rm="$(sysctl -n net.core.rmem_max 2>/dev/null)"
    wm="$(sysctl -n net.core.wmem_max 2>/dev/null)"

    [[ "$cc" == "$expect_cc" ]] || { printf '拥塞控制算法未生效: 期望 %s，实际 %s\n' "$expect_cc" "$cc"; return 1; }
    [[ "$qd" == "$expect_qdisc" ]] || { printf '队列规则未生效: 期望 %s，实际 %s\n' "$expect_qdisc" "$qd"; return 1; }
    [[ "$rm" == "$expect_buf" ]] || { printf 'rmem_max 未生效: 期望 %s，实际 %s\n' "$expect_buf" "$rm"; return 1; }
    [[ "$wm" == "$expect_buf" ]] || { printf 'wmem_max 未生效: 期望 %s，实际 %s\n' "$expect_buf" "$wm"; return 1; }
    return 0
}

# ============================================================
# BBR 主流程
# ============================================================
net_bbr() {
    require_root

    module_begin "BBR 加速"
    if ! _bbr_supported; then
        log_warn "当前内核未提供 bbr，尝试加载内核模块 ..."
        if ! _bbr_ensure_module; then
            log_err "内核不支持 BBR（需要 4.9 以上且已编译 tcp_bbr）。"
            log_info "当前可用算法: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
            module_end
            return 1
        fi
        log_ok "已加载 tcp_bbr 模块"
    fi
    ui_kv "内核" "$KERNEL"
    ui_kv "可用算法" "$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)"
    ui_kv "当前算法" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    ui_kv "当前队列规则" "$(sysctl -n net.core.default_qdisc 2>/dev/null)"
    printf '\n'
    pause

    # ---- 采集输入 ----
    module_begin "BBR 加速 · 参数"
    printf '  %s带宽和延迟用来计算 BDP（带宽延迟积），决定缓冲区大小。%s\n' "$C_DIM" "$C_RESET"
    printf '  %s填错会导致缓冲区过大浪费内存或过小跑不满带宽。%s\n\n' "$C_DIM" "$C_RESET"

    local bw rtt
    while true; do
        ask "服务器带宽 (Mbps)" "${BBR_INPUT_BW:-}"
        bw="$REPLY"
        [[ "$bw" =~ ^[0-9]+$ ]] && (( bw >= 1 && bw <= 100000 )) && break
        log_warn "请输入 1-100000 之间的整数（Mbps）"
    done
    while true; do
        ask "网络延迟 (ms)" "${BBR_INPUT_RTT:-}"
        rtt="$REPLY"
        [[ "$rtt" =~ ^[0-9]+$ ]] && (( rtt >= 1 && rtt <= 5000 )) && break
        log_warn "请输入 1-5000 之间的整数（毫秒）"
    done

    _bbr_calc "$bw" "$rtt"

    # ---- 列出会被删除的配置 ----
    local victims=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && victims+=("$f")
    done < <(_bbr_list_conflicts)

    local conf_lines=()
    while IFS= read -r n; do
        [[ -n "$n" ]] && conf_lines+=("$n")
    done < <(_bbr_list_sysctl_conf_lines)

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "计算依据"
    ui_kv "带宽" "${bw} Mbps"
    ui_kv "延迟" "${rtt} ms"
    ui_kv "BDP" "${BBR_BDP_RAW} 字节"
    ui_kv "缓冲区" "${BBR_BUF} 字节 ($(awk -v b="$BBR_BUF" 'BEGIN{printf "%.1f MB", b/1048576}'))"

    ui_section "将要删除"
    if (( ${#victims[@]} == 0 )); then
        printf '  %s(无)%s\n' "$C_DIM" "$C_RESET"
    else
        for f in "${victims[@]}"; do
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$f"
        done
    fi

    if (( ${#conf_lines[@]} > 0 )); then
        printf '\n'
        ui_section "$SYSCTL_CONF 中将被注释的行"
        for n in "${conf_lines[@]}"; do
            printf '  %s#%s %s\n' "$C_YELLOW" "$n" "$(sed -n "${n}p" "$SYSCTL_CONF")"
        done
        printf '  %s这个文件优先级高于 sysctl.d/，不处理会直接盖掉新配置。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '  %s未列出的文件（README.sysctl、IPv6 设置等）一律保留%s\n' "$C_DIM" "$C_RESET"

    ui_section "将要写入 $BBR_CONF"
    _bbr_render "$bw" "$rtt" | sed 's/^/  /'

    printf '\n'
    log_warn "此操作不可撤销，且不会备份原文件。"
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 应用 ----
    module_begin "应用配置"
    _bbr_snapshot

    local f n i
    for f in "${victims[@]}"; do
        if rm -f "$f"; then log_ok "已删除 $f"; else log_err "删除失败: $f"; fi
    done

    if (( ${#conf_lines[@]} > 0 )); then
        local tmp
        tmp="$(mktemp)"
        awk -v lines="${conf_lines[*]}" '
            BEGIN { n = split(lines, a, " "); for (i=1;i<=n;i++) skip[a[i]] = 1 }
            skip[NR] { printf "# [linux-toolkit] 被 BBR 配置覆盖: %s\n", $0; next }
            { print }
        ' "$SYSCTL_CONF" >"$tmp" && install -m 0644 "$tmp" "$SYSCTL_CONF"
        rm -f "$tmp"
        log_ok "已注释 $SYSCTL_CONF 中 ${#conf_lines[@]} 行冲突设置"
    fi

    mkdir -p "$(dirname "$BBR_CONF")"
    if _bbr_render "$bw" "$rtt" >"$BBR_CONF"; then
        log_ok "已写入 $BBR_CONF"
    else
        log_err "写入失败，正在回滚..."
        _bbr_rollback
        module_end
        return 1
    fi

    # ---- 生效并验证 ----
    ui_section "加载并验证"
    sysctl --system >/dev/null 2>&1 || true

    if _bbr_verify "$BBR_BUF" bbr fq; then
        log_ok "BBR + fq 已启用，参数已生效。"
        rm -rf "${BBR_SNAP_DIR:-}"      # 已生效，现场快照不再需要
        BBR_SNAP_DIR=''
        ui_section "当前状态"
        ui_kv "拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"
        ui_kv "队列规则" "$(sysctl -n net.core.default_qdisc)"
        ui_kv "rmem_max" "$(sysctl -n net.core.rmem_max)"
        ui_kv "wmem_max" "$(sysctl -n net.core.wmem_max)"
        ui_kv "somaxconn" "$(sysctl -n net.core.somaxconn)"
        ui_kv "netdev_backlog" "$(sysctl -n net.core.netdev_max_backlog)"
        log_info "已建立的连接沿用旧算法，新建连接才走 BBR。"
    else
        log_err "验证未通过，正在回滚..."
        _bbr_rollback
        if _bbr_verify "$(sysctl -n net.core.rmem_max)" "$(sysctl -n net.ipv4.tcp_congestion_control)" "$(sysctl -n net.core.default_qdisc)"; then
            log_ok "已恢复到变更前状态。"
        else
            log_warn "回滚后请手动检查: sysctl -n net.ipv4.tcp_congestion_control"
        fi
        module_end
        return 1
    fi

    module_end
}

# ------------------------------------------------------------
# 其余功能占位
# ------------------------------------------------------------
net_ip_config() {
    not_implemented          # TODO: 静态 IP / DHCP 配置
    module_end
}

net_proxy() {
    not_implemented          # TODO: 系统代理 / 环境变量代理
    module_end
}

net_connectivity() {
    not_implemented          # TODO: 连通性测试 / 测速
    module_end
}

menu_network() {
    local items=(
        "BBR 加速|拥塞控制 + fq，按带宽延迟调优"
        "DNS 设置|Cloudflare / Google / 腾讯 / 阿里"
        "DoT 加密 DNS|DNS over TLS，检查 853 端口"
        "IP 配置|静态 IP / DHCP"
        "代理设置|系统级 / 终端代理"
        "连通测试|延迟 / 测速"
    )
    local fns=(net_bbr net_dns net_dot net_ip_config net_proxy net_connectivity)
    run_submenu "网络设置" items fns
}

register_module "network" "网络设置" "menu_network" "BBR / DNS / DoT / 代理"
