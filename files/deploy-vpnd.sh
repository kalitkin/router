#!/bin/bash
###############################################################################
# deploy-vpnd.sh — раскладывает vpnd-бинарники по CDN-путям OpenWrt архитектур.
# Запускается на сервере после SCP dist/ → /tmp/vpnd-dist/
#
# Usage: bash files/deploy-vpnd.sh [dist-dir]
###############################################################################

set -e

DIST="${1:-/tmp/vpnd-dist}"
WEB="/var/www/self-music.online/packages/latest"

if [ ! -d "$DIST" ]; then
    echo "ERROR: dist dir not found: $DIST"
    exit 1
fi

echo "=== deploy-vpnd: installing from $DIST ==="

install_bin() {
    local src="$DIST/vpnd-$1"
    local arch="$2"
    local dst="$WEB/$arch"

    if [ ! -f "$src" ]; then
        echo "  WARN: $src not found — skipping $arch"
        return
    fi

    mkdir -p "$dst"
    cp "$src" "$dst/vpnd"
    chmod 755 "$dst/vpnd"
    echo "  ✓ $arch  ($(du -sh "$dst/vpnd" | cut -f1))"
}

# ── MIPS big-endian ──────────────────────────────────────────────────────────
install_bin mips-softfloat      mips-softfloat
install_bin mips-softfloat      mips_24kc
install_bin mips-softfloat      mips_4kc
install_bin mips-softfloat      mips_4kec
install_bin mips-softfloat      mips_74kc
install_bin mips-softfloat      mips_mips32

# ── MIPS64 big-endian ────────────────────────────────────────────────────────
install_bin mips64-softfloat    mips64_mips642
install_bin mips64-softfloat    mips64_mips64r2
install_bin mips64-softfloat    mips64_octeonplus
install_bin mips64-softfloat    mips64_octonplus

# ── MIPSel little-endian ─────────────────────────────────────────────────────
install_bin mipsle-softfloat    mipsle
install_bin mipsle-softfloat    mipsle-softfloat
install_bin mipsle-softfloat    mipsel_24kc
install_bin mipsle-softfloat    mipsel_24kc_24kf
install_bin mipsle-softfloat    mipsel_24kec
install_bin mipsle-softfloat    mipsel_74kc
install_bin mipsle-softfloat    mipsel_mips32

# ── MIPS64el little-endian ───────────────────────────────────────────────────
install_bin mips64le-softfloat  mips64el_mips64r2

# ── ARM ──────────────────────────────────────────────────────────────────────
install_bin armv5               armv5
install_bin armv5               arm_arm926ej-s
install_bin armv5               arm_fa526
install_bin armv5               arm_xscale
install_bin armv6               arm_arm1176jzf-s_vfp
install_bin armv7               armv7
install_bin armv7               arm_cortex-a5_vfpv4
install_bin armv7               arm_cortex-a7
install_bin armv7               arm_cortex-a7_neon-vfpv4
install_bin armv7               arm_cortex-a7_vfpv4
install_bin armv7               arm_cortex-a8_vfpv3
install_bin armv7               arm_cortex-a9
install_bin armv7               arm_cortex-a9_neon
install_bin armv7               arm_cortex-a9_vfpv3-d16
install_bin armv7               arm_cortex-a15_neon-vfpv4

# ── ARM64 ────────────────────────────────────────────────────────────────────
install_bin arm64               arm64
install_bin arm64               aarch64_cortex-a53
install_bin arm64               aarch64_cortex-a72
install_bin arm64               aarch64_cortex-a73
install_bin arm64               aarch64_cortex-a76
install_bin arm64               aarch64_generic

# ── LoongArch64 ──────────────────────────────────────────────────────────────
install_bin loong64             loongarch64_generic

# ── RISC-V 64 ────────────────────────────────────────────────────────────────
install_bin riscv64             riscv64_riscv64

# ── x86 ──────────────────────────────────────────────────────────────────────
install_bin x86_64              x86_64
install_bin x86                 x86
install_bin x86                 i386_pentium4
install_bin x86                 i386_pentium-mmx
install_bin x86                 i386_pntium4
install_bin x86                 i386_pntium-mmx

echo ""
echo "=== deploy-vpnd done ==="
ls -lh "$WEB"/*/vpnd 2>/dev/null | awk '{print "  " $NF, $5}'
