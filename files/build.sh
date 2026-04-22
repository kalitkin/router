#!/bin/bash
###############################################################################
# build.sh — Скачивает xray-core бинарники и создаёт пакетный репозиторий
#
# Использование:
#   ./build.sh v1.0.0                    # топ-6 архитектур
#   ./build.sh v1.0.0 --all              # все 35 архитектур OpenWrt 24.10
#   ./build.sh v1.0.0 --xray v25.10.15  # конкретная версия xray
#   ./build.sh v1.0.0 --force            # перезаписать
#
# Требования на сервере: curl, unzip, sha256sum, jq
###############################################################################

set -euo pipefail

PACKAGES_ROOT="/var/www/self-music.online/packages"
XRAY_GITHUB="https://github.com/XTLS/Xray-core"
OPENWRT_DL="https://downloads.openwrt.org"
OPENWRT_RELEASE="24.10.4"

MAX_RETRIES=3

# Топ-6 архитектур — покрывают ~95% домашних роутеров
POPULAR_ARCHS="aarch64_cortex-a53 aarch64_cortex-a72 mipsel_24kc arm_cortex-a7_neon-vfpv4 arm_cortex-a15_neon-vfpv4 x86_64"

# ═══ Аргументы ═══

VERSION="${1:-}"
XRAY_VERSION=""
FORCE=0
ALL_ARCHS=0

[ -z "$VERSION" ] && { echo "Usage: $0 VERSION [--all] [--xray VER] [--force]"; exit 1; }

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --xray)   XRAY_VERSION="$2"; shift 2 ;;
        --force)  FORCE=1; shift ;;
        --all)    ALL_ARCHS=1; shift ;;
        *)        echo "Unknown: $1"; exit 1 ;;
    esac
done

# ═══ Утилиты ═══

log()  { echo "[$(date '+%H:%M:%S')] $1"; }
ok()   { echo "[$(date '+%H:%M:%S')] ✓ $1"; }
fail() { echo "[$(date '+%H:%M:%S')] ✗ $1" >&2; }

retry_dl() {
    local url="$1" out="$2" i=1
    while [ $i -le $MAX_RETRIES ]; do
        curl -fsSL --connect-timeout 15 --max-time 120 -o "$out" "$url" 2>/dev/null && [ -s "$out" ] && return 0
        i=$((i + 1)); sleep 3
    done
    rm -f "$out"; return 1
}

# OpenWrt arch → Xray release name
map_xray() {
    case "$1" in
        aarch64*)                                                   echo "arm64-v8a" ;;
        arm_cortex-a15*|arm_cortex-a7_neon*|arm_cortex-a9_neon*)    echo "arm32-v7a" ;;
        arm_cortex-a7|arm_cortex-a7_vfpv4|arm_cortex-a8*|arm_cortex-a9*) echo "arm32-v7a" ;;
        arm_*)                                                      echo "arm32-v5" ;;
        x86_64)                                                     echo "64" ;;
        i386*)                                                      echo "32" ;;
        mips_*)                                                     echo "mips32" ;;
        mipsel_*)                                                   echo "mips32le" ;;
        mips64_*)                                                   echo "mips64" ;;
        mips64el_*)                                                 echo "mips64le" ;;
        riscv64*)                                                   echo "riscv64" ;;
        loongarch64*)                                               echo "loong64" ;;
        *)                                                          echo "" ;;
    esac
}

# ═══ Проверки ═══

for CMD in curl unzip sha256sum jq; do
    command -v "$CMD" > /dev/null || { fail "need: $CMD"; exit 1; }
done

VERDIR="$PACKAGES_ROOT/$VERSION"
[ -d "$VERDIR" ] && [ $FORCE -eq 0 ] && { fail "$VERSION exists — use --force"; exit 1; }

# ═══ Версия xray ═══

