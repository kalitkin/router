#!/bin/sh
# Integration tests for Keenetic VPN scripts
# Runs inside test-runner container against mock services.

PASS=0
FAIL=0
SKIP=0

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
RESET='\033[0m'

pass() { printf "  ${GREEN}PASS${RESET}: %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "  ${RED}FAIL${RESET}: %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "  ${YELLOW}SKIP${RESET}: %s\n" "$1"; SKIP=$((SKIP+1)); }

section() { printf "\n=== %s ===\n" "$1"; }
info()    { printf "  info: %s\n" "$1"; }

# ── Ожидание сервисов ─────────────────────────────────────────────────────────

wait_for() {
    url="$1"
    label="$2"
    printf "Waiting for %s..." "$label"
    for i in $(seq 1 30); do
        curl -sf "$url" > /dev/null 2>&1 && { echo " OK"; return 0; }
        sleep 1
        printf "."
    done
    echo " TIMEOUT"
    return 1
}

wait_for "http://mock-vpnapi:8080/health"    "mock-vpnapi" || { echo "FATAL: mock-vpnapi not available"; exit 1; }
wait_for "http://keenetic-mock:8000/"        "keenetic-mock" || { echo "FATAL: keenetic-mock not available"; exit 1; }

# ── Сброс состояния ───────────────────────────────────────────────────────────

reset_state() {
    rm -f /opt/etc/vpn/token /opt/etc/vpn/device_id /opt/etc/vpn/config \
          /opt/etc/vpn/secret /opt/etc/vpn/mac /opt/etc/vpn/arch \
          /opt/etc/vpn/rci_password /opt/etc/vpn/applied_hash \
          /opt/etc/xray/config.json /opt/etc/xray/config.json.bak \
          /opt/var/run/xray.pid /opt/var/run/vpn-agent.pid
    rm -rf /tmp/iptables_state
    # Убить stub xray если запущен
    pkill -f "sleep 86400" 2>/dev/null || true
    sleep 1
}

# ═══════════════════════════════════════════════════════════════════════════════
section "Test Suite: keenetic-connect.sh"
# ═══════════════════════════════════════════════════════════════════════════════

section "1 — код валидация (без сети)"

sh /opt/bin/keenetic-connect.sh 2>/dev/null
[ $? -ne 0 ] && pass "no-args returns error" || fail "no-args should return error"

sh /opt/bin/keenetic-connect.sh abc123 2>/dev/null
[ $? -ne 0 ] && pass "rejects non-numeric code" || fail "accepted non-numeric code"

sh /opt/bin/keenetic-connect.sh 12345 2>/dev/null
[ $? -ne 0 ] && pass "rejects 5-digit code" || fail "accepted 5-digit code"

sh /opt/bin/keenetic-connect.sh 1234567 2>/dev/null
[ $? -ne 0 ] && pass "rejects 7-digit code" || fail "accepted 7-digit code"

# ── Предотвращаем запуск агента (нет init.d и нет keenetic-agent.sh в PATH)
# keenetic-connect.sh пытается запустить агента — подавим это через stub
mkdir -p /opt/etc/init.d

section "2 — регистрация по коду"
reset_state

# Перехватим запуск агента
cat > /opt/etc/init.d/S99vpn-agent << 'EOF'
#!/bin/sh
[ "$1" = "start" ] && echo "[stub] vpn-agent start called" && exit 0
EOF
chmod +x /opt/etc/init.d/S99vpn-agent

output=$(sh /opt/bin/keenetic-connect.sh 123456 2>&1)
ret=$?

info "exit code: $ret"
info "output: $(echo "$output" | tail -1)"

[ $ret -eq 0 ] && pass "exit code 0" || fail "exit code $ret (output: $output)"

[ -f /opt/etc/vpn/token ]     && pass "token saved"     || fail "token missing"
[ -f /opt/etc/vpn/device_id ] && pass "device_id saved" || fail "device_id missing"
[ -f /opt/etc/vpn/config ]    && pass "config saved"    || fail "config missing"
[ -f /opt/etc/vpn/mac ]       && pass "mac saved"       || fail "mac missing"
[ -f /opt/etc/vpn/arch ]      && pass "arch saved"      || fail "arch missing"

TOKEN=$(cat /opt/etc/vpn/token 2>/dev/null)
[ "$TOKEN" = "test-token-abc123def456" ] && pass "token matches" || fail "token='$TOKEN'"

