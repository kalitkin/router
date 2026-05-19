#!/bin/sh
# /opt/bin/keenetic-connect.sh — регистрация роутера по OTP-коду
# Usage: keenetic-connect.sh CODE [RCI_PASSWORD]
# Идемпотентен: повторный запуск перезапишет credentials

API="${VPN_API_URL:-https://self-music.online/vpnapi/v1/router}"
DIR="/opt/etc/vpn"
LOG="/opt/var/log/vpn-agent.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [connect] $*" | tee -a "$LOG"; }
die() { log "ERROR: $*"; exit 1; }

# ── Аргументы ─────────────────────────────────────────────────────────────────

CODE="$1"
RCI_PASS="${2:-}"

[ -z "$CODE" ] && {
    echo "Usage: keenetic-connect.sh CODE [RCI_PASSWORD]"
    echo "  CODE          — 6-значный код из Telegram"
    echo "  RCI_PASSWORD  — пароль admin роутера (необязательно, для получения модели)"
    exit 1
}

# Защита от command injection — только 6 цифр
case "$CODE" in
    [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) die "code must be exactly 6 digits, got: '$CODE'" ;;
esac

mkdir -p "$DIR" /opt/var/log

# ── MAC-адрес ─────────────────────────────────────────────────────────────────

get_mac() {
    # Сохранённый MAC имеет приоритет (стабильность идентификатора)
    if [ -f "$DIR/mac" ] && [ -s "$DIR/mac" ]; then
        cat "$DIR/mac"
        return
    fi

    for iface in eth0 eth1 br0 GigabitEthernet0 GigabitEthernet0/0; do
        f="/sys/class/net/$iface/address"
        [ -f "$f" ] || continue
        mac=$(cat "$f")
        case "$mac" in "00:00:00:00:00:00"|"") continue ;; esac
        echo "$mac"
        return
    done

    # Fallback: ip link — первый не-loopback ether
    ip link show 2>/dev/null | awk '/ether/ {print $2; exit}'
}

# ── Архитектура ───────────────────────────────────────────────────────────────
# Нужна для CDN xray: self-music.online/packages/latest/{ARCH}/xray

get_arch() {
    if command -v opkg > /dev/null 2>&1; then
        arch=$(opkg print-architecture 2>/dev/null | \
            awk '$1=="arch" && $3>=10 {print $2}' | \
            grep -v 'all\|noarch' | tail -1)
        [ -n "$arch" ] && { echo "$arch"; return; }
    fi

    case "$(uname -m)" in
        mips*)   echo "mipsel_24kc" ;;
        armv7*)  echo "arm_cortex-a7_neon-vfpv4" ;;
        aarch64) echo "aarch64_cortex-a53" ;;
        *)       echo "unknown" ;;
    esac
}

# ── Информация об устройстве ──────────────────────────────────────────────────
# Приоритет: RCI API → /proc/sys/keenetic/ → uname

get_device_info() {
    MODEL="Keenetic"
    HW_ID=""
    FW_VER="unknown"

    # /proc/sys/keenetic/ — доступно на некоторых версиях KeeneticOS
    [ -f /proc/sys/keenetic/model ]   && MODEL=$(cat /proc/sys/keenetic/model   2>/dev/null)
    [ -f /proc/sys/keenetic/hw-id ]   && HW_ID=$(cat /proc/sys/keenetic/hw-id   2>/dev/null)
    [ -f /proc/sys/keenetic/release ] && FW_VER=$(cat /proc/sys/keenetic/release 2>/dev/null)

    # RCI API точнее — перезаписываем если доступно
    if [ -n "$RCI_PASS" ]; then
        rci=$(curl -s -m 5 -u "admin:${RCI_PASS}" \
            "http://192.168.1.1/rci/show/version" 2>/dev/null)

        if [ -n "$rci" ]; then
            _rf() { printf '%s' "$rci" | grep -o "\"$1\":\"[^\"]*\"" | cut -d'"' -f4 | head -1; }
            rci_model=$(_rf model)
            rci_hwid=$(_rf hw-id)
            rci_fw=$(_rf release)
            [ -n "$rci_model" ] && MODEL="$rci_model"
            [ -n "$rci_hwid"  ] && HW_ID="$rci_hwid"
            [ -n "$rci_fw"    ] && FW_VER="$rci_fw"
        else
            log "WARN: RCI unreachable (wrong password or host?)"
        fi
    fi

    # Собираем строку модели: "Viva KN-1811" или просто "Keenetic"
    if [ -n "$HW_ID" ]; then
        FULL_MODEL="$MODEL $HW_ID"
    else
        FULL_MODEL="$MODEL"
    fi
}

