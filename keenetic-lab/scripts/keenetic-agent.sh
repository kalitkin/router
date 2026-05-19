#!/bin/sh
# /opt/bin/keenetic-agent.sh
# Keenetic VPN Agent: heartbeat + desired-state + self-healing xray + rollback
# Запускается через Entware init.d (S99vpn-agent)

# ── Конфигурация ──────────────────────────────────────────────────────────────

API="${VPN_API_URL:-https://self-music.online/vpnapi/v1/router}"
BYPASS_URL="${VPN_BYPASS_URL:-https://self-music.online/router}"

DIR="/opt/etc/vpn"
XRAY_CFG="/opt/etc/xray/config.json"
XRAY_BAK="/opt/etc/xray/config.json.bak"
XRAY_BIN="/opt/bin/xray"
XRAY_PID="/opt/var/run/xray.pid"
APPLY_SCRIPT="/opt/bin/keenetic-apply.sh"
LOG="/opt/var/log/vpn-agent.log"

# Keenetic RCI API (локальный роутер)
RCI_HOST="${RCI_HOST:-http://192.168.1.1}"
RCI_PASS_FILE="$DIR/rci_password"

# Интервалы
PING_INTERVAL=45
PING_RETRY_DELAY=10
CONFIG_POLL_INTERVAL=5
CONFIG_MAX_ATTEMPTS=60
CONFIG_CHECK_INTERVAL=300    # 5 мин
BYPASS_CHECK_INTERVAL=3600   # 1 час
VERIFY_TIMEOUT=30
HEAL_EVERY=4                 # self-heal каждые N циклов heartbeat

# TProxy
TPROXY_PORT=12345
TPROXY_MARK=1
TPROXY_TABLE=100
TPROXY_CHAIN="VPN_TPROXY"

# ── Логирование ───────────────────────────────────────────────────────────────

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [agent] $*" >> "$LOG"; }

rotate_log() {
    [ ! -f "$LOG" ] && return
    size=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    [ "$size" -gt 51200 ] && {
        tail -n 100 "$LOG" > "${LOG}.tmp"
        mv "${LOG}.tmp" "$LOG"
        log "log rotated"
    }
}

# ── JSON утилита ──────────────────────────────────────────────────────────────
# Приоритет: jq → jsonfilter (OpenWrt) → grep fallback

json_get() {
    # $1 = JSON-строка, $2 = имя поля
    if command -v jq > /dev/null 2>&1; then
        printf '%s' "$1" | jq -r ".$2 // empty" 2>/dev/null
    elif command -v jsonfilter > /dev/null 2>&1; then
        printf '%s' "$1" | jsonfilter -e "@.$2" 2>/dev/null
    else
        printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d'"' -f4 | head -1
    fi
}

# ── RCI API ───────────────────────────────────────────────────────────────────

rci_call() {
    # $1 = путь (show/version, show/interface, ...)
    # Возвращает JSON или пустую строку при ошибке
    [ ! -f "$RCI_PASS_FILE" ] && return 1
    rci_pass=$(cat "$RCI_PASS_FILE")
    curl -s -m 5 -u "admin:${rci_pass}" "${RCI_HOST}/rci/$1" 2>/dev/null
}

rci_get_isp_state() {
    resp=$(rci_call "show/interface" 2>/dev/null)
    [ -z "$resp" ] && { echo "unknown"; return; }
    # ищем тип pppoe/dhcp и state=up
    if printf '%s' "$resp" | grep -q '"state":"up"'; then
        echo "up"
    else
        echo "down"
    fi
}

rci_get_wan_ip() {
    resp=$(rci_call "show/interface" 2>/dev/null)
    [ -z "$resp" ] && return
    # ISP-интерфейс: первый не-ethernet с address
    printf '%s' "$resp" | grep -A5 '"type":"pppoe"\|"type":"dhcp"' | \
        grep -o '"address":"[^"]*"' | head -1 | cut -d'"' -f4
}

