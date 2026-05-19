#!/bin/sh
# /opt/bin/keenetic-apply.sh
# Применяет VPN конфиг на Keenetic:
#   subscription URL → распарсить → xray config.json → запустить xray
# Поддерживает: VLESS+REALITY, VLESS+TLS+WS, VMess+WS+TLS, Trojan

DIR="/opt/etc/vpn"
XRAY_CFG="/opt/etc/xray/config.json"
XRAY_BIN="/opt/bin/xray"
XRAY_PID="/opt/var/run/xray.pid"
LOG="/opt/var/log/vpn-agent.log"
BYPASS_DOMAINS="$DIR/bypass_domains.txt"
BYPASS_URL="${VPN_BYPASS_URL:-https://self-music.online/router}"
TPROXY_PORT=12345

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [apply] $*" >> "$LOG"; }
die()  { log "FATAL: $*"; exit 1; }

# ── Предварительные проверки ──────────────────────────────────────────────────

[ -f "$DIR/config" ] && [ -s "$DIR/config" ] || die "no config file at $DIR/config"
SUBSCRIPTION_URL=$(cat "$DIR/config")
[ -n "$SUBSCRIPTION_URL" ] || die "config file is empty"

mkdir -p /opt/etc/xray /opt/var/log /opt/var/run

# ── URL decode ────────────────────────────────────────────────────────────────

url_decode() {
    printf '%s' "$1" | sed \
        's/%2F/\//g; s/%3D/=/g; s/%2B/+/g; s/%3A/:/g; s/%40/@/g; s/%20/ /g; s/%25/%/g'
}

# ── Скачать и декодировать subscription ───────────────────────────────────────

download_subscription() {
    log "downloading subscription: $SUBSCRIPTION_URL"
    raw=$(curl -s -m 20 \
        -H "User-Agent: v2rayN/6.23" \
        -H "Accept: */*" \
        "$SUBSCRIPTION_URL" 2>/dev/null)

    [ -z "$raw" ] && die "empty response from subscription URL"

    # Marzban отдаёт base64. Если строка содержит :// — уже декодировано
    if printf '%s' "$raw" | grep -qE '^(vless|vmess|trojan|ss)://'; then
        PROXY_LIST="$raw"
    else
        PROXY_LIST=$(printf '%s' "$raw" | base64 -d 2>/dev/null)
        [ -z "$PROXY_LIST" ] && die "base64 decode failed"
    fi

    log "subscription decoded: $(printf '%s' "$PROXY_LIST" | wc -l) lines"
}

# ── Выбор лучшего прокси ─────────────────────────────────────────────────────
# Приоритет: VLESS+REALITY > VLESS+TLS > VMess > Trojan

select_proxy() {
    # VLESS с REALITY
    SELECTED=$(printf '%s' "$PROXY_LIST" | grep '^vless://' | while IFS= read -r line; do
        case "$line" in *security=reality*) printf '%s\n' "$line"; break ;; esac
    done)

    # VLESS без REALITY (TLS/WS)
    [ -z "$SELECTED" ] && SELECTED=$(printf '%s' "$PROXY_LIST" | grep '^vless://' | head -1)

    # VMess
    [ -z "$SELECTED" ] && SELECTED=$(printf '%s' "$PROXY_LIST" | grep '^vmess://' | head -1)

    # Trojan
    [ -z "$SELECTED" ] && SELECTED=$(printf '%s' "$PROXY_LIST" | grep '^trojan://' | head -1)

    [ -z "$SELECTED" ] && die "no supported proxy URI found in subscription"

    log "selected: $(printf '%s' "$SELECTED" | cut -c1-80)..."
}

# ── Парсинг VLESS URI ─────────────────────────────────────────────────────────
# vless://UUID@HOST:PORT?security=...&sni=...&fp=...&pbk=...&sid=...&flow=...#name

