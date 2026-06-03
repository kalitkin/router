#!/bin/bash
###############################################################################
# patch-ipk.sh — собирает IPK v1.3.0
#
# Изменения v1.3.0-r11:
#   - vpnd: BusyBox ip compat — добавляет "2022 vpn" в /etc/iproute2/rt_tables
#   - vpnd: semanticHash стрипает short_id/fingerprint/utls (меньше лишних Apply)
#   - vpnd: исправлен unused "strings" import (CI go vet ранее падал)
#
# Изменения v1.3.0-r10:
#   - patchRouterConfig: interrupt_exist_connections=false (switch не роняет LAN)
#   - postinst: nftables forward_lan → sing-tun (fw4 policy drop) + persist файл
#   - postinst: fallback arch detection через DISTRIB_ARCH из openwrt_release
#
# Использование:
#   ./patch-ipk.sh              # собирает luci-app-vpnbot_1.3.0-r11_all.ipk
#   ./patch-ipk.sh output.ipk   # указать имя результата
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
OUTPUT="${1:-$SCRIPT_DIR/luci-app-vpnbot_1.3.0-r11_all.ipk}"

PKG_NAME="luci-app-vpnbot"
PKG_VERSION="1.3.0"
PKG_RELEASE="11"

CDN="https://self-music.online/packages/latest"

echo "=== IPK Builder v${PKG_VERSION}-r${PKG_RELEASE} ==="
echo "Файлы: $FILES_DIR"
echo "Выход: $OUTPUT"
echo ""

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/data" "$TMPDIR/ctrl"

# ═══ 1. data.tar.gz ═══

echo "[1/4] Сборка data.tar.gz..."

# Init-скрипты
install -D -m 755 "$FILES_DIR/vpnd.init"        "$TMPDIR/data/etc/init.d/vpnd"
install -D -m 755 "$FILES_DIR/sing-box.init"    "$TMPDIR/data/etc/init.d/sing-box"

# Вспомогательные скрипты
install -D -m 755 "$FILES_DIR/vpn-bootstrap.sh" "$TMPDIR/data/usr/bin/vpn-bootstrap.sh"
install -D -m 755 "$FILES_DIR/vpn-connect.sh"   "$TMPDIR/data/usr/bin/vpn-connect.sh"

# LuCI — Lua контроллер + HTML шаблон (требует luci-lua-runtime)
install -D -m 644 "$FILES_DIR/vpn.lua"   "$TMPDIR/data/usr/lib/lua/luci/controller/vpn.lua"
install -D -m 644 "$FILES_DIR/index.htm" "$TMPDIR/data/usr/lib/lua/luci/view/vpn/index.htm"

# Каталоги конфигов
mkdir -p "$TMPDIR/data/etc/vpn" "$TMPDIR/data/etc/sing-box"
printf '# vpnd config\n' > "$TMPDIR/data/etc/vpn/.keep"
printf '# sing-box config\n' > "$TMPDIR/data/etc/sing-box/.keep"

# Версия
mkdir -p "$TMPDIR/data/etc/vpn-agent"
echo "${PKG_VERSION}-r${PKG_RELEASE}" > "$TMPDIR/data/etc/vpn-agent/version"

# sysupgrade keep
install -D -m 644 /dev/null "$TMPDIR/data/lib/upgrade/keep.d/$PKG_NAME"
printf '/etc/vpn/\n/etc/sing-box/\n/usr/bin/vpnd\n/usr/bin/sing-box\n' \
    > "$TMPDIR/data/lib/upgrade/keep.d/$PKG_NAME"

cd "$TMPDIR/data"
tar czf "$TMPDIR/data.tar.gz" .
cd "$TMPDIR"
echo "  OK ($(du -sh data.tar.gz | cut -f1))"

# ═══ 2. control.tar.gz ═══

echo "[2/4] Сборка control.tar.gz..."