# ── Определение MAC ───────────────────────────────────────────────────────────

get_mac() {
    # Приоритет: сохранённый → eth0 → br0 → RCI
    [ -f "$DIR/mac" ] && cat "$DIR/mac" && return

    for iface in eth0 eth1 br0 GigabitEthernet0; do
        addr_file="/sys/class/net/$iface/address"
        if [ -f "$addr_file" ]; then
            mac=$(cat "$addr_file")
            # пропускаем нулевые и мультикаст
            case "$mac" in
                "00:00:00:00:00:00"|"") continue ;;
            esac
            echo "$mac"
            return
        fi
    done

    # Последний резерв — RCI
    resp=$(rci_call "show/interface" 2>/dev/null)
    [ -n "$resp" ] && printf '%s' "$resp" | grep -o '"mac":"[^"]*"' | \
        head -1 | cut -d'"' -f4
}

# ── Xray управление ───────────────────────────────────────────────────────────

xray_is_running() {
    [ -f "$XRAY_PID" ] || return 1
    pid=$(cat "$XRAY_PID")
    kill -0 "$pid" 2>/dev/null
}

xray_start() {
    [ ! -f "$XRAY_CFG" ] && { log "ERROR: xray config not found"; return 1; }
    [ ! -x "$XRAY_BIN" ] && { log "ERROR: xray binary not found/executable"; return 1; }

    xray_stop
    "$XRAY_BIN" run -c "$XRAY_CFG" >> "$LOG" 2>&1 &
    echo $! > "$XRAY_PID"
    log "xray started pid=$(cat "$XRAY_PID")"
}

xray_stop() {
    if [ -f "$XRAY_PID" ]; then
        pid=$(cat "$XRAY_PID")
        kill "$pid" 2>/dev/null
        rm -f "$XRAY_PID"
    fi
    # страховка: убить все оставшиеся процессы
    killall xray 2>/dev/null
    sleep 1
}

self_heal_xray() {
    xray_is_running && return 0

    [ ! -f "$XRAY_CFG" ] && return 0   # конфига нет — нечего лечить

    log "xray dead — restarting"
    xray_start
    sleep 3
    if xray_is_running; then
        log "xray recovered"
    else
        log "ERROR: xray failed to restart"
        return 1
    fi
}

# ── TProxy (iptables) ─────────────────────────────────────────────────────────

tproxy_is_active() {
    iptables -t mangle -L "$TPROXY_CHAIN" > /dev/null 2>&1
}

setup_tproxy() {
    log "setting up TProxy rules"

    # ip rule + ip route для tproxy
    ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null
    ip route add local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" 2>/dev/null

    # создать цепочку
    iptables -t mangle -N "$TPROXY_CHAIN" 2>/dev/null
    iptables -t mangle -F "$TPROXY_CHAIN"

    # ── bypass: частные сети и локальные адреса (всегда прямо) ──
    iptables -t mangle -A "$TPROXY_CHAIN" -d 127.0.0.0/8    -j RETURN
    iptables -t mangle -A "$TPROXY_CHAIN" -d 192.168.0.0/16 -j RETURN
    iptables -t mangle -A "$TPROXY_CHAIN" -d 10.0.0.0/8     -j RETURN
    iptables -t mangle -A "$TPROXY_CHAIN" -d 172.16.0.0/12  -j RETURN

    # ── bypass: российские IP из bypass_ips.txt ──
    if [ -f "$DIR/bypass_ips.txt" ]; then
        while IFS= read -r subnet; do
            case "$subnet" in
                "#"*|"") continue ;;   # пропустить комментарии и пустые строки
            esac
            iptables -t mangle -A "$TPROXY_CHAIN" -d "$subnet" -j RETURN
        done < "$DIR/bypass_ips.txt"
        log "bypass_ips rules added"
    fi

    # ── всё остальное → TPROXY → xray ──
    iptables -t mangle -A "$TPROXY_CHAIN" -p tcp \
        -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$TPROXY_MARK"
    iptables -t mangle -A "$TPROXY_CHAIN" -p udp \
        -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$TPROXY_MARK"

    # прикрепить цепочку к PREROUTING (LAN трафик)
    iptables -t mangle -D PREROUTING -i br0 -j "$TPROXY_CHAIN" 2>/dev/null
    iptables -t mangle -A PREROUTING -i br0 -j "$TPROXY_CHAIN"

    log "TProxy active on :$TPROXY_PORT"
}

