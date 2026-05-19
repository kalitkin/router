#!/usr/bin/env python3
"""
Mock server for self-music.online VPN API.
Эмулирует /vpnapi/v1/router/* для локального тестирования скриптов.
Also serves subscription URL and bypass lists.

Base: http://localhost:8080
"""

import base64
import hashlib
import os
import time
from pathlib import Path
from typing import Any

from flask import Flask, jsonify, request

app = Flask(__name__)

# ── Static mock data ──────────────────────────────────────────────────────────

_DEVICE_ID  = "test-device-001"
_TOKEN      = "test-token-abc123def456"
_SECRET     = "test-secret-xyz789uvw"

# Realistic VLESS+REALITY URI pointing at a "mock" server.
# 203.0.113.x = TEST-NET-3 (RFC 5737) — safe to use in tests.
_VLESS_URI = (
    "vless://00000000-0000-0000-0000-000000000001"
    "@203.0.113.1:443"
    "?security=reality"
    "&sni=www.microsoft.com"
    "&fp=chrome"
    "&pbk=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    "&sid=aabbccdd"
    "&flow=xtls-rprx-vision"
    "&type=tcp"
    "#Test-Reality-Mock"
)

_SUBSCRIPTION_B64 = base64.b64encode(_VLESS_URI.encode()).decode()
_CONFIG_HASH = hashlib.md5(_VLESS_URI.encode()).hexdigest()

_PORT      = int(os.environ.get("PORT", 8080))
_SELF_HOST = os.environ.get("SELF_HOST", f"mock-vpnapi:{_PORT}")
_SUB_URL   = f"http://{_SELF_HOST}/subscription/test"

_BYPASS_IPS = """\
# Mock bypass IPs (TEST-NET ranges, RFC 5737)
192.0.2.0/24
198.51.100.0/24
203.0.113.0/24
"""

_BYPASS_DOMAINS = """\
ya.ru
yandex.ru
vk.com
ok.ru
mail.ru
sber.ru
"""

_PORT      = int(os.environ.get("PORT", 8080))
_SELF_HOST = os.environ.get("SELF_HOST", f"mock-vpnapi:{_PORT}")
_SUB_URL   = f"http://{_SELF_HOST}/subscription/test"

# Ping log for debugging
_pings: list[dict[str, Any]] = []

# ── /vpnapi/v1/router/register_by_code ───────────────────────────────────────

@app.route("/vpnapi/v1/router/register_by_code", methods=["POST"])
def register_by_code():
    data = request.get_json(silent=True) or {}
    code = data.get("code", "")
    mac  = data.get("mac", "")

    if len(code) != 6 or not code.isdigit():
        return jsonify({"detail": "invalid code format"}), 400

    app.logger.info(f"register_by_code: code={code} mac={mac} model={data.get('model')} arch={data.get('arch')}")

    return jsonify({
        "device_id":     _DEVICE_ID,
        "token":         _TOKEN,
        "device_secret": _SECRET,
        "config":        _SUB_URL,
    }), 200


# ── /vpnapi/v1/router/config_by_mac ──────────────────────────────────────────

@app.route("/vpnapi/v1/router/config_by_mac", methods=["GET"])
def config_by_mac():
    mac    = request.args.get("mac", "")
    secret = request.args.get("secret", "")

    if not mac:
        return jsonify({"status": "not_registered", "detail": "mac required"}), 400

    app.logger.info(f"config_by_mac: mac={mac}")

    return jsonify({
        "status":      "ready",
        "config":      _SUB_URL,
        "config_hash": _CONFIG_HASH,
    }), 200


# ── /vpnapi/v1/router/ping ────────────────────────────────────────────────────

@app.route("/vpnapi/v1/router/ping", methods=["GET"])
def ping_get():
    return jsonify({"ok": True, "ts": int(time.time())}), 200


@app.route("/vpnapi/v1/router/ping", methods=["POST"])
def ping_post():
    data = request.get_json(silent=True) or {}
    entry = {
        "ts":       int(time.time()),
        "mac":      data.get("mac", ""),
        "ip":       data.get("ip", ""),
        "vpn_up":   data.get("vpn_up", False),
        "failover": data.get("failover", False),
        "type":     data.get("type", ""),
    }
    _pings.append(entry)
    if len(_pings) > 100:
        _pings.pop(0)
    app.logger.info(f"ping: {entry}")
    return "", 204


# ── /subscription/test ────────────────────────────────────────────────────────

@app.route("/subscription/test", methods=["GET"])
def subscription():
    return _SUBSCRIPTION_B64, 200, {"Content-Type": "text/plain; charset=utf-8"}


# ── /router/bypass_*.txt ─────────────────────────────────────────────────────

@app.route("/router/bypass_ips.txt", methods=["GET"])
def bypass_ips():
    return _BYPASS_IPS, 200, {"Content-Type": "text/plain"}


@app.route("/router/bypass_domains.txt", methods=["GET"])
def bypass_domains():
    return _BYPASS_DOMAINS, 200, {"Content-Type": "text/plain"}


# ── /keenetic/manifest.txt ───────────────────────────────────────────────────
# Возвращает фейковый manifest чтобы install.sh мог проверить integrity flow.
# Хэши реальные — вычисляются из скриптов на лету (скрипты монтированы в /opt/scripts).

@app.route("/keenetic/manifest.txt", methods=["GET"])
def keenetic_manifest():
    import os
    import hashlib

    scripts_dir = "/opt/scripts"
    files = [
        "keenetic-connect.sh", "keenetic-apply.sh",
        "keenetic-agent.sh", "S99vpn-agent", "install.sh",
    ]
    lines = [
        "# sha256  size  filename",
        f"# generated: {__import__('datetime').datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}",
    ]
    for name in files:
        path = os.path.join(scripts_dir, name)
        if os.path.exists(path):
            data = open(path, "rb").read()
            sha = hashlib.sha256(data).hexdigest()
            size = len(data)
            lines.append(f"{sha}  {size}  {name}")
        else:
            lines.append(f"{'0'*64}  0  {name}")

    return "\n".join(lines) + "\n", 200, {"Content-Type": "text/plain"}


# ── Debug: last pings ─────────────────────────────────────────────────────────

@app.route("/debug/pings", methods=["GET"])
def debug_pings():
    return jsonify(_pings)


# ── Health ────────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
@app.route("/", methods=["GET"])
def health():
    return jsonify({
        "service":     "VPN API Mock",
        "status":      "ok",
        "device_id":   _DEVICE_ID,
        "sub_url":     _SUB_URL,
        "config_hash": _CONFIG_HASH,
    })


if __name__ == "__main__":
    host = os.environ.get("HOST", "0.0.0.0")

    print(f"\n  VPN API Mock  ->  http://localhost:{_PORT}")
    print(f"  Register:  POST /vpnapi/v1/router/register_by_code")
    print(f"  Config:    GET  /vpnapi/v1/router/config_by_mac?mac=...&secret=...")
    print(f"  Ping:      POST /vpnapi/v1/router/ping")
    print(f"  Sub URL:   {_SUB_URL}")
    print(f"  Debug:     GET  /debug/pings\n")

    app.run(host=host, port=_PORT, debug=False)
