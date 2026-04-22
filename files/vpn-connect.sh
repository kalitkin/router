#!/bin/sh
# /usr/bin/vpn-connect.sh — регистрация роутера по коду из Telegram
# Usage: vpn-connect.sh CODE
# Идемпотентный: безопасно запускать повторно

API="https://self-music.online/vpnapi/v1/router"
DIR="/etc/vpn"
LOG="/tmp/vpn.log"
PROG=/tmp/vpn-progress

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [connect] $1" >> "$LOG"; echo "$1"; }
progress() { printf '{"stage":"%s","pct":%d,"msg":"%s"}' "$1" "$2" "$3" > "$PROG"; }

CODE="$1"
if [ -z "$CODE" ]; then
    log "ERROR: usage: vpn-connect.sh CODE"
    exit 1
fi

# Валидация кода — ТОЛЬКО 6 цифр (защита от injection)
case "$CODE" in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *)
        log "ERROR: code must be exactly 6 digits, got: $CODE"
        exit 1
        ;;
esac

# Получаем MAC
MAC=""
for IFACE in br-lan eth0 wan; do
    [ -f "/sys/class/net/$IFACE/address" ] && {
        MAC=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null)
        break
    }
done
# fallback через ifconfig
[ -z "$MAC" ] && MAC=$(ifconfig br-lan 2>/dev/null | grep -o '[0-9a-f:]\{17\}' | head -1)

if [ -z "$MAC" ]; then
    log "ERROR: cannot detect MAC address"
    exit 1
fi

MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "OpenWrt")
FW=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d"'" -f2 || echo "unknown")
RAM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

log "Registering: code=$CODE mac=$MAC model=$MODEL fw=$FW ram=${RAM}MB"
progress "connecting" 20 "Регистрируем роутер..."

mkdir -p "$DIR"

# Регистрация
RESP=$(curl -s -m 20 -X POST "$API/register_by_code" \
    -H "Content-Type: application/json" \
    -d "{\"code\":\"$CODE\",\"mac\":\"$MAC\",\"model\":\"$MODEL\",\"firmware\":\"$FW\",\"ram_mb\":\"$RAM\"}")

if [ -z "$RESP" ]; then
    log "ERROR: empty response from server (network issue?)"
    exit 1
fi

# Проверяем ответ — ищем device_id
echo "$RESP" | grep -q '"device_id"'
if [ $? -ne 0 ]; then
    # Ошибка — парсим detail
    ERROR=""
    if command -v jsonfilter > /dev/null 2>&1; then
        ERROR=$(echo "$RESP" | jsonfilter -e '@.detail' 2>/dev/null)
    fi
    [ -z "$ERROR" ] && ERROR=$(echo "$RESP" | grep -o '"detail":"[^"]*"' | cut -d'"' -f4)
    [ -z "$ERROR" ] && ERROR="$RESP"
    log "ERROR: registration failed: $ERROR"
    progress "error" 0 "$ERROR"
    echo "FAIL: $ERROR"
    exit 1
fi

# Парсим ответ
TOKEN="" ; SECRET="" ; DEVICE_ID="" ; CONFIG=""
if command -v jsonfilter > /dev/null 2>&1; then
    TOKEN=$(echo "$RESP" | jsonfilter -e '@.token' 2>/dev/null)
    SECRET=$(echo "$RESP" | jsonfilter -e '@.device_secret' 2>/dev/null)
    DEVICE_ID=$(echo "$RESP" | jsonfilter -e '@.device_id' 2>/dev/null)
    CONFIG=$(echo "$RESP" | jsonfilter -e '@.config' 2>/dev/null)
else
    TOKEN=$(echo "$RESP" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
    SECRET=$(echo "$RESP" | grep -o '"device_secret":"[^"]*"' | cut -d'"' -f4)
    DEVICE_ID=$(echo "$RESP" | grep -o '"device_id":"[^"]*"' | cut -d'"' -f4)
    CONFIG=$(echo "$RESP" | grep -o '"config":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$TOKEN" ]; then
    log "ERROR: token is empty in response"
    log "DEBUG: RESP=$RESP"
    exit 1
fi

# Сохраняем credentials (атомарно: пишем в .tmp, потом mv)
echo "$TOKEN" > "$DIR/token.tmp" && mv "$DIR/token.tmp" "$DIR/token"
echo "$SECRET" > "$DIR/secret.tmp" && mv "$DIR/secret.tmp" "$DIR/secret"
echo "$DEVICE_ID" > "$DIR/device_id.tmp" && mv "$DIR/device_id.tmp" "$DIR/device_id"
echo "$MAC" > "$DIR/mac"
chmod 600 "$DIR/token" "$DIR/secret"

log "OK: registered device_id=$DEVICE_ID"
progress "connecting" 60 "Регистрация успешна..."

# Если конфиг пришёл сразу — сохраняем и применяем
if [ -n "$CONFIG" ] && [ "$CONFIG" != "null" ] && [ "$CONFIG" != "" ]; then
    echo "$CONFIG" > "$DIR/config.tmp" && mv "$DIR/config.tmp" "$DIR/config"
    log "OK: config received immediately, applying..."
    progress "connecting" 70 "Применяем конфиг..."
    /usr/bin/vpn-apply.sh 2>>"$LOG" &
else
    progress "ready" 100 ""
    log "OK: no config yet, agent will poll for it"
fi

# Запускаем/рестартим агент
if [ -f /etc/init.d/vpn-agent ]; then
    /etc/init.d/vpn-agent enable 2>/dev/null
    /etc/init.d/vpn-agent restart 2>/dev/null
    log "OK: agent started"
else
    log "WARNING: /etc/init.d/vpn-agent not found"
fi

echo "OK"
exit 0
