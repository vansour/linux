#!/usr/bin/env bash
# ============================================================
# 模块: 时间与时区
# id: time
#
# 两件事：把系统时区设对（改的是「怎么看时间」），把系统时钟校准
# （改的是「时间本身」）。两者失败模式完全不同，所以流程也分开：
# 时区走「验证 → 预览 → 快照 → 原子替换 → 验证 → 失败回滚」，
# NTP 只动开关不碰时钟，「立即校时」单独确认。
#
# 只动 /etc/localtime 与 /etc/timezone 两个文件；硬件时钟与 /etc/adjtime
# 一律不碰（唯一例外是下面 _time_rtc_is_local 命中时，会先把后果讲清楚）。
#
# 时区名必须先验证通过才允许写入。这不是洁癖：TZ 指向坏文件时 date 不会
# 报错，而是静默按 UTC 走 —— 等于悄悄把系统时间搞错，比报错难查得多。
# ============================================================

TIME_LOCALTIME="${TIME_LOCALTIME:-/etc/localtime}"
TIME_TZFILE="${TIME_TZFILE:-/etc/timezone}"
TIME_ZONEINFO="${TIME_ZONEINFO:-/usr/share/zoneinfo}"
TIME_SYNC_WAIT="${TIME_SYNC_WAIT:-15}"      # 等首次同步的上限（秒）

# ============================================================
# 探测
# ============================================================

# timedatectl 装了不等于能用：非 systemd 的系统上它照样装得上，
# 一跑就报 "System has not been booted with systemd as init system"。
# 所以不能用 have_cmd 判断，要真跑一次 —— 见 _time_td_get。
_time_have_systemd() {
    [[ -d /run/systemd/system ]] && have_cmd timedatectl
}

# 取 timedatectl 属性，取不到返回非 0。
# --value 是 systemd 230 之后才有的，老版本退回解析 "Prop=值"。
_time_td_get() {
    local prop="$1" out
    _time_have_systemd || return 1
    if out="$(timedatectl show -p "$prop" --value 2>/dev/null)"; then
        printf '%s' "$out"
        return 0
    fi
    out="$(timedatectl show -p "$prop" 2>/dev/null)" || return 1
    printf '%s' "${out#*=}"
}

# /etc/localtime 的形态：symlink | copy | missing
_time_localtime_kind() {
    if [[ -L "$TIME_LOCALTIME" ]]; then
        printf 'symlink'
    elif [[ -f "$TIME_LOCALTIME" ]]; then
        printf 'copy'
    else
        printf 'missing'
    fi
}

# /etc/localtime 是不是挂进来的（-v /etc/localtime:/etc/localtime:ro 很常见）。
# 有挂载行就说明容器里改它等于改宿主机，且重建即失效。
# 没命中要返回非 0 —— awk 无匹配时是「空输出 + 退出码 0」，
# 光看退出码会把「不是挂载点」误判成挂载点。
_time_localtime_mountinfo() {
    local line=''
    [[ -r /proc/self/mountinfo ]] || return 1
    line="$(awk -v p="$TIME_LOCALTIME" '$5 == p { print $0; exit }' /proc/self/mountinfo)"
    [[ -n "$line" ]] || return 1
    printf '%s' "$line"
}

# 当前时区名。取不到返回非 0（输出为空）。
#
# 三条独立来源依次尝试，任何一条能用就返回：
#   timedatectl   —— systemd 下最权威，且它自己已按 verify_timezone 校过
#   /etc/localtime 符号链接
#   /etc/timezone —— Debian 系的老式纯文本记录，可能是陈旧的
#
# 注意 timedatectl 在 /etc/localtime 是「普通文件副本」时输出空串
# （它内部 readlink 拿不到名字，没有扫描 zoneinfo 的兜底），
# 所以不能因为它返回空就断定没有时区。
_time_tz_current() {
    local tz='' target

    if _time_have_systemd; then
        tz="$(_time_td_get Timezone)"
        [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    fi

    if [[ -L "$TIME_LOCALTIME" ]]; then
        # 先 readlink（不解析）拿到原始目标：readlink -f 在副本文件上会
        # 原样吐出 /etc/localtime，拿它当名字来源是错的
        target="$(readlink "$TIME_LOCALTIME" 2>/dev/null)"
        case "$target" in
            "${TIME_ZONEINFO}/"*) printf '%s' "${target#"${TIME_ZONEINFO}/"}"; return 0 ;;
            "../usr/share/zoneinfo/"*) printf '%s' "${target#../usr/share/zoneinfo/}"; return 0 ;;
        esac
    fi

    if [[ -r "$TIME_TZFILE" ]]; then
        tz="$(head -n1 "$TIME_TZFILE" 2>/dev/null | tr -d '[:space:]')"
        [[ -n "$tz" ]] && { printf '%s' "$tz"; return 0; }
    fi

    return 1
}

# 名字是从哪来的 —— 状态页要分开显示各来源，不能揉成一行。
# 各来源不一致时，合并显示正是误诊的根源。
_time_tz_source_label() {
    if _time_have_systemd && [[ -n "$(_time_td_get Timezone)" ]]; then
        printf 'timedatectl（systemd 管理）'
        return 0
    fi
    case "$(_time_localtime_kind)" in
        symlink) printf '%s 符号链接' "$TIME_LOCALTIME" ;;
        copy)    printf '%s 普通文件（时区副本，读不出名字）' "$TIME_LOCALTIME" ;;
        *)       printf '未知' ;;
    esac
}

# ============================================================
# 校验
#
# 四道门，任一不过即拒。前三道对应用户输入的错误类型，
# 第四道挡住「存在但内容不是时区」的文件。
# ============================================================

# 头四字节是不是 TZif（tzfile 的魔数）。
# zoneinfo 顶层躺着 leapseconds 这类纯文本文件，光看存在性会放它过去。
#
# 用 read -n 4 而不是 head -c 4：后者每个文件 fork 一次，浏览全部时区时
# 要校验四百多个文件，实测 1.3 秒，进菜单前会明显卡一下；read 是内建，
# 同样这批文件 0.016 秒。两者对真实/伪造 tzfile 的判定完全一致。
_time_tz_is_tzfile() {
    local magic=''
    IFS= read -r -n 4 magic <"$1" 2>/dev/null
    [[ "$magic" == "TZif" ]]
}