teardown_tproxy() {
    log "tearing down TProxy rules"
    iptables -t mangle -D PREROUTING -i br0 -j "$TPROXY_CHAIN" 2>/dev/null
    iptables -t mangle -F "$TPROXY_CHAIN" 2>/dev/null
    iptables -t mangle -X "$TPROXY_CHAIN" 2>/dev/null
    ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" 2>/dev/null
}

# ── Apply / Verify / Rollback / Failover ─────────────────────────────────────

apply_config() {
    log "applying config"

    # backup текущего конфига для возможного rollback
    [ -f "$XRAY_CFG" ] && cp "$XRAY_CFG" "$XRAY_BAK"

    # вызываем keenetic-apply.sh который:
    #   1. скачивает subscription URL
    #   2. парсит → xray config.json (с bypass_domains)
    #   3. поднимает xray
    if ! sh "$APPLY_SCRIPT" >> "$LOG" 2>&1; then
        log "ERROR: keenetic-apply.sh failed"
        return 1
    fi

    # (пере)собрать iptables — bypass_ips могли обновиться
    teardown_tproxy
    setup_tproxy

    return 0
}

verify_connectivity() {
    # Проверяем что VPN реально работает после apply
    # Возвращает 0 = ОК, 1 = сломано
    deadline=$(( $(date +%s) + VERIFY_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if xray_is_running; then
            break
        fi
        sleep 2
    done

    if ! xray_is_running; then
        log "verify FAIL: xray not running after ${VERIFY_TIMEOUT}s"
        return 1
    fi

    # Проверяем доступность сервера через обычный curl
    # (не через xray — просто что сетевой путь до VPN-сервера есть)
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
        "$API/ping" 2>/dev/null || echo "000")

    if [ "$http_code" = "000" ]; then
        log "verify FAIL: cannot reach server (http_code=$http_code)"
        return 1
    fi

    log "verify OK (xray pid=$(cat "$XRAY_PID" 2>/dev/null), server=$http_code)"
    return 0
}

rollback() {
    log "ROLLBACK: restoring backup config"

    if [ ! -f "$XRAY_BAK" ]; then
        log "ROLLBACK: no backup available"
        return 1
    fi

    cp "$XRAY_BAK" "$XRAY_CFG"
    xray_stop
    xray_start
    sleep 3

    if xray_is_running; then
        log "ROLLBACK: xray running with backup config"
        return 0
    fi

    log "ROLLBACK: failed — xray won't start even with backup"
    return 1
}

failover() {
    # Последний рубеж: убрать TProxy → трафик идёт напрямую без VPN
    log "FAILOVER: removing TProxy rules — direct routing active"
    xray_stop
    teardown_tproxy

    # Уведомить сервер
    curl -s -m 10 -X POST "$API/ping" \
        -H "Content-Type: application/json" \
        -d "{\"mac\":\"$MAC\",\"secret\":\"$SECRET\",\"vpn_up\":false,\"failover\":true}" \
        > /dev/null 2>&1 || true
}

# ── Обновление bypass-списков ─────────────────────────────────────────────────

check_bypass_update() {
    changed=0

    for f in bypass_domains.txt bypass_ips.txt; do
        new=$(curl -s -m 15 "$BYPASS_URL/$f" 2>/dev/null)
        [ -z "$new" ] && continue
        old=$(cat "$DIR/$f" 2>/dev/null)
        [ "$new" = "$old" ] && continue

        printf '%s\n' "$new" > "$DIR/$f.tmp" && mv "$DIR/$f.tmp" "$DIR/$f"
        log "bypass updated: $f"
        changed=1
    done

    [ "$changed" = "0" ] && return 0

    log "bypass changed — rebuilding tproxy + reloading xray"

    # bypass_ips.txt → iptables (пересобрать)
    teardown_tproxy
    setup_tproxy

    # bypass_domains.txt → xray routing (перегенерировать конфиг)
    if xray_is_running; then
        apply_config && verify_connectivity || {
            log "bypass reload failed — attempting rollback"
            rollback
        }
    fi
}

# ── ФАЗА 1: Получить конфиг ───────────────────────────────────────────────────

get_config() {
    if [ -f "$DIR/config" ] && [ -s "$DIR/config" ]; then
        log "config exists ($(wc -c < "$DIR/config") bytes) — applying"
        apply_config
        verify_connectivity || log "WARN: initial verify failed, continuing"
        return 0
    fi

    log "waiting for config from server..."
    attempts=0

    while [ "$attempts" -lt "$CONFIG_MAX_ATTEMPTS" ]; do
        resp=$(curl -s -m 10 "${API}/config_by_mac?mac=${MAC_ENCODED}&secret=${SECRET}" 2>/dev/null)
        status=$(json_get "$resp" "status")

        case "$status" in
            ok)
                cfg=$(json_get "$resp" "config")
                if [ -n "$cfg" ] && [ "$cfg" != "null" ]; then
                    printf '%s\n' "$cfg" > "$DIR/config.tmp" && \
                        mv "$DIR/config.tmp" "$DIR/config"
                    log "config received ($(wc -c < "$DIR/config") bytes)"
                    apply_config
                    if verify_connectivity; then
                        cfg_hash=$(printf '%s' "$cfg" | md5sum | cut -d' ' -f1)
                        printf '%s' "$cfg_hash" > "$DIR/applied_hash"
                    else
                        log "WARN: initial verify failed, continuing"
                    fi
                    return 0
                fi
                ;;
            pending)
                [ $(( attempts % 12 )) -eq 0 ] && [ "$attempts" -gt 0 ] && \
                    log "waiting for config (attempt $attempts/$CONFIG_MAX_ATTEMPTS)"
                ;;
            blocked)
                log "BLOCKED by server — stopping"
                return 1
                ;;
            not_registered)
                log "not registered — stopping (run keenetic-connect.sh first)"
                return 1
                ;;
            *)
                [ $(( attempts % 12 )) -eq 0 ] && \
                    log "poll: unexpected status='$status' (attempt $attempts)"
                ;;
        esac

        attempts=$(( attempts + 1 ))
        sleep "$CONFIG_POLL_INTERVAL"
    done

    log "timeout: no config after $CONFIG_MAX_ATTEMPTS attempts"
    return 1
}

