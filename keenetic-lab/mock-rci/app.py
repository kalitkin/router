#!/usr/bin/env python3
"""
Keenetic RCI API Mock Server
Эмулирует KeeneticOS REST Configuration Interface для разработки/тестирования.

Auth:  admin / keenetic  (Basic Auth или challenge-response)
Base:  http://localhost:8000/rci/
"""

import hashlib
import os
import time

from flask import Flask, jsonify, make_response, request, session

app = Flask(__name__)
app.secret_key = os.urandom(24)

ADMIN_LOGIN = os.environ.get("ADMIN_LOGIN", "admin")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "keenetic")
CHALLENGE = "deadbeef12345678abcd"
REALM = "Keenetic (KN-1811)"

# ── Mutable state (имитирует running config роутера) ──────────────────────────

_state = {
    "wireguard0": {
        "enabled": False,
        "connected": False,
        "address": "",
        "peer_endpoint": "",
        "peer_pubkey": "",
    }
}

# ── Static mock data ──────────────────────────────────────────────────────────

_VERSION = {
    "arch": "mips32",
    "release": "2.16.4.1082",
    "sandbox": "3.8.1.0-1",
    "title": "NDMS",
    "hw-id": "KN-1811",
    "model": "Viva",
    "manufacturer": "Keenetic Ltd.",
    "device": "KN-1811",
    "ndm": "2.16.4",
    "firmware": "2.16.4.1082",
    "builtin-start": "2024-01-15",
}

_START_TIME = time.time()


def _interfaces():
    wg = _state["wireguard0"]
    return {
        "GigabitEthernet0/0": {
            "id": "GigabitEthernet0/0",
            "index": 1,
            "type": "ethernet",
            "description": "Home",
            "link": "up",
            "connected": True,
            "state": "up",
            "mtu": 1500,
            "mac": "00:00:5E:00:53:01",
            "speed": "1000",
            "duplex": "full",
            "address": "192.168.1.1",
            "mask": "255.255.255.0",
        },
        "ISP": {
            "id": "ISP",
            "index": 5,
            "type": "pppoe",
            "description": "Интернет",
            "link": "up",
            "connected": True,
            "state": "up",
            "mtu": 1492,
            "address": "100.64.1.1",
            "mask": "255.255.255.255",
        },
        "Wireguard0": {
            "id": "Wireguard0",
            "index": 10,
            "type": "wireguard",
            "description": "WireGuard VPN",
            "link": "up" if wg["connected"] else "down",
            "connected": wg["connected"],
            "state": "up" if wg["enabled"] else "down",
            "mtu": 1420,
            "address": wg["address"] if wg["connected"] else "",
            "mask": "255.255.255.0" if wg["connected"] else "",
            "wireguard": {
                "peer-endpoint": wg["peer_endpoint"],
                "peer-public-key": wg["peer_pubkey"],
            } if wg["peer_pubkey"] else {},
        },
    }


def _routes():
    routes = [
        {
            "destination": "0.0.0.0",
            "prefix": 0,
            "gateway": "100.64.1.1",
            "interface": "ISP",
            "type": "dynamic",
            "proto": "default",
        },
        {
            "destination": "192.168.1.0",
            "prefix": 24,
            "gateway": "0.0.0.0",
            "interface": "GigabitEthernet0/0",
            "type": "connected",
            "proto": "kernel",
        },
    ]
    if _state["wireguard0"]["connected"]:
        routes.append({
            "destination": "10.0.0.0",
            "prefix": 24,
            "gateway": "0.0.0.0",
            "interface": "Wireguard0",
            "type": "connected",
            "proto": "kernel",
        })
        routes.append({
            "destination": "0.0.0.0",
            "prefix": 0,
            "gateway": "0.0.0.0",
            "interface": "Wireguard0",
            "type": "policy",
            "proto": "vpn",
            "comment": "VPN policy route",
        })
    return routes


def _system():
    uptime = int(time.time() - _START_TIME)
    total = 134217728  # 128 MB
    return {
        "uptime": uptime,
        "hostname": "Keenetic-Viva",
        "memory": {
            "total": total,
            "free": int(total * 0.38),
            "used": int(total * 0.62),
        },
        "cpu": {"usage": 7},
        "temperature": None,
        "load": [0.12, 0.08, 0.05],
    }


# ── Auth helpers ──────────────────────────────────────────────────────────────