_time_tz_valid() {
    local tz="$1" f

    [[ -n "$tz" ]] || return 1

    # 门 1：字符集与分段。与 systemd verify_timezone() 的字符集一致
    # （多一个 -），保证我们放行的名字 timedatectl 也一定认。
    # 禁掉 '.' 是关键：既堵死 ../../etc/passwd 这类穿越，又顺带排除
    # zoneinfo 下的 zone.tab / tzdata.zi 等元数据 —— 实测真实时区名
    # 没有一个是带点的。
    [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1

    # 门 2：已知的陷阱名，逐个挡住（这些都能通过门 1 和门 3）：
    #   localtime    /usr/share/zoneinfo/localtime 是指回 /etc/localtime 的
    #                链接，装上去就成了符号链接自我循环
    #   posixrules   软链到 America/New_York，用户会莫名其妙拿到纽约时间
    #   Factory      合法 TZif 但不属于任何地区，缩写只会是 -00
    #   right/*      带闰秒，比 UTC 快约 27 秒 —— Debian 上没有，
    #                RHEL/Arch 的 zoneinfo 里有，属于发布后才暴露的坑
    #   posix/*      同一时区的副本，没有理由选它
    case "$tz" in
        localtime|posixrules|Factory) return 1 ;;
        right/*|posix/*)              return 1 ;;
    esac

    # 门 3：必须真实存在且是普通文件（跟随符号链接）。挡掉 'Asia'
    # 这种只写了目录名的输入，也挡掉失效链接。
    f="$TIME_ZONEINFO/$tz"
    [[ -f "$f" ]] || return 1

    # 门 4：内容得真是时区数据
    _time_tz_is_tzfile "$f"
}

# 无效时给一句有指向性的说明，省得用户对着「无效」两个字猜
_time_tz_hint() {
    local tz="$1" head
    local f="$TIME_ZONEINFO/$tz"
    if [[ "$tz" == *..* ]]; then
        log_info "时区名里不允许出现 .."
        return 0
    fi
    head="${tz%%/*}"
    if [[ -d "$TIME_ZONEINFO/$tz" ]]; then
        log_info "$tz 是个目录，请写到具体城市，例如 $(_time_tz_suggest "$tz")"
    elif [[ -f "$f" ]]; then
        log_info "$f 不是时区数据文件，换个名字试试"
    elif [[ -d "$TIME_ZONEINFO/$head" ]]; then
        log_info "提示: ls $TIME_ZONEINFO/$head 可以看到该地区下有哪些城市"
    elif [[ ! -d "$TIME_ZONEINFO" ]]; then
        log_info "$TIME_ZONEINFO 不存在，需要先安装 tzdata"
    fi
    return 0
}

# 目录名 → 该目录下第一个真实时区，只用作提示
_time_tz_suggest() {
    local dir="$TIME_ZONEINFO/$1" f
    if [[ -d "$dir" ]]; then
        for f in "$dir"/*; do
            [[ -f "$f" ]] || continue
            _time_tz_is_tzfile "$f" || continue
            printf '%s/%s' "$1" "$(basename "$f")"
            return 0
        done
    fi
    printf '%s/城市名' "$1"
}

# 偏移与缩写。必须现算 —— Etc/GMT+8 是 POSIX 反向记法（实际 -0800），
# 夏令时也会让写死的值出错。
_time_tz_offset() { TZ="$1" date '+%z' 2>/dev/null; }

_time_tz_label() {
    local tz="$1" abbr off
    abbr="$(TZ="$tz" date '+%Z' 2>/dev/null)"
    off="$(_time_tz_offset "$tz")"
    if [[ -n "$off" ]]; then
        printf '%s (%s, %s)' "$tz" "${abbr:-?}" "$off"
    else
        printf '%s' "$tz"
    fi
}

# 硬件时钟是否按本地时间走（/etc/adjtime 第三行是 LOCAL）。
# 命中时改时区会连带改变 RTC 数值的含义，重启后系统时钟会跳 ——
# 这是本功能里唯一会真正动到时钟的操作，必须单独提示。
_time_rtc_is_local() {
    local f=/etc/adjtime
    if [[ -r "$f" ]]; then
        [[ "$(sed -n '3p' "$f" 2>/dev/null)" == "LOCAL" ]] && return 0
    fi
    if _time_have_systemd; then
        [[ "$(_time_td_get LocalRTC)" == "yes" ]] && return 0
    fi
    return 1
}

# ============================================================
# 写入 / 回滚
# ============================================================

# 原子替换符号链接：先在旁边建好，再一次 rename 到位。
# 不用 ln -sfn —— 那是先删后建，中间那一瞬间 /etc/localtime 不存在，
# 此刻读时间的进程会看到 UTC。
_time_tz_link() {
    local target="$1" link="$2" tmp

    # 目标是目录时 mv 会「移进去」而不是替换。GNU 的 -T 能避免，
    # busybox（Alpine）没有 -T，所以在这里先挡一道。
    [[ -d "$link" ]] && return 1

    tmp="${link}.tmp.$$"
    rm -f "$tmp"
    ln -s "$target" "$tmp" 2>/dev/null || return 1

    if mv -T "$tmp" "$link" 2>/dev/null; then
        return 0
    fi
    # 老 coreutils / busybox 的 mv 没有 -T，退回两步式（窗口极短）
    rm -f "$tmp"
    rm -f "$link" && ln -s "$target" "$link"
}

# /etc/timezone 是 Debian 系的约定文件，dpkg-reconfigure tzdata 会读它
# 并把 /etc/localtime 按它重写 —— 只改链接不改它，下次 apt 升级 tzdata
# 时区可能被悄悄改回去。其它发行版没人读这个文件，就不凭空造一个。
_time_tz_write_tzfile() {
    local tz="$1" tmp
    case "$DISTRO_FAMILY" in
        debian) ;;
        *) [[ -e "$TIME_TZFILE" ]] || return 0 ;;
    esac
    tmp="${TIME_TZFILE}.tmp.$$"
    printf '%s\n' "$tz" >"$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$TIME_TZFILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

_time_tz_apply() {
    local tz="$1"

    # 有 systemd 就交给 timedatectl 管 /etc/localtime：绕过它手工改
    # 会让它的状态和磁盘对不上。
    if _time_have_systemd; then
        if timedatectl set-timezone "$tz" 2>/dev/null; then
            # 但 timedatectl 不碰 /etc/timezone —— 实测 systemd 257 上
            # 文件已存在也不更新，会留下陈旧内容。而 Debian 的 tzdata
            # postinst 与 dpkg-reconfigure tzdata 恰恰读它，于是下一次
            # apt 升级 tzdata 就可能把用户刚设好的时区改回去。所以补齐。
            _time_tz_write_tzfile "$tz" \
                || log_warn "更新 $TIME_TZFILE 失败；时区本身已生效，但升级 tzdata 时可能被改回去"
            return 0
        fi
        log_warn "timedatectl set-timezone 失败，改用直接写文件的方式"
    fi

    _time_tz_link "$TIME_ZONEINFO/$tz" "$TIME_LOCALTIME" || {
        log_err "写入 $TIME_LOCALTIME 失败"
        return 1
    }
    _time_tz_write_tzfile "$tz" || {
        log_err "写入 $TIME_TZFILE 失败"
        return 1
    }
    return 0
}

# 记录现场。
#
# /etc/localtime 是二进制 tzfile，含 NUL 字节，$(cat) 那种存内存的写法
# （07-swap 的 fstab、04-network 的 resolv.conf 用的）会把它毁掉，还原时
# 就得到一个损坏的文件。所以按字节复制到临时目录 —— 和 _net_snapshot 一样。
# cp -a 还有个好处：符号链接按链接复制，相对目标的相对性天然保持。
_time_tz_snapshot() {
    TIME_SNAP_DIR=''
    TIME_SNAP_KIND=''
    TIME_SNAP_TZ_EXISTED=''

    TIME_SNAP_DIR="$(mktemp -d 2>/dev/null)" || return 1

    TIME_SNAP_KIND="$(_time_localtime_kind)"
    if [[ "$TIME_SNAP_KIND" != "missing" ]]; then
        cp -a "$TIME_LOCALTIME" "$TIME_SNAP_DIR/localtime" 2>/dev/null || return 1
    fi

    if [[ -e "$TIME_TZFILE" ]]; then
        TIME_SNAP_TZ_EXISTED=1
        cp -a "$TIME_TZFILE" "$TIME_SNAP_DIR/timezone" 2>/dev/null || return 1
    fi
    return 0
}

_time_tz_snapshot_cleanup() {
    [[ -n "${TIME_SNAP_DIR:-}" && -d "${TIME_SNAP_DIR:-}" ]] && rm -rf "$TIME_SNAP_DIR"
    TIME_SNAP_DIR=''
    return 0
}

_time_tz_rollback() {
    local old="${TIME_SNAP_OLD_TZ:-}"

    # 原时区名有效且 systemd 在管，就交回 timedatectl 还原 ——
    # 它同时管着 /etc/localtime 和 /etc/timezone，手工改容易留下不一致
    if [[ -n "$old" ]] && _time_have_systemd && _time_tz_valid "$old"; then
        if timedatectl set-timezone "$old" 2>/dev/null; then
            _time_tz_snapshot_cleanup
            return 0
        fi
    fi

    [[ -n "${TIME_SNAP_DIR:-}" && -d "${TIME_SNAP_DIR:-}" ]] || return 0

    if [[ -n "${TIME_SNAP_KIND:-}" && "${TIME_SNAP_KIND}" != "missing" ]]; then
        rm -f "$TIME_LOCALTIME"
        cp -a "$TIME_SNAP_DIR/localtime" "$TIME_LOCALTIME" 2>/dev/null || true
    else
        rm -f "$TIME_LOCALTIME"
    fi

    if [[ -n "${TIME_SNAP_TZ_EXISTED:-}" ]]; then
        cp -a "$TIME_SNAP_DIR/timezone" "$TIME_TZFILE" 2>/dev/null || true
    else
        rm -f "$TIME_TZFILE"      # 原本没有就得删掉，不能留个空文件
    fi

    _time_tz_snapshot_cleanup
    return 0
}

# 写入后验证。不通过则输出原因。
#
# 不能用 TZ="$tz" date 判断好坏 —— 名字无效时它会静默退回 +0000 而不报错。
# 所以只断言两件能直接检验的事：链接身份、内容是真正的 tzfile。
#
# 曾经这里还有第三条「unset TZ 的 date 与 TZ=$tz 的 date 结果应当一致」。
# 去掉了：它读的是全局 /etc/localtime 而不是本模块的 TIME_LOCALTIME，
# 换路径就没法测；而且前两条已经蕴含了它（链接正好指向那个文件，两边
# 读的就是同一个 tzfile），它只能带来夏令时临界点上跨秒的误报。
_time_tz_verify() {
    local tz="$1" want
    want="$TIME_ZONEINFO/$tz"

    [[ -L "$TIME_LOCALTIME" ]] || { printf '不是符号链接'; return 1; }
    [[ "$(readlink -f "$TIME_LOCALTIME" 2>/dev/null)" == "$want" ]] \
        || { printf '链接指向别处'; return 1; }
    _time_tz_is_tzfile "$TIME_LOCALTIME" || { printf '不是 TZif 文件'; return 1; }
    return 0
}

# ============================================================
# NTP 探测
# ============================================================

# 单元文件在不在盘上（判断「装没装」，不看是否在跑）。
# 不能用 have_cmd：systemd-timesyncd 的二进制在 /usr/lib/systemd/ 下，
# 不在 PATH 里。也正因为先查单元文件，Arch 上 timesyncd 随 systemd 包
# 自带的情况自然被识别为「已安装」，不会去装一个不存在的包。
_time_unit_installed() {
    local u="$1" d
    for d in /etc/systemd/system /run/systemd/system \
             /usr/lib/systemd/system /lib/systemd/system; do
        [[ -f "$d/$u.service" ]] && return 0
    done
    return 1
}

_time_ntp_unit() {
    local u
    for u in systemd-timesyncd chronyd ntpd; do
        _time_unit_installed "$u" && { printf '%s' "$u"; return 0; }
    done
    return 1
}

_time_ntp_active() {
    have_cmd systemctl || return 1
    systemctl is-active --quiet "$1.service" 2>/dev/null
}

# 需要装的包名；已经有校时服务了就输出空串
_time_ntp_pkg() {
    _time_ntp_unit >/dev/null && return 0
    case "$DISTRO_FAMILY" in
        debian) printf 'systemd-timesyncd' ;;   # 单包，且直接被 timedatectl 接管
        rhel)   printf 'systemd-timesyncd' ;;   # RHEL9+/Fedora 有，老版本装不上会退 chrony
        *)      printf 'chrony' ;;
    esac
    return 0
}

# 等首次同步，最多 TIME_SYNC_WAIT 秒。
# 用循环计数而不是 date +%s 算截止时间 —— 这个功能的全部意义就是时钟
# 可能被步进，拿一个正在被改的时钟去算超时是不靠谱的。
_time_ntp_wait_sync() {
    local i
    (( TIME_SYNC_WAIT > 0 )) || return 1
    for (( i=0; i<TIME_SYNC_WAIT; i++ )); do
        [[ "$(_time_td_get NTPSynchronized)" == "yes" ]] && { printf '\n'; return 0; }
        printf '.'
        sleep 1
    done
    printf '\n'
    return 1
}

# ============================================================
# NTP 服务器配置
#
# 三套实现的写法完全不同：
#   systemd-timesyncd  写 /etc/systemd/timesyncd.conf.d/ 下的 drop-in，
#                      发行版自带的 timesyncd.conf 一字不动（那个文件自己的
#                      注释就推荐用 drop-in）
#   chrony / ntpd      在主配置里维护一个带标记的块
#
# 两者都只新增，不改动用户原有的行：chrony 与 ntpd 会在多个源之间自动挑
# 可达的，所以保留原有的 pool / server 不会冲突，也省得去猜哪一行能动。
# 撤销就是删掉我们写的那一份（drop-in 文件，或标记块）。
# ============================================================

TIME_TIMESYNCD_DROPIN="${TIME_TIMESYNCD_DROPIN:-/etc/systemd/timesyncd.conf.d/99-linux-toolkit.conf}"
TIME_CHRONY_CONF_DEB="${TIME_CHRONY_CONF_DEB:-/etc/chrony/chrony.conf}"
TIME_CHRONY_CONF_ALT="${TIME_CHRONY_CONF_ALT:-/etc/chrony.conf}"
TIME_NTPD_CONF="${TIME_NTPD_CONF:-/etc/ntp.conf}"

TIME_BLOCK_BEGIN='# >>> linux-toolkit ntp servers >>>'
TIME_BLOCK_END='# <<< linux-toolkit ntp servers <<<'

# 备选服务器。国内可达性优先，国际的放后面。
NTP_SERVER_LIST=(
    "ntp.aliyun.com"
    "ntp.tencent.com"
    "cn.pool.ntp.org"
    "cn.ntp.org.cn"
    "ntp.ntsc.ac.cn"
    "time.cloudflare.com"
    "pool.ntp.org"
)
NTP_SERVER_NOTE=(
    "阿里云"
    "腾讯云"
    "NTP Pool 中国"
    "国家授时中心"
    "国家授时中心 NTSC"
    "Cloudflare"
    "国际 NTP Pool"
)

# 当前在用的校时实现。systemd 单元优先，其次按命令找 ——
# Alpine 这类没有 systemd 单元，只有命令。
_time_ntp_impl() {
    local u=''
    u="$(_time_ntp_unit || true)"
    [[ -n "$u" ]] && { printf '%s' "$u"; return 0; }
    if have_cmd chronyd; then printf 'chronyd'; return 0; fi
    if have_cmd systemd-timesyncd; then printf 'systemd-timesyncd'; return 0; fi
    if have_cmd ntpd; then printf 'ntpd'; return 0; fi
    return 1
}

# 该实现要写的配置文件
_time_ntp_conf() {
    case "$1" in
        systemd-timesyncd) printf '%s' "$TIME_TIMESYNCD_DROPIN" ;;
        chronyd)
            if [[ -e "$TIME_CHRONY_CONF_DEB" ]]; then
                printf '%s' "$TIME_CHRONY_CONF_DEB"
            else
                printf '%s' "$TIME_CHRONY_CONF_ALT"
            fi
            ;;
        ntpd) printf '%s' "$TIME_NTPD_CONF" ;;
        *)    return 1 ;;
    esac
}

# 配置里当前的服务器（每行一个）
_time_ntp_servers_current() {
    local conf=''
    case "$1" in
        systemd-timesyncd)
            [[ -r "$TIME_TIMESYNCD_DROPIN" ]] || return 0
            awk -F= '/^NTP=/ { print $2 }' "$TIME_TIMESYNCD_DROPIN"
            ;;
        chronyd)
            conf="$(_time_ntp_conf chronyd)"
            [[ -r "$conf" ]] || return 0
            awk '$1 == "server" || $1 == "pool" { print $2 }' "$conf"
            ;;
        ntpd)
            [[ -r "$TIME_NTPD_CONF" ]] || return 0
            awk '$1 == "server" { print $2 }' "$TIME_NTPD_CONF"
            ;;
    esac
}

# 探测服务器是否真的应答：ok / nodns / noresp / unprobe
#
# 只查 DNS 不够 —— 名字能解析不代表 UDP 123 通得过，等配置写完才发现
# 连不上等于白改。这里真发一个 NTP 客户端请求过去看应答。
#
# 关键：48 字节必须一次 write 出去。UDP 面向报文，用
# `{ printf '\x1b'; head -c 47 /dev/zero; } >&3` 这种写法会分成两次
# write，变成 1 字节 + 47 字节两个无效包，服务器看都不看，于是所有
# 服务器都「无应答」—— 这个坑实测踩过。
_time_probe_ntp() {
    local host="$1" resp

    have_cmd timeout || { printf 'unprobe'; return 0; }

    if have_cmd getent && ! getent hosts "$host" >/dev/null 2>&1; then
        printf 'nodns'
        return 0
    fi

    exec 3<>"/dev/udp/$host/123" 2>/dev/null || { printf 'nodns'; return 0; }
    printf '\x1b\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' >&3 2>/dev/null
    resp="$(timeout 4 dd bs=48 count=1 <&3 2>/dev/null | od -An -tx1 | head -1)"
    exec 3<&- 2>/dev/null

    [[ -n "$resp" ]] && printf 'ok' || printf 'noresp'
}

# 把服务器写进配置。只新增，不动用户原有的行；重复执行不会累积。
_time_ntp_servers_write() {
    local impl="$1" servers="$2" conf='' tmp='' mode='' s=''

    if [[ "$impl" == "systemd-timesyncd" ]]; then
        mkdir -p "$(dirname "$TIME_TIMESYNCD_DROPIN")" || return 1
        printf '[Time]\nNTP=%s\n' "$servers" >"$TIME_TIMESYNCD_DROPIN" || return 1
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")" || return 1
    tmp="$(mktemp)" || return 1

    # 先摘掉上次写的块，再追加新的
    if [[ -r "$conf" ]]; then
        awk -v b="$TIME_BLOCK_BEGIN" -v e="$TIME_BLOCK_END" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            !skip
        ' "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }
    fi
    {
        printf '%s\n' "$TIME_BLOCK_BEGIN"
        for s in $servers; do printf 'server %s iburst\n' "$s"; done
        printf '%s\n' "$TIME_BLOCK_END"
    } >>"$tmp" || { rm -f "$tmp"; return 1; }

    if [[ -e "$conf" ]]; then
        mode="$(stat -c %a "$conf" 2>/dev/null || echo 644)"
        install -m "$mode" "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    else
        install -m 0644 "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
    return 0
}

# 撤掉本工具写的配置，回到发行版默认
_time_ntp_servers_clear() {
    local impl="$1" conf='' tmp='' mode=''

    if [[ "$impl" == "systemd-timesyncd" ]]; then
        rm -f "$TIME_TIMESYNCD_DROPIN"
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")" || return 1
    [[ -r "$conf" ]] || return 0
    grep -qF -- "$TIME_BLOCK_BEGIN" "$conf" || return 0   # 没有我们的块，什么都不用做

    tmp="$(mktemp)" || return 1
    awk -v b="$TIME_BLOCK_BEGIN" -v e="$TIME_BLOCK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip
    ' "$conf" >"$tmp" || { rm -f "$tmp"; return 1; }

    mode="$(stat -c %a "$conf" 2>/dev/null || echo 644)"
    install -m "$mode" "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"

    # 摘掉我们的块之后一个字都不剩，说明这个文件本来就是为它建的，
    # 一并删掉，避免留一个空配置文件让人困惑（注释行也算内容，会保留）
    if ! grep -qvE '^[[:space:]]*$' "$conf" 2>/dev/null; then
        rm -f "$conf"
    fi
    return 0
}

_time_ntp_conf_snapshot() {
    local conf
    TIME_SRV_SNAP_DIR=''
    TIME_SRV_SNAP_EXISTED=''
    TIME_SRV_CONF="$(_time_ntp_conf "$1")" || return 1
    conf="$TIME_SRV_CONF"

    TIME_SRV_SNAP_DIR="$(mktemp -d 2>/dev/null)" || return 1
    if [[ -e "$conf" ]]; then
        TIME_SRV_SNAP_EXISTED=1
        cp -a "$conf" "$TIME_SRV_SNAP_DIR/conf" 2>/dev/null || return 1
    fi
    return 0
}

_time_ntp_conf_snapshot_cleanup() {
    [[ -n "${TIME_SRV_SNAP_DIR:-}" && -d "${TIME_SRV_SNAP_DIR:-}" ]] && rm -rf "$TIME_SRV_SNAP_DIR"
    TIME_SRV_SNAP_DIR=''
    return 0
}

_time_ntp_conf_rollback() {
    [[ -n "${TIME_SRV_SNAP_DIR:-}" && -d "${TIME_SRV_SNAP_DIR:-}" ]] || return 0
    if [[ -n "${TIME_SRV_SNAP_EXISTED:-}" ]]; then
        cp -a "$TIME_SRV_SNAP_DIR/conf" "$TIME_SRV_CONF" 2>/dev/null || true
    else
        rm -f "$TIME_SRV_CONF"      # 原本没有就得删掉，不能留个我们建的文件
    fi
    _time_ntp_conf_snapshot_cleanup
    return 0
}

# 写完后确认服务器真的进了生效配置。
# timesyncd 用 systemd-analyze cat-config 看合并后的结果 —— 这能证明
# drop-in 的路径与写法都被认了，而不只是「文件写出去了」。
_time_ntp_servers_verify() {
    local impl="$1" servers="$2" conf='' eff='' s=''

    if [[ "$impl" == "systemd-timesyncd" ]] && have_cmd systemd-analyze; then
        if eff="$(systemd-analyze cat-config systemd/timesyncd.conf 2>/dev/null)" && [[ -n "$eff" ]]; then
            for s in $servers; do
                [[ "$eff" == *"$s"* ]] || { printf '生效配置里没有 %s' "$s"; return 1; }
            done
            return 0
        fi
    fi

    conf="$(_time_ntp_conf "$impl")"
    [[ -r "$conf" ]] || { printf '%s 读不到' "$conf"; return 1; }
    for s in $servers; do
        grep -qF -- "$s" "$conf" || { printf '配置里没有 %s' "$s"; return 1; }
    done
    return 0
}

# 让新配置生效：重启校时服务，并等它真的连上其中一个服务器
_time_ntp_reload() {
    local impl="$1" servers="$2" srv='' i s=''

    case "$impl" in
        systemd-timesyncd)
            _time_have_systemd || return 0
            [[ "$(_time_td_get NTP)" == "yes" ]] || {
                log_info "NTP 自动校时当前是关闭的，配置已写入，等开启后生效。"
                return 0
            }
            systemctl restart systemd-timesyncd >/dev/null 2>&1 || {
                log_warn "重启 systemd-timesyncd 失败，配置已写入但可能未生效。"
                return 0
            }
            # 没指定服务器（恢复默认的场景）就只确认服务起来了 ——
            # 不去等它连上谁，否则会白白等满超时再报一句吓人的假警报
            if [[ -z "${servers// /}" ]]; then
                log_ok "服务已重启，已回到发行版默认服务器。"
                return 0
            fi
            for (( i=0; i<10; i++ )); do
                srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
                for s in $servers; do
                    [[ "$srv" == *"$s"* ]] && { log_ok "已连上 $srv"; return 0; }
                done
                sleep 1
            done
            log_warn "服务已重启，但 10 秒内没看到它连上指定的服务器。"
            log_info "可能是出站 UDP 123 不通，稍后可用「状态查看」再看。"
            ;;
        *)
            # chrony / ntpd 走各自的 init
            if have_cmd systemctl && _time_have_systemd; then
                systemctl restart "$impl" >/dev/null 2>&1 && log_ok "已重启 $impl"
            elif have_cmd rc-service; then
                rc-service "$impl" restart >/dev/null 2>&1 && log_ok "已重启 $impl"
            elif have_cmd service; then
                service "$impl" restart >/dev/null 2>&1 && log_ok "已重启 $impl"
            else
                log_info "没找到可用的服务管理命令，请手动重启 $impl 让配置生效。"
            fi
            ;;
    esac
    return 0
}

# 恢复发行版默认
_time_ntp_server_restore() {
    local impl="$1" conf=''

    conf="$(_time_ntp_conf "$impl")"

    module_begin "恢复默认校时服务器"
    ui_section "将删除"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        if [[ -e "$TIME_TIMESYNCD_DROPIN" ]]; then
            printf '  %s-%s %s\n' "$C_RED" "$C_RESET" "$TIME_TIMESYNCD_DROPIN"
        else
            printf '  %s本工具没有写过配置，无需删除%s\n' "$C_DIM" "$C_RESET"
            module_end
            return 0
        fi
    else
        if [[ -r "$conf" ]] && grep -qF -- "$TIME_BLOCK_BEGIN" "$conf"; then
            printf '  %s-%s %s 中本工具写的那一段（标记之间）\n' "$C_RED" "$C_RESET" "$conf"
            printf '  %s  用户原有的 pool / server 行一律保留%s\n' "$C_DIM" "$C_RESET"
        else
            printf '  %s本工具没有写过配置，无需删除%s\n' "$C_DIM" "$C_RESET"
            module_end
            return 0
        fi
    fi

    ui_section "不受影响"
    printf '  %s发行版自带的配置文件、其它服务器配置一律不动%s\n' "$C_DIM" "$C_RESET"
    printf '  %s校时服务本身不卸载、不停止%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认恢复默认?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if ! _time_ntp_conf_snapshot "$impl"; then
        log_err "无法备份现有配置，为安全起见不做修改。"
        module_end
        return 1
    fi
    if ! _time_ntp_servers_clear "$impl"; then
        log_err "删除失败，正在回滚..."
        _time_ntp_conf_rollback
        module_end
        return 1
    fi
    _time_ntp_conf_snapshot_cleanup
    log_ok "已恢复发行版默认。"
    _time_ntp_reload "$impl" ""
    module_end
}

# ============================================================
# 设置 NTP 服务器
# ============================================================
time_ntp_server() {
    require_root

    local impl='' conf='' cur='' i s='' servers='' custom_idx=0
    local items=() srv='' mode=''
    local ok_n=0 bad_n=0 unres_n=0 bad_list='' unres_list=''

    module_begin "设置 NTP 服务器"

    if ! impl="$(_time_ntp_impl)"; then
        log_warn "系统里没有安装任何校时服务，暂时无处可写。"
        log_info "请先执行「开启自动校时」装一个（那里会说明装的是哪个），再回来设置服务器。"
        module_end
        return 0
    fi

    conf="$(_time_ntp_conf "$impl")"
    cur="$(_time_ntp_servers_current "$impl" | tr '\n' ' ')"
    cur="${cur% }"

    ui_section "当前状态"
    ui_kv "校时实现" "$impl"
    ui_kv "配置文件" "$conf"
    if [[ -n "$cur" ]]; then
        ui_kv "当前服务器" "$cur"
    else
        ui_kv "当前服务器" "本工具未配置过"
    fi
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
        [[ -n "$srv" ]] && ui_kv "正在使用" "$srv"
    fi

    for (( i=0; i<${#NTP_SERVER_LIST[@]}; i++ )); do
        items+=("${NTP_SERVER_LIST[i]}|${NTP_SERVER_NOTE[i]}")
    done
    custom_idx=${#items[@]}
    items+=("手动输入地址|可填多个，空格分隔")
    items+=("恢复默认|删掉本工具写的配置")

    ui_menu "选择 NTP 服务器" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0

    if (( UI_CHOICE == custom_idx + 1 )); then
        _time_ntp_server_restore "$impl"
        return $?
    fi

    if (( UI_CHOICE == custom_idx )); then
        module_begin "手动输入 NTP 服务器"
        printf '  %s可填多个，用空格分隔。例: ntp.aliyun.com ntp.tencent.com%s\n\n' "$C_DIM" "$C_RESET"
        while true; do
            if ! ask "服务器地址（直接回车放弃）" ""; then
                log_info "输入中断，已取消。"
                return 0
            fi
            servers="${REPLY//,/ }"
            [[ -n "${servers// /}" ]] || { log_info "未输入，已取消。"; return 0; }

            # 逐个体检。只允许主机名 / IPv4 的字符集 —— 地址要拼进配置文件，
            # 放行任意字符等于让用户能往配置里注任意内容
            local bad=''
            for s in $servers; do
                [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || { bad="$s"; break; }
            done
            if [[ -n "$bad" ]]; then
                log_warn "「$bad」不是合法的服务器地址（只允许字母、数字与 . _ -）"
                continue
            fi
            break
        done
    else
        servers="${NTP_SERVER_LIST[UI_CHOICE]}"
    fi

    # ---- 探测：真发 NTP 请求，不只看 DNS ----
    module_begin "探测服务器"
    for s in $servers; do
        case "$(_time_probe_ntp "$s")" in
            ok)      log_ok "$s 应答正常"; ok_n=$(( ok_n + 1 )) ;;
            nodns)   log_err "$s 解析不了（域名可能写错）"; bad_n=$(( bad_n + 1 )); bad_list+="$s " ;;
            noresp)  log_warn "$s 无应答（UDP 123 可能不通）"; unres_n=$(( unres_n + 1 )); unres_list+="$s " ;;
            *)       log_info "本机无法探测，跳过"; unres_n=$(( unres_n + 1 )); unres_list+="$s " ;;
        esac
    done

    if (( bad_n > 0 )); then
        log_err "有地址解析不了，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 预览 ----
    module_begin "确认变更"
    ui_section "将写入"
    ui_kv "配置文件" "$conf"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        ui_kv "形式" "drop-in 文件（发行版自带的 timesyncd.conf 不动）"
        printf '  %s[Time]%s\n' "$C_DIM" "$C_RESET"
        printf '  %sNTP=%s%s\n' "$C_BCYAN" "$servers" "$C_RESET"
    else
        ui_kv "形式" "在配置文件末尾追加一个带标记的块"
        for s in $servers; do
            printf '  %s+%s server %s iburst\n' "$C_GREEN" "$C_RESET" "$s"
        done
    fi

    ui_section "不会改动"
    if [[ "$impl" == "systemd-timesyncd" ]]; then
        printf '  %s发行版自带的 /etc/systemd/timesyncd.conf 一字不动%s\n' "$C_DIM" "$C_RESET"
    else
        printf '  %s已有的 pool / server 行一律保留 —— %s 会在多个源之间自动挑可达的%s\n' \
            "$C_DIM" "$impl" "$C_RESET"
        printf '  %s只动标记块之内的内容%s\n' "$C_DIM" "$C_RESET"
    fi
    printf '  %s时区、NTP 开关状态、软件包一律不动%s\n' "$C_DIM" "$C_RESET"

    ui_section "将备份（仅失败回滚用，成功后删除）"
    if [[ -e "$conf" ]]; then
        ui_kv "$conf" "整份复制到临时目录"
    else
        printf '  %s%s 不存在，将新建（回滚时会删掉它）%s\n' "$C_DIM" "$conf" "$C_RESET"
    fi

    if (( unres_n > 0 )); then
        printf '\n'
        log_warn "以下服务器没有应答: ${unres_list% }"
        log_info "可能只是 UDP 123 出站被挡。仍可写入，但同步未必能成。"
    fi

    printf '\n'
    if ! confirm "确认写入?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    if ! _time_ntp_conf_snapshot "$impl"; then
        log_err "无法备份现有配置，为安全起见不做任何修改。"
        _time_ntp_conf_snapshot_cleanup
        module_end
        return 1
    fi

    if ! _time_ntp_servers_write "$impl" "$servers"; then
        log_err "写入失败，正在回滚..."
        _time_ntp_conf_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "已写入 $conf"

    # ---- 验证 ----
    if ! mode="$(_time_ntp_servers_verify "$impl" "$servers")"; then
        log_err "验证未通过（$mode），正在回滚..."
        _time_ntp_conf_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "生效配置中已包含所选服务器"

    _time_ntp_conf_snapshot_cleanup
    _time_ntp_reload "$impl" "$servers"

    ui_section "设置后"
    ui_kv "配置文件" "$conf"
    ui_kv "服务器" "$servers"
    module_end
}

# ============================================================
# 1) 状态查看（只读）
# ============================================================
time_status() {
    local tz kind

    ui_section "当前时间"
    # 本进程若带着 TZ 环境变量，date 显示的是 TZ 的结果而不是系统时区 ——
    # 这正是「改了时区却没生效」最常见的误诊来源，先把它摆出来
    if [[ -n "${TZ:-}" ]]; then
        ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')  ${C_YELLOW}← 受环境变量 TZ=$TZ 影响${C_RESET}"
    else
        ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    fi
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    ui_kv "时间戳" "$(date +%s)"

    ui_section "时区"
    if tz="$(_time_tz_current)"; then
        ui_kv "时区" "$(_time_tz_label "$tz")"
    else
        ui_kv "时区" "读不出名字"
    fi
    ui_kv "来源" "$(_time_tz_source_label)"

    kind="$(_time_localtime_kind)"
    case "$kind" in
        symlink)
            ui_kv "$TIME_LOCALTIME" "符号链接 → $(readlink "$TIME_LOCALTIME" 2>/dev/null)"
            [[ -e "$TIME_LOCALTIME" ]] || printf '  %s但链接已失效（date 会静默按 UTC 走）%s\n' \
                "$C_YELLOW" "$C_RESET"
            ;;
        copy)
            ui_kv "$TIME_LOCALTIME" "普通文件（$(stat -c %s "$TIME_LOCALTIME" 2>/dev/null || echo '?') 字节的时区副本）"
            ;;
        *)
            ui_kv "$TIME_LOCALTIME" "不存在（等同 UTC）"
            ;;
    esac

    if [[ -r "$TIME_TZFILE" ]]; then
        ui_kv "$TIME_TZFILE" "$(head -n1 "$TIME_TZFILE" 2>/dev/null)"
    else
        ui_kv "$TIME_TZFILE" "不存在"
    fi

    if [[ -n "${tz:-}" ]] && ! _time_tz_valid "$tz"; then
        printf '  %s时区名 %s 在 %s 下没有对应的时区文件，这个时区可能已失效%s\n' \
            "$C_YELLOW" "$tz" "$TIME_ZONEINFO" "$C_RESET"
    fi

    ui_section "自动校时"
    local impl='' srv='' srvlist=''
    impl="$(_time_ntp_impl || true)"

    if _time_have_systemd; then
        if [[ -n "$impl" ]]; then
            if _time_ntp_active "$impl"; then
                ui_kv "校时服务" "$impl（运行中）"
            else
                ui_kv "校时服务" "$impl（未运行）"
            fi
        else
            ui_kv "校时服务" "未安装"
        fi
        ui_kv "NTP 已启用" "$(_time_td_get NTP)"
        ui_kv "已同步" "$(_time_td_get NTPSynchronized)"
        ui_kv "可启用 NTP" "$(_time_td_get CanNTP)"
        ui_kv "RTC 走本地时间" "$(_time_td_get LocalRTC)"
    else
        ui_kv "systemd" "未运行（timedatectl 不可用）"
        ui_kv "校时服务" "${impl:-未安装}"
    fi

    if [[ -n "$impl" ]]; then
        srvlist="$(_time_ntp_servers_current "$impl" | tr '\n' ' ')"
        srvlist="${srvlist% }"
        if [[ -n "$srvlist" ]]; then
            ui_kv "已配服务器" "$srvlist"
        else
            ui_kv "已配服务器" "本工具未配置过（用发行版默认）"
        fi
        if _time_have_systemd; then
            srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
            [[ -n "$srv" ]] && ui_kv "正在使用" "$srv"
        fi
    fi

    ui_section "时区数据库"
    if [[ -d "$TIME_ZONEINFO" ]]; then
        ui_kv "目录" "$TIME_ZONEINFO"
        ui_kv "时区文件" "$(find -L "$TIME_ZONEINFO" -type f 2>/dev/null | wc -l | tr -d ' ') 个"
    else
        ui_kv "目录" "$TIME_ZONEINFO（不存在，需要安装 tzdata）"
    fi

    module_end
}

# ============================================================
# 2) 设置时区
# ============================================================

# 常用时区。偏移不写死，选择时用 TZ=<zone> date 现算。
TIME_ZONE_LIST=(
    "Asia/Shanghai" "Asia/Urumqi" "Asia/Hong_Kong" "Asia/Taipei"
    "Asia/Tokyo" "Asia/Seoul" "Asia/Singapore" "Asia/Bangkok"
    "Asia/Kolkata" "Asia/Dubai"
    "Europe/London" "Europe/Paris" "Europe/Moscow"
    "America/New_York" "America/Los_Angeles"
    "UTC"
)
TIME_ZONE_NOTE=(
    "中国标准时间" "中国新疆时间" "香港" "台北"
    "日本" "韩国" "新加坡" "泰国"
    "印度" "阿联酋"
    "英国" "中欧" "俄罗斯（莫斯科）"
    "美国东部" "美国西部"
    "协调世界时"
)

# 确认并切换时区。调用前调用方已画好界面。
_time_tz_change() {
    local tz="$1" cur='' now after

    module_begin "切换时区"

    # ---- 1. 验证：不过就一个文件都不动 ----
    # 返回 0 而不是 1：这是处理得了的输入错误，不是故障。返回非 0 会让
    # run_submenu 再补一句「返回码 1」并二次暂停，反而把话说糊了。
    if ! _time_tz_valid "$tz"; then
        log_err "「$tz」不是有效的时区名，未做任何修改。"
        _time_tz_hint "$tz"
        module_end
        return 0
    fi

    cur="$(_time_tz_current || true)"
    if [[ "$tz" == "$cur" ]]; then
        log_info "当前时区已经是 $tz，无需修改。"
        module_end
        return 0
    fi

    # ---- 2. 预览 ----
    module_begin "确认变更"
    ui_section "时区"
    if [[ -n "$cur" ]]; then
        ui_kv "当前" "$(_time_tz_label "$cur")"
    else
        ui_kv "当前" "读不出名字"
    fi
    ui_kv "改为" "$(_time_tz_label "$tz")"

    ui_section "将写入"
    if _time_have_systemd; then
        ui_kv "方式" "timedatectl set-timezone"
    else
        ui_kv "方式" "直接写文件（未运行 systemd）"
    fi
    ui_kv "$TIME_LOCALTIME" "符号链接 → $TIME_ZONEINFO/$tz"
    ui_kv "$TIME_TZFILE" "$tz"

    ui_section "将备份（仅失败回滚用，成功后删除）"
    case "$(_time_localtime_kind)" in
        symlink) ui_kv "$TIME_LOCALTIME" "记下链接目标 → $(readlink "$TIME_LOCALTIME" 2>/dev/null)" ;;
        copy)    ui_kv "$TIME_LOCALTIME" "整份复制到临时目录（二进制，不能存内存）" ;;
        *)       printf '  %s%s 不存在，无需备份%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET" ;;
    esac
    if [[ -e "$TIME_TZFILE" ]]; then
        ui_kv "$TIME_TZFILE" "整份复制到临时目录"
    else
        printf '  %s%s 不存在，无需备份（回滚时会删掉它）%s\n' "$C_DIM" "$TIME_TZFILE" "$C_RESET"
    fi

    ui_section "不受影响"
    printf '  %s不会删除或清空任何目录，不卸载任何软件包%s\n' "$C_DIM" "$C_RESET"
    if _time_rtc_is_local; then
        printf '\n'
        log_warn "硬件时钟当前按「本地时间」解释（/etc/adjtime 为 LOCAL，或 LocalRTC=yes）。"
        log_warn "这种配置下改时区会连带改变 RTC 数值的含义，重启后系统时钟可能跳变。"
        log_info "建议先执行: timedatectl set-local-rtc 0（把硬件时钟改回 UTC）"
    else
        printf '  %s硬件时钟与 /etc/adjtime 一律不动%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    if ! confirm "确认切换时区?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 3. 执行 ----
    module_begin "执行变更"

    if _time_localtime_mountinfo >/dev/null; then
        # 容器里 -v /etc/localtime:/etc/localtime 很常见：改它等于改宿主机
        log_err "$TIME_LOCALTIME 是被挂载进来的，容器内改它等于改宿主机的时区。"
        log_info "请在宿主机上设置时区，或用 -e TZ=Asia/Shanghai 给容器单独指定。"
        module_end
        return 1
    fi

    TIME_SNAP_OLD_TZ="$cur"
    if ! _time_tz_snapshot; then
        log_err "无法备份现有配置，为安全起见不做任何修改。"
        _time_tz_snapshot_cleanup
        module_end
        return 1
    fi

    if ! _time_tz_apply "$tz"; then
        log_err "写入失败，正在回滚..."
        _time_tz_rollback
        log_info "已恢复到变更前的状态。"
        module_end
        return 1
    fi
    log_ok "已写入"

    # ---- 4. 验证 ----
    if ! now="$(_time_tz_verify "$tz")"; then
        log_err "验证未通过（$now），正在回滚..."
        _time_tz_rollback
        after="$(_time_tz_current || true)"
        if [[ "$after" == "$cur" ]]; then
            log_ok "已恢复到变更前的时区 ${cur:-（无）}。"
        else
            log_err "回滚后读到 ${after:-未知}，请手动检查 $TIME_LOCALTIME"
        fi
        module_end
        return 1
    fi

    _time_tz_snapshot_cleanup
    log_ok "时区已切换为 $tz"

    ui_section "当前时间"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    printf '\n  %s若某个程序自带 TZ 环境变量，它仍按自己的时区走，不受这里影响。%s\n' \
        "$C_DIM" "$C_RESET"
    module_end
}

# ------------------------------------------------------------
# 浏览全部时区
#
# zoneinfo 下光文件名就有四百多个（America 一个地区 157 个），
# 平铺成一个菜单既列不下也没法看，所以按地区分组 + 分页。
# ------------------------------------------------------------

# 终端行数，用来定分页大小。取不到就按 24 行算。
_time_term_rows() {
    local r="${LINES:-0}"
    (( r > 0 )) || r="$(tput lines 2>/dev/null || echo 24)"
    [[ "$r" =~ ^[0-9]+$ ]] || r=24
    (( r >= 12 )) || r=12
    printf '%s' "$r"
}

# 地区名 → 中文标签。空串代表顶层那些不属于任何地区的时区。
_time_zone_region_label() {
    case "$1" in
        "")         printf '其它' ;;
        Africa)     printf '非洲' ;;
        America)    printf '美洲' ;;
        Antarctica) printf '南极洲' ;;
        Arctic)     printf '北极' ;;
        Asia)       printf '亚洲' ;;
        Atlantic)   printf '大西洋' ;;
        Australia)  printf '澳大利亚' ;;
        Etc)        printf 'Etc（固定偏移）' ;;
        Europe)     printf '欧洲' ;;
        Indian)     printf '印度洋' ;;
        Pacific)    printf '太平洋' ;;
        US|Canada|Brazil|Chile|Mexico)
                    printf '%s（旧式别名）' "$1" ;;
        *)          printf '%s' "$1" ;;
    esac
}

# 某地区下真正可用的时区，每行一个（已按名字排序）。
# 地区名为空 = 顶层散装时区（UTC / GMT 这些）。
_time_zone_list_region() {
    local base f
    if [[ -z "$1" ]]; then
        base="$TIME_ZONEINFO"
        find -L "$base" -maxdepth 1 -type f 2>/dev/null | sort | while IFS= read -r f; do
            f="${f#"$TIME_ZONEINFO"/}"
            _time_tz_valid "$f" && printf '%s\n' "$f"
        done
        return 0
    fi

    base="$TIME_ZONEINFO/$1"
    [[ -d "$base" ]] || return 0
    # 递归：America 底下还有 Argentina / Indiana / Kentucky / North_Dakota 一层
    find -L "$base" -type f 2>/dev/null | sort | while IFS= read -r f; do
        f="${f#"$TIME_ZONEINFO"/}"
        _time_tz_valid "$f" && printf '%s\n' "$f"
    done
    return 0
}

_time_zone_count_region() {
    _time_zone_list_region "$1" | wc -l | tr -d ' '
}

# 全部地区（含用空串表示的顶层）。空的地区由调用方按数量过滤掉。
_time_zone_regions() {
    local d
    for d in "$TIME_ZONEINFO"/*/; do
        [[ -d "$d" ]] || continue
        printf '%s\n' "$(basename "$d")"
    done
    printf '\n'      # 顶层散装
    return 0
}

