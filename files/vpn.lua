module("luci.controller.vpn", package.seeall)

local sys = require "luci.sys"
local http = require "luci.http"
local fs = require "nixio.fs"

function index()
    entry({"admin", "services", "vpn"}, template("vpn/index"), _("VPN Setup"), 90)
    entry({"admin", "services", "vpn", "connect"}, call("action_connect")).leaf = true
    entry({"admin", "services", "vpn", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "vpn", "progress"}, call("action_progress")).leaf = true
end

function action_progress()
    local f = io.open("/tmp/vpn-progress", "r")
    local data = f and f:read("*all") or '{"stage":"unknown","pct":0,"msg":""}'
    if f then f:close() end
    http.prepare_content("application/json")
    http.write(data)
end

function action_connect()
    local code = http.formvalue("code") or ""

    -- ВАЛИДАЦИЯ: строго 6 цифр — защита от command injection
    if not code:match("^%d%d%d%d%d%d$") then
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"Code must be exactly 6 digits"}')
        return
    end

    -- Безопасно — code гарантированно 6 цифр
    local result = sys.exec("/usr/bin/vpn-connect.sh " .. code .. " 2>&1")

    if not result or result == "" then
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"No response from vpn-connect.sh"}')
        return
    end

    local ok = result:match("^OK") or result:match("\nOK")

    if ok then
        local device_id = fs.readfile("/etc/vpn/device_id") or ""
        device_id = device_id:gsub("%s+", "")
        http.prepare_content("application/json")
        http.write('{"ok":true,"device_id":"' .. device_id .. '"}')
    else
        -- Безопасная очистка ошибки для JSON
        local err = result:gsub('"', '\\"'):gsub('\n', ' '):gsub('\r', ''):sub(1, 200)
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"' .. err .. '"}')
    end
end

function action_status()
    local registered = fs.access("/etc/vpn/token") ~= nil
    local config_data = fs.readfile("/etc/vpn/config")
    local connected = config_data ~= nil and #config_data > 0

    -- Проверяем жив ли VPN-процесс
    local vpn_up = false
    local xray_check = sys.exec("pgrep -f xray 2>/dev/null")
    if xray_check and #xray_check > 0 then vpn_up = true end
    if not vpn_up then
        local v2ray_check = sys.exec("pgrep -f v2ray 2>/dev/null")
        if v2ray_check and #v2ray_check > 0 then vpn_up = true end
    end

    local device_id = ""
    local did = fs.readfile("/etc/vpn/device_id")
    if did then device_id = did:gsub("%s+", "") end

    http.prepare_content("application/json")
    http.write(string.format(
        '{"registered":%s,"connected":%s,"vpn_up":%s,"device_id":"%s"}',
        registered and "true" or "false",
        connected and "true" or "false",
        vpn_up and "true" or "false",
        device_id
    ))
end
