#!/bin/sh
###############################################################################
# install.sh — Единый установщик для роутера OpenWrt
#
# curl -sL https://self-music.online/install.sh | sh -s -- CODE
# curl -sL https://self-music.online/install.sh | sh -s -- CODE v1.0.0
# curl -sL https://self-music.online/install.sh | sh -s -- --update
###############################################################################

set -e

SERVER="https://self-music.online"
API="$SERVER/vpnapi/v1/router"
PKG="$SERVER/packages"
RTR="$SERVER/router"
DIR="/etc/vpn"
LOG="/tmp/vpn-install.log"

# ═══ Аргументы ═══

CODE=""; VER="latest"; UPDATE=0
for A in "$@"; do
    case "$A" in
        --update)                       UPDATE=1 ;;
        --)                             ;;
        v[0-9]*)                        VER="$A" ;;
        [0-9][0-9][0-9][0-9][0-9][0-9]) CODE="$A" ;;
    esac
done

[ -z "$CODE" ] && [ $UPDATE -eq 0 ] && {
    echo "Usage: curl -sL $SERVER/install.sh | sh -s -- CODE [VERSION]"
    echo "       curl -sL $SERVER/install.sh | sh -s -- --update"
    echo "Get code: Telegram @noose4bot → Подключить роутер → Получить код"
    exit 1
}

# ═══ Утилиты ═══

ts() { date '+%H:%M:%S'; }
log()  { echo "[$(ts)] $1" | tee -a "$LOG"; }
ok()   { echo "[$(ts)] OK: $1" | tee -a "$LOG"; }
fail() { echo "[$(ts)] FAIL: $1" | tee -a "$LOG" >&2; }

dl() {
    # dl URL OUTPUT [quiet]
    _u="$1"; _o="$2"; _i=1
    while [ $_i -le 3 ]; do
        curl -fsSL --connect-timeout 10 --max-time 60 -o "$_o" "$_u" 2>/dev/null && [ -s "$_o" ] && return 0
        _i=$((_i + 1)); sleep 2
    done
    rm -f "$_o"; return 1
}

# ═══ [1/7] Архитектура ═══

echo ""
echo "=== VPN Bot Router Installer ==="
echo "" >> "$LOG"
log "=== install started $(date) ==="

log "[1/7] Architecture..."

ARCH=""
# opkg — самый надёжный способ
if command -v opkg > /dev/null 2>&1; then
    ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $3>10 {print $2}' | grep -v 'all\|noarch' | tail -1)
fi
# fallback: openwrt_release
[ -z "$ARCH" ] && [ -f /etc/openwrt_release ] && ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
# fallback: uname
if [ -z "$ARCH" ]; then
    case "$(uname -m)" in
        aarch64) ARCH="aarch64_cortex-a53" ;;
        armv7l)  ARCH="arm_cortex-a7_neon-vfpv4" ;;
        mips)    ARCH="mips_24kc" ;;
        mipsel)  ARCH="mipsel_24kc" ;;
        x86_64)  ARCH="x86_64" ;;
        *)       ARCH="aarch64_cortex-a53" ;;
    esac
fi
ok "$ARCH"

# Xray arch mapping (для GitHub fallback)
case "$ARCH" in
    aarch64*)                                                   XRAY_ARCH="arm64-v8a" ;;
    arm_cortex-a15*|arm_cortex-a7_neon*|arm_cortex-a9_neon*)    XRAY_ARCH="arm32-v7a" ;;
    arm_cortex-a7*|arm_cortex-a8*|arm_cortex-a9*)               XRAY_ARCH="arm32-v7a" ;;
    arm_*)                                                      XRAY_ARCH="arm32-v5" ;;
    x86_64)                                                     XRAY_ARCH="64" ;;
    i386*)                                                      XRAY_ARCH="32" ;;
    mips_*)                                                     XRAY_ARCH="mips32" ;;
    mipsel_*)                                                   XRAY_ARCH="mips32le" ;;
    mips64_*|mips64el_*)                                        XRAY_ARCH="mips64le" ;;
    riscv64*)                                                   XRAY_ARCH="riscv64" ;;
    *)                                                          XRAY_ARCH="" ;;
esac

# ═══ [2/7] Версия ═══

log "[2/7] Version check..."

mkdir -p /etc/vpn-agent
RVER=""
if dl "$PKG/$VER/VERSION" "/tmp/.vpn-remote-ver"; then
    RVER=$(grep '^version=' /tmp/.vpn-remote-ver | cut -d= -f2)
    RXRAY=$(grep '^xray_version=' /tmp/.vpn-remote-ver | cut -d= -f2)
    ok "remote $RVER (xray $RXRAY)"
