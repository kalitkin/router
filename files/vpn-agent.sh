#!/bin/sh
# /usr/bin/vpn-agent.sh — фоновый агент: получает конфиг + heartbeat
# Запускается через procd (init.d)
# Две фазы: 1) poll для конфига если нет  2) heartbeat loop

API="https://self-music.online/vpnapi/v1/router"
BYPASS_URL="https://self-music.online/router"
DIR="/etc/vpn"
LOG="/tmp/vpn.log"
PING_INTERVAL=45
PING_RETRY_DELAY=10
CONFIG_POLL_INTERVAL=5
CONFIG_MAX_ATTEMPTS=60
CONFIG_CHECK_INTERVAL=300   # проверка обновлений конфига (5 мин)
BYPASS_CHECK_INTERVAL=3600  # проверка обновлений bypass-списков (1 час)

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [agent] $1" >> "$LOG"; }

# ═══════════════════════════════════════════════════
#  Утилиты
# ═══════════════════════════════════════════════════

rotate_log() {
    [ ! -f "$LOG" ] && return
    SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$SIZE" -gt 51200 ] && {
        tail -n 100 "$LOG" > "${LOG}.tmp"
        mv "${LOG}.tmp" "$LOG"
        log "log rotated"
    }
}

# JSON парсинг — jsonfilter (OpenWrt) или grep fallback
json_get() {
    # $1 = json string, $2 = field name
    if command -v jsonfilter > /dev/null 2>&1; then
        echo "$1" | jsonfilter -e "@.$2" 2>/dev/null
    else
        echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4
    fi
}

vpn_is_running() {
    pgrep -f "xray" > /dev/null 2>&1 && return 0
    pgrep -f "v2ray" > /dev/null 2>&1 && return 0
    pgrep -f "sing-box" > /dev/null 2>&1 && return 0
    return 1
}

passwall_is_enabled() {
    [ -f /etc/init.d/passwall ] && {
        ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null)
        [ "$ENABLED" = "1" ] && return 0
    }
    [ -f /etc/init.d/passwall2 ] && {
        ENABLED=$(uci get passwall2.@global[0].enabled 2>/dev/null)
        [ "$ENABLED" = "1" ] && return 0
    }
    return 1
}

check_vpn_health() {
    # Если VPN жив — не трогаем
    vpn_is_running && return 0

    # Нет конфига — нечего запускать
    [ ! -f "$DIR/config" ] || [ ! -s "$DIR/config" ] && return 1

    # Есть конфиг, VPN мёртв
    if passwall_is_enabled; then
        log "VPN process dead but passwall enabled — reapplying"
        /usr/bin/vpn-apply.sh 2>>"$LOG"
    else
        # Не пишем лог каждый раз — только первый раз
        :
    fi
    return 0
}

# ═══════════════════════════════════════════════════
#  Обновление bypass-списков
# ═══════════════════════════════════════════════════

check_bypass_update() {
    CHANGED=0
    for F in bypass_domains.txt bypass_ips.txt; do
        NEW=$(curl -s -m 15 "$BYPASS_URL/$F" 2>/dev/null)
        [ -z "$NEW" ] && continue
        OLD=$(cat "$DIR/$F" 2>/dev/null)
        [ "$NEW" = "$OLD" ] && continue
        printf '%s\n' "$NEW" > "$DIR/$F.tmp" && mv "$DIR/$F.tmp" "$DIR/$F"
        log "bypass updated: $F"
        CHANGED=1
    done

    [ "$CHANGED" = "0" ] && return 0

    for PW in passwall passwall2; do
        [ -f /etc/init.d/$PW ] || continue
        PW_RULES_DIR="/usr/share/${PW}/rules"
        mkdir -p "$PW_RULES_DIR"
        grep -v '^#' "$DIR/bypass_ips.txt"     | grep -v '^\s*$' | tr -d '\r' > "$PW_RULES_DIR/direct_ip"
        grep -v '^#' "$DIR/bypass_domains.txt" | grep -v '^\s*$' | tr -d '\r' > "$PW_RULES_DIR/direct_host"
        log "bypass rules applied → $PW, reloading"
        /etc/init.d/$PW reload >>"$LOG" 2>&1 || /etc/init.d/$PW restart >>"$LOG" 2>&1 || true
        break
    done
}

