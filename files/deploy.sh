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

echo "[1/4] Директории..."
mkdir -p "$WEB/router" "$WEB/packages"
echo "  OK"

# ═══ 2. Файлы ═══

echo "[2/4] Копирование файлов..."

for F in vpn-connect.sh vpn-bootstrap.sh; do
    install -m 755 "$SCRIPT_DIR/$F" "$WEB/router/$F"
done

for F in bypass_ips.txt bypass_domains.txt vpn.lua index.htm; do
    install -m 644 "$SCRIPT_DIR/$F" "$WEB/router/$F"
done

for BPFILE in bypass_ips.txt bypass_domains.txt; do
    sha256sum "$WEB/router/$BPFILE" | cut -d' ' -f1 > "$WEB/router/${BPFILE}.sha256"
    chmod 644 "$WEB/router/${BPFILE}.sha256"
done

# Keenetic one-command installer and scripts
mkdir -p "$WEB/router/keenetic"
install -m 755 "$SCRIPT_DIR/keenetic-install.sh"     "$WEB/router/keenetic-install.sh"
install -m 755 "$SCRIPT_DIR/S99vpnd"                  "$WEB/router/keenetic/S99vpnd"
install -m 755 "$SCRIPT_DIR/sing-box-init"             "$WEB/router/keenetic/sing-box-init"
install -m 755 "$SCRIPT_DIR/vpn-connect-keenetic.sh"  "$WEB/router/keenetic/vpn-connect.sh"

echo "  OK"

# ═══ 3. IPK ═══

echo "[3/4] IPK..."

IPK_SRC=""
if [ "${SKIP_IPK_BUILD:-0}" = "1" ] && [ -f /tmp/router.ipk ]; then
    IPK_SRC=/tmp/router.ipk
else
    for P in "$SCRIPT_DIR/../luci-app-vpnbot_"*.ipk /tmp/router.ipk; do
        [ -f "$P" ] && { IPK_SRC="$P"; break; }
    done
fi

if [ -n "$IPK_SRC" ]; then
    install -m 644 "$IPK_SRC" "$WEB/router.ipk"
    echo "  Скопирован: $(basename "$IPK_SRC") ($(du -sh "$WEB/router.ipk" | cut -f1))"
else
    echo "  WARNING: IPK не найден — загрузите вручную:"
    echo "    scp luci-app-vpnbot_*.ipk root@self-music.online:$WEB/router.ipk"
fi

# ═══ 4. Nginx ═══

echo "[4/4] Nginx..."

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

    try_add 'location /router/'      'location /router/ { alias /var/www/self-music.online/router/; }'
    try_add 'location /packages/'    'location /packages/ { alias /var/www/self-music.online/packages/; autoindex on; }'
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
    location = /router.ipk   { alias /var/www/self-music.online/router.ipk; }

HINT
fi

# ═══ Итого ═══

echo ""
echo "════════════════════════════════════════"
echo "  Готово!"
echo ""
echo "  Проверка:"
echo "    curl -sI https://self-music.online/router.ipk"
echo "    curl -sI https://self-music.online/packages/latest/armv7/vpnd"
echo ""
echo "  Установка на роутере:"
echo "    opkg install https://self-music.online/router.ipk"
echo "════════════════════════════════════════"