if [ -z "$XRAY_VERSION" ]; then
    log "detecting latest xray-core..."
    XRAY_VERSION=$(curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" | jq -r '.tag_name')
    [ -z "$XRAY_VERSION" ] || [ "$XRAY_VERSION" = "null" ] && { fail "cannot get xray version"; exit 1; }
fi
ok "xray: $XRAY_VERSION"

# ═══ Список архитектур ═══

if [ $ALL_ARCHS -eq 1 ]; then
    log "fetching all OpenWrt architectures..."
    # Lookahead/lookbehind — извлекаем имя между href=" и /"
    # Только записи с '_' (все реальные arch имеют подчёркивание)
    ARCH_LIST=$(curl -fsSL "$OPENWRT_DL/releases/$OPENWRT_RELEASE/packages/" \
        | grep -oP '(?<=href=")[a-z][a-z0-9_-]+(?=/")' \
        | grep '_' \
        | sort -u)
else
    ARCH_LIST="$POPULAR_ARCHS"
fi

ARCH_COUNT=$(echo "$ARCH_LIST" | wc -w)
ok "architectures: $ARCH_COUNT"

# ═══ Создаём структуру ═══

mkdir -p "$VERDIR/common"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# ═══ Скачиваем xray для каждой архитектуры ═══

declare -A XRAY_CACHE
SUCCESS=0; SKIPPED=0; FAILED=0

for OWRT_ARCH in $ARCH_LIST; do
    XRAY_ARCH=$(map_xray "$OWRT_ARCH")
    [ -z "$XRAY_ARCH" ] && { SKIPPED=$((SKIPPED+1)); continue; }

    mkdir -p "$VERDIR/$OWRT_ARCH"

    # Уже скачан этот xray?
    if [ -n "${XRAY_CACHE[$XRAY_ARCH]:-}" ]; then
        cp "${XRAY_CACHE[$XRAY_ARCH]}" "$VERDIR/$OWRT_ARCH/xray"
        chmod +x "$VERDIR/$OWRT_ARCH/xray"
        ok "$OWRT_ARCH → $XRAY_ARCH (cached)"
        SUCCESS=$((SUCCESS+1))
        continue
    fi

    # Скачиваем
    ZIP_URL="$XRAY_GITHUB/releases/download/$XRAY_VERSION/Xray-linux-$XRAY_ARCH.zip"
    ZIP="$TMPDIR/$XRAY_ARCH.zip"
    EXTRACT="$TMPDIR/extract-$XRAY_ARCH"

    log "downloading xray $XRAY_ARCH..."
    if retry_dl "$ZIP_URL" "$ZIP"; then
        mkdir -p "$EXTRACT"
        unzip -qo "$ZIP" -d "$EXTRACT" 2>/dev/null

        BIN=$(find "$EXTRACT" -name "xray" -type f | head -1)
        if [ -n "$BIN" ] && [ -s "$BIN" ]; then
            cp "$BIN" "$VERDIR/$OWRT_ARCH/xray"
            chmod +x "$VERDIR/$OWRT_ARCH/xray"
            XRAY_CACHE[$XRAY_ARCH]="$VERDIR/$OWRT_ARCH/xray"
            SIZE=$(du -h "$VERDIR/$OWRT_ARCH/xray" | cut -f1)
            ok "$OWRT_ARCH → $XRAY_ARCH ($SIZE)"
            SUCCESS=$((SUCCESS+1))
        else
            fail "$OWRT_ARCH: xray not found in zip"
            FAILED=$((FAILED+1))
        fi
        rm -rf "$EXTRACT" "$ZIP"
    else
        fail "$OWRT_ARCH: download failed"
        FAILED=$((FAILED+1))
    fi
done

# ═══ SHA256 ═══

log "generating checksums..."
find "$VERDIR" -name "xray" -type f | while read -r F; do
    sha256sum "$F" | awk '{print $1}' > "${F}.sha256"
done

# ═══ Метаданные ═══

cat > "$VERDIR/VERSION" << EOF
version=$VERSION
xray_version=$XRAY_VERSION
openwrt_release=$OPENWRT_RELEASE
build_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
arch_count=$ARCH_COUNT
xray_ok=$SUCCESS
EOF

echo "$ARCH_LIST" | tr ' ' '\n' > "$VERDIR/architectures.txt"

# ═══ Симлинк ═══

ln -sfn "$VERSION" "$PACKAGES_ROOT/latest"

# ═══ Итого ═══

echo ""
echo "════════════════════════════════════════"
echo "  Build: $VERSION"
echo "  Xray:  $XRAY_VERSION"
echo "  Archs: $SUCCESS ok / $SKIPPED skip / $FAILED fail"
echo "  Path:  $VERDIR"
echo "  Link:  $PACKAGES_ROOT/latest → $VERSION"
echo "════════════════════════════════════════"
