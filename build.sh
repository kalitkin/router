#!/bin/sh
# Build vpnd for all OpenWrt architectures.
# Usage: ./build.sh [outdir]
set -e

OUTDIR="${1:-dist}"
mkdir -p "$OUTDIR"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS="-s -w -X main.version=${VERSION}"

build() {
    GOOS="$1" GOARCH="$2" GOMIPS="${3:-}" GOARM="${4:-}" NAME="$5"

    out="${OUTDIR}/vpnd-${NAME}"
    GOOS="$GOOS" GOARCH="$GOARCH" GOMIPS="$GOMIPS" GOARM="$GOARM" \
        CGO_ENABLED=0 go build \
        -trimpath \
        -ldflags="$LDFLAGS" \
        -o "$out" \
        ./cmd/vpnd

    SIZE=$(du -sh "$out" | cut -f1)
    echo "  ✓ $NAME  ($SIZE)  →  $out"
}

echo "Building vpnd ${VERSION} for all OpenWrt targets..."
echo ""

# ── MIPS (big-endian, softfloat) ─────────────────────────────────────
# ar71xx, ath79, octeon
build linux mips    softfloat ""  mips-softfloat

# ── MIPSel (little-endian, softfloat) ────────────────────────────────
# ramips/mt7620, mt7621 — most home routers (TP-Link, Xiaomi, etc.)
build linux mipsle  softfloat ""  mipsle-softfloat

# ── ARM ──────────────────────────────────────────────────────────────
# ARMv5: kirkwood, orion
build linux arm     ""        5   armv5
# ARMv7: ipq40xx, bcm53xx, sunxi, imx6, many others
build linux arm     ""        7   armv7

# ── ARM64 ────────────────────────────────────────────────────────────
# ipq807x, mt7622, bcm2711 (RPi 4), rockchip
build linux arm64   ""        ""  arm64

# ── x86 ──────────────────────────────────────────────────────────────
# x86 routers, VMs, containers
build linux amd64   ""        ""  x86_64
build linux 386     ""        ""  x86

echo ""
echo "Done. Artifacts in ./${OUTDIR}/"
ls -lh "${OUTDIR}/"