fi
[ -z "$RVER" ] && RVER="$VER"

CVER=""
[ -f /etc/vpn-agent/version ] && CVER=$(cat /etc/vpn-agent/version)

if [ "$CVER" = "$RVER" ] && [ $UPDATE -eq 0 ] && [ -n "$CODE" ]; then
    ok "already $CVER — re-registering only"
    /usr/bin/vpn-connect.sh "$CODE" 2>>"$LOG"
    exit $?
fi

# ═══ [3/7] Зависимости ═══

log "[3/7] Dependencies..."

opkg update > /dev/null 2>&1 || true

# Обязательные
for P in curl ca-bundle; do
    opkg list-installed 2>/dev/null | grep -q "^$P " || {
        log "  installing $P"
        opkg install "$P" > /dev/null 2>&1 || true
    }
done

# Для PassWall (тихо, не ломаем если нет)
for P in ipset iptables-mod-tproxy kmod-tun kmod-ipt-tproxy unzip; do
    opkg install "$P" > /dev/null 2>&1 || true
done

ok "deps ready"

# ═══ [4/7] Xray ═══

log "[4/7] Xray..."

XRAY_OK=0

# A) Бинарник с нашего сервера (предпочтительный)
XBIN="/tmp/.xray-bin"
if dl "$PKG/$VER/$ARCH/xray" "$XBIN"; then
    # SHA256
    EXPECT_SHA=""
    dl "$PKG/$VER/$ARCH/xray.sha256" "/tmp/.xray-sha" 2>/dev/null && EXPECT_SHA=$(cat /tmp/.xray-sha 2>/dev/null)
    if [ -n "$EXPECT_SHA" ] && command -v sha256sum > /dev/null 2>&1; then
        ACTUAL_SHA=$(sha256sum "$XBIN" | cut -d' ' -f1)
        if [ "$ACTUAL_SHA" != "$EXPECT_SHA" ]; then
            fail "xray sha256 mismatch!"
            rm -f "$XBIN"
        fi
    fi
    if [ -s "$XBIN" ]; then
        cp "$XBIN" /usr/bin/xray
        chmod +x /usr/bin/xray
        ok "xray binary from server"
        XRAY_OK=1
    fi
    rm -f "$XBIN" "/tmp/.xray-sha"
fi

# B) opkg
if [ $XRAY_OK -eq 0 ]; then
    log "  trying opkg..."
    opkg install xray-core 2>>"$LOG" && XRAY_OK=1 && ok "xray via opkg"
fi

# C) GitHub
if [ $XRAY_OK -eq 0 ] && [ -n "$XRAY_ARCH" ]; then
    log "  trying GitHub..."
    XVER="${RXRAY:-}"
    [ -z "$XVER" ] && XVER=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" 2>/dev/null | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$XVER" ]; then
        GH="https://github.com/XTLS/Xray-core/releases/download/$XVER/Xray-linux-$XRAY_ARCH.zip"
        if dl "$GH" "/tmp/.xray.zip"; then
            cd /tmp && mkdir -p .xray-ext && unzip -qo .xray.zip -d .xray-ext 2>/dev/null
            [ -f /tmp/.xray-ext/xray ] && {
                cp /tmp/.xray-ext/xray /usr/bin/xray
                chmod +x /usr/bin/xray
                ok "xray from GitHub ($XVER)"
                XRAY_OK=1
            }
            rm -rf /tmp/.xray.zip /tmp/.xray-ext
        fi
    fi
fi

# Проверяем
if [ $XRAY_OK -eq 1 ] && [ -x /usr/bin/xray ]; then
    XV=$(/usr/bin/xray version 2>/dev/null | head -1 || echo "binary ok")
    ok "xray: $XV"
else
    fail "xray NOT installed — PassWall may not work"
fi

# ═══ [5/7] PassWall ═══

log "[5/7] PassWall..."

PW_OK=0
[ -f /etc/config/passwall ] && [ -f /etc/init.d/passwall ] && { ok "already installed"; PW_OK=1; }

# A) ipk с нашего сервера
if [ $PW_OK -eq 0 ]; then
    if dl "$PKG/$VER/common/luci-app-passwall.ipk" "/tmp/.pw.ipk"; then
        opkg install /tmp/.pw.ipk --force-depends 2>>"$LOG" && PW_OK=1 && ok "passwall from server"
        rm -f /tmp/.pw.ipk
    fi
fi