parse_vless() {
    uri="${SELECTED#vless://}"

    VLESS_UUID="${uri%%@*}"
    after_at="${uri#*@}"
    hostport="${after_at%%\?*}"
    VLESS_HOST="${hostport%%:*}"
    VLESS_PORT="${hostport##*:}"
    query="${after_at#*\?}"; query="${query%%#*}"

    _qp() { printf '%s' "$query" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1; }

    VLESS_SECURITY=$(url_decode "$(_qp security)")
    VLESS_SNI=$(url_decode "$(_qp sni)")
    VLESS_FP=$(url_decode "$(_qp fp)")
    VLESS_PBK=$(url_decode "$(_qp pbk)")
    VLESS_SID=$(url_decode "$(_qp sid)")
    VLESS_FLOW=$(url_decode "$(_qp flow)")
    VLESS_NET=$(url_decode "$(_qp type)")      # тип транспорта (ws, tcp, grpc...)
    VLESS_PATH=$(url_decode "$(_qp path)")
    VLESS_WSHOST=$(url_decode "$(_qp host)")

    [ -z "$VLESS_NET" ] && VLESS_NET="tcp"

    log "VLESS host=$VLESS_HOST port=$VLESS_PORT security=$VLESS_SECURITY net=$VLESS_NET"
}

# ── Парсинг VMess URI ─────────────────────────────────────────────────────────
# vmess://BASE64_JSON  (JSON: {v,ps,add,port,id,net,tls,path,host,sni,...})

parse_vmess() {
    b64="${SELECTED#vmess://}"
    json=$(printf '%s' "$b64" | base64 -d 2>/dev/null)
    [ -z "$json" ] && die "vmess base64 decode failed"

    _jf() { printf '%s' "$json" | grep -o "\"$1\":[^,}]*" | head -1 | \
            sed 's/^"[^"]*":\s*//' | tr -d '"'; }

    VMESS_UUID=$(_jf id)
    VMESS_HOST=$(_jf add)
    VMESS_PORT=$(_jf port)
    VMESS_NET=$(_jf net)
    VMESS_TLS=$(_jf tls)
    VMESS_PATH=$(url_decode "$(_jf path)")
    VMESS_SNI=$(_jf sni)
    VMESS_WSHOST=$(_jf host)
    VMESS_AID=$(_jf aid)

    [ -z "$VMESS_NET" ] && VMESS_NET="tcp"
    [ -z "$VMESS_AID" ] && VMESS_AID="0"

    log "VMess host=$VMESS_HOST port=$VMESS_PORT net=$VMESS_NET tls=$VMESS_TLS"
}

# ── Парсинг Trojan URI ────────────────────────────────────────────────────────
# trojan://PASSWORD@HOST:PORT?sni=...&type=...&path=...#name

parse_trojan() {
    uri="${SELECTED#trojan://}"

    TROJAN_PASS="${uri%%@*}"
    after_at="${uri#*@}"
    hostport="${after_at%%\?*}"
    TROJAN_HOST="${hostport%%:*}"
    TROJAN_PORT="${hostport##*:}"
    query="${after_at#*\?}"; query="${query%%#*}"

    _qp() { printf '%s' "$query" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | head -1; }

    TROJAN_SNI=$(url_decode "$(_qp sni)")
    TROJAN_NET=$(url_decode "$(_qp type)")
    TROJAN_PATH=$(url_decode "$(_qp path)")

    [ -z "$TROJAN_NET" ] && TROJAN_NET="tcp"
    [ -z "$TROJAN_SNI" ] && TROJAN_SNI="$TROJAN_HOST"

    log "Trojan host=$TROJAN_HOST port=$TROJAN_PORT sni=$TROJAN_SNI"
}

# ── Bypass domains → JSON array ───────────────────────────────────────────────

build_bypass_domains_rule() {
    [ ! -f "$BYPASS_DOMAINS" ] || [ ! -s "$BYPASS_DOMAINS" ] && return

    # "domain:yandex.ru","domain:vk.com",...
    domain_list=$(grep -v '^#' "$BYPASS_DOMAINS" | grep -v '^[[:space:]]*$' | \
        tr -d '\r' | awk '{printf "\"%s\",", "domain:"$0}' | sed 's/,$//')

    [ -z "$domain_list" ] && return

    # Возвращаем как отдельный JSON-объект routing rule (с ведущей запятой)
    printf ',\n      {\n        "type": "field",\n        "domain": [%s],\n        "outboundTag": "direct"\n      }' \
        "$domain_list"
}

