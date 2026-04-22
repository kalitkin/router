#!/bin/sh
# /usr/bin/vpn-apply.sh — применяет VPN конфиг на роутере
# Поддерживает: PassWall, PassWall2, raw xray
# ИДЕМПОТЕНТНЫЙ: не рестартит если конфиг не изменился и VPN работает

DIR="/etc/vpn"
LOG="/tmp/vpn.log"
APPLIED_HASH_FILE="$DIR/applied_hash"
BYPASS_IPS="$DIR/bypass_ips.txt"
BYPASS_DOMAINS="$DIR/bypass_domains.txt"
BYPASS_URL_IPS="https://self-music.online/router/bypass_ips.txt"
BYPASS_URL_DOMAINS="https://self-music.online/router/bypass_domains.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [apply] $1" >> "$LOG"; }

CONFIG_FILE="$DIR/config"

if [ ! -f "$CONFIG_FILE" ] || [ ! -s "$CONFIG_FILE" ]; then
    log "no config file — nothing to apply"
    exit 1
fi

CONFIG=$(cat "$CONFIG_FILE")

# ═══════════════════════════════════════════════════
#  Утилиты
# ═══════════════════════════════════════════════════

vpn_is_running() {
    pgrep -f "xray" > /dev/null 2>&1 && return 0
    pgrep -f "v2ray" > /dev/null 2>&1 && return 0
    pgrep -f "sing-box" > /dev/null 2>&1 && return 0
    return 1
}

find_passwall() {
    # Проверяем наличие config файла И init.d скрипта
    if [ -f /etc/config/passwall ] && [ -f /etc/init.d/passwall ]; then
        echo "passwall"; return 0
    fi
    if [ -f /etc/config/passwall2 ] && [ -f /etc/init.d/passwall2 ]; then
        echo "passwall2"; return 0
    fi
    return 1
}

find_xray() {
    # Ищем xray в нескольких местах
    for P in /usr/bin/xray /opt/xray/xray /usr/local/bin/xray; do
        [ -x "$P" ] && { echo "$P"; return 0; }
    done
    command -v xray >/dev/null 2>&1 && { which xray; return 0; }
    return 1
}

# md5sum хеш конфига для проверки "уже применено"
config_hash() {
    if command -v md5sum > /dev/null 2>&1; then
        echo "$CONFIG" | md5sum | cut -d' ' -f1
    else
        # fallback: первые 32 символа + длина
        echo "${CONFIG}" | wc -c
    fi
}

get_ram_mb() {
    RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -n "$RAM_KB" ] && [ "$RAM_KB" -gt 0 ] 2>/dev/null; then
        echo $((RAM_KB / 1024))
    else
        echo 128
    fi
}

# ═══════════════════════════════════════════════════
#  Проверка: уже применено?
# ═══════════════════════════════════════════════════

HASH=$(config_hash)
if [ -f "$APPLIED_HASH_FILE" ]; then
    OLD_HASH=$(cat "$APPLIED_HASH_FILE" 2>/dev/null)
    if [ "$HASH" = "$OLD_HASH" ] && vpn_is_running; then
        log "config unchanged (hash=$HASH) and VPN running — SKIP"
        exit 0
    fi
fi

log "applying config (hash=$HASH): $(echo "$CONFIG" | head -c 60)..."

# ═══════════════════════════════════════════════════
#  Bypass-списки
# ═══════════════════════════════════════════════════

download_bypass_lists() {
    # Только если файлов нет или они старше 24ч
    NEED_DOWNLOAD=0
    for F in "$BYPASS_IPS" "$BYPASS_DOMAINS"; do
        if [ ! -f "$F" ] || [ ! -s "$F" ]; then
            NEED_DOWNLOAD=1
            break
        fi
        # Проверяем возраст файла (если find поддерживает -mtime)
        if find "$F" -mtime +1 2>/dev/null | grep -q "$F"; then
            NEED_DOWNLOAD=1
            break
        fi
    done

    if [ $NEED_DOWNLOAD -eq 1 ]; then
        log "downloading bypass lists..."
        curl -s -m 15 -o "${BYPASS_IPS}.tmp" "$BYPASS_URL_IPS" 2>/dev/null && \
            [ -s "${BYPASS_IPS}.tmp" ] && mv "${BYPASS_IPS}.tmp" "$BYPASS_IPS"
        curl -s -m 15 -o "${BYPASS_DOMAINS}.tmp" "$BYPASS_URL_DOMAINS" 2>/dev/null && \
            [ -s "${BYPASS_DOMAINS}.tmp" ] && mv "${BYPASS_DOMAINS}.tmp" "$BYPASS_DOMAINS"
    fi
}