# 分页菜单。选中把下标写进 UI_CHOICE，放弃写 -1。
#
# 不用 ui_menu：它一次把所有选项铺完，一百多项会直接冲掉整个回滚缓冲，
# 用户得拿终端回滚当翻页用。这里按终端高度算每页条数，n/p 翻页、q 放弃。
_time_menu_paged() {
    local title="$1" arr_ref="$2"
    local -n _pg="$arr_ref"
    local total=${#_pg[@]}
    local per rows pages page=0 i start end choice err=''

    rows="$(_time_term_rows)"
    per=$(( rows - 16 ))          # 减掉横幅、标题、翻页提示与输入提示占的行
    (( per >= 8 ))  || per=8
    (( per <= 40 )) || per=40

    pages=$(( (total + per - 1) / per ))
    (( pages >= 1 )) || pages=1

    UI_CHOICE=-1
    while true; do
        ui_screen
        ui_title "$title（第 $(( page + 1 ))/$pages 页 · 共 $total 项）"
        # 每次都重画屏幕，报错得画在重画之后，否则会被清掉看不见
        [[ -n "$err" ]] && { printf ' %s%s%s\n\n' "$C_RED" "$err" "$C_RESET"; err=''; }

        start=$(( page * per ))
        end=$(( start + per ))
        (( end <= total )) || end=$total
        for (( i=start; i<end; i++ )); do
            printf ' %s%3d)%s %s\n' "$C_BCYAN" $(( i + 1 )) "$C_RESET" "${_pg[i]}"
        done

        printf '\n '
        (( page > 0 ))        && printf '%sn)%s 上一页  ' "$C_DIM" "$C_RESET"
        (( page < pages - 1 )) && printf '%sp)%s 下一页  ' "$C_DIM" "$C_RESET"
        printf '%sq)%s 放弃\n\n' "$C_DIM" "$C_RESET"

        printf '%s请输入序号%s %s[1-%d]%s: ' "$C_BYELLOW" "$C_RESET" "$C_DIM" "$total" "$C_RESET"
        ui_read choice || { printf '\n'; UI_CHOICE=-1; return 0; }

        case "$choice" in
            q|Q) UI_CHOICE=-1; return 0 ;;
            n|N) (( page < pages - 1 )) && page=$(( page + 1 )); continue ;;
            p|P) (( page > 0 )) && page=$(( page - 1 )); continue ;;
        esac
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            UI_CHOICE=$(( choice - 1 ))
            return 0
        fi
        err="无效输入，请输入序号或用 n / p / q"
    done
}

