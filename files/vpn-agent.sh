#!/bin/sh
# /usr/bin/vpn-agent.sh — фоновый агент: desired-state + heartbeat + self-heal + rollback
# Запускается через procd (init.d)

API="https://self-music.online/vpnapi/v1/router"
BYPASS_URL="https://self-music.online/router"
DIR="/etc/vpn"
LOG="/etc/vpn/vpn-agent.log"    # persistent: выживает после ребута
PING_INTERVAL=45
PING_RETRY_DELAY=10
CONFIG_POLL_INTERVAL=5
CONFIG_MAX_ATTEMPTS=60
CONFIG_CHECK_INTERVAL=300       # 5 мин
BYPASS_CHECK_INTERVAL=3600      # 1 час
HEAL_EVERY=4                    # self-heal каждые N циклов heartbeat
VERIFY_TIMEOUT=30               # сек ожидания запуска xray

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [agent] $1" >> "$LOG"; }

# ── Ротация лога ──────────────────────────────────────────────────────────────

rotate_log() {
    [ ! -f "$LOG" ] && return
    SIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$SIZE" -gt 102400 ] && {
        tail -n 200 "$LOG" > "${LOG}.tmp"
        mv "${LOG}.tmp" "$LOG"
        log "log rotated"
    }
}

# ── JSON парсинг ──────────────────────────────────────────────────────────────

json_get() {
    if command -v jsonfilter > /dev/null 2>&1; then
        echo "$1" | jsonfilter -e "@.$2" 2>/dev/null
    else
        echo "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4
    fi
}

# ── VPN состояние ─────────────────────────────────────────────────────────────

