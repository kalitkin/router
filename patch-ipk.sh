#!/bin/bash
###############################################################################
# patch-ipk.sh — собирает IPK из файлов репозитория с memory-safe postinst
#
# Берёт файлы из files/ (актуальные версии), собирает data.tar.gz и
# control.tar.gz с deferred postinst. Не зависит от OpenWrt SDK.
#
# Использование:
#   ./patch-ipk.sh                    # собирает luci-app-vpnbot_1.2.0-r1_all.ipk
#   ./patch-ipk.sh output.ipk         # указать имя результата
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILES_DIR="$SCRIPT_DIR/files"
OUTPUT="${1:-$SCRIPT_DIR/luci-app-vpnbot_1.2.0-r2_all.ipk}"

PKG_NAME="luci-app-vpnbot"
PKG_VERSION="1.2.0"
PKG_RELEASE="2"

echo "=== IPK Builder ==="
echo "Файлы: $FILES_DIR"
echo "Выход: $OUTPUT"
echo ""

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

mkdir -p "$TMPDIR/data" "$TMPDIR/ctrl"

# ═══ 1. Собираем data.tar.gz из files/ ═══

echo "[1/4] Сборка data.tar.gz (актуальные файлы из files/)..."

# Shell-скрипты
install -D -m 755 "$FILES_DIR/vpn-connect.sh" "$TMPDIR/data/usr/bin/vpn-connect.sh"
install -D -m 755 "$FILES_DIR/vpn-agent.sh"   "$TMPDIR/data/usr/bin/vpn-agent.sh"
install -D -m 755 "$FILES_DIR/vpn-apply.sh"   "$TMPDIR/data/usr/bin/vpn-apply.sh"

# Init.d
install -D -m 755 "$FILES_DIR/vpn-agent.init"  "$TMPDIR/data/etc/init.d/vpn-agent"
install -D -m 755 "$FILES_DIR/xray-fetch.init" "$TMPDIR/data/etc/init.d/xray-fetch"

# LuCI
install -D -m 644 "$FILES_DIR/vpn.lua"   "$TMPDIR/data/usr/lib/lua/luci/controller/vpn.lua"
install -D -m 644 "$FILES_DIR/index.htm" "$TMPDIR/data/usr/lib/lua/luci/view/vpn/index.htm"

# Bypass-листы и конфиг
install -D -m 644 "$FILES_DIR/bypass_ips.txt"     "$TMPDIR/data/etc/vpn/bypass_ips.txt"
install -D -m 644 "$FILES_DIR/bypass_domains.txt" "$TMPDIR/data/etc/vpn/bypass_domains.txt"

# Версия
mkdir -p "$TMPDIR/data/etc/vpn-agent"
echo "${PKG_VERSION}-r${PKG_RELEASE}" > "$TMPDIR/data/etc/vpn-agent/version"

# keep.d для sysupgrade
install -D -m 644 /dev/null "$TMPDIR/data/lib/upgrade/keep.d/$PKG_NAME"
printf '/etc/vpn/\n/etc/vpn-agent/\n' > "$TMPDIR/data/lib/upgrade/keep.d/$PKG_NAME"

cd "$TMPDIR/data"
tar czf "$TMPDIR/data.tar.gz" .
cd "$TMPDIR"
echo "  OK ($(du -sh data.tar.gz | cut -f1))"

# ═══ 2. Собираем control.tar.gz ═══

echo "[2/4] Сборка control.tar.gz..."

# control
INSTALLED_SIZE=$(du -sk "$TMPDIR/data" | cut -f1)
cat > "$TMPDIR/ctrl/control" << CTRL
Package: $PKG_NAME
Version: ${PKG_VERSION}-r${PKG_RELEASE}
Depends: libc, luci-base, jsonfilter
License: MIT
Section: luci
Architecture: all
Installed-Size: $((INSTALLED_SIZE * 1024))
Description: VPN Bot — подключение роутера к VPN через Telegram-код.
 Поддерживает PassWall, auto-setup, bypass-листы, heartbeat, обновления конфига.
CTRL

# conffiles — только конкретные файлы, не директории
cat > "$TMPDIR/ctrl/conffiles" << 'CONF'
/etc/vpn/bypass_ips.txt
/etc/vpn/bypass_domains.txt
CONF

