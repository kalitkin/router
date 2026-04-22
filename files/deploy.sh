#!/bin/bash
###############################################################################
# deploy.sh — разворачивает всё на сервере self-music.online
#
# Первый запуск:
#   git clone https://github.com/kalitkin/router.git /root/router
#   bash /root/router/files/deploy.sh
#
# Обновление:
#   cd /root/router && git pull && bash files/deploy.sh
###############################################################################

set -e

WEB="/var/www/self-music.online"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== VPN Bot Deploy ==="
echo "Источник: $SCRIPT_DIR"
echo "Цель:     $WEB"
echo ""

# ═══ 1. Директории ═══

echo "[1/5] Директории..."
mkdir -p "$WEB/router" "$WEB/packages" /root/vpn-scripts
echo "  OK"

# ═══ 2. Файлы ═══

echo "[2/5] Копирование файлов..."

cp "$SCRIPT_DIR/install.sh" "$WEB/install.sh"
chmod 644 "$WEB/install.sh"

for F in vpn-connect.sh vpn-agent.sh vpn-apply.sh vpn-agent.init \
         bypass_ips.txt bypass_domains.txt vpn.lua index.htm; do
    cp "$SCRIPT_DIR/$F" "$WEB/router/$F"
done

chmod +x "$WEB/router/"*.sh "$WEB/router/"*.init 2>/dev/null || true
chmod 644 "$WEB/router/"*.txt "$WEB/router/"*.lua "$WEB/router/"*.htm 2>/dev/null || true

cp "$SCRIPT_DIR/build.sh" /root/vpn-scripts/build.sh
chmod +x /root/vpn-scripts/build.sh

echo "  OK"

# ═══ 3. IPK ═══

echo "[3/5] IPK..."

IPK_SRC=""
for P in "$SCRIPT_DIR/../luci-app-vpnbot_"*r2*.ipk \
         "$SCRIPT_DIR/../luci-app-vpnbot_"*.ipk \
         /tmp/router.ipk; do
    # убираем glob-незакрытые пути
    [ -f "$P" ] && { IPK_SRC="$P"; break; }
done

if [ -n "$IPK_SRC" ]; then
    cp "$IPK_SRC" "$WEB/router.ipk"
    chmod 644 "$WEB/router.ipk"
    echo "  Скопирован: $(basename "$IPK_SRC")"
else
    echo "  WARNING: IPK не найден — загрузите вручную:"
    echo "    scp luci-app-vpnbot_*r2*.ipk root@self-music.online:$WEB/router.ipk"
fi

# ═══ 4. Nginx ═══

echo "[4/5] Nginx..."

NGINX_CONF=""
for F in /etc/nginx/sites-enabled/self-music.online \
         /etc/nginx/conf.d/self-music.online.conf; do
    [ -f "$F" ] && { NGINX_CONF="$F"; break; }
done
[ -z "$NGINX_CONF" ] && \
    NGINX_CONF=$(grep -rl "self-music.online" /etc/nginx/ 2>/dev/null | head -1)

if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
    RELOAD=0

    try_add() {
        grep -q "$1" "$NGINX_CONF" && return
        sed -i "/^}/i\\    $2" "$NGINX_CONF"
        RELOAD=1
        echo "  Добавлен: $1"
    }

    try_add 'location /router/'    'location /router/ { alias /var/www/self-music.online/router/; }'
    try_add 'location /packages/'  'location /packages/ { alias /var/www/self-music.online/packages/; autoindex on; }'
    try_add 'location = /install'  'location = /install.sh { alias /var/www/self-music.online/install.sh; default_type text/plain; }'
    try_add 'location = /router.ipk' 'location = /router.ipk { alias /var/www/self-music.online/router.ipk; }'

    if [ $RELOAD -eq 1 ]; then
        nginx -t && nginx -s reload && echo "  nginx перезагружен"
    else
        echo "  nginx уже настроен"
    fi
else
    echo "  WARNING: nginx конфиг не найден, добавьте вручную:"
    cat << 'HINT'

    location /router/        { alias /var/www/self-music.online/router/; }
    location /packages/      { alias /var/www/self-music.online/packages/; autoindex on; }
    location = /install.sh   { alias /var/www/self-music.online/install.sh; default_type text/plain; }
    location = /router.ipk   { alias /var/www/self-music.online/router.ipk; }

HINT
fi

# ═══ 5. Xray бинарники ═══

echo "[5/5] Xray репозиторий..."

if ! command -v jq > /dev/null 2>&1 || ! command -v unzip > /dev/null 2>&1; then
    echo "  Устанавливаем jq/unzip..."
    apt-get install -y jq unzip > /dev/null 2>&1 || \
        yum install -y jq unzip > /dev/null 2>&1 || true
fi

if command -v jq > /dev/null 2>&1; then
    /root/vpn-scripts/build.sh v1.0.0 --force
else
    echo "  WARNING: jq не установлен, запустите вручную:"
    echo "    /root/vpn-scripts/build.sh v1.0.0"
fi

# ═══ Итого ═══

echo ""
echo "════════════════════════════════════════"
echo "  Готово!"
echo ""
echo "  Проверка:"
echo "    curl -sI https://self-music.online/router.ipk"
echo "    curl -sI https://self-music.online/install.sh"
echo "    curl -sI https://self-music.online/router/vpn-connect.sh"
echo ""
echo "  Установка на роутере:"
echo "    opkg install https://self-music.online/router.ipk"
echo ""
echo "  Или через curl:"
echo "    curl -sL https://self-music.online/install.sh | sh -s -- КОД"
echo "════════════════════════════════════════"
