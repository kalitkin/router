#!/bin/bash
###############################################################################
# deploy-singbox.sh — скачивает sing-box с GitHub releases и раскладывает
# по CDN-путям OpenWrt архитектур.
#
# Usage:
#   bash files/deploy-singbox.sh             # latest release
#   bash files/deploy-singbox.sh 1.11.0      # конкретная версия
#   bash files/deploy-singbox.sh --check     # показать что уже есть
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

# ── Маппинг OpenWrt arch → sing-box release arch ─────────────────────────────

map_sb() {
    case "$1" in
        aarch64*)                       echo "linux-arm64" ;;
        arm_cortex-a15*|arm_cortex-a7_neon*|arm_cortex-a9_neon*) echo "linux-arm-v7" ;;
        arm_cortex-a7|arm_cortex-a7_vfpv4|arm_cortex-a8*|arm_cortex-a9*) echo "linux-arm-v7" ;;
        arm_xscale|arm_arm1176*)        echo "linux-arm-v5" ;;
        arm_*)                          echo "linux-arm-v7" ;;
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

# ── Скачиваем и раскладываем ─────────────────────────────────────────────────

declare -A CACHE
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

OK=0; SKIP=0; FAIL=0

for OWRT_ARCH in $ARCHS; do
    SB_ARCH=$(map_sb "$OWRT_ARCH")
    if [ -z "$SB_ARCH" ]; then
        echo "  SKIP: $OWRT_ARCH (no mapping)"
        SKIP=$((SKIP+1))
        continue
    fi

    DST="$WEB/$OWRT_ARCH"
    mkdir -p "$DST"

    # Проверяем кэш (тот же SB_ARCH уже скачан)
    if [ -n "${CACHE[$SB_ARCH]:-}" ]; then
        cp "${CACHE[$SB_ARCH]}" "$DST/sing-box"
        chmod 755 "$DST/sing-box"
        echo "  ✓ $OWRT_ARCH  (cached from $SB_ARCH)"
        OK=$((OK+1))
        continue
    fi

    # Собираем имя архива: sing-box-VERSION-linux-arch.tar.gz
    ARCHIVE="sing-box-${VERSION#v}-${SB_ARCH}.tar.gz"
    URL="$GITHUB/releases/download/$VERSION/$ARCHIVE"
    TGZ="$TMPDIR/$ARCHIVE"

    echo "  downloading $SB_ARCH..."
    if curl -fsSL --connect-timeout 15 --max-time 120 -o "$TGZ" "$URL" 2>/dev/null && [ -s "$TGZ" ]; then
        BIN=$(tar -tzf "$TGZ" 2>/dev/null | grep '/sing-box$' | head -1)
        if [ -n "$BIN" ]; then
            tar -xzf "$TGZ" -C "$TMPDIR" "$BIN" 2>/dev/null
            EXTRACTED="$TMPDIR/$BIN"
            if [ -f "$EXTRACTED" ]; then
                cp "$EXTRACTED" "$DST/sing-box"
                chmod 755 "$DST/sing-box"
                CACHE[$SB_ARCH]="$DST/sing-box"
                SIZE=$(du -sh "$DST/sing-box" | cut -f1)
                echo "  ✓ $OWRT_ARCH  ($SIZE)"
                OK=$((OK+1))
            else
                echo "  FAIL: $OWRT_ARCH — binary not found in archive"
                FAIL=$((FAIL+1))
            fi
        else
            echo "  FAIL: $OWRT_ARCH — sing-box not in archive"
            FAIL=$((FAIL+1))
        fi
    else
        echo "  FAIL: $OWRT_ARCH — download failed: $URL"
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "=== deploy-singbox done: $OK ok / $SKIP skip / $FAIL fail ==="
echo ""
ls -lh "$WEB"/*/sing-box 2>/dev/null | awk '{print "  " $NF, $5}'