# 按地区浏览全部时区。选中的时区名写进 TIME_PICKED_TZ，空串表示放弃。
#
# 结果走全局变量而不是 stdout：这个函数要画好几屏界面，那些输出也在
# stdout 上，用 tz="$(_time_zone_browse)" 接结果会把界面文字一起接走，
# 于是「时区名」变成一整屏菜单，验证必然不过。
_time_zone_browse() {
    local regions=() items=() zones=() r n='' tz=''

    TIME_PICKED_TZ=''

    while IFS= read -r r; do
        n="$(_time_zone_count_region "$r")"
        (( n > 0 )) || continue
        regions+=("$r")
        items+=("$(_time_zone_region_label "$r")|$n 个")
    done < <(_time_zone_regions)

    module_begin "全部时区"
    if (( ${#regions[@]} == 0 )); then
        log_warn "$TIME_ZONEINFO 下没有找到可用的时区，可能需要安装 tzdata。"
        module_end
        return 0
    fi

    ui_menu "选择地区" items "← 返回"
    (( UI_CHOICE < 0 )) && return 0
    r="${regions[UI_CHOICE]}"

    while IFS= read -r tz; do
        [[ -n "$tz" ]] && zones+=("$tz")
    done < <(_time_zone_list_region "$r")
    (( ${#zones[@]} > 0 )) || return 0

    _time_menu_paged "时区 · $(_time_zone_region_label "$r")" zones || return 0
    (( UI_CHOICE >= 0 )) || return 0
    TIME_PICKED_TZ="${zones[UI_CHOICE]}"
    return 0
}

time_set_tz() {
    require_root

    local i tz='' items=() zones=() custom_idx=0 browse_idx=0 cur=''

    cur="$(_time_tz_current || true)"

    # 表里编的时区理论上都在，但精简过的 tzdata 可能缺 —— 缺的不进菜单，
    # 所以要用 zones 另存一份，保证下标与菜单项严格对应
    for (( i=0; i<${#TIME_ZONE_LIST[@]}; i++ )); do
        tz="${TIME_ZONE_LIST[i]}"
        _time_tz_valid "$tz" || continue
        zones+=("$tz")
        items+=("$tz|${TIME_ZONE_NOTE[i]}  UTC$(_time_tz_offset "$tz")")
    done
    browse_idx=${#zones[@]}
    items+=("按地区浏览全部时区|按地区分组，分页显示")
    custom_idx=$(( browse_idx + 1 ))
    items+=("手动输入时区名|如 America/New_York、Europe/Berlin")

    module_begin "设置时区"
    if [[ -n "$cur" ]]; then
        ui_kv "当前时区" "$(_time_tz_label "$cur")"
    else
        ui_kv "当前时区" "读不出名字"
    fi
    if [[ ! -d "$TIME_ZONEINFO" ]]; then
        log_warn "$TIME_ZONEINFO 不存在，需要先安装 tzdata 才能设置时区。"
        module_end
        return 1
    fi

    ui_menu "选择时区" items "← 放弃修改"
    (( UI_CHOICE < 0 )) && return 0

    if (( UI_CHOICE == browse_idx )); then
        _time_zone_browse
        tz="$TIME_PICKED_TZ"
        [[ -n "$tz" ]] || return 0
    elif (( UI_CHOICE == custom_idx )); then
        module_begin "手动输入时区名"
        printf '  %s时区名形如 地区/城市，可用 ls %s/地区 查看%s\n\n' \
            "$C_DIM" "$TIME_ZONEINFO" "$C_RESET"
        while true; do
            if ! ask "时区名（直接回车放弃）" ""; then
                log_info "输入中断，已取消。"
                return 0
            fi
            tz="${REPLY//[[:space:]]/}"
            if [[ -z "$tz" ]]; then
                log_info "未输入，已取消。"
                return 0
            fi
            if _time_tz_valid "$tz"; then
                break
            fi
            log_warn "「$tz」不是有效的时区名"
            _time_tz_hint "$tz"
        done
    else
        tz="${zones[UI_CHOICE]}"
    fi

    _time_tz_change "$tz"
}

# ============================================================
# 3) 开启自动校时
# ============================================================
time_ntp_on() {
    require_root

    module_begin "开启自动校时"

    if ! _time_have_systemd; then
        _time_ntp_on_nosystemd
        return $?
    fi

    local unit='' pkg='' ntp='' can=''
    unit="$(_time_ntp_unit || true)"
    ntp="$(_time_td_get NTP)"
    can="$(_time_td_get CanNTP)"

    ui_section "当前状态"
    if [[ -n "$unit" ]]; then
        if _time_ntp_active "$unit"; then
            ui_kv "校时服务" "$unit（运行中）"
        else
            ui_kv "校时服务" "$unit（未运行）"
        fi
    else
        ui_kv "校时服务" "未安装"
    fi
    ui_kv "NTP 已启用" "$ntp"
    ui_kv "已同步" "$(_time_td_get NTPSynchronized)"

    if [[ "$ntp" == "yes" ]]; then
        log_info "NTP 自动校时已经是开启状态，无需重复开启。"
        module_end
        return 0
    fi

    # CanNTP 就是 timedated 判断「有没有可用的校时服务」的那个条件，
    # 为 no 时直接调 set-ntp 只会拿到 "NTP not supported" 这句没用的报错
    if [[ -z "$unit" ]]; then
        pkg="$(_time_ntp_pkg)"
    elif [[ "$can" != "yes" ]]; then
        log_warn "已有 $unit 但系统报告 NTP 不可启用，仍尝试直接启用服务。"
    fi

    ui_section "将执行"
    if [[ -n "$pkg" ]]; then
        printf '  %s+%s 安装软件包 %s%s%s 并刷新软件源缓存\n' \
            "$C_GREEN" "$C_RESET" "$C_BOLD" "$pkg" "$C_RESET"
    fi
    printf '  %s*%s 启用并启动校时服务\n' "$C_GREEN" "$C_RESET"
    printf '  %s*%s 打开 NTP 自动校时开关\n' "$C_GREEN" "$C_RESET"

    ui_section "不受影响"
    printf '  %s系统时区与 %s 一律不动%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"
    printf '  %s只新增依赖，不卸载任何已有软件%s\n' "$C_DIM" "$C_RESET"
    printf '\n  %s首次同步可能需要十几秒；出站 UDP 123 被挡时无法同步。%s\n' \
        "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    # ---- 执行 ----
    module_begin "执行"
    if [[ -n "$pkg" ]]; then
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install "$pkg"; then
            log_warn "$pkg 安装失败，改试 chrony ..."
            pkg='chrony'
            if ! pkg_install "$pkg"; then
                log_err "systemd-timesyncd 与 chrony 都装不上，请手动安装后重试。"
                module_end
                return 1
            fi
        fi
        unit="$(_time_ntp_unit || true)"
        if [[ -z "$unit" ]]; then
            log_err "软件包装上了但找不到校时服务单元，请手动检查。"
            module_end
            return 1
        fi
        log_ok "已安装 $pkg（服务单元 $unit）"
    fi

    # timedated 在自己启动时就把「系统里有哪些校时服务」查好并缓存了，
    # 之后新装的包它并不知道。实测（systemd 257）：装完 systemd-timesyncd，
    # 单元已 enabled+active，CanNTP 却仍是 no，set-ntp true 直接返回
    # "NTP not supported"；重启 systemd-timedated 后立刻变 yes 并成功。
    # 不处理这条，「缺服务 → 装一个 → 启用」这个最常见的场景就会
    # 「装成功了但启用失败」，还得用户重启机器才能好。
    if [[ -n "$unit" && "$can" != "yes" ]]; then
        log_info "让 systemd 重新识别校时服务（重启 systemd-timedated）"
        systemctl restart systemd-timedated >/dev/null 2>&1 || true
        can="$(_time_td_get CanNTP)"
        log_debug "刷新后 CanNTP=$can"
    fi

    if ! timedatectl set-ntp true 2>/dev/null; then
        log_warn "timedatectl set-ntp 失败，改用直接启用服务..."
        if ! systemctl enable --now "$unit.service" >/dev/null 2>&1; then
            log_err "启用 $unit 失败。"
            log_info "排查: systemctl status $unit.service"
            module_end
            return 1
        fi
    fi

    # ---- 验证 ----
    local i
    for (( i=0; i<10; i++ )); do
        ntp="$(_time_td_get NTP)"
        [[ "$ntp" == "yes" ]] && break
        sleep 0.5
    done
    if [[ "$ntp" != "yes" ]]; then
        log_err "启用后 NTP 状态仍是 ${ntp:-未知}，未生效。"
        log_info "排查: systemctl status $unit.service; journalctl -u $unit.service -n 30"
        module_end
        return 1
    fi
    log_ok "NTP 自动校时已启用（$unit）"

    printf '\n  %s等待首次同步（最多 %s 秒）' "$C_DIM" "$TIME_SYNC_WAIT"
    if _time_ntp_wait_sync; then
        log_ok "系统时钟已同步。"
    else
        # 不因为首次同步慢就回滚 —— 开 NTP 是配置变更，生效是异步的
        log_warn "等待 ${TIME_SYNC_WAIT} 秒仍未同步，这不代表失败。"
        log_info "常见原因: 出站 UDP 123 被防火墙挡住、网络不通、或首次同步尚未完成。"
        log_info "稍后可再看: timedatectl show -p NTPSynchronized"
    fi

    local srv
    srv="$(timedatectl show-timesync --property=ServerName --value 2>/dev/null)"
    [[ -n "$srv" ]] && ui_kv "同步服务器" "$srv"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    module_end
}

# 没有 systemd 的系统（Alpine/Devuan）：用 chrony + 系统自带 init
_time_ntp_on_nosystemd() {
    local pkg='chrony' need_install=0 ran=0

    have_cmd chronyd || need_install=1

    ui_section "当前状态"
    ui_kv "systemd" "未运行"
    if have_cmd chronyd; then
        ui_kv "chronyd" "已安装"
    else
        ui_kv "chronyd" "未安装"
    fi

    ui_section "将执行"
    if (( need_install )); then
        printf '  %s+%s 安装软件包 %s\n' "$C_GREEN" "$C_RESET" "$pkg"
    fi
    printf '  %s*%s 启动 chronyd 并设为开机自启\n' "$C_GREEN" "$C_RESET"

    ui_section "不受影响"
    printf '  %s系统时区与 %s 一律不动%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"

    printf '\n'
    if ! confirm "确认执行?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if (( need_install )); then
        pkg_refresh >/dev/null 2>&1 || true
        if ! pkg_install "$pkg"; then
            log_err "安装 $pkg 失败。"
            module_end
            return 1
        fi
    fi

    if have_cmd rc-update; then
        rc-update add chronyd default >/dev/null 2>&1 || log_warn "rc-update 设置自启失败"
        ran=1
    elif have_cmd update-rc.d; then
        update-rc.d chronyd defaults >/dev/null 2>&1 || log_warn "update-rc.d 设置自启失败"
        ran=1
    fi

    if have_cmd rc-service; then
        rc-service chronyd start >/dev/null 2>&1 || { log_err "启动 chronyd 失败。"; module_end; return 1; }
        ran=1
    elif have_cmd service; then
        service chronyd start >/dev/null 2>&1 || { log_err "启动 chronyd 失败。"; module_end; return 1; }
        ran=1
    fi

    if (( ! ran )); then
        log_warn "没找到可用的服务管理命令，chronyd 已安装但未启动。"
        log_info "请手动启动: rc-service chronyd start 或 service chronyd start"
        module_end
        return 1
    fi

    log_ok "chronyd 已启动并设为开机自启。"
    _time_chrony_offset
    module_end
    return 0
}

# chrony 量到的系统时钟偏移，能取到就打印一行（取不到就什么也不说）
_time_chrony_offset() {
    local off=''
    have_cmd chronyc || return 0
    off="$(chronyc tracking 2>/dev/null | awk -F': *' '/^System time/ { print $2 }')"
    [[ -n "$off" ]] && ui_kv "系统时钟偏移" "$off"
    return 0
}

# ============================================================
# 4) 关闭自动校时
# ============================================================
time_ntp_off() {
    require_root

    module_begin "关闭自动校时"

    local unit='' ntp='' i

    if ! _time_have_systemd; then
        _time_ntp_off_nosystemd
        return $?
    fi

    unit="$(_time_ntp_unit || true)"
    ntp="$(_time_td_get NTP)"

    ui_section "当前状态"
    ui_kv "NTP 已启用" "$ntp"
    ui_kv "校时服务" "${unit:-未安装}"

    if [[ "$ntp" != "yes" ]]; then
        log_info "NTP 自动校时本来就是关闭的，无需操作。"
        module_end
        return 0
    fi

    ui_section "将执行"
    printf '  %s-%s 停用并禁止开机自启校时服务\n' "$C_RED" "$C_RESET"
    printf '  %s-%s 关闭 NTP 自动校时开关\n' "$C_RED" "$C_RESET"

    ui_section "不会做的事"
    printf '  %s不卸载任何软件包%s\n' "$C_DIM" "$C_RESET"
    printf '  %s不改系统时区、不动 %s%s\n' "$C_DIM" "$TIME_LOCALTIME" "$C_RESET"
    printf '  %s不修改系统时间（当前时间会保持，只是不再自动校正）%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认关闭自动校时?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    timedatectl set-ntp false 2>/dev/null || log_warn "timedatectl set-ntp false 失败，改用直接停用服务"

    for (( i=0; i<10; i++ )); do
        ntp="$(_time_td_get NTP)"
        [[ "$ntp" == "no" ]] && break
        sleep 0.5
    done

    if [[ "$ntp" == "no" ]]; then
        # set-ntp false 通常已经停了服务；这里再兜一次，确保没有残留的自启
        [[ -n "$unit" ]] && systemctl disable --now "$unit.service" >/dev/null 2>&1
        log_ok "NTP 自动校时已关闭，系统时间保持当前值不再自动校正。"
    else
        log_warn "NTP 状态仍是 ${ntp:-未知}，可能没关干净。"
        log_info "排查: systemctl status ${unit:-systemd-timesyncd}.service"
    fi

    module_end
}

_time_ntp_off_nosystemd() {
    local stopped=0

    ui_section "当前状态"
    ui_kv "systemd" "未运行"

    if ! have_cmd chronyd; then
        log_info "系统里没有 chronyd，无需操作。"
        module_end
        return 0
    fi

    ui_section "将执行"
    printf '  %s-%s 停止 chronyd 并取消开机自启\n' "$C_RED" "$C_RESET"
    ui_section "不会做的事"
    printf '  %s不卸载软件包，不改时区%s\n' "$C_DIM" "$C_RESET"

    printf '\n'
    if ! confirm "确认关闭自动校时?" n; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行"
    if have_cmd rc-service; then
        rc-service chronyd stop >/dev/null 2>&1 && stopped=1
        have_cmd rc-update && rc-update del chronyd default >/dev/null 2>&1
    elif have_cmd service; then
        service chronyd stop >/dev/null 2>&1 && stopped=1
    fi

    if (( stopped )); then
        log_ok "chronyd 已停止并取消开机自启。"
    else
        log_warn "未能确认 chronyd 已停止，请手动检查。"
    fi
    module_end
}

# ============================================================
# 5) 立即校时
#
# 只用系统里已经配置好的客户端，不自己编造 NTP 服务器地址 ——
# 客户端已经知道自己该找谁（chrony.conf / timesyncd.conf），
# 我们另报一个服务器反而可能是不通的地址。
# ============================================================
time_ntp_sync() {
    require_root

    module_begin "立即校时"

    local unit='' how='' ok=0 before after

    unit="$(_time_ntp_unit || true)"

    if have_cmd chronyc && have_cmd chronyd; then
        how="chronyc makestep（chrony 立即步进）"
    elif [[ "$unit" == "systemd-timesyncd" ]]; then
        how="重启 systemd-timesyncd 触发同步"
    fi

    ui_section "同步前"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"

    if [[ -z "$how" ]]; then
        ui_section "无可用的校时客户端"
        ui_kv "chronyc" "$(have_cmd chronyc && echo 有 || echo 无)"
        if [[ -n "$unit" ]]; then
            ui_kv "校时服务" "$unit（不支持立即同步）"
        else
            ui_kv "校时服务" "未安装"
        fi
        log_warn "没有可以立即触发同步的客户端。"
        log_info "请先执行「开启自动校时」装上校时服务，再回来用本功能。"
        module_end
        return 1
    fi

    ui_section "将执行"
    printf '  %s*%s %s\n' "$C_GREEN" "$C_RESET" "$how"

    ui_section "不受影响"
    printf '  %s时区、NTP 开关状态、软件包一律不动%s\n' "$C_DIM" "$C_RESET"
    if [[ "$unit" == "systemd-timesyncd" ]]; then
        printf '  %s注意: systemd-timesyncd 没有一次性同步模式，它按自己的节奏走，%s\n' \
            "$C_DIM" "$C_RESET"
        printf '  %s      这里只是重启它并等一段时间，不保证立刻完成。%s\n' "$C_DIM" "$C_RESET"
    fi

    printf '\n'
    if ! confirm "确认立即校时?" y; then
        log_info "已取消，未做任何修改。"
        module_end
        return 0
    fi

    module_begin "执行校时"
    before="$(date +%s)"

    if have_cmd chronyc && have_cmd chronyd; then
        # 输出里有它实际量到的偏移，这是判断「真同步了还是没连上」的证据。
        # 先把输出收下来再判断退出码 —— 管道的退出码取的是最后一段
        # （sed 恒为 0），直接 if cmd | sed 会把失败当成成功。
        local out=''
        if out="$(chronyc makestep 2>&1)"; then
            ok=1
        else
            log_err "chronyc makestep 失败 —— 通常是 chronyd 没在跑。"
        fi
        [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/  /'
    else
        if systemctl restart systemd-timesyncd >/dev/null 2>&1; then
            printf '  %s等待同步（最多 %s 秒）' "$C_DIM" "$TIME_SYNC_WAIT"
            if _time_ntp_wait_sync; then
                ok=1
            else
                log_warn "重启后 ${TIME_SYNC_WAIT} 秒内未见同步完成。"
                log_info "可能是出站 UDP 123 被挡、网络不通，或首次同步还在进行。"
            fi
        else
            log_err "重启 systemd-timesyncd 失败。"
        fi
    fi

    after="$(date +%s)"

    ui_section "同步后"
    ui_kv "本地时间" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    ui_kv "UTC 时间" "$(date -u '+%Y-%m-%d %H:%M:%S')"
    ui_kv "本次耗时" "$(( after - before )) 秒"
    if _time_have_systemd; then
        ui_kv "已同步" "$(_time_td_get NTPSynchronized)"
    fi
    _time_chrony_offset

    printf '\n'
    if (( ok )); then
        log_ok "校时完成。"
    else
        log_warn "未确认同步成功，详见上面的说明。"
    fi

    module_end
    (( ok )) && return 0
    return 1
}

# ============================================================
# 模块入口
# ============================================================
menu_time() {
    local items=(
        "状态查看|时间 / 时区 / 校时服务状态，不做任何修改"
        "设置时区|常用列表或手动输入，改前预览确认"
        "开启自动校时|启用 NTP，缺少客户端时提示并安装"
        "关闭自动校时|停用 NTP 校时，不卸载软件包"
        "设置 NTP 服务器|自定义校时服务器，写前先探测可达性"
        "立即校时|用已配置的客户端强制同步一次"
    )
    local fns=(time_status time_set_tz time_ntp_on time_ntp_off time_ntp_server time_ntp_sync)
    run_submenu "时间与时区" items fns
}

register_module "time" "时间与时区" "menu_time" "时区设置 / NTP 自动校时"