INSTALLED_SIZE=$(du -sk "$TMPDIR/data" | cut -f1)
cat > "$TMPDIR/ctrl/control" << CTRL
Package: $PKG_NAME
Version: ${PKG_VERSION}-r${PKG_RELEASE}
Depends: libc, luci-base, luci-lua-runtime, jsonfilter, curl, ca-bundle, kmod-tun
License: MIT
Section: luci
Architecture: all
Installed-Size: $((INSTALLED_SIZE * 1024))
Description: VPN Bot — sing-box + vpnd daemon для роутера.
 Автонастройка через Telegram: зарегистрируй роутер, получи конфиг, трафик пойдёт через VPN.
 RU-трафик (Яндекс, ВК, Госуслуги) идёт напрямую без VPN.
CTRL

cat > "$TMPDIR/ctrl/conffiles" << 'CONF'
/etc/vpn/.keep
/etc/sing-box/.keep
CONF

# postinst — скачивает vpnd + sing-box с CDN, настраивает zram
cat > "$TMPDIR/ctrl/postinst" << POSTINST_EOF
#!/bin/sh
[ "\${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "\${IPKG_INSTROOT}" ] && exit 0

SETUP=/tmp/.vpnd-setup.sh
CDN="${CDN}"
LOG=/tmp/vpnd-install.log
PROG=/tmp/vpnd-progress

progress() { printf '{"stage":"%s","pct":%d,"msg":"%s"}' "\$1" "\$2" "\$3" > "\$PROG"; }

cat > "\$SETUP" << 'ENDSETUP'
#!/bin/sh
LOG=/tmp/vpnd-install.log
PROG=/tmp/vpnd-progress
CDN="__CDN__"

progress() { printf '{"stage":"%s","pct":%d,"msg":"%s"}' "\$1" "\$2" "\$3" > "\$PROG"; }
log() { echo "[\$(date '+%H:%M:%S')] \$1" >> "\$LOG"; }

log "=== vpnd-setup start ==="
progress "setup" 2 "Старт..."

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# ── 1. zram ──────────────────────────────────────────────────────────
if [ -x /usr/bin/vpn-bootstrap.sh ]; then
    log "zram: running bootstrap"
    progress "setup" 5 "Настройка zram..."
    /usr/bin/vpn-bootstrap.sh
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    log "zram: done"
fi

# ── 2. Архитектура ────────────────────────────────────────────────────
OWRT_ARCH=\$(opkg print-architecture 2>/dev/null | awk '\$1=="arch" && \$3>=10 {print \$2}' | grep -v 'all\|noarch' | tail -1)
# Fallback: читаем DISTRIB_ARCH из /etc/openwrt_release
[ -z "\$OWRT_ARCH" ] && OWRT_ARCH=\$(grep 'DISTRIB_ARCH' /etc/openwrt_release 2>/dev/null | cut -d'"' -f2)
log "arch=\$OWRT_ARCH"

# ── 3. vpnd ───────────────────────────────────────────────────────────
# Always re-download vpnd so upgrades via --force-reinstall pick up the
# latest binary. Download to .new, replace atomically only on success.
log "vpnd: downloading..."
progress "setup" 20 "Скачиваем vpnd..."
URL="\$CDN/\$OWRT_ARCH/vpnd"
if wget -q -O /usr/bin/vpnd.new "\$URL" 2>>\$LOG && [ -s /usr/bin/vpnd.new ]; then
    mv /usr/bin/vpnd.new /usr/bin/vpnd
    chmod +x /usr/bin/vpnd
    log "vpnd: ok"
else
    rm -f /usr/bin/vpnd.new
    if [ -x /usr/bin/vpnd ]; then
        log "vpnd: download failed, keeping existing"
    else
        log "vpnd: FAILED \$URL"
    fi
fi
sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# ── 4. sing-box ───────────────────────────────────────────────────────
# sing-box is ~20MB — only download if missing.
if [ ! -x /usr/bin/sing-box ]; then
    log "sing-box: downloading..."
    progress "setup" 50 "Скачиваем sing-box (~20MB)..."
    URL="\$CDN/\$OWRT_ARCH/sing-box"
    if wget -q -O /usr/bin/sing-box "\$URL" 2>>\$LOG && [ -s /usr/bin/sing-box ]; then
        chmod +x /usr/bin/sing-box
        log "sing-box: ok"
    else
        rm -f /usr/bin/sing-box
        log "sing-box: FAILED \$URL"
    fi
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
else
    log "sing-box: already installed"
fi

# ── 5. Сервисы ────────────────────────────────────────────────────────
progress "setup" 90 "Включаем сервисы..."
mkdir -p /etc/vpn /etc/sing-box /var/lib/sing-box

/etc/init.d/sing-box enable 2>/dev/null || true
/etc/init.d/vpnd enable 2>/dev/null || true
/etc/init.d/vpnd start 2>/dev/null || true

rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

# ── 6. Firewall — fw4 forward chain has policy drop ──────────────────
# Allow br-lan → sing-tun forwarding. Write persistent include so the
# rule survives firewall reloads (netifd triggers reload on iface events).
if command -v nft >/dev/null 2>&1; then
    mkdir -p /etc/nftables.d
    echo 'add rule inet fw4 forward_lan oifname "sing-tun" accept comment "vpnd"' \
        > /etc/nftables.d/99-vpnd.nft
    nft list chain inet fw4 forward_lan 2>/dev/null | grep -q 'sing-tun' || \
        nft insert rule inet fw4 forward_lan oifname "sing-tun" accept 2>/dev/null || true
    log "nft: forward_lan → sing-tun done"
fi

progress "ready" 100 ""
log "=== vpnd-setup done ==="
rm -f "\$SETUP"
ENDSETUP

sed -i "s|__CDN__|${CDN}|g" "\$SETUP"
chmod +x "\$SETUP"
(sh "\$SETUP" >> /dev/null 2>&1) &

# Синхронно: очищаем кеш и перезапускаем uhttpd
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache /tmp/luci-sessions* 2>/dev/null
/etc/init.d/uhttpd restart 2>/dev/null || true

exit 0
POSTINST_EOF
chmod 755 "$TMPDIR/ctrl/postinst"

# prerm
cat > "$TMPDIR/ctrl/prerm" << 'PRERM_EOF'
#!/bin/sh
[ -z "${IPKG_INSTROOT}" ] && {
    /etc/init.d/vpnd stop 2>/dev/null || true
    /etc/init.d/vpnd disable 2>/dev/null || true
    /etc/init.d/sing-box stop 2>/dev/null || true
    /etc/init.d/sing-box disable 2>/dev/null || true
}
exit 0
PRERM_EOF
chmod 755 "$TMPDIR/ctrl/prerm"

cd "$TMPDIR/ctrl"
tar czf "$TMPDIR/control.tar.gz" .
cd "$TMPDIR"
echo "  OK"

# ═══ 3. debian-binary ═══

echo "2.0" > "$TMPDIR/debian-binary"

# ═══ 4. IPK ═══

echo "[3/4] Сборка IPK..."
cd "$TMPDIR"
tar czf "$OUTPUT" ./debian-binary ./control.tar.gz ./data.tar.gz
echo "  OK"

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "════════════════════════════════════"
echo "  Готово! ${PKG_VERSION}-r${PKG_RELEASE}"
echo "  Файл: $(basename $OUTPUT) ($SIZE)"
echo ""
echo "  Залить на сервер:"
echo "     scp $(basename $OUTPUT) root@self-music.online:/var/www/self-music.online/router.ipk"
echo ""
echo "  Установка на роутере:"
echo "     opkg install https://self-music.online/router.ipk"
echo ""
echo "  Прогресс:"
echo "     tail -f /tmp/vpnd-install.log"
echo "════════════════════════════════════"