# ── Desired-State: проверка обновлений конфига ────────────────────────────────

check_config_update() {
    resp=$(curl -s -m 10 \
        "${API}/config_by_mac?mac=${MAC_ENCODED}&secret=${SECRET}" 2>/dev/null)
    status=$(json_get "$resp" "status")

    case "$status" in
        ok)
            new_cfg=$(json_get "$resp" "config")
            [ -z "$new_cfg" ] || [ "$new_cfg" = "null" ] && return 0

            # Desired-state: сравниваем по config_hash если сервер его отдаёт,
            # иначе fallback на md5 полного конфига
            server_hash=$(json_get "$resp" "config_hash")
            if [ -z "$server_hash" ]; then
                server_hash=$(printf '%s' "$new_cfg" | md5sum | cut -d' ' -f1)
            fi
            applied_hash=$(cat "$DIR/applied_hash" 2>/dev/null || echo "")

            if [ "$server_hash" = "$applied_hash" ]; then
                return 0   # конфиг не изменился
            fi

            log "desired-state mismatch: server=$server_hash applied=$applied_hash"

            printf '%s\n' "$new_cfg" > "$DIR/config.tmp" && \
                mv "$DIR/config.tmp" "$DIR/config"

            if apply_config; then
                if verify_connectivity; then
                    printf '%s' "$server_hash" > "$DIR/applied_hash"
                    log "config update applied: hash=$server_hash"
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
            xray_stop
            teardown_tproxy
            ;;
        *)
            : # сервер недоступен или другой статус — молча пропускаем
            ;;
    esac
}

