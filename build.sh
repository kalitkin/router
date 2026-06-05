#!/bin/sh
# Build vpnd for all OpenWrt architectures.
# Usage: ./build.sh [outdir]
set -e

OUTDIR="${1:-dist}"
mkdir -p "$OUTDIR"

VERSION=$(git describe --tags --always --dirty 2>/dev/null || echo "dev")
LDFLAGS="-s -w -X main.version=${VERSION}"

build() {
    local goos="$1" goarch="$2" gomips="${3:-}" goarm="${4:-}" name="$5"
    local out="${OUTDIR}/vpnd-${name}"
    # GOMIPS64 mirrors GOMIPS so mips64/mips64le builds also get softfloat.
    GOOS="$goos" GOARCH="$goarch" GOMIPS="$gomips" GOMIPS64="$gomips" GOARM="$goarm" \
        CGO_ENABLED=0 go build \
        -trimpath \
        -ldflags="$LDFLAGS" \
        -o "$out" \
        ./cmd/vpnd
    SIZE=$(du -sh "$out" | cut -f1)
    echo "  ✓ $name  ($SIZE)  →  $out"
}

echo "Building vpnd ${VERSION} for all OpenWrt targets..."
echo ""

# ── MIPS big-endian ───────────────────────────────────────────────────
# ar71xx, ath79, octeon — 24Kc/74Kc/4Kc cores
build linux mips     softfloat ""  mips-softfloat

# ── MIPS64 big-endian ─────────────────────────────────────────────────
# octeon, mips64r2 — rare but present (EdgeRouter Lite, etc.)
build linux mips64   softfloat ""  mips64-softfloat

# ── MIPSel little-endian ──────────────────────────────────────────────
# ramips/mt7620, mt7621 — most home routers (TP-Link, Xiaomi, etc.)
build linux mipsle   softfloat ""  mipsle-softfloat

# ── MIPS64el little-endian ────────────────────────────────────────────
build linux mips64le softfloat ""  mips64le-softfloat

# ── ARM ───────────────────────────────────────────────────────────────
# ARMv5: kirkwood, orion, FA526
build linux arm      ""        5   armv5
# ARMv6: BCM2835 (RPi 1), Marvell Kirkwood MV88F6281
build linux arm      ""        6   armv6
# ARMv7: ipq40xx, bcm53xx, sunxi, imx6, Cortex-A7/A8/A9/A15
build linux arm      ""        7   armv7

# ── ARM64 ─────────────────────────────────────────────────────────────
# ipq807x, mt7622, bcm2711 (RPi 4), rockchip, Cortex-A53/72/73/76
build linux arm64    ""        ""  arm64

# ── LoongArch64 ───────────────────────────────────────────────────────
# loongarch64 — emerging Chinese routers/SBCs
build linux loong64  ""        ""  loong64

# ── RISC-V 64 ─────────────────────────────────────────────────────────
# riscv64 — emerging (StarFive, SiFive boards)
build linux riscv64  ""        ""  riscv64

# ── x86 ───────────────────────────────────────────────────────────────
# x86 routers, VMs, containers
build linux amd64    ""        ""  x86_64
build linux 386      ""        ""  x86

echo ""
echo "Done. Artifacts in ./${OUTDIR}/"
ls -lh "${OUTDIR}/"
