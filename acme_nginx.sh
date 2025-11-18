#!/usr/bin/env bash
set -euo pipefail

export ACME_DNS=
export CF_Token=
export CF_Account_ID=


NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_SSL_BASE="/etc/nginx/ssl"

# 尝试找到 acme.sh
find_acme() {
    if command -v acme.sh >/dev/null 2>&1; then
        echo "acme.sh"
    elif [ -x "${HOME}/.acme.sh/acme.sh" ]; then
        echo "${HOME}/.acme.sh/acme.sh"
    elif [ -x "/root/.acme.sh/acme.sh" ]; then
        echo "/root/.acme.sh/acme.sh"
    else
        echo ""
    fi
}

ACME_BIN="$(find_acme)"

if [ "$#" -lt 1 ]; then
    echo "用法："
    echo "  $0 create <saas_custom_host> <origin_domain> <port>"
    echo "  $0 list"
    exit 1
fi

ACTION="$1"

# =========================
# 功能一：列出 server_name 和 proxy_pass 端口
# =========================
if [ "$ACTION" = "list" ]; then
    echo "=== 列出 Nginx 配置中的 server_name 和反向代理端口 (基于 ${NGINX_SITES_AVAILABLE}) ==="
    shopt -s nullglob
    for f in "${NGINX_SITES_AVAILABLE}"/*.conf; do
        echo
        echo "文件: $f"
        # 抽取 server_name
        awk '
            $1 == "server_name" {
                line = $0
                sub(/server_name[[:space:]]+/, "", line)
                sub(/;/, "", line)
                gsub(/[[:space:]]+/, " ", line)
                print "  server_name: " line
            }
            $1 == "proxy_pass" && $2 ~ /127\.0\.0\.1:[0-9]+/ {
                # 形如 proxy_pass http://127.0.0.1:9001;
                match($2, /127\.0\.0\.1:([0-9]+)/, m)
                if (m[1] != "") {
                    print "  proxy_pass port: " m[1]
                }
            }
        ' "$f"
    done
    exit 0
fi

# =========================
# 功能二：创建新站点
# =========================
if [ "$ACTION" != "create" ]; then
    echo "未知动作：$ACTION"
    echo "用法："
    echo "  $0 create <saas_custom_host> <origin_domain> <port>"
    echo "  $0 list"
    exit 1
fi

if [ "$#" -ne 4 ]; then
    echo "create 模式需要三个参数："
    echo "  $0 create <saas_custom_host> <origin_domain> <port>"
    exit 1
fi

SAAS_CUSTOM_HOST="$2"  # 只写 server_name，不申请证书
ORIGIN_DOMAIN="$3"     # 需要申请证书 + server_name
BACKEND_PORT="$4"      # 反向代理端口

if [ -z "$ACME_BIN" ]; then
    echo "错误：未找到 acme.sh，请先安装 acme.sh 再运行此脚本。"
    echo "示例安装："
    echo "  curl https://get.acme.sh | sh"
    exit 1
fi

"$ACME_BIN" --set-default-ca --server letsencrypt

echo "==> 使用参数："
echo "  SaaS 自定义主机名: $SAAS_CUSTOM_HOST"
echo "  回源 / 默认域名:   $ORIGIN_DOMAIN"
echo "  反向代理端口:      $BACKEND_PORT"
echo

# 证书目标目录
SSL_DIR="${NGINX_SSL_BASE}/${ORIGIN_DOMAIN}"
SSL_KEY="${SSL_DIR}/privkey.pem"
SSL_FULLCHAIN="${SSL_DIR}/fullchain.pem"

mkdir -p "${SSL_DIR}"

# =========================
# 1. 使用 acme.sh 申请/续期证书（仅 origin_domain）
# =========================

echo "==> 为域名 ${ORIGIN_DOMAIN} 申请/续期证书（使用 acme.sh）"

ISSUE_CMD=()

if [ -n "${ACME_DNS-}" ]; then
    echo "检测到 ACME_DNS=${ACME_DNS}，使用 DNS API 方式签发证书"
    ISSUE_CMD=("$ACME_BIN" --issue --dns "$ACME_DNS" -d "$ORIGIN_DOMAIN")
else
    echo "未设置 ACME_DNS，使用 standalone 模式签发证书（将临时占用80端口）"
    ISSUE_CMD=("$ACME_BIN" --issue --standalone -d "$ORIGIN_DOMAIN")
fi

# 执行签发
"${ISSUE_CMD[@]}"

echo "==> 安装证书到 ${SSL_DIR}"

"$ACME_BIN" --install-cert -d "$ORIGIN_DOMAIN" \
  --key-file       "$SSL_KEY" \
  --fullchain-file "$SSL_FULLCHAIN" \
  --reloadcmd      "nginx -s reload || systemctl reload nginx || service nginx reload"


# =========================
# 2. 生成 Nginx 配置文件
# =========================
mkdir -p "$NGINX_SITES_AVAILABLE" "$NGINX_SITES_ENABLED"

NGINX_CONF="${NGINX_SITES_AVAILABLE}/${ORIGIN_DOMAIN}.conf"

echo "==> 生成 Nginx 配置: ${NGINX_CONF}"

cat > "$NGINX_CONF" <<EOF
# 自动生成的 Nginx 配置
# SaaS 自定义主机名: ${SAAS_CUSTOM_HOST} （仅 server_name，不独立证书）
# 回源 / 默认域名:   ${ORIGIN_DOMAIN} （使用 acme.sh 签发的证书）
# 反向代理端口:      ${BACKEND_PORT}

# 80端口：统一跳转到 HTTPS
server {
    listen 80;
    server_name ${SAAS_CUSTOM_HOST} ${ORIGIN_DOMAIN};

    return 301 https://\$host\$request_uri;
}

# 443端口：HTTPS + 反向代理到本机 ${BACKEND_PORT}
server {
    listen 443 ssl;
    http2 on;
    server_name ${SAAS_CUSTOM_HOST} ${ORIGIN_DOMAIN};

    # SSL 证书（由 acme.sh 管理）
    ssl_certificate     ${SSL_FULLCHAIN};
    ssl_certificate_key ${SSL_KEY};

    # 反向代理到后端服务
    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};

        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
EOF

# =========================
# 3. 自动 ln -s 到 sites-enabled
# =========================
echo "==> 创建软链接到 ${NGINX_SITES_ENABLED}"

ln -sf "$NGINX_CONF" "${NGINX_SITES_ENABLED}/${ORIGIN_DOMAIN}.conf"

# =========================
# 4. 检查 Nginx 配置并重载
# =========================
echo "==> 检查 Nginx 配置语法"
nginx -t

echo "==> 重载 Nginx"
if systemctl is-active nginx >/dev/null 2>&1; then
    systemctl reload nginx
elif service nginx status >/dev/null 2>&1; then
    service nginx reload
else
    nginx -s reload
fi

echo "==> 完成。"
echo "  - Nginx 配置: ${NGINX_CONF}"
echo "  - server_name: ${SAAS_CUSTOM_HOST} ${ORIGIN_DOMAIN}"
echo "  - proxy_pass:  http://127.0.0.1:${BACKEND_PORT}"
echo "  - 证书路径:    ${SSL_FULLCHAIN} / ${SSL_KEY}"