def _is_authenticated() -> bool:
    auth = request.headers.get("Authorization", "")
    if auth.startswith("Basic "):
        import base64
        try:
            decoded = base64.b64decode(auth[6:]).decode()
            login, password = decoded.split(":", 1)
            if login == ADMIN_LOGIN and password == ADMIN_PASSWORD:
                return True
        except Exception:
            pass
    return bool(session.get("authenticated"))


def _unauthorized():
    resp = make_response(
        jsonify({"error": "Unauthorized", "code": 401}), 401
    )
    resp.headers["WWW-Authenticate"] = f'Basic realm="{REALM}"'
    return resp


# ── /auth ─────────────────────────────────────────────────────────────────────

@app.route("/auth", methods=["GET"])
def auth_challenge():
    """Шаг 1: получить challenge для MD5 auth."""
    resp = make_response("", 401)
    resp.headers["X-NDM-Challenge"] = CHALLENGE
    resp.headers["X-NDM-Realm"] = REALM
    return resp


@app.route("/auth", methods=["POST"])
def auth_login():
    """Шаг 2: логин (MD5 challenge-response или plain password для теста)."""
    data = request.get_json(silent=True) or {}
    login = data.get("login", "")
    password = data.get("password", "")

    # Ожидаемый хэш: md5(realm + md5(password) + challenge)
    pw_md5 = hashlib.md5(ADMIN_PASSWORD.encode()).hexdigest()
    expected = hashlib.md5((REALM + pw_md5 + CHALLENGE).encode()).hexdigest()

    if login == ADMIN_LOGIN and password in (expected, ADMIN_PASSWORD):
        session["authenticated"] = True
        return jsonify({"login": login, "session": True}), 200

    return jsonify({"error": "Invalid credentials"}), 403


@app.route("/auth", methods=["DELETE"])
def auth_logout():
    session.pop("authenticated", None)
    return "", 204


# ── GET /rci/show/* ───────────────────────────────────────────────────────────

@app.route("/rci/show/version", methods=["GET"])
def show_version():
    if not _is_authenticated():
        return _unauthorized()
    return jsonify({"version": _VERSION})


@app.route("/rci/show/interface", methods=["GET"])
def show_interfaces():
    if not _is_authenticated():
        return _unauthorized()
    return jsonify({"interface": _interfaces()})


@app.route("/rci/show/interface/<name>", methods=["GET"])
def show_interface(name):
    if not _is_authenticated():
        return _unauthorized()
    ifaces = _interfaces()
    if name not in ifaces:
        return jsonify({"error": f"Interface '{name}' not found"}), 404
    return jsonify({"interface": {name: ifaces[name]}})


@app.route("/rci/show/ip/route", methods=["GET"])
def show_ip_route():
    if not _is_authenticated():
        return _unauthorized()
    return jsonify({"route": _routes()})


@app.route("/rci/show/system", methods=["GET"])
def show_system():
    if not _is_authenticated():
        return _unauthorized()
    return jsonify({"system": _system()})


@app.route("/rci/show/rc/running", methods=["GET"])
def show_running_config():
    """Полный running config — самый полезный эндпоинт для изучения."""
    if not _is_authenticated():
        return _unauthorized()
    wg = _state["wireguard0"]
    return jsonify({
        "rc": {
            "system": {"hostname": "Keenetic-Viva"},
            "interface": {
                "Wireguard0": {
                    "description": "WireGuard VPN",
                    "security-level": "private",
                    "up": wg["enabled"],
                    "wireguard": {
                        "private-key": "(hidden)",
                        "peer": {
                            "public-key": wg["peer_pubkey"] or "(not set)",
                            "endpoint": wg["peer_endpoint"] or "(not set)",
                            "allowed-address": "0.0.0.0/0",
                            "persistent-keepalive": 25,
                        },
                    },
                }
            },
            "ip": {
                "route": [r for r in _routes() if r.get("proto") != "kernel"]
            },
        }
    })


# ── POST /rci/interface/<name> ────────────────────────────────────────────────

