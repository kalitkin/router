#!/bin/sh
# Keenetic VPN Installer
# Usage:  curl -s https://self-music.online/router/keenetic-install.sh | sh
# Requires: Entware installed (/opt), internet access

CDN="https://self-music.online/packages/latest"
SCRIPTS="https://self-music.online/router/keenetic"
LOG="/tmp/vpn-keenetic-install.log"

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }

# ── 1. Detect architecture ────────────────────────────────────────────────────

detect_arch() {
    EA=$(opkg print-architecture 2>/dev/null \
        | awk '$1=="arch" && $3>=10 {print $2}' \
        | grep -v '^all$\|^noarch$' | tail -1)
    case "$EA" in
        mipselsf|mipsel-*|mipsel_*) echo "mipsle-softfloat" ; return ;;
        mipssf|mips-*|mips_*)       echo "mips-softfloat"   ; return ;;
        aarch64*)                    echo "aarch64_generic"   ; return ;;
        armv7*)                      echo "armv7"             ; return ;;
        armv6*)                      echo "armv6"             ; return ;;
        armv5*)                      echo "armv5"             ; return ;;
    esac
    case "$(uname -m)" in
        aarch64) echo "aarch64_generic" ;;
        armv7l)  echo "armv7" ;;
        armv6l)  echo "armv6" ;;
        mips)    echo "mipsle-softfloat" ;;
        *)       echo "" ;;
    esac
}

ARCH=$(detect_arch)
if [ -z "$ARCH" ]; then
    log "ERROR: cannot detect architecture"
    log "  opkg print-architecture: $(opkg print-architecture 2>/dev/null | head -5)"
    log "  uname -m: $(uname -m)"
    exit 1
fi
log "Architecture: $ARCH"

# ── 2. Install required packages ──────────────────────────────────────────────

install_pkg() {
    if ! command -v "$2" > /dev/null 2>&1; then
        log "Installing $1..."
        opkg install "$1" > /dev/null 2>&1 || { log "ERROR: failed to install $1"; exit 1; }
    fi
}

install_pkg curl     curl
install_pkg iptables iptables

# ── 3. Directories ────────────────────────────────────────────────────────────

mkdir -p /opt/usr/bin /opt/usr/share
mkdir -p /opt/etc/vpn /opt/etc/sing-box /opt/etc/init.d /opt/etc/ndm/fs.d

# ── 3. Download vpnd ──────────────────────────────────────────────────────────

log "Downloading vpnd..."
curl -sf -o /opt/usr/bin/vpnd.new "$CDN/$ARCH/vpnd" || {
    log "ERROR: failed to download vpnd from $CDN/$ARCH/vpnd"
    exit 1
}
chmod +x /opt/usr/bin/vpnd.new
mv /opt/usr/bin/vpnd.new /opt/usr/bin/vpnd
log "vpnd: $(ls -lh /opt/usr/bin/vpnd | awk '{print $5}')"

# ── 4. Download sing-box ──────────────────────────────────────────────────────

log "Downloading sing-box..."
SINGBOX_GZ=/opt/usr/share/sing-box.tar.gz

# Prefer pre-compressed .tar.gz from CDN (much smaller download).
# If not available, download full binary and compress locally (one-time).
if curl -sf -o "$SINGBOX_GZ" "$CDN/$ARCH/sing-box.tar.gz" 2>/dev/null; then
    log "sing-box.tar.gz: $(ls -lh "$SINGBOX_GZ" | awk '{print $5}') (from CDN)"
else
    log "No .tar.gz on CDN — downloading full binary (~58 MB)..."
    curl -sf -o /tmp/sing-box "$CDN/$ARCH/sing-box" || {
        log "ERROR: failed to download sing-box"
        exit 1
    }
    chmod +x /tmp/sing-box
    cd /tmp && tar czf "$SINGBOX_GZ" sing-box
    log "sing-box.tar.gz: $(ls -lh "$SINGBOX_GZ" | awk '{print $5}') (compressed locally)"
fi

# ── 5. Install init scripts ───────────────────────────────────────────────────

log "Installing init scripts..."
curl -sf -o /opt/etc/init.d/S99vpnd  "$SCRIPTS/S99vpnd"  || { log "ERROR: S99vpnd download failed";     exit 1; }
curl -sf -o /opt/etc/init.d/sing-box "$SCRIPTS/sing-box-init" || { log "ERROR: sing-box-init failed";   exit 1; }
curl -sf -o /opt/etc/vpn-connect.sh  "$SCRIPTS/vpn-connect.sh" || { log "ERROR: vpn-connect.sh failed"; exit 1; }
chmod +x /opt/etc/init.d/S99vpnd /opt/etc/init.d/sing-box /opt/etc/vpn-connect.sh

# ── 6. Autostart on boot ─────────────────────────────────────────────────────

log "Setting up autostart..."
cat > /opt/etc/ndm/fs.d/010-entware.sh << 'HOOK'
#!/bin/sh
[ -x /opt/etc/init.d/rc.unslung ] && /opt/etc/init.d/rc.unslung start
HOOK
chmod +x /opt/etc/ndm/fs.d/010-entware.sh

# netfilter.d hook: NDM rebuilds iptables on every reconfigure (WAN change, reboot,
# firewall edit) and wipes our custom chains. This restores TPROXY rules each time.
# NDM passes $type (iptables/ip6tables) and $table (filter/nat/mangle).
mkdir -p /opt/etc/ndm/netfilter.d
cat > /opt/etc/ndm/netfilter.d/100-vpnd.sh << 'NFHOOK'
#!/bin/sh
[ "$type" = "iptables" ] || exit 0
[ "$table" = "mangle" ] || exit 0
[ -x /opt/etc/init.d/S99vpnd ] && /opt/etc/init.d/S99vpnd retproxy
NFHOOK
chmod +x /opt/etc/ndm/netfilter.d/100-vpnd.sh

# ── Done ──────────────────────────────────────────────────────────────────────

log ""
log "====================================="
log "  Installation complete!"
log "====================================="
log ""
log "  1. Get a 6-digit code from Telegram bot"
log "  2. Register:"
log "       /opt/etc/vpn-connect.sh 123456"
log ""
log "  3. Start VPN:"
log "       /opt/etc/init.d/S99vpnd start"
log ""
log "  Logs: tail -f /tmp/vpnd.log"
log "====================================="