vpn_is_running() {
    pgrep -f "xray"     > /dev/null 2>&1 && return 0
    pgrep -f "v2ray"    > /dev/null 2>&1 && return 0
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

# ── Verify / Rollback / Failover ──────────────────────────────────────────────

verify_connectivity() {
    DEADLINE=$(( $(date +%s) + VERIFY_TIMEOUT ))
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        vpn_is_running && break
        sleep 2
    done

    if ! vpn_is_running; then
        log "verify FAIL: no VPN process after ${VERIFY_TIMEOUT}s"
        return 1
    fi

    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$API/ping" 2>/dev/null || echo "000")
    if [ "$HTTP_CODE" = "000" ]; then
        log "verify FAIL: cannot reach server"
        return 1
    fi

    log "verify OK (server=$HTTP_CODE)"
    return 0
}

rollback() {
    log "ROLLBACK: restoring backup config"
    [ ! -f "$DIR/config.bak" ] && { log "ROLLBACK: no backup available"; return 1; }

    cp "$DIR/config.bak" "$DIR/config"
    /usr/bin/vpn-apply.sh 2>>"$LOG"
    sleep 5

    if vpn_is_running; then
        log "ROLLBACK: success"
        return 0
    fi
    log "ROLLBACK: failed — VPN won't start with backup"
    return 1
}

failover() {
    log "FAILOVER: stopping VPN — direct routing active"
    rm -f "$DIR/vpn_started"
    [ -f /etc/init.d/passwall ]  && /etc/init.d/passwall  stop 2>/dev/null || true
    [ -f /etc/init.d/passwall2 ] && /etc/init.d/passwall2 stop 2>/dev/null || true
    killall xray 2>/dev/null || true
    curl -s -m 10 -X POST "$API/ping" \
        -H "Content-Type: application/json" \
        -d "{\"mac\":\"$MAC\",\"secret\":\"$SECRET\",\"vpn_up\":false,\"failover\":true}" \
        > /dev/null 2>&1 || true
}

# ── Self-heal ─────────────────────────────────────────────────────────────────

check_vpn_health() {
    vpn_is_running && return 0
    [ ! -f "$DIR/config" ] || [ ! -s "$DIR/config" ] && return 0
    passwall_is_enabled || return 0

    log "VPN process dead — self-healing"
    /usr/bin/vpn-apply.sh 2>>"$LOG"
    sleep 5

    if vpn_is_running; then
        log "self-heal: VPN recovered"
        date +%s > "$DIR/vpn_started"
    else
        log "self-heal: apply failed — rolling back"
        rollback || failover
    fi
}

# ── Обновление bypass-списков ─────────────────────────────────────────────────

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

# ── Credentials ───────────────────────────────────────────────────────────────

if [ ! -f "$DIR/token" ]; then
    log "no token — not registered, exiting"
    exit 0
fi

chmod 600 "$DIR/token" "$DIR/secret" 2>/dev/null || true

SECRET=$(cat "$DIR/secret" 2>/dev/null || echo "")
MAC=""
if [ -f "$DIR/mac" ]; then
    MAC=$(cat "$DIR/mac")
fi
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
mkdir -p "$DIR"
log "started pid=$$ mac=$MAC"

# ── ФАЗА 1: Получить конфиг (polling) ────────────────────────────────────────

get_config() {
    if [ -f "$DIR/config" ] && [ -s "$DIR/config" ]; then
        log "config exists ($(wc -c < "$DIR/config") bytes)"
        # Если после ребута VPN не поднялся — помогаем
        if ! vpn_is_running && passwall_is_enabled; then
            log "VPN not running on startup — applying config"
            /usr/bin/vpn-apply.sh 2>>"$LOG"
            sleep 5
            vpn_is_running && date +%s > "$DIR/vpn_started"
        fi
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
                    log "config received ($(echo "$CFG" | wc -c) bytes)"
                    /usr/bin/vpn-apply.sh 2>>"$LOG"
                    sleep 5
                    if verify_connectivity; then
                        CFG_HASH=$(printf '%s' "$CFG" | md5sum | cut -d' ' -f1)
                        printf '%s' "$CFG_HASH" > "$DIR/applied_hash"
                        date +%s > "$DIR/vpn_started"
                    fi
                    return 0
                fi
                ;;
            pending)
                [ $((ATTEMPTS % 12)) -eq 0 ] && [ $ATTEMPTS -gt 0 ] && \
                    log "still waiting (attempt $ATTEMPTS/$CONFIG_MAX_ATTEMPTS)"
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
                    log "poll: status='$STATUS' (attempt $ATTEMPTS)"
                ;;
        esac

        ATTEMPTS=$((ATTEMPTS + 1))
        sleep $CONFIG_POLL_INTERVAL
    done

    log "timeout: no config after $CONFIG_MAX_ATTEMPTS attempts"
    return 1
}

# ── Desired-state: проверка обновлений конфига ────────────────────────────────

check_config_update() {
    URL="${API}/config_by_mac?mac=${MAC_ENCODED}"
    [ -n "$SECRET" ] && URL="${URL}&secret=${SECRET}"

    RESP=$(curl -s -m 10 "$URL" 2>/dev/null)
    STATUS=$(json_get "$RESP" "status")

    case "$STATUS" in
        ok)
            NEW_CFG=$(json_get "$RESP" "config")
            [ -z "$NEW_CFG" ] || [ "$NEW_CFG" = "null" ] && return 0

            # Desired-state через hash: сервер может отдать config_hash, иначе считаем md5
            SERVER_HASH=$(json_get "$RESP" "config_hash")
            [ -z "$SERVER_HASH" ] && SERVER_HASH=$(printf '%s' "$NEW_CFG" | md5sum | cut -d' ' -f1)
            APPLIED_HASH=$(cat "$DIR/applied_hash" 2>/dev/null || echo "")

            [ "$SERVER_HASH" = "$APPLIED_HASH" ] && return 0

            log "desired-state mismatch: server=$SERVER_HASH applied=$APPLIED_HASH — updating"

            [ -f "$DIR/config" ] && cp "$DIR/config" "$DIR/config.bak"
            echo "$NEW_CFG" > "$DIR/config.tmp" && mv "$DIR/config.tmp" "$DIR/config"

            if /usr/bin/vpn-apply.sh 2>>"$LOG"; then
                sleep 5
                if verify_connectivity; then
                    printf '%s' "$SERVER_HASH" > "$DIR/applied_hash"
                    date +%s > "$DIR/vpn_started"
                    log "config updated: hash=$SERVER_HASH"
                else
                    log "verify failed after update — rolling back"
                    rollback || failover
                fi
            else
                log "apply failed — rolling back"
                rollback || failover
            fi
            ;;
        blocked)
            log "device BLOCKED — stopping VPN"
            rm -f "$DIR/vpn_started"
            [ -f /etc/init.d/passwall ]  && /etc/init.d/passwall  stop 2>/dev/null || true
            [ -f /etc/init.d/passwall2 ] && /etc/init.d/passwall2 stop 2>/dev/null || true
            killall xray 2>/dev/null || true
            ;;
    esac
}