# ═══════════════════════════════════════════════════
#  Проверка credentials
# ═══════════════════════════════════════════════════

if [ ! -f "$DIR/token" ]; then
    log "no token — not registered, exiting"
    exit 0
fi

TOKEN=$(cat "$DIR/token")
SECRET=$(cat "$DIR/secret" 2>/dev/null || echo "")
MAC=""
if [ -f "$DIR/mac" ]; then
    MAC=$(cat "$DIR/mac")
fi
# fallback
if [ -z "$MAC" ]; then
    for IFACE in br-lan eth0 wan; do
        [ -f "/sys/class/net/$IFACE/address" ] && {
            MAC=$(cat "/sys/class/net/$IFACE/address")
            break
        }
    done
fi

if [ -z "$MAC" ]; then
    log "ERROR: cannot determine MAC, exiting"
    exit 1
fi

MAC_ENCODED=$(echo "$MAC" | sed 's/:/%3A/g')

log "started pid=$$ mac=$MAC"

# ═══════════════════════════════════════════════════
#  ФАЗА 1: Получить конфиг (polling каждые 5 сек)
# ═══════════════════════════════════════════════════

get_config() {
    if [ -f "$DIR/config" ] && [ -s "$DIR/config" ]; then
        log "config already exists ($(wc -c < "$DIR/config") bytes)"
        return 0
    fi

    log "waiting for config..."
    ATTEMPTS=0

    while [ $ATTEMPTS -lt $CONFIG_MAX_ATTEMPTS ]; do
        URL="${API}/config_by_mac?mac=${MAC_ENCODED}"
        [ -n "$SECRET" ] && URL="${URL}&secret=${SECRET}"

        RESP=$(curl -s -m 10 "$URL" 2>/dev/null)
        STATUS=$(json_get "$RESP" "status")

        case "$STATUS" in
            ok)
                CFG=$(json_get "$RESP" "config")
                if [ -n "$CFG" ] && [ "$CFG" != "null" ]; then
                    echo "$CFG" > "$DIR/config.tmp" && mv "$DIR/config.tmp" "$DIR/config"
                    log "config received! ($(echo "$CFG" | wc -c) bytes)"
                    /usr/bin/vpn-apply.sh 2>>"$LOG"
                    return 0
                fi
                ;;
            pending)
                # Нормально — сервер ещё не выдал конфиг
                [ $((ATTEMPTS % 12)) -eq 0 ] && [ $ATTEMPTS -gt 0 ] && \
                    log "still waiting for config (attempt $ATTEMPTS/$CONFIG_MAX_ATTEMPTS)"
                ;;
            blocked)
                log "BLOCKED by server, stopping agent"
                return 1
                ;;
            not_registered)
                log "not registered on server, stopping agent"
                return 1
                ;;
            *)
                [ $((ATTEMPTS % 12)) -eq 0 ] && \
                    log "poll: unexpected status='$STATUS' (attempt $ATTEMPTS)"
                ;;
        esac

        ATTEMPTS=$((ATTEMPTS + 1))
        sleep $CONFIG_POLL_INTERVAL
    done

    log "timeout: no config after $CONFIG_MAX_ATTEMPTS attempts ($(( CONFIG_MAX_ATTEMPTS * CONFIG_POLL_INTERVAL ))s)"
    return 1
}

# ═══════════════════════════════════════════════════
#  Проверка обновлений конфига
# ═══════════════════════════════════════════════════