CONFIG=$(cat /opt/etc/vpn/config 2>/dev/null)
printf '%s' "$CONFIG" | grep -q "mock-vpnapi" && pass "config is subscription URL" || \
    fail "config='$CONFIG'"

ARCH=$(cat /opt/etc/vpn/arch 2>/dev/null)
info "detected arch: $ARCH"
[ -n "$ARCH" ] && pass "arch non-empty" || fail "arch empty"

section "3 — регистрация с RCI паролем"
reset_state
cat > /opt/etc/init.d/S99vpn-agent << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x /opt/etc/init.d/S99vpn-agent

sh /opt/bin/keenetic-connect.sh 123456 keenetic 2>/dev/null
ret=$?
[ $ret -eq 0 ] && pass "with RCI pass: exit code 0" || fail "with RCI pass: failed ($ret)"
[ -f /opt/etc/vpn/rci_password ] && pass "rci_password saved" || fail "rci_password not saved"

# ═══════════════════════════════════════════════════════════════════════════════
section "Test Suite: keenetic-apply.sh"
# ═══════════════════════════════════════════════════════════════════════════════

section "4 — apply без config файла"

reset_state
sh /opt/bin/keenetic-apply.sh 2>/dev/null
[ $? -ne 0 ] && pass "fails without config file" || fail "should fail without config"

section "5 — полный apply"

