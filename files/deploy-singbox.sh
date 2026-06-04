#!/bin/bash
###############################################################################
# deploy-singbox.sh — скачивает sing-box с GitHub releases и раскладывает
# по CDN-путям OpenWrt архитектур.
#
# Usage:
#   bash files/deploy-singbox.sh             # latest release
#   bash files/deploy-singbox.sh 1.13.13     # конкретная версия
#   bash files/deploy-singbox.sh --check     # показать что уже есть
#
# Стратегия:
#   1. Пробуем OpenWrt-специфичный IPK (sing-box_VER_openwrt_ARCH.ipk)
#      — есть для большинства arch, оптимизирован под конкретный CPU.
#   2. Fallback на generic tar.gz (sing-box-VER-linux-ARCH.tar.gz).
#
# Запускать на сервере (root@self-music.online).
###############################################################################

set -e

WEB="/var/www/self-music.online/packages/latest"
GITHUB="https://github.com/SagerNet/sing-box"
API="https://api.github.com/repos/SagerNet/sing-box"

# ── Версия ───────────────────────────────────────────────────────────────────

if [ "${1:-}" = "--check" ]; then
    echo "=== sing-box on CDN ==="
    ls -lh "$WEB"/*/sing-box 2>/dev/null | awk '{print "  " $NF, $5}' || echo "  (none)"
    exit 0
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "detecting latest sing-box release..."
    VERSION=$(curl -fsSL "$API/releases/latest" | grep '"tag_name"' | head -1 | grep -oP 'v[\d.]+')
    [ -z "$VERSION" ] && { echo "ERROR: cannot detect latest version"; exit 1; }
fi
echo "sing-box version: $VERSION"

# ── Fallback: маппинг OpenWrt arch → generic tar.gz arch ────────────────────
# Используется только если OpenWrt IPK для данной arch не существует.

map_sb_generic() {
    case "$1" in
        aarch64*)                       echo "linux-arm64" ;;
        arm_xscale|arm_arm1176*)        echo "linux-armv5" ;;
        arm_*)                          echo "linux-armv7" ;;
        mipsel_*)                       echo "linux-mipsle-softfloat" ;;
        mips_*)                         echo "linux-mips-softfloat" ;;
        x86_64)                         echo "linux-amd64" ;;
        i386*)                          echo "linux-386" ;;
        *)                              echo "" ;;
    esac
}

# ── Архитектуры ──────────────────────────────────────────────────────────────

ARCHS="
aarch64_cortex-a53
aarch64_cortex-a72
aarch64_cortex-a73
aarch64_generic
arm_cortex-a7_neon-vfpv4
arm_cortex-a7
arm_cortex-a9
arm_cortex-a15_neon-vfpv4
arm_xscale
mipsel_24kc
mipsel_24kec
mipsel_74kc
mips_24kc
mips_74kc
x86_64
i386_pentium4
"

# ── Вспомогательные функции ──────────────────────────────────────────────────

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Скачать и установить из OpenWrt IPK.
# IPK — это ar-архив, внутри data.tar.gz с /usr/bin/sing-box.
try_ipk() {
    local OWRT_ARCH="$1" DST="$2"
    local IPK_NAME="sing-box_${VERSION#v}_openwrt_${OWRT_ARCH}.ipk"
    local IPK_URL="$GITHUB/releases/download/$VERSION/$IPK_NAME"
    local IPK_FILE="$TMPDIR/$IPK_NAME"

    curl -fsSL --connect-timeout 15 --max-time 120 -o "$IPK_FILE" "$IPK_URL" 2>/dev/null || return 1
    [ -s "$IPK_FILE" ] || return 1

    local DATA_TGZ="$TMPDIR/data_${OWRT_ARCH}.tar.gz"
    # New sing-box IPK format: tar.gz(data.tar.gz + control.tar.gz + debian-binary)
    # Old classic IPK format: ar archive containing data.tar.gz
    if file "$IPK_FILE" 2>/dev/null | grep -q gzip; then
        tar -xzf "$IPK_FILE" -O data.tar.gz > "$DATA_TGZ" 2>/dev/null
    else
        ar p "$IPK_FILE" data.tar.gz > "$DATA_TGZ" 2>/dev/null
    fi
    [ -s "$DATA_TGZ" ] || return 1

    local EXTRACT_DIR="$TMPDIR/ex_${OWRT_ARCH}"
    mkdir -p "$EXTRACT_DIR"
    tar -xzf "$DATA_TGZ" -C "$EXTRACT_DIR" "./usr/bin/sing-box" 2>/dev/null || return 1
    [ -f "$EXTRACT_DIR/usr/bin/sing-box" ] || return 1

    cp "$EXTRACT_DIR/usr/bin/sing-box" "$DST/sing-box"
    chmod 755 "$DST/sing-box"
    return 0
}

# Скачать и установить из generic tar.gz (с кэшем по SB_ARCH).
# Печатает результат сама; возвращает 0 при успехе.
declare -A GEN_CACHE
try_generic() {
    local OWRT_ARCH="$1" DST="$2"
    local SB_ARCH
    SB_ARCH=$(map_sb_generic "$OWRT_ARCH")
    [ -z "$SB_ARCH" ] && return 1

    if [ -n "${GEN_CACHE[$SB_ARCH]:-}" ]; then
        cp "${GEN_CACHE[$SB_ARCH]}" "$DST/sing-box"
        chmod 755 "$DST/sing-box"
        local SIZE; SIZE=$(du -sh "$DST/sing-box" | cut -f1)
        echo "  ✓ $OWRT_ARCH  ($SIZE, generic/$SB_ARCH cached)"
        return 0
    fi

    local ARCHIVE="sing-box-${VERSION#v}-${SB_ARCH}.tar.gz"
    local URL="$GITHUB/releases/download/$VERSION/$ARCHIVE"
    local TGZ="$TMPDIR/$ARCHIVE"

    curl -fsSL --connect-timeout 15 --max-time 120 -o "$TGZ" "$URL" 2>/dev/null || return 1
    [ -s "$TGZ" ] || return 1

    local BIN
    BIN=$(tar -tzf "$TGZ" 2>/dev/null | grep '/sing-box$' | head -1)
    [ -n "$BIN" ] || return 1

    tar -xzf "$TGZ" -C "$TMPDIR" "$BIN" 2>/dev/null
    local EXTRACTED="$TMPDIR/$BIN"
    [ -f "$EXTRACTED" ] || return 1

    cp "$EXTRACTED" "$DST/sing-box"
    chmod 755 "$DST/sing-box"
    GEN_CACHE[$SB_ARCH]="$DST/sing-box"
    local SIZE; SIZE=$(du -sh "$DST/sing-box" | cut -f1)
    echo "  ✓ $OWRT_ARCH  ($SIZE, generic/$SB_ARCH)"
    return 0
}

# ── Скачиваем и раскладываем ─────────────────────────────────────────────────

OK=0; SKIP=0; FAIL=0

for OWRT_ARCH in $ARCHS; do
    DST="$WEB/$OWRT_ARCH"
    mkdir -p "$DST"

    if try_ipk "$OWRT_ARCH" "$DST"; then
        SIZE=$(du -sh "$DST/sing-box" | cut -f1)
        echo "  ✓ $OWRT_ARCH  ($SIZE, ipk)"
        OK=$((OK+1))
    elif try_generic "$OWRT_ARCH" "$DST"; then
        OK=$((OK+1))
    else
        echo "  FAIL: $OWRT_ARCH — both ipk and generic download failed"
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "=== deploy-singbox done: $OK ok / $SKIP skip / $FAIL fail ==="
echo ""
ls -lh "$WEB"/*/sing-box 2>/dev/null | awk '{print "  " $NF, $5}'