check_config_update() {
    URL="${API}/config_by_mac?mac=${MAC_ENCODED}"
    [ -n "$SECRET" ] && URL="${URL}&secret=${SECRET}"

    RESP=$(curl -s -m 10 "$URL" 2>/dev/null)
    STATUS=$(json_get "$RESP" "status")

    case "$STATUS" in
        ok)
            NEW_CFG=$(json_get "$RESP" "config")
            if [ -n "$NEW_CFG" ] && [ "$NEW_CFG" != "null" ]; then
                OLD_CFG=$(cat "$DIR/config" 2>/dev/null)
                if [ "$NEW_CFG" != "$OLD_CFG" ]; then
                    log "CONFIG UPDATED — reapplying"
                    echo "$NEW_CFG" > "$DIR/config.tmp" && mv "$DIR/config.tmp" "$DIR/config"
                    /usr/bin/vpn-apply.sh 2>>"$LOG"
                fi
            fi
            ;;
        blocked)
            log "device BLOCKED — stopping VPN"
            # Остановить PassWall/xray
            [ -f /etc/init.d/passwall ] && /etc/init.d/passwall stop 2>/dev/null
            [ -f /etc/init.d/passwall2 ] && /etc/init.d/passwall2 stop 2>/dev/null
            killall xray 2>/dev/null
            ;;
    esac
}

# ═══════════════════════════════════════════════════
#  ФАЗА 2: Heartbeat loop
# ═══════════════════════════════════════════════════

heartbeat_loop() {
    log "heartbeat started (ping=${PING_INTERVAL}s, config_check=${CONFIG_CHECK_INTERVAL}s, bypass_check=${BYPASS_CHECK_INTERVAL}s)"
    CONSECUTIVE_FAILS=0
    CYCLE=0
    CYCLES_PER_CONFIG_CHECK=$((CONFIG_CHECK_INTERVAL / PING_INTERVAL))
    CYCLES_PER_BYPASS_CHECK=$((BYPASS_CHECK_INTERVAL / PING_INTERVAL))

    while true; do
        # Собираем данные
        IP=""
        for IFACE in br-lan eth0 wan; do
            IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
            [ -n "$IP" ] && break
        done

        FW=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d"'" -f2 || echo "")

        VPN_UP="false"
        vpn_is_running && VPN_UP="true"

        # Heartbeat
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$API/ping" \
            -H "Content-Type: application/json" \
            -d "{\"mac\":\"$MAC\",\"ip\":\"$IP\",\"firmware_version\":\"$FW\",\"secret\":\"$SECRET\",\"vpn_up\":$VPN_UP}" \
            2>/dev/null)

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            if [ $CONSECUTIVE_FAILS -gt 0 ]; then
                log "ping recovered after $CONSECUTIVE_FAILS fails"
            fi
            CONSECUTIVE_FAILS=0
        else
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            if [ $CONSECUTIVE_FAILS -le 5 ]; then
                log "ping FAIL #$CONSECUTIVE_FAILS (HTTP $HTTP_CODE)"
            fi
            # Быстрый retry
            if [ $CONSECUTIVE_FAILS -le 3 ]; then
                sleep $PING_RETRY_DELAY
                continue
            fi
        fi

        CYCLE=$((CYCLE + 1))

        # Проверка обновлений конфига (каждые ~5 мин)
        if [ $((CYCLE % CYCLES_PER_CONFIG_CHECK)) -eq 0 ]; then
            check_config_update
        fi

        # Проверка обновлений bypass-списков (каждый час)
        if [ $((CYCLE % CYCLES_PER_BYPASS_CHECK)) -eq 0 ] && [ $CYCLE -gt 0 ]; then
            check_bypass_update
        fi

        # Health check VPN (каждые ~3 мин = ~4 цикла)
        if [ $((CYCLE % 4)) -eq 0 ]; then
            check_vpn_health
        fi

        # Ротация логов (каждые ~15 мин)
        if [ $((CYCLE % 20)) -eq 0 ]; then
            rotate_log
        fi

        sleep $PING_INTERVAL
    done
}

# ═══════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════

get_config
RC=$?
if [ $RC -eq 0 ]; then
    heartbeat_loop
else
    log "failed to get config (rc=$RC), exiting — procd will retry"
    exit 1
fi
