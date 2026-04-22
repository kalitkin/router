#!/bin/sh
# /usr/bin/vpn-apply.sh — применяет VPN конфиг на роутере
# Поддерживает: PassWall, PassWall2, raw xray
# ИДЕМПОТЕНТНЫЙ: не рестартит если конфиг не изменился и VPN работает

DIR="/etc/vpn"
LOG="/tmp/vpn.log"
PROG=/tmp/vpn-progress
APPLIED_HASH_FILE="$DIR/applied_hash"
BYPASS_IPS="$DIR/bypass_ips.txt"
BYPASS_DOMAINS="$DIR/bypass_domains.txt"
BYPASS_URL_IPS="https://self-music.online/router/bypass_ips.txt"
BYPASS_URL_DOMAINS="https://self-music.online/router/bypass_domains.txt"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [apply] $1" >> "$LOG"; }
progress() { printf '{"stage":"%s","pct":%d,"msg":"%s"}' "$1" "$2" "$3" > "$PROG"; }

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
    for PW in passwall passwall2; do
        [ -f /etc/config/$PW ] || continue
        # init.d might be missing after manual opkg remove — reinstall if needed
        if [ ! -f /etc/init.d/$PW ]; then
            log "passwall config found but init.d missing — reinstalling $PW"
            opkg install "luci-app-$PW" >> "$LOG" 2>&1 || true
        fi
        [ -f /etc/init.d/$PW ] && { echo "$PW"; return 0; }
    done
    return 1
}

find_xray() {
    for P in /usr/bin/xray /tmp/xray /opt/xray/xray /usr/local/bin/xray; do
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
progress "applying" 25 "Проверяем VPN клиент..."

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
    log "auto-installing PassWall via opkg..."
    progress "installing" 35 "Добавляем репозиторий PassWall..."

    SF="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
    REL=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE%.*}" || echo "24.10")
    ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $3>=10 {print $2}' | grep -v 'all\|noarch' | tail -1)

    if [ -z "$ARCH" ]; then
        log "ERROR: cannot detect arch for PassWall install"
        progress "error" 0 "Не удалось определить архитектуру"
        return 1
    fi

    grep -q "passwall_packages" /etc/opkg/customfeeds.conf 2>/dev/null || \
        echo "src/gz passwall_packages ${SF}/releases/packages-${REL}/${ARCH}/passwall_packages" >> /etc/opkg/customfeeds.conf
    grep -q "passwall_luci" /etc/opkg/customfeeds.conf 2>/dev/null || \
        echo "src/gz passwall_luci ${SF}/releases/packages-${REL}/${ARCH}/passwall_luci" >> /etc/opkg/customfeeds.conf

    progress "installing" 45 "Обновляем список пакетов..."
    log "running opkg update..."
    opkg update >> "$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

    progress "installing" 60 "Устанавливаем PassWall..."
    log "running opkg install luci-app-passwall..."
    if opkg install luci-app-passwall >> "$LOG" 2>&1; then
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
        log "PassWall installed successfully"
        return 0
    fi

    log "ERROR: PassWall install failed — check $LOG"
    progress "error" 0 "Не удалось установить PassWall"
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
    progress "applying" 75 "Настраиваем $PW..."

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
        progress "done" 100 "VPN активен!"
    else
        log "$PW: configured but VPN process not detected yet (may take a moment)"
        progress "done" 100 "Конфиг применён, VPN запускается..."
    fi

    echo "$HASH" > "$APPLIED_HASH_FILE"
    exit 0
fi

# --- Ищем raw xray ---

XRAY_BIN=$(find_xray)
if [ -n "$XRAY_BIN" ]; then
    log "found: xray at $XRAY_BIN"

    # Subscription URL — нужен PassWall, raw xray не умеет subscription
    if echo "$CONFIG" | grep -q "^http"; then
        log "subscription URL — needs PassWall, triggering auto-install"
        progress "installing" 30 "Нужен PassWall для подписки..."
        wait $BYPASS_PID 2>/dev/null
        if auto_install_passwall; then
            log "re-running apply after PassWall install..."
            exec /usr/bin/vpn-apply.sh
        fi
        log "PassWall auto-install failed"
        exit 1
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
log "WARNING: no PassWall/xray found — auto-installing"
progress "installing" 30 "Устанавливаем PassWall..."

if auto_install_passwall; then
    log "re-running apply after install..."
    exec /usr/bin/vpn-apply.sh
fi

progress "error" 0 "Не удалось установить VPN клиент"
log "FATAL: no VPN client, auto-install failed"
log "Manual: cd /tmp && wget https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh && chmod +x passwallx.sh && sh passwallx.sh"
exit 1