# B) SourceForge passwall-build
if [ $PW_OK -eq 0 ]; then
    log "  trying SourceForge repo..."
    SF="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
    curl -fsSL -o /tmp/.pw.pub "$SF/passwall.pub" 2>/dev/null && opkg-key add /tmp/.pw.pub 2>/dev/null; rm -f /tmp/.pw.pub
    REL=$(. /etc/openwrt_release 2>/dev/null && echo "${DISTRIB_RELEASE%.*}" || echo "24.10")
    for F in passwall_luci passwall_packages; do
        grep -q "$F" /etc/opkg/customfeeds.conf 2>/dev/null || \
            echo "src/gz $F ${SF}/releases/packages-${REL}/${ARCH}/${F}" >> /etc/opkg/customfeeds.conf
    done
    opkg update > /dev/null 2>&1
    opkg install luci-app-passwall 2>>"$LOG" && PW_OK=1 && ok "passwall from SourceForge"
fi

# C) passwallx.sh
if [ $PW_OK -eq 0 ]; then
    log "  trying passwallx.sh..."
    RAM=$(awk '/MemTotal/{printf "%d",$2/1024}' /proc/meminfo 2>/dev/null || echo 256)
    cd /tmp && rm -f passwallx.sh
    curl -fsSL -o passwallx.sh "https://raw.githubusercontent.com/amirhosseinchoghaei/Passwall/main/passwallx.sh" 2>/dev/null
    if [ -s passwallx.sh ]; then
        chmod +x passwallx.sh
        if [ "$RAM" -le 160 ]; then
            printf '1\n2\n' | sh passwallx.sh >>"$LOG" 2>&1 || true
        else
            printf '1\n1\n' | sh passwallx.sh >>"$LOG" 2>&1 || true
        fi
        rm -f passwallx.sh
        [ -f /etc/config/passwall ] && PW_OK=1 && ok "passwall via passwallx.sh (RAM=${RAM}MB)"
    fi
fi

[ $PW_OK -eq 0 ] && fail "PassWall NOT installed"

# ═══ [6/7] VPN Agent ═══

log "[6/7] VPN agent scripts..."

mkdir -p "$DIR" /usr/bin

for F in vpn-connect.sh vpn-agent.sh vpn-apply.sh; do
    dl "$RTR/$F" "/usr/bin/$F" || { fail "cannot download $F"; exit 1; }
    chmod +x "/usr/bin/$F"
done

dl "$RTR/vpn-agent.init" "/etc/init.d/vpn-agent" || { fail "cannot download vpn-agent.init"; exit 1; }
chmod +x /etc/init.d/vpn-agent
/etc/init.d/vpn-agent enable 2>/dev/null || true

# Bypass
dl "$RTR/bypass_ips.txt"     "$DIR/bypass_ips.txt" 2>/dev/null || true
dl "$RTR/bypass_domains.txt" "$DIR/bypass_domains.txt" 2>/dev/null || true

# LuCI VPN page
mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/vpn
dl "$RTR/vpn.lua"   "/usr/lib/lua/luci/controller/vpn.lua" 2>/dev/null || true
dl "$RTR/index.htm"  "/usr/lib/lua/luci/view/vpn/index.htm" 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

# Web terminal (опционально)
opkg install luci-app-ttyd 2>/dev/null || true

# Версия
echo "$RVER" > /etc/vpn-agent/version

ok "agent installed"

# ═══ [7/7] Регистрация ═══

if [ -n "$CODE" ]; then
    log "[7/7] Registering: $CODE"
    /usr/bin/vpn-connect.sh "$CODE"
    RC=$?
else
    log "[7/7] Update — skip registration"
    [ -f "$DIR/token" ] && { /etc/init.d/vpn-agent restart 2>/dev/null || true; }
    RC=0
fi

# ═══ Итого ═══

echo ""
if [ $RC -eq 0 ]; then
    echo "======================================="
    echo "  VPN Router Ready"
    echo "======================================="
    echo "  Version:   $RVER"
    echo "  Arch:      $ARCH"
    echo "  Xray:      $([ $XRAY_OK -eq 1 ] && echo 'yes' || echo 'NO')"
    echo "  PassWall:  $([ $PW_OK -eq 1 ] && echo 'yes' || echo 'NO')"
    echo ""
    echo "  Logs:      cat /tmp/vpn.log"
    echo "  LuCI:      Services > VPN Setup"
    echo "  Terminal:  Services > Terminal"
    echo ""
    echo "  Update:    curl -sL $SERVER/install.sh | sh -s -- --update"
    echo "  Uninstall: /etc/init.d/vpn-agent stop"
    echo "             rm -rf /etc/vpn /etc/vpn-agent"
    echo "             rm -f /usr/bin/vpn-*.sh /etc/init.d/vpn-agent"
    echo "======================================="
else
    echo "======================================="
    echo "  Registration FAILED (rc=$RC)"
    echo "  Retry: /usr/bin/vpn-connect.sh $CODE"
    echo "======================================="
fi

exit $RC