# ── Скачать bypass-списки если нужно ─────────────────────────────────────────

ensure_bypass_lists() {
    for f in bypass_ips.txt bypass_domains.txt; do
        fp="$DIR/$f"
        [ -f "$fp" ] && [ -s "$fp" ] && continue
        log "downloading $f..."
        curl -s -m 15 -o "${fp}.tmp" "$BYPASS_URL/$f" 2>/dev/null && \
            [ -s "${fp}.tmp" ] && mv "${fp}.tmp" "$fp" || \
            log "WARN: failed to download $f"
    done
}

# ── Генерация xray config.json ────────────────────────────────────────────────

write_config() {
    cat > "$XRAY_CFG.tmp" << EOF
$1
EOF
    mv "$XRAY_CFG.tmp" "$XRAY_CFG"
    log "config.json written ($(wc -c < "$XRAY_CFG") bytes)"
}

generate_config_vless_reality() {
    bypass_rule=$(build_bypass_domains_rule)

    # flow нужен только если задан (XTLS требует, обычный TLS нет)
    if [ -n "$VLESS_FLOW" ]; then
        flow_line='"flow": "'"$VLESS_FLOW"'",'
    else
        flow_line=''
    fi

    write_config '{
  "log": {
    "loglevel": "warning",
    "error": "/opt/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": { "tproxy": "tproxy" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "'"$VLESS_HOST"'",
            "port": '"$VLESS_PORT"',
            "users": [
              {
                '"$flow_line"'
                "id": "'"$VLESS_UUID"'",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "fingerprint": "'"$VLESS_FP"'",
          "serverName": "'"$VLESS_SNI"'",
          "publicKey": "'"$VLESS_PBK"'",
          "shortId": "'"$VLESS_SID"'"
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }'"$bypass_rule"',
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}'
}

generate_config_vless_ws_tls() {
    bypass_rule=$(build_bypass_domains_rule)
    sni="${VLESS_SNI:-$VLESS_HOST}"
    ws_host="${VLESS_WSHOST:-$VLESS_HOST}"
    path="${VLESS_PATH:-/}"

    write_config '{
  "log": {
    "loglevel": "warning",
    "error": "/opt/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": { "tproxy": "tproxy" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "'"$VLESS_HOST"'",
            "port": '"$VLESS_PORT"',
            "users": [
              { "id": "'"$VLESS_UUID"'", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "serverName": "'"$sni"'",
          "allowInsecure": false
        },
        "wsSettings": {
          "path": "'"$path"'",
          "headers": { "Host": "'"$ws_host"'" }
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }'"$bypass_rule"',
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}'
}

generate_config_vmess() {
    bypass_rule=$(build_bypass_domains_rule)
    sni="${VMESS_SNI:-$VMESS_HOST}"
    ws_host="${VMESS_WSHOST:-$VMESS_HOST}"
    path="${VMESS_PATH:-/}"

    if [ "$VMESS_TLS" = "tls" ]; then
        tls_block='"security": "tls",
        "tlsSettings": { "serverName": "'"$sni"'", "allowInsecure": false },'
    else
        tls_block='"security": "none",'
    fi

    write_config '{
  "log": {
    "loglevel": "warning",
    "error": "/opt/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": { "tproxy": "tproxy" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vmess",
      "settings": {
        "vnext": [
          {
            "address": "'"$VMESS_HOST"'",
            "port": '"$VMESS_PORT"',
            "users": [
              { "id": "'"$VMESS_UUID"'", "alterId": '"$VMESS_AID"' }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "'"$VMESS_NET"'",
        '"$tls_block"'
        "wsSettings": {
          "path": "'"$path"'",
          "headers": { "Host": "'"$ws_host"'" }
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }'"$bypass_rule"',
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}'
}

generate_config_trojan() {
    bypass_rule=$(build_bypass_domains_rule)
    path="${TROJAN_PATH:-/}"

    write_config '{
  "log": {
    "loglevel": "warning",
    "error": "/opt/var/log/xray-error.log"
  },
  "inbounds": [
    {
      "port": '"$TPROXY_PORT"',
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": { "tproxy": "tproxy" }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "trojan",
      "settings": {
        "servers": [
          {
            "address": "'"$TROJAN_HOST"'",
            "port": '"$TROJAN_PORT"',
            "password": "'"$TROJAN_PASS"'"
          }
        ]
      },
      "streamSettings": {
        "network": "'"$TROJAN_NET"'",
        "security": "tls",
        "tlsSettings": {
          "serverName": "'"$TROJAN_SNI"'",
          "allowInsecure": false
        }
      }
    },
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block",  "protocol": "blackhole" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      }'"$bypass_rule"',
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy"
      }
    ]
  }
}'
}

# ── Валидация JSON ────────────────────────────────────────────────────────────

validate_config() {
    if command -v jq > /dev/null 2>&1; then
        jq empty "$XRAY_CFG" 2>/dev/null && return 0
        log "ERROR: config.json is invalid JSON"
        return 1
    fi
    # Без jq: минимальная проверка что файл не пустой и содержит '{' и '}'
    [ -s "$XRAY_CFG" ] || { log "ERROR: config.json is empty"; return 1; }
    grep -q '{' "$XRAY_CFG" && grep -q '}' "$XRAY_CFG" && return 0
    log "ERROR: config.json looks malformed"
    return 1
}

# ── Xray: остановить / запустить ──────────────────────────────────────────────

xray_stop() {
    if [ -f "$XRAY_PID" ]; then
        pid=$(cat "$XRAY_PID")
        kill "$pid" 2>/dev/null
        rm -f "$XRAY_PID"
    fi
    killall xray 2>/dev/null
    sleep 1
}

xray_start() {
    [ -x "$XRAY_BIN" ] || die "xray binary not found or not executable: $XRAY_BIN"

    "$XRAY_BIN" run -c "$XRAY_CFG" >> "$LOG" 2>&1 &
    echo $! > "$XRAY_PID"
    sleep 2

    pid=$(cat "$XRAY_PID" 2>/dev/null)
    if kill -0 "$pid" 2>/dev/null; then
        log "xray started pid=$pid"
        return 0
    else
        log "ERROR: xray failed to start — check $LOG"
        rm -f "$XRAY_PID"
        return 1
    fi
}

# ── MAIN ──────────────────────────────────────────────────────────────────────

log "=== apply start ==="

ensure_bypass_lists &
bypass_dl_pid=$!

download_subscription
select_proxy

# Определяем тип протокола и генерируем config.json
case "$SELECTED" in
    vless://*)
        parse_vless
        case "$VLESS_SECURITY" in
            reality)
                log "generating config: VLESS+REALITY"
                generate_config_vless_reality
                ;;
            tls|"")
                log "generating config: VLESS+TLS+WS"
                generate_config_vless_ws_tls
                ;;
            *)
                log "generating config: VLESS+TLS+WS (security=$VLESS_SECURITY)"
                generate_config_vless_ws_tls
                ;;
        esac
        ;;
    vmess://*)
        parse_vmess
        log "generating config: VMess"
        generate_config_vmess
        ;;
    trojan://*)
        parse_trojan
        log "generating config: Trojan"
        generate_config_trojan
        ;;
    *)
        die "unsupported proxy protocol: $(printf '%s' "$SELECTED" | cut -c1-30)"
        ;;
esac

# Дождаться скачивания bypass-списков
wait "$bypass_dl_pid" 2>/dev/null

# Проверить JSON
validate_config || die "aborting: invalid config.json"

# Перезапустить xray
xray_stop
xray_start || die "xray failed to start"

log "=== apply done ==="
