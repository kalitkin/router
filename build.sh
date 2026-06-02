#!/bin/sh
# Build vpnd for OpenWrt mipsel_24kc (ramips/mt7621)
set -e

OUT="${1:-vpnd-mipsle}"

GOOS=linux GOARCH=mipsle GOMIPS=softfloat \
    CGO_ENABLED=0 \
    go build \
    -trimpath \
    -ldflags="-s -w" \
    -o "$OUT" \
    ./cmd/vpnd

echo "Built: $OUT ($(du -sh "$OUT" | cut -f1))"