# postinst — минимальный, фоновый, без default_postinst
cat > "$TMPDIR/ctrl/postinst" << 'POSTINST_EOF'
#!/bin/sh
# Exits immediately — defers all heavy work to background.
# Prevents OOM on routers with 32-64MB RAM.
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && exit 0

SETUP=/tmp/.vpn-setup.sh
cat > "$SETUP" << 'ENDSETUP'
#!/bin/sh
sleep 5
LOG=/tmp/vpn-install.log
PROG=/tmp/vpn-progress
progress() { printf '{"stage":"%s","pct":%d,"msg":"%s"}' "$1" "$2" "$3" > "$PROG"; }

echo "[$(date '+%H:%M:%S')] vpn-setup: start" >> "$LOG"
progress "setup" 5 "Инициализация..."

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

for P in curl ca-bundle jsonfilter; do
    opkg list-installed 2>/dev/null | grep -q "^$P " && continue
    echo "[$(date '+%H:%M:%S')] vpn-setup: installing $P" >> "$LOG"
    progress "setup" 20 "Устанавливаем $P..."
    opkg install "$P" >> "$LOG" 2>&1 && {
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        continue
    }
    opkg update >> "$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    opkg install "$P" >> "$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
done

if ! command -v xray > /dev/null 2>&1 && [ ! -x /tmp/xray ]; then
    OWRT_ARCH=$(opkg print-architecture 2>/dev/null | awk '$1=="arch" && $3>=10 {print $2}' | grep -v 'all\|noarch' | tail -1)
    if [ -z "$OWRT_ARCH" ]; then
        echo "[$(date '+%H:%M:%S')] vpn-setup: cannot detect arch, skipping xray" >> "$LOG"
    else
        echo "[$(date '+%H:%M:%S')] vpn-setup: downloading xray for ${OWRT_ARCH}" >> "$LOG"
        progress "setup" 50 "Загружаем xray для ${OWRT_ARCH}..."
        curl -fsSL --connect-timeout 15 --max-time 120 \
            -o /tmp/xray "https://self-music.online/packages/latest/${OWRT_ARCH}/xray" >> "$LOG" 2>&1 && \
            [ -s /tmp/xray ] && chmod +x /tmp/xray && \
            echo "[$(date '+%H:%M:%S')] vpn-setup: xray downloaded ok" >> "$LOG"
    fi
fi

chmod +x /usr/bin/vpn-connect.sh /usr/bin/vpn-agent.sh /usr/bin/vpn-apply.sh 2>/dev/null
/etc/init.d/xray-fetch enable 2>/dev/null
/etc/init.d/vpn-agent enable 2>/dev/null
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

progress "ready" 100 ""
echo "[$(date '+%H:%M:%S')] vpn-setup: done" >> "$LOG"
rm -f "$SETUP"
ENDSETUP

chmod +x "$SETUP"
(sh "$SETUP" > /dev/null 2>&1) &
exit 0
POSTINST_EOF
chmod 755 "$TMPDIR/ctrl/postinst"

# prerm
cat > "$TMPDIR/ctrl/prerm" << 'PRERM_EOF'
#!/bin/sh
[ -z "${IPKG_INSTROOT}" ] && {
    /etc/init.d/vpn-agent stop 2>/dev/null
    /etc/init.d/vpn-agent disable 2>/dev/null
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

# ═══ 4. Собираем IPK ═══

echo "[3/4] Сборка IPK..."
cd "$TMPDIR"
tar czf "$OUTPUT" ./debian-binary ./control.tar.gz ./data.tar.gz
echo "  OK"

# ═══ Итого ═══

SIZE=$(du -h "$OUTPUT" | cut -f1)
echo ""
echo "════════════════════════════════════"
echo "  Готово!"
echo "  Файл: $(basename $OUTPUT) ($SIZE)"
echo ""
echo "  Деплой на сервер:"
echo "    scp $(basename $OUTPUT) root@self-music.online:/var/www/self-music.online/router.ipk"
echo ""
echo "  Установка на роутере:"
echo "    opkg install https://self-music.online/router.ipk"
echo ""
echo "  Прогресс:"
echo "    tail -f /tmp/vpn-install.log"
echo "════════════════════════════════════"