apply_bypass_passwall() {
    PW="$1"
    PW_RULES_DIR="/usr/share/${PW}/rules"
    mkdir -p "$PW_RULES_DIR" 2>/dev/null

    if [ -f "$BYPASS_IPS" ] && [ -s "$BYPASS_IPS" ]; then
        grep -v '^#' "$BYPASS_IPS" | grep -v '^\s*$' | tr -d '\r' > "$PW_RULES_DIR/direct_ip"
        IPCOUNT=$(wc -l < "$PW_RULES_DIR/direct_ip")
        log "bypass IPs: $IPCOUNT rules → $PW_RULES_DIR/direct_ip"
    fi

    if [ -f "$BYPASS_DOMAINS" ] && [ -s "$BYPASS_DOMAINS" ]; then
        grep -v '^#' "$BYPASS_DOMAINS" | grep -v '^\s*$' | tr -d '\r' > "$PW_RULES_DIR/direct_host"
        DOMCOUNT=$(wc -l < "$PW_RULES_DIR/direct_host")
        log "bypass domains: $DOMCOUNT rules → $PW_RULES_DIR/direct_host"
    fi
}

# ═══════════════════════════════════════════════════
#  Автоустановка PassWall
# ═══════════════════════════════════════════════════

auto_install_passwall() {
    log "auto-installing PassWall..."
    RAM=$(get_ram_mb)
    log "detected RAM: ${RAM}MB"

    cd /tmp || return 1
    rm -f passwallx.sh

    curl -s -m 30 -o passwallx.sh \
        "https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh" 2>/dev/null

    if [ ! -f passwallx.sh ] || [ ! -s passwallx.sh ]; then
        log "ERROR: cannot download passwallx.sh"
        return 1
    fi
    chmod +x passwallx.sh

    # passwallx.sh — интерактивный скрипт с меню
    # Меню: 1) Install PassWall  2) Install PassWall2  3) Uninstall
    # Подменю RAM: 1) 256MB+  2) 128MB
    if [ "$RAM" -le 160 ]; then
        log "128MB variant selected"
        printf '1\n2\n' | sh passwallx.sh >>"$LOG" 2>&1
    else
        log "256MB+ variant selected"
        printf '1\n1\n' | sh passwallx.sh >>"$LOG" 2>&1
    fi

    rm -f passwallx.sh
    sleep 3

    if find_passwall > /dev/null 2>&1; then
        log "PassWall installed successfully!"
        return 0
    fi

    log "ERROR: PassWall install failed — check log"
    return 1
}

# ═══════════════════════════════════════════════════
#  MAIN: Apply config
# ═══════════════════════════════════════════════════

# Загружаем bypass-списки (параллельно)
download_bypass_lists &
BYPASS_PID=$!

# --- Ищем PassWall ---

PW=$(find_passwall)
if [ -n "$PW" ]; then
    log "found: $PW"

    # Настраиваем subscription
    uci set "${PW}.vpn_sub=subscribe_list"
    uci set "${PW}.vpn_sub.remark=VPN Bot"
    uci set "${PW}.vpn_sub.url=$CONFIG"
    uci set "${PW}.vpn_sub.allowInsecure=1"

    # Bypass
    wait $BYPASS_PID 2>/dev/null
    apply_bypass_passwall "$PW"

    uci commit "$PW"

    # Обновляем подписки PassWall
    SUBSCRIBE_SH="/usr/share/${PW}/subscribe.sh"
    if [ -f "$SUBSCRIBE_SH" ]; then
        log "running $SUBSCRIBE_SH..."
        sh "$SUBSCRIBE_SH" >>"$LOG" 2>&1
    fi

    # Рестарт
    "/etc/init.d/${PW}" restart >>"$LOG" 2>&1
    sleep 2

    if vpn_is_running; then
        log "$PW: configured and VPN is UP"
    else
        log "$PW: configured but VPN process not detected yet (may take a moment)"
    fi

    # Запоминаем хеш
    echo "$HASH" > "$APPLIED_HASH_FILE"
    exit 0
fi

# --- Ищем raw xray ---

XRAY_BIN=$(find_xray)
if [ -n "$XRAY_BIN" ]; then
    log "found: xray at $XRAY_BIN"

    # Если config — URL подписки
    if echo "$CONFIG" | grep -q "^http"; then
        log "downloading xray config from subscription URL..."
        RAW=$(curl -s -m 15 "$CONFIG" 2>/dev/null)
        if [ -n "$RAW" ]; then
            DECODED=$(echo "$RAW" | base64 -d 2>/dev/null)
            if [ -n "$DECODED" ]; then
                mkdir -p /etc/xray
                echo "$DECODED" > /etc/xray/config.json
                log "xray config saved ($(wc -c < /etc/xray/config.json) bytes)"
            else
                log "ERROR: base64 decode failed"
                exit 1
            fi
        else
            log "ERROR: empty response from subscription URL"
            exit 1
        fi
    fi

    # Рестарт
    if [ -f /etc/init.d/xray ]; then
        /etc/init.d/xray restart >>"$LOG" 2>&1
    else
        killall xray 2>/dev/null
        sleep 1
        "$XRAY_BIN" run -config /etc/xray/config.json > /dev/null 2>&1 &
    fi

    log "xray restarted"
    echo "$HASH" > "$APPLIED_HASH_FILE"
    exit 0
fi

# --- Ничего нет — автоустановка ---

wait $BYPASS_PID 2>/dev/null
log "WARNING: no PassWall/xray found"

if auto_install_passwall; then
    log "re-running apply after install..."
    exec /usr/bin/vpn-apply.sh
fi

log "FATAL: no VPN client, auto-install failed"
log "Manual: cd /tmp && wget https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh && chmod +x passwallx.sh && sh passwallx.sh"
exit 1
