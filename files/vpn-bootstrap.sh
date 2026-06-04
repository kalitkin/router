#!/bin/sh
# /usr/bin/vpn-bootstrap.sh
# Определяет RAM-профиль устройства, вычисляет размер zram.
# НЕ вызывает opkg — только записывает файлы конфигурации.
# Запускается один раз из postinst ДО ожидания opkg lock.
# Идемпотентный: если profile уже есть — не перезаписывает.

DIR="/etc/vpn"
LOG="/tmp/vpnd-install.log"
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

# ── 2. zram размер (hint для setup-скрипта, без opkg) ────────────────────
# opkg install zram-swap вызывается setup-скриптом ПОСЛЕ opkg update
# чтобы избежать конфликта с opkg lock при первой установке.

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)

if [ "$MEM_KB" -le 131072 ]; then
    if [ "$MEM_KB" -le 32768 ]; then
        ZRAM_PCT=35
    elif [ "$MEM_KB" -le 65536 ]; then
        ZRAM_PCT=30
    else
        ZRAM_PCT=15
    fi
    ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
    [ "$ZRAM_MB" -lt 4 ] && ZRAM_MB=4
    echo "$ZRAM_MB" > "$DIR/zram_size"
    log "zram: hint written (${ZRAM_MB}MB, to be installed after opkg update)"
else
    rm -f "$DIR/zram_size"
    log "zram: skipping (MEM=${MEM_KB}kB > 128MB)"
fi

# ── 3. nf_conntrack tuning ───────────────────────────────────────────────
# With TPROXY each TCP connection = 2 conntrack entries.
# Default established timeout (~120h) causes entries to accumulate (12000+).
# Lower to 10 minutes; TIME_WAIT and others get tighter limits too.
CT=/proc/sys/net/netfilter
if [ -f "$CT/nf_conntrack_tcp_timeout_established" ]; then
    echo 600   > "$CT/nf_conntrack_tcp_timeout_established"
    echo 60    > "$CT/nf_conntrack_tcp_timeout_time_wait"
    echo 30    > "$CT/nf_conntrack_tcp_timeout_close_wait"
    echo 10    > "$CT/nf_conntrack_tcp_timeout_fin_wait"
    log "conntrack: TCP timeouts tuned (established=600s)"
fi

# ── 4. Sentinel ───────────────────────────────────────────────────────────
touch "$SENTINEL"
log "bootstrap done (profile=$PROFILE)"
