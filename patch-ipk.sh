#!/bin/bash
###############################################################################
# patch-ipk.sh — патчит IPK для роутеров с малым объёмом RAM
#
# Проблема: opkg install router.ipk убивается OOM-киллером потому что:
#   1. Depends: curl, ca-bundle → opkg update → 10-20MB индекс пакетов в RAM
#   2. default_postinst (luci.mk) → перестройка LuCI cache через Lua → +5-10MB
#   3. Всё это одновременно, пока opkg сам в памяти
#
# Решение:
#   - Убираем curl/ca-bundle из Depends (opkg не трогает package lists)
#   - Заменяем postinst на минимальный: запускает фоновый скрипт и сразу выходит
#   - Фоновый скрипт запускается ПОСЛЕ того как opkg вышел и освободил память
#   - opkg update + install deps — последовательно, по одному пакету за раз
#
# Использование:
#   ./patch-ipk.sh                           # патчит первый .ipk в текущей папке
#   ./patch-ipk.sh input.ipk                 # патчит конкретный файл
#   ./patch-ipk.sh input.ipk output.ipk      # указать имя результата
###############################################################################

set -e

INPUT="${1:-}"
if [ -z "$INPUT" ]; then
    INPUT=$(ls luci-app-vpnbot_*.ipk 2>/dev/null | sort -V | tail -1)
fi

if [ -z "$INPUT" ] || [ ! -f "$INPUT" ]; then
    echo "ERROR: IPK файл не найден"
    echo "Использование: $0 [input.ipk] [output.ipk]"
    exit 1
fi

# Имя выходного файла: меняем суффикс на _r2_all.ipk
BASE="${INPUT%_all.ipk}"
BASE="${BASE%_r1}"
BASE="${BASE%_r2}"
OUTPUT="${2:-${BASE}_r2_all.ipk}"

echo "=== IPK Patcher ==="
echo "Вход:  $INPUT"
echo "Выход: $OUTPUT"
echo ""

WORKDIR=$(pwd)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ═══ 1. Распаковываем IPK ═══

echo "[1/5] Распаковка IPK..."
cd "$TMPDIR"
tar xzf "$WORKDIR/$INPUT"
echo "  OK"

# ═══ 2. Распаковываем control.tar.gz ═══

echo "[2/5] Распаковка control.tar.gz..."
mkdir -p ctrl
cd ctrl
tar xzf "$TMPDIR/control.tar.gz"
cd "$TMPDIR"
echo "  OK"

# ═══ 3. Записываем новый postinst ═══

echo "[3/5] Заменяем postinst на memory-safe версию..."

cat > ctrl/postinst << 'POSTINST_EOF'
#!/bin/sh
# Minimal postinst — exits immediately, defers all heavy work to background.
# This prevents OOM on routers with 32-64MB RAM.
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "${IPKG_INSTROOT}" ] && exit 0

SETUP=/tmp/.vpn-setup.sh
cat > "$SETUP" << 'ENDSETUP'
#!/bin/sh
# Deferred setup — runs after opkg exits (full RAM available again)
sleep 5
LOG=/tmp/vpn-install.log
echo "[$(date '+%H:%M:%S')] vpn-setup: start" >> "$LOG"

# Free page cache
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null

# Install missing deps one at a time.
# First try without opkg update (uses cached package lists).
# Only run opkg update if a package is truly missing.
for P in curl ca-bundle jsonfilter; do
    opkg list-installed 2>/dev/null | grep -q "^$P " && continue
    echo "[$(date '+%H:%M:%S')] vpn-setup: installing $P" >> "$LOG"
    opkg install "$P" >> "$LOG" 2>&1 && {
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        continue
    }
    # Install failed — need fresh package lists
    echo "[$(date '+%H:%M:%S')] vpn-setup: opkg update (needed for $P)" >> "$LOG"
    opkg update >> "$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    opkg install "$P" >> "$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
done

# Permissions
chmod +x /usr/bin/vpn-connect.sh /usr/bin/vpn-agent.sh /usr/bin/vpn-apply.sh 2>/dev/null

# Enable agent (only if not already registered — token not present yet)
/etc/init.d/vpn-agent enable 2>/dev/null

# Clear LuCI cache so the new menu item appears on next page load
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null

echo "[$(date '+%H:%M:%S')] vpn-setup: done" >> "$LOG"
rm -f "$SETUP"
ENDSETUP

chmod +x "$SETUP"
# Run in subshell so it's detached from opkg process group
(sh "$SETUP" > /dev/null 2>&1) &
exit 0
POSTINST_EOF

chmod 755 ctrl/postinst

# postinst-pkg больше не нужен (был нужен только для default_postinst из luci.mk)
cat > ctrl/postinst-pkg << 'PREINST_EOF'
#!/bin/sh
exit 0
PREINST_EOF
chmod 755 ctrl/postinst-pkg

echo "  OK"

# ═══ 4. Обновляем control (убираем curl, ca-bundle из Depends) ═══

echo "[4/5] Обновляем Depends в control..."

# Меняем Depends: оставляем только libc, luci-base, jsonfilter
sed -i 's/^Depends:.*/Depends: libc, luci-base, jsonfilter/' ctrl/control

# Меняем версию на r2
sed -i 's/^Version:.*/Version: 1.1.0-r2/' ctrl/control

echo "  Новый Depends: $(grep ^Depends ctrl/control)"
echo "  Новая Version: $(grep ^Version ctrl/control)"

# ═══ 5. Пересобираем IPK ═══

echo "[5/5] Пересборка IPK..."

# Пересобираем control.tar.gz
cd ctrl
tar czf "$TMPDIR/control.tar.gz" .
cd "$TMPDIR"

# Пересобираем IPK (tar.gz из debian-binary + control.tar.gz + data.tar.gz)
tar czf "$WORKDIR/$OUTPUT" ./debian-binary ./control.tar.gz ./data.tar.gz

echo "  OK"

# ═══ Итого ═══

SIZE=$(du -h "$WORKDIR/$OUTPUT" | cut -f1)
echo ""
echo "════════════════════════════════════"
echo "  Готово!"
echo "  Файл: $OUTPUT ($SIZE)"
echo ""
echo "  Деплой на сервер:"
echo "    scp $OUTPUT root@self-music.online:/var/www/self-music.online/router.ipk"
echo ""
echo "  Установка на роутере:"
echo "    opkg install https://self-music.online/router.ipk"
echo ""
echo "  Прогресс установки (через 10 сек после opkg):"
echo "    tail -f /tmp/vpn-install.log"
echo "════════════════════════════════════"