reset_state
# Записываем subscription URL напрямую (как если бы connect уже отработал)
SUB_URL=$(curl -sf http://mock-vpnapi:8080/ 2>/dev/null | grep -o '"sub_url":"[^"]*"' | cut -d'"' -f4)
[ -z "$SUB_URL" ] && SUB_URL="http://mock-vpnapi:8080/subscription/test"
printf '%s' "$SUB_URL" > /opt/etc/vpn/config
info "using subscription URL: $SUB_URL"

sh /opt/bin/keenetic-apply.sh 2>/dev/null
ret=$?
[ $ret -eq 0 ] && pass "apply exit code 0" || fail "apply exit code $ret"

[ -f /opt/etc/xray/config.json ] && pass "xray config.json created" || fail "config.json missing"

if [ -f /opt/etc/xray/config.json ]; then
    grep -q '"inbounds"'  /opt/etc/xray/config.json && pass "has inbounds"  || fail "missing inbounds"
    grep -q '"outbounds"' /opt/etc/xray/config.json && pass "has outbounds" || fail "missing outbounds"
    grep -q '"routing"'   /opt/etc/xray/config.json && pass "has routing"   || fail "missing routing"
    grep -q 'tproxy'      /opt/etc/xray/config.json && pass "has tproxy"    || fail "missing tproxy"
    grep -q 'vless'       /opt/etc/xray/config.json && pass "has vless"     || fail "missing vless"

    info "config.json size: $(wc -c < /opt/etc/xray/config.json) bytes"

    if command -v jq > /dev/null 2>&1; then
        jq empty /opt/etc/xray/config.json 2>/dev/null && pass "config.json is valid JSON" || fail "config.json invalid JSON"
    else
        skip "jq not available for JSON validation"
    fi
fi

sleep 1
if [ -f /opt/var/run/xray.pid ]; then
    PID=$(cat /opt/var/run/xray.pid)
    kill -0 "$PID" 2>/dev/null && pass "xray running (pid=$PID)" || fail "xray pid=$PID dead"
else
    fail "xray.pid not created"
fi

section "6 — idempotency: повторный apply не меняет hash"

HASH1=$(md5sum /opt/etc/xray/config.json 2>/dev/null | cut -d' ' -f1)
sh /opt/bin/keenetic-apply.sh 2>/dev/null
HASH2=$(md5sum /opt/etc/xray/config.json 2>/dev/null | cut -d' ' -f1)
[ "$HASH1" = "$HASH2" ] && pass "config.json identical on re-apply" || \
    fail "config.json changed: $HASH1 -> $HASH2"

# ═══════════════════════════════════════════════════════════════════════════════
section "Test Suite: VPN API Mock"
# ═══════════════════════════════════════════════════════════════════════════════

section "7 — mock-vpnapi endpoints"

RESP=$(curl -sf http://mock-vpnapi:8080/health 2>/dev/null)
printf '%s' "$RESP" | grep -q '"status":"ok"' && pass "GET /health ok" || fail "GET /health failed"

RESP=$(curl -sf http://mock-vpnapi:8080/vpnapi/v1/router/ping 2>/dev/null)
printf '%s' "$RESP" | grep -q '"ok":' && pass "GET /ping returns ok" || fail "GET /ping failed: $RESP"

RESP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    http://mock-vpnapi:8080/vpnapi/v1/router/ping \
    -H "Content-Type: application/json" \
    -d '{"mac":"aa:bb:cc:dd:ee:ff","secret":"test","vpn_up":true,"type":"keenetic"}' 2>/dev/null)
[ "$RESP_CODE" = "204" ] && pass "POST /ping → 204" || fail "POST /ping → $RESP_CODE"

section "8 — subscription URL"

RESP=$(curl -sf http://mock-vpnapi:8080/subscription/test 2>/dev/null)
[ -n "$RESP" ] && pass "subscription returns data" || fail "subscription empty"

DECODED=$(printf '%s' "$RESP" | base64 -d 2>/dev/null)
printf '%s' "$DECODED" | grep -q '^vless://' && pass "contains VLESS URI" || \
    fail "no VLESS URI: $(printf '%s' "$DECODED" | head -1)"
printf '%s' "$DECODED" | grep -q 'security=reality' && pass "has REALITY" || fail "no REALITY"
printf '%s' "$DECODED" | grep -q 'flow=' && pass "has flow param" || fail "no flow param"

section "9 — bypass файлы"

RESP=$(curl -sf "http://mock-vpnapi:8080/router/bypass_ips.txt" 2>/dev/null)
printf '%s' "$RESP" | grep -qE '^[0-9]' && pass "bypass_ips.txt has subnets" || fail "bypass_ips.txt empty/invalid"

RESP=$(curl -sf "http://mock-vpnapi:8080/router/bypass_domains.txt" 2>/dev/null)
printf '%s' "$RESP" | grep -q '\.' && pass "bypass_domains.txt has domains" || fail "bypass_domains.txt empty"

section "10 — keenetic-mock RCI"

RESP=$(curl -sf -u admin:keenetic "http://keenetic-mock:8000/rci/show/version" 2>/dev/null)
printf '%s' "$RESP" | grep -q 'KN-1811' && pass "RCI version has KN-1811" || fail "RCI version failed: $RESP"

RESP=$(curl -sf -u admin:keenetic "http://keenetic-mock:8000/rci/show/interface" 2>/dev/null)
printf '%s' "$RESP" | grep -q '"state"' && pass "RCI interface returns state" || fail "RCI interface failed"

section "11 — manifest.txt и integrity check"

MANIFEST=$(curl -sf "http://mock-vpnapi:8080/keenetic/manifest.txt" 2>/dev/null)
[ -n "$MANIFEST" ] && pass "manifest.txt доступен" || fail "manifest.txt недоступен"

if [ -n "$MANIFEST" ]; then
    count=$(printf '%s' "$MANIFEST" | grep -c '^[a-f0-9]' || echo 0)
    info "файлов в manifest: $count"
    [ "$count" -ge 4 ] && pass "manifest содержит >= 4 файлов" || fail "manifest содержит $count файлов"

    # Проверяем что реальный sha256 совпадает с manifest для одного из скриптов
    if command -v sha256sum > /dev/null 2>&1 && [ -f /opt/bin/keenetic-connect.sh ]; then
        expected=$(printf '%s' "$MANIFEST" | awk '$3=="keenetic-connect.sh" {print $1}')
        actual=$(sha256sum /opt/bin/keenetic-connect.sh | cut -d' ' -f1)
        if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
            pass "sha256 keenetic-connect.sh совпадает с manifest"
        elif [ -z "$expected" ]; then
            skip "keenetic-connect.sh не найден в manifest"
        else
            fail "sha256 mismatch: expected=$expected actual=$actual"
        fi
    else
        skip "sha256sum недоступен или скрипт не установлен"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────

printf "\n══════════════════════════════════════\n"
printf "Results: ${GREEN}%d passed${RESET}, ${RED}%d failed${RESET}, ${YELLOW}%d skipped${RESET}\n" \
    "$PASS" "$FAIL" "$SKIP"
printf "══════════════════════════════════════\n\n"

[ $FAIL -eq 0 ] && exit 0 || exit 1
