#!/bin/bash
###############################################################################
# deploy.sh — Разворачивает всё на сервере self-music.online
# Запуск: bash deploy.sh
###############################################################################

set -e

WEB="/var/www/self-music.online"

echo "=== Deploying VPN Router Package System ==="
echo ""

# ═══ 1. Директории ═══

echo "[1/5] Creating directories..."
mkdir -p "$WEB/router"
mkdir -p "$WEB/packages"
mkdir -p /root/vpn-scripts

echo "  OK"

# ═══ 2. Копируем файлы ═══

echo "[2/5] Copying files..."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# install.sh → корень сайта
cp "$SCRIPT_DIR/install.sh" "$WEB/install.sh"

# router/ — скрипты для роутера
for F in vpn-connect.sh vpn-agent.sh vpn-apply.sh vpn-agent.init \
         bypass_ips.txt bypass_domains.txt vpn.lua index.htm; do
    cp "$SCRIPT_DIR/router/$F" "$WEB/router/$F"
done

# build.sh — серверный скрипт
cp "$SCRIPT_DIR/scripts/build.sh" /root/vpn-scripts/build.sh
chmod +x /root/vpn-scripts/build.sh

echo "  OK"

# ═══ 3. Права ═══

echo "[3/5] Setting permissions..."
chmod +x "$WEB/router/"*.sh 2>/dev/null || true
chmod 644 "$WEB/install.sh"
chmod 644 "$WEB/router/"*.txt "$WEB/router/"*.lua "$WEB/router/"*.htm 2>/dev/null || true

echo "  OK"

# ═══ 4. Nginx ═══

echo "[4/5] Checking nginx..."

NGINX_CONF="/etc/nginx/sites-enabled/self-music.online"
[ ! -f "$NGINX_CONF" ] && NGINX_CONF="/etc/nginx/conf.d/self-music.online.conf"
[ ! -f "$NGINX_CONF" ] && NGINX_CONF=$(grep -rl "self-music.online" /etc/nginx/ 2>/dev/null | head -1)

if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
    NEEDS_RELOAD=0

    # Проверяем каждый location
    if ! grep -q 'location /router/' "$NGINX_CONF"; then
        echo "  Adding /router/ location..."
        # Вставляем перед последней закрывающей скобкой server блока
        sed -i '/^}/i\
    location /router/ {\
        alias /var/www/self-music.online/router/;\
    }' "$NGINX_CONF"
        NEEDS_RELOAD=1
    fi

    if ! grep -q 'location /packages/' "$NGINX_CONF"; then
        echo "  Adding /packages/ location..."
        sed -i '/^}/i\
    location /packages/ {\
        alias /var/www/self-music.online/packages/;\
        autoindex on;\
    }' "$NGINX_CONF"
        NEEDS_RELOAD=1
    fi

    if ! grep -q 'location = /install.sh' "$NGINX_CONF"; then
        echo "  Adding /install.sh location..."
        sed -i '/^}/i\
    location = /install.sh {\
        alias /var/www/self-music.online/install.sh;\
        default_type text/plain;\
    }' "$NGINX_CONF"
        NEEDS_RELOAD=1
    fi

    if [ $NEEDS_RELOAD -eq 1 ]; then
        nginx -t && nginx -s reload
        echo "  nginx reloaded"
    else
        echo "  nginx already configured"
    fi
else
    echo "  WARNING: nginx config not found"
    echo "  Add manually to your server block:"
    echo ""
    echo "    location /router/ {"
    echo "        alias /var/www/self-music.online/router/;"
    echo "    }"
    echo "    location /packages/ {"
    echo "        alias /var/www/self-music.online/packages/;"
    echo "        autoindex on;"
    echo "    }"
    echo "    location = /install.sh {"
    echo "        alias /var/www/self-music.online/install.sh;"
    echo "        default_type text/plain;"
    echo "    }"
fi

# ═══ 5. Собираем xray бинарники ═══

echo "[5/5] Building xray package repository..."

if command -v jq > /dev/null 2>&1 && command -v unzip > /dev/null 2>&1; then
    /root/vpn-scripts/build.sh v1.0.0 --force
else
    echo "  Installing jq and unzip..."
    apt-get install -y jq unzip > /dev/null 2>&1 || yum install -y jq unzip > /dev/null 2>&1 || true
    if command -v jq > /dev/null 2>&1; then
        /root/vpn-scripts/build.sh v1.0.0 --force
    else
        echo "  WARNING: jq not available — run manually:"
        echo "    /root/vpn-scripts/build.sh v1.0.0"
    fi
fi

# ═══ Проверка ═══

echo ""
echo "════════════════════════════════════════"
echo "  Deploy complete!"
echo "════════════════════════════════════════"
echo ""
echo "  Files:"
echo "    $WEB/install.sh"
echo "    $WEB/router/*"
echo "    $WEB/packages/latest/ → v1.0.0"
echo ""
echo "  Test:"
echo "    curl -sI https://self-music.online/install.sh"
echo "    curl -sI https://self-music.online/router/vpn-connect.sh"
echo "    curl -sI https://self-music.online/packages/latest/VERSION"
echo ""
echo "  On router:"
echo "    curl -sL https://self-music.online/install.sh | sh -s -- CODE"
echo ""
echo "════════════════════════════════════════"
