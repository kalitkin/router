#!/bin/sh
# Register Keenetic router with VPN server using a 6-digit OTP code
# Usage: vpn-connect-keenetic.sh <CODE>
# Writes token, device_id, mac to /opt/etc/vpn/

set -e

CODE="$1"
API_BASE="https://self-music.online/vpnapi/v1/router"
VPN_DIR="/opt/etc/vpn"
SINGBOX_DIR="/opt/etc/sing-box"

if [ -z "$CODE" ]; then
    echo "Usage: $0 <6-digit-code>"
    exit 1
fi

mkdir -p "$VPN_DIR" "$SINGBOX_DIR"

# Detect MAC from Bridge0 (Keenetic LAN bridge) or fallback
MAC=""
for iface in br0 Bridge0 br-lan eth0; do
    f="/sys/class/net/$iface/address"
    if [ -f "$f" ]; then
        m=$(cat "$f")
        if [ -n "$m" ] && [ "$m" != "00:00:00:00:00:00" ]; then
            MAC="$m"
            break
        fi
    fi
done
if [ -z "$MAC" ]; then
    MAC=$(cat /sys/class/net/*/address 2>/dev/null | grep -v "00:00:00:00:00:00" | head -1)
fi

echo "MAC: $MAC"

RAM=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo "0")
PAYLOAD="{\"code\":\"$CODE\",\"mac\":\"$MAC\",\"model\":\"Keenetic\",\"firmware\":\"Keenetic OS5\",\"ram_mb\":\"$RAM\"}"

RESPONSE=$(curl -s -m 20 -X POST "$API_BASE/register_by_code" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD")

echo "Response: $RESPONSE"

TOKEN=$(echo "$RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
DEVICE_ID=$(echo "$RESPONSE" | grep -o '"device_id":"[^"]*"' | cut -d'"' -f4)
CONFIG_URL=$(echo "$RESPONSE" | grep -o '"config":"[^"]*"' | cut -d'"' -f4)

if [ -z "$TOKEN" ]; then
    echo "ERROR: Registration failed — no token in response"
    exit 1
fi

echo "$TOKEN" > "$VPN_DIR/token"
echo "$DEVICE_ID" > "$VPN_DIR/device_id"
echo "$MAC" > "$VPN_DIR/mac"
chmod 600 "$VPN_DIR/token" "$VPN_DIR/device_id" "$VPN_DIR/mac"

echo "Registered: device_id=$DEVICE_ID"

if [ -n "$CONFIG_URL" ]; then
    SINGBOX_URL="${CONFIG_URL}/sing-box"
    echo "Fetching sing-box config from $SINGBOX_URL..."
    curl -s "$SINGBOX_URL" -o "$SINGBOX_DIR/config.json"
    echo "Config written to $SINGBOX_DIR/config.json"
fi

echo "Done. Run: /opt/etc/init.d/S99vpnd start"