# ── ФАЗА 2: Heartbeat loop ────────────────────────────────────────────────────

heartbeat_loop() {
    log "heartbeat started (ping=${PING_INTERVAL}s config=${CONFIG_CHECK_INTERVAL}s bypass=${BYPASS_CHECK_INTERVAL}s)"
    CONSECUTIVE_FAILS=0
    CYCLE=0
    CYCLES_PER_CONFIG_CHECK=$((CONFIG_CHECK_INTERVAL / PING_INTERVAL))
    CYCLES_PER_BYPASS_CHECK=$((BYPASS_CHECK_INTERVAL / PING_INTERVAL))
    VPN_WAS_UP=0

    while true; do
        IP=""
        for IFACE in br-lan eth0 wan; do
            IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -o 'inet [0-9.]*' | cut -d' ' -f2)
            [ -n "$IP" ] && break
        done

        FW=$(grep DISTRIB_RELEASE /etc/openwrt_release 2>/dev/null | cut -d"'" -f2 || echo "")

        VPN_UP="false"
        if vpn_is_running; then
            VPN_UP="true"
            if [ "$VPN_WAS_UP" = "0" ]; then
                date +%s > "$DIR/vpn_started"
                VPN_WAS_UP=1
            fi
        else
            VPN_WAS_UP=0
            rm -f "$DIR/vpn_started"
        fi

        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$API/ping" \
            -H "Content-Type: application/json" \
            -d "{\"mac\":\"$MAC\",\"ip\":\"$IP\",\"firmware_version\":\"$FW\",\"secret\":\"$SECRET\",\"vpn_up\":$VPN_UP}" \
            2>/dev/null)

        if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
            [ $CONSECUTIVE_FAILS -gt 0 ] && log "ping recovered after $CONSECUTIVE_FAILS fails"
            CONSECUTIVE_FAILS=0
        else
            CONSECUTIVE_FAILS=$((CONSECUTIVE_FAILS + 1))
            [ $CONSECUTIVE_FAILS -le 5 ] && log "ping FAIL #$CONSECUTIVE_FAILS (HTTP $HTTP_CODE)"
            if [ $CONSECUTIVE_FAILS -le 3 ]; then
                sleep $PING_RETRY_DELAY
                continue
            fi
        fi

        CYCLE=$((CYCLE + 1))

        [ $((CYCLE % CYCLES_PER_CONFIG_CHECK)) -eq 0 ] && check_config_update
        [ $((CYCLE % CYCLES_PER_BYPASS_CHECK)) -eq 0 ] && [ $CYCLE -gt 0 ] && check_bypass_update
        [ $((CYCLE % HEAL_EVERY)) -eq 0 ] && check_vpn_health
        [ $((CYCLE % 20)) -eq 0 ] && rotate_log

        sleep $PING_INTERVAL
    done
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

get_config
RC=$?
if [ $RC -eq 0 ]; then
    heartbeat_loop
else
    log "failed to get config (rc=$RC), exiting — procd will retry"
    exit 1
fi
