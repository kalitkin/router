#!/bin/sh
# /usr/bin/vpn-bootstrap.sh
# Определяет RAM-профиль устройства, настраивает zram-swap.
# Запускается один раз из postinst ДО установки PassWall.
# Идемпотентный: если profile уже есть — не перезаписывает.

DIR="/etc/vpn"
LOG="/tmp/vpn-install.log"
PROFILE_FILE="$DIR/profile"
SENTINEL="$DIR/.bootstrap_done"

log() { echo "[$(date '+%H:%M:%S')] bootstrap: $1" >> "$LOG"; }

mkdir -p "$DIR"

# ── 1. RAM профиль (immutable) ─────────────────────────────────────────────

if [ -f "$PROFILE_FILE" ]; then
    PROFILE=$(cat "$PROFILE_FILE")
    log "profile already set: $PROFILE (skipping detection)"
else
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)
    if [ "$MEM_KB" -le 65536 ]; then
        PROFILE="tiny"
    else
        PROFILE="normal"
    fi
    echo "$PROFILE" > "$PROFILE_FILE"
    log "profile detected: $PROFILE (MemTotal=${MEM_KB}kB)"
fi

# ── 2. zram-swap (только для ≤128MB) ─────────────────────────────────────

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)

if [ "$MEM_KB" -le 131072 ]; then
    # Процент от RAM: ≤32MB→35%, ≤64MB→30%, ≤128MB→15%
    if [ "$MEM_KB" -le 32768 ]; then
        ZRAM_PCT=35
    elif [ "$MEM_KB" -le 65536 ]; then
        ZRAM_PCT=30
    else
        ZRAM_PCT=15
    fi
    ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
    [ "$ZRAM_MB" -lt 4 ] && ZRAM_MB=4

    log "zram: MEM=${MEM_KB}kB pct=${ZRAM_PCT}% size=${ZRAM_MB}MB"

    if ! opkg list-installed 2>/dev/null | grep -q "^zram-swap "; then
        log "zram: installing zram-swap"
        opkg install zram-swap >> "$LOG" 2>&1 || {
            log "zram: install failed, skipping"
            touch "$SENTINEL"
            exit 0
        }
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    fi

    if [ -f /etc/init.d/zram-swap ]; then
        /etc/init.d/zram-swap stop 2>/dev/null || true
        uci set zram-swap.@zram-swap[0].size="$ZRAM_MB" 2>/dev/null && \
            uci commit zram-swap 2>/dev/null || true
        /etc/init.d/zram-swap start 2>/dev/null || true
        /etc/init.d/zram-swap enable 2>/dev/null || true
        log "zram: configured ${ZRAM_MB}MB and started"
    else
        log "zram: init script not found, skipping"
    fi
else
    log "zram: skipping (MEM=${MEM_KB}kB > 128MB)"
fi

# ── 3. Sentinel ───────────────────────────────────────────────────────────
touch "$SENTINEL"
log "bootstrap done (profile=$PROFILE)"
