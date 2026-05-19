#!/bin/bash
###############################################################################
# deploy-keenetic.sh — деплой Keenetic VPN-агента на сервер
#
# Запуск на сервере:
#   cd /root/router && git pull && bash files/deploy-keenetic.sh
#
# Что делает:
#   1. Копирует скрипты в /var/www/self-music.online/keenetic/ (атомарно)
#   2. Генерирует manifest.txt (sha256 + size для integrity check на роутере)
#   3. Прописывает nginx location /keenetic/ если ещё нет
###############################################################################

set -e

WEB="/var/www/self-music.online"
DST="$WEB/keenetic"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/../keenetic-lab/scripts"

echo "=== Keenetic Deploy ==="
echo "Источник : $SRC"
echo "Цель     : $DST"
echo ""

# ── Проверки ──────────────────────────────────────────────────────────────────

[ -d "$SRC" ] || { echo "ERROR: $SRC не найден — запустите из корня репозитория"; exit 1; }

for f in keenetic-connect.sh keenetic-apply.sh keenetic-agent.sh S99vpn-agent install.sh; do
    [ -f "$SRC/$f" ] || { echo "ERROR: $SRC/$f не найден"; exit 1; }
done

# ── 1. Директория ─────────────────────────────────────────────────────────────

echo "[1/3] Директории..."
mkdir -p "$DST"
echo "  OK: $DST"

# ── 2. Файлы (атомарно: tmp → mv) ─────────────────────────────────────────────

echo "[2/3] Копирование файлов..."

copy_atomic() {
    local src="$1" dst="$2"
    cp "$src" "${dst}.tmp"
    mv "${dst}.tmp" "$dst"
    echo "  → $(basename "$dst")"
}

for f in keenetic-connect.sh keenetic-apply.sh keenetic-agent.sh S99vpn-agent install.sh; do
    copy_atomic "$SRC/$f" "$DST/$f"
done

chmod +x "$DST/keenetic-connect.sh" "$DST/keenetic-apply.sh" \
         "$DST/keenetic-agent.sh"   "$DST/S99vpn-agent" \
         "$DST/install.sh"

# ── Manifest ──────────────────────────────────────────────────────────────────

echo "  Генерируем manifest.txt..."
{
    echo "# sha256  size  filename"
    echo "# generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for f in keenetic-connect.sh keenetic-apply.sh keenetic-agent.sh S99vpn-agent install.sh; do
        sha256=$(sha256sum "$DST/$f" | cut -d' ' -f1)
        size=$(wc -c < "$DST/$f")
        printf '%s  %d  %s\n' "$sha256" "$size" "$f"
    done
} > "$DST/manifest.txt.tmp"
mv "$DST/manifest.txt.tmp" "$DST/manifest.txt"

echo "  manifest.txt:"
grep -v '^#' "$DST/manifest.txt" | while read -r hash size name; do
    printf "    %-20s %6d bytes  %.16s...\n" "$name" "$size" "$hash"
done

# ── 3. Nginx ──────────────────────────────────────────────────────────────────

echo "[3/3] Nginx..."

NGINX_CONF=""
for F in /etc/nginx/sites-enabled/self-music.online \
         /etc/nginx/conf.d/self-music.online.conf; do
    [ -f "$F" ] && { NGINX_CONF="$F"; break; }
done
[ -z "$NGINX_CONF" ] && \
    NGINX_CONF=$(grep -rl "self-music.online" /etc/nginx/ 2>/dev/null | head -1 || true)

if [ -n "$NGINX_CONF" ] && [ -f "$NGINX_CONF" ]; then
    if ! grep -q "location /keenetic/" "$NGINX_CONF"; then
        sed -i "/^}/i\\    location /keenetic/ { alias ${DST}/; }" "$NGINX_CONF"
        nginx -t && nginx -s reload
        echo "  Добавлен location /keenetic/ и nginx перезагружен"
    else
        echo "  location /keenetic/ уже есть"
        nginx -t && nginx -s reload
        echo "  nginx перезагружен"
    fi
else
    echo "  WARN: nginx конфиг не найден, добавьте вручную:"
    echo ""
    echo "    location /keenetic/ { alias ${DST}/; }"
    echo ""
fi

# ── Итого ─────────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  Готово!"
echo ""
echo "  Проверка:"
echo "    curl -sI https://self-music.online/keenetic/install.sh"
echo "    curl -s  https://self-music.online/keenetic/manifest.txt"
echo ""
echo "  Установка на роутере:"
echo "    curl -fsSL https://self-music.online/keenetic/install.sh | sh"
echo ""
echo "  После установки — регистрация:"
echo "    sh /opt/bin/keenetic-connect.sh XXXXXX"
echo "═══════════════════════════════════════════"