@app.route("/rci/interface/<name>", methods=["POST"])
def configure_interface(name):
    """Включить / выключить / настроить интерфейс."""
    if not _is_authenticated():
        return _unauthorized()

    data = request.get_json(silent=True) or {}

    if name != "Wireguard0":
        return jsonify({"error": f"Interface '{name}' not configurable in mock"}), 404

    wg = _state["wireguard0"]
    changed = []

    if "up" in data:
        wg["enabled"] = bool(data["up"])
        wg["connected"] = bool(data["up"])
        if wg["enabled"] and not wg["address"]:
            wg["address"] = "10.0.0.2"
        changed.append("up" if wg["enabled"] else "down")

    if "wireguard" in data:
        cfg = data["wireguard"]
        if "peer" in cfg:
            peer = cfg["peer"]
            wg["peer_endpoint"] = peer.get("endpoint", wg["peer_endpoint"])
            wg["peer_pubkey"] = peer.get("public-key", wg["peer_pubkey"])
            changed.append("wireguard-peer-configured")
        if "address" in cfg:
            wg["address"] = cfg["address"]
            changed.append(f"address={cfg['address']}")

    return jsonify({
        "success": True,
        "interface": name,
        "changes": changed,
        "state": "up" if wg["enabled"] else "down",
        "connected": wg["connected"],
    })


# ── POST /rci/ — batch commands ───────────────────────────────────────────────

@app.route("/rci/", methods=["POST"])
@app.route("/rci", methods=["POST"])
def rci_batch():
    """
    Пакетный режим — несколько команд одним запросом.

    Пример:
    {
      "show": { "version": {}, "interface": {}, "system": {} },
      "interface": { "Wireguard0": { "up": true } }
    }
    """
    if not _is_authenticated():
        return _unauthorized()

    data = request.get_json(silent=True) or {}
    result = {}

    if "show" in data:
        show_req = data["show"]
        result["show"] = {}
        if "version" in show_req:
            result["show"]["version"] = _VERSION
        if "interface" in show_req:
            result["show"]["interface"] = _interfaces()
        if "system" in show_req:
            result["show"]["system"] = _system()
        if "ip" in show_req:
            result["show"]["ip"] = {"route": _routes()}

    if "interface" in data:
        result["interface"] = {}
        for iface, cfg in data["interface"].items():
            if iface == "Wireguard0":
                wg = _state["wireguard0"]
                if "up" in cfg:
                    wg["enabled"] = bool(cfg["up"])
                    wg["connected"] = bool(cfg["up"])
                result["interface"][iface] = {
                    "success": True,
                    "state": "up" if wg["enabled"] else "down",
                }

    return jsonify(result)


# ── RCI tree explorer ─────────────────────────────────────────────────────────

@app.route("/rci/", methods=["GET"])
@app.route("/rci", methods=["GET"])
def rci_tree():
    """Карта всего RCI-дерева — удобно для изучения API."""
    if not _is_authenticated():
        return _unauthorized()
    return jsonify({
        "_info": "Keenetic RCI tree (mock). GET для чтения, POST для записи.",
        "show": {
            "version":   "GET /rci/show/version",
            "interface": "GET /rci/show/interface  |  GET /rci/show/interface/<name>",
            "ip":        {"route": "GET /rci/show/ip/route"},
            "system":    "GET /rci/show/system",
            "rc":        {"running": "GET /rci/show/rc/running"},
        },
        "interface": {
            "<name>": "POST /rci/interface/<name>  — {up: bool, wireguard: {...}}",
        },
        "batch": "POST /rci/  — любые команды одним запросом",
        "auth": {
            "challenge": "GET /auth  → X-NDM-Challenge + X-NDM-Realm",
            "login":     "POST /auth  → {login, password}",
            "logout":    "DELETE /auth",
            "basic":     f"Authorization: Basic base64({ADMIN_LOGIN}:{ADMIN_PASSWORD})",
        },
    })


# ── Health ────────────────────────────────────────────────────────────────────

@app.route("/", methods=["GET"])
def health():
    return jsonify({
        "service":         "Keenetic RCI Mock",
        "status":          "ok",
        "model":           _VERSION["model"],
        "firmware":        _VERSION["release"],
        "wireguard_state": "up" if _state["wireguard0"]["enabled"] else "down",
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8000))
    print(f"\n  Keenetic RCI Mock  ->  http://localhost:{port}")
    print(f"  Credentials: {ADMIN_LOGIN} / {ADMIN_PASSWORD}")
    print(f"  RCI tree:    http://localhost:{port}/rci/\n")
    app.run(host="0.0.0.0", port=port, debug=False)