# ── JSON get ──────────────────────────────────────────────────────────────────

json_get() {
    # $1 = поле, $RESP должен быть установлен
    printf '%s' "$RESP" | grep -o "\"$1\":\"[^\"]*\"" | cut -d'"' -f4 | head -1
}

# ── Атомарное сохранение файла ────────────────────────────────────────────────

save_file() {
    # $1 = имя файла в $DIR, $2 = содержимое
    printf '%s\n' "$2" > "$DIR/$1.tmp" && mv "$DIR/$1.tmp" "$DIR/$1"
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

MAC=$(get_mac)
[ -z "$MAC" ] && die "cannot determine MAC address"

ARCH=$(get_arch)
RAM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")

get_device_info

log "registering: code=$CODE mac=$MAC model='$FULL_MODEL' fw=$FW_VER arch=$ARCH ram=${RAM}MB"

# ── POST /register_by_code ────────────────────────────────────────────────────

RESP=$(curl -s -m 20 \
    -X POST "$API/register_by_code" \
    -H "Content-Type: application/json" \
    -d "{
      \"code\":     \"$CODE\",
      \"mac\":      \"$MAC\",
      \"model\":    \"$FULL_MODEL\",
      \"firmware\": \"$FW_VER\",
      \"ram_mb\":   \"$RAM\",
      \"arch\":     \"$ARCH\",
      \"type\":     \"keenetic\"
    }" 2>/dev/null)

[ -z "$RESP" ] && die "empty response from server (check internet connection)"

# ── Проверка ответа ───────────────────────────────────────────────────────────

if ! printf '%s' "$RESP" | grep -q '"device_id"'; then
    err=$(printf '%s' "$RESP" | grep -o '"detail":"[^"]*"' | cut -d'"' -f4)
    [ -z "$err" ] && err=$(printf '%s' "$RESP" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)
    [ -z "$err" ] && err="$RESP"
    die "registration failed: $err"
fi

# ── Парсинг ───────────────────────────────────────────────────────────────────

TOKEN=$(json_get token)
SECRET=$(json_get device_secret)
DEVICE_ID=$(json_get device_id)
CONFIG=$(json_get config)

[ -z "$TOKEN" ]     && die "token missing in server response"
[ -z "$DEVICE_ID" ] && die "device_id missing in server response"

# ── Сохранение credentials ────────────────────────────────────────────────────

save_file token     "$TOKEN"
save_file secret    "$SECRET"
save_file device_id "$DEVICE_ID"
save_file mac       "$MAC"
save_file arch      "$ARCH"

# RCI-пароль — только если передан
[ -n "$RCI_PASS" ] && save_file rci_password "$RCI_PASS"

# Секретные файлы — только для root
chmod 600 "$DIR/token" "$DIR/secret" 2>/dev/null
[ -f "$DIR/rci_password" ] && chmod 600 "$DIR/rci_password"

log "registered OK: device_id=$DEVICE_ID"

# ── Конфиг пришёл сразу? ──────────────────────────────────────────────────────

if [ -n "$CONFIG" ] && [ "$CONFIG" != "null" ] && [ "$CONFIG" != "" ]; then
    save_file config "$CONFIG"
    log "config received immediately ($(printf '%s' "$CONFIG" | wc -c) bytes) — applying..."
    sh /opt/bin/keenetic-apply.sh >> "$LOG" 2>&1 &
    APPLY_PID=$!
    log "apply started (pid=$APPLY_PID)"
else
    log "no config yet — agent will poll /config_by_mac"
fi

# ── Запуск/перезапуск агента ──────────────────────────────────────────────────

if [ -f /opt/etc/init.d/S99vpn-agent ]; then
    /opt/etc/init.d/S99vpn-agent stop  2>/dev/null
    /opt/etc/init.d/S99vpn-agent start
    log "agent started via init.d"
elif [ -f /opt/bin/keenetic-agent.sh ]; then
    # Entware init.d ещё не настроен — запустить напрямую
    pkill -f keenetic-agent.sh 2>/dev/null
    sleep 1
    sh /opt/bin/keenetic-agent.sh >> "$LOG" 2>&1 &
    log "agent started (pid=$!, background)"
else
    log "WARN: agent script not found — start manually: sh /opt/bin/keenetic-agent.sh"
fi

echo "OK: registered as $DEVICE_ID"
exit 0