# ── ФАЗА 2: Heartbeat loop ────────────────────────────────────────────────────

heartbeat_loop() {
    log "heartbeat started (ping=${PING_INTERVAL}s config=${CONFIG_CHECK_INTERVAL}s bypass=${BYPASS_CHECK_INTERVAL}s)"

    consecutive_fails=0
    cycle=0
    cycles_config=$(( CONFIG_CHECK_INTERVAL / PING_INTERVAL ))
    cycles_bypass=$(( BYPASS_CHECK_INTERVAL / PING_INTERVAL ))

    while true; do
        # ── собрать данные для ping ──
        wan_ip=$(rci_get_wan_ip 2>/dev/null)
        [ -z "$wan_ip" ] && wan_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2)

        fw_ver=$(cat /opt/etc/keenetic_fw 2>/dev/null || echo "")

        vpn_up="false"
        xray_is_running && vpn_up="true"

        # ── heartbeat ──
        http_code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 \
            -X POST "$API/ping" \
            -H "Content-Type: application/json" \
            -d "{\"mac\":\"$MAC\",\"ip\":\"$wan_ip\",\"firmware_version\":\"$fw_ver\",\"secret\":\"$SECRET\",\"vpn_up\":$vpn_up,\"type\":\"keenetic\"}" \
            2>/dev/null || echo "000")

        if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
            [ "$consecutive_fails" -gt 0 ] && \
                log "ping recovered after $consecutive_fails fails"
            consecutive_fails=0
        else
            consecutive_fails=$(( consecutive_fails + 1 ))
            [ "$consecutive_fails" -le 5 ] && \
                log "ping FAIL #$consecutive_fails (HTTP $http_code)"
            if [ "$consecutive_fails" -le 3 ]; then
                sleep "$PING_RETRY_DELAY"
                continue
            fi
        fi

        cycle=$(( cycle + 1 ))

        # ── desired-state (каждые 5 мин) ──
        if [ $(( cycle % cycles_config )) -eq 0 ]; then
            check_config_update
        fi

        # ── bypass update (каждый час) ──
        if [ "$cycle" -gt 0 ] && [ $(( cycle % cycles_bypass )) -eq 0 ]; then
            check_bypass_update
        fi

        # ── self-heal xray (каждые N циклов) ──
        if [ $(( cycle % HEAL_EVERY )) -eq 0 ]; then
            self_heal_xray
        fi

        # ── ротация лога ──
        if [ $(( cycle % 20 )) -eq 0 ]; then
            rotate_log
        fi

        sleep "$PING_INTERVAL"
    done
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

# Проверить регистрацию
if [ ! -f "$DIR/token" ]; then
    log "no token — not registered. Run keenetic-connect.sh first"
    exit 0
fi

SECRET=$(cat "$DIR/secret" 2>/dev/null || echo "")
MAC=$(get_mac)

if [ -z "$MAC" ]; then
    log "ERROR: cannot determine MAC address"
    exit 1
fi

MAC_ENCODED=$(printf '%s' "$MAC" | sed 's/:/%3A/g')
log "started pid=$$ mac=$MAC"

# Создать нужные директории
mkdir -p "$(dirname "$LOG")" /opt/etc/xray "$DIR"

get_config
rc=$?

if [ "$rc" -eq 0 ]; then
    heartbeat_loop
else
    log "failed to get config (rc=$rc) — exiting (init.d will retry)"
    exit 1
fi
