#!/bin/bash
# Keenetic RCI API Playground
# Запуск: bash playground.sh [BASE_URL]
# Требует: curl, jq

BASE="${1:-http://localhost:8000}"
AUTH="admin:keenetic"

sep() { echo; echo "─── $* ───────────────────────────────────────────"; }

rci_get()  { curl -s -u "$AUTH" "$BASE/rci/$1" | jq .; }
rci_post() { curl -s -u "$AUTH" -X POST -H "Content-Type: application/json" -d "$2" "$BASE/rci/$1" | jq .; }

# ── 1. Карта RCI-дерева ───────────────────────────────────────────────────────
sep "RCI tree (карта API)"
curl -s -u "$AUTH" "$BASE/rci/" | jq .

# ── 2. Версия прошивки ────────────────────────────────────────────────────────
sep "show/version"
rci_get "show/version"
echo
echo "Модель:    $(curl -s -u "$AUTH" "$BASE/rci/show/version" | jq -r '.version.model')"
echo "Прошивка:  $(curl -s -u "$AUTH" "$BASE/rci/show/version" | jq -r '.version.release')"
echo "Устройство: $(curl -s -u "$AUTH" "$BASE/rci/show/version" | jq -r '.version["hw-id"]')"

# ── 3. Интерфейсы ─────────────────────────────────────────────────────────────
sep "show/interface — краткий список"
curl -s -u "$AUTH" "$BASE/rci/show/interface" | \
    jq -r '.interface | to_entries[] | "\(.key)\t\(.value.state // "?")\t\(.value.address // "-")"'

sep "show/interface/Wireguard0"
rci_get "show/interface/Wireguard0"

# ── 4. Таблица маршрутизации ──────────────────────────────────────────────────
sep "show/ip/route"
curl -s -u "$AUTH" "$BASE/rci/show/ip/route" | \
    jq -r '.route[] | "\(.destination)/\(.prefix)\t→ \(.interface)\t[\(.proto)]"'

# ── 5. Системная информация ───────────────────────────────────────────────────
sep "show/system"
curl -s -u "$AUTH" "$BASE/rci/show/system" | \
    jq -r '"Uptime: \(.system.uptime)s  |  RAM free: \(.system.memory.free / 1024 / 1024 | floor)MB  |  CPU: \(.system.cpu.usage)%"'

# ── 6. Running config ─────────────────────────────────────────────────────────
sep "show/rc/running"
rci_get "show/rc/running"

# ── 7. WireGuard — настройка пира ────────────────────────────────────────────
sep "POST: настроить WireGuard пир"
rci_post "interface/Wireguard0" '{
  "wireguard": {
    "peer": {
      "public-key": "test-pubkey-base64==",
      "endpoint": "vpn.example.com:51820",
      "allowed-address": "0.0.0.0/0",
      "persistent-keepalive": 25
    },
    "address": "10.0.0.2"
  }
}'

# ── 8. WireGuard — включить ───────────────────────────────────────────────────
sep "POST: включить WireGuard (up: true)"
rci_post "interface/Wireguard0" '{"up": true}'

sep "Wireguard0 состояние после включения"
curl -s -u "$AUTH" "$BASE/rci/show/interface/Wireguard0" | \
    jq -r '.interface.Wireguard0 | "State: \(.state)  Connected: \(.connected)  IP: \(.address // "-")"'

# ── 9. Маршруты после VPN UP ─────────────────────────────────────────────────
sep "Маршруты после VPN UP"
curl -s -u "$AUTH" "$BASE/rci/show/ip/route" | \
    jq -r '.route[] | "\(.destination)/\(.prefix)\t→ \(.interface)\t[\(.proto)]"'

# ── 10. WireGuard — выключить ─────────────────────────────────────────────────
sep "POST: выключить WireGuard (up: false)"
rci_post "interface/Wireguard0" '{"up": false}'

# ── 11. Batch ─────────────────────────────────────────────────────────────────
sep "POST /rci/ — batch: version + interface + system одним запросом"
rci_post "" '{
  "show": {
    "version": {},
    "interface": {},
    "system": {}
  }
}'

# ── 12. Auth challenge-response ───────────────────────────────────────────────
sep "Auth: MD5 challenge-response"
echo "Шаг 1 — получить challenge:"
CHALLENGE=$(curl -si "$BASE/auth" 2>/dev/null | grep -i "X-NDM-Challenge:" | awk '{print $2}' | tr -d '\r')
REALM=$(curl -si "$BASE/auth" 2>/dev/null | grep -i "X-NDM-Realm:" | cut -d' ' -f2- | tr -d '\r')
echo "  Challenge: $CHALLENGE"
echo "  Realm:     $REALM"

if command -v python3 &>/dev/null && [ -n "$CHALLENGE" ]; then
    HASH=$(python3 -c "
import hashlib, sys
pw, realm, challenge = sys.argv[1], sys.argv[2], sys.argv[3]
pw_md5 = hashlib.md5(pw.encode()).hexdigest()
result = hashlib.md5((realm + pw_md5 + challenge).encode()).hexdigest()
print(result)
" "keenetic" "$REALM" "$CHALLENGE" 2>/dev/null)
    echo
    echo "Шаг 2 — логин с MD5 hash ($HASH):"
    curl -s -X POST -H "Content-Type: application/json" \
        -d "{\"login\": \"admin\", \"password\": \"$HASH\"}" \
        "$BASE/auth" | jq .
fi

echo
echo "Playground завершён. Mock API работает на $BASE"
