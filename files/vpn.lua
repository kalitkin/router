module("luci.controller.vpn", package.seeall)

local sys = require "luci.sys"
local http = require "luci.http"
local fs = require "nixio.fs"

function index()
    entry({"admin", "services", "vpn"}, template("vpn/index"), _("VPN Setup"), 90)
    entry({"admin", "services", "vpn", "connect"},  call("action_connect")).leaf  = true
    entry({"admin", "services", "vpn", "status"},   call("action_status")).leaf   = true
    entry({"admin", "services", "vpn", "progress"}, call("action_progress")).leaf = true
    entry({"admin", "services", "vpn", "update"},   call("action_update")).leaf   = true
end

function action_progress()
    local f = io.open("/tmp/vpn-progress", "r")
    local data
    if f then
        data = f:read("*all")
        f:close()
        -- if file exists but is empty or stale "done/ready", treat as ready
        if not data or data == "" then
            data = '{"stage":"ready","pct":100,"msg":""}'
        end
    else
        -- no file = setup never ran or already finished
        data = '{"stage":"ready","pct":100,"msg":""}'
    end
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

function action_update()
    local script = [[
#!/bin/sh
PROG=/tmp/vpn-progress
printf '{"stage":"setup","pct":15,"msg":"Скачиваем обновление..."}' > "$PROG"
if opkg install --force-reinstall 'https://self-music.online/router.ipk' >> /tmp/vpn-update.log 2>&1; then
    printf '{"stage":"done","pct":100,"msg":"Обновление установлено!"}' > "$PROG"
    sleep 1
    /etc/init.d/vpn-agent restart >> /tmp/vpn-update.log 2>&1 || \
    /etc/init.d/vpn-agent start   >> /tmp/vpn-update.log 2>&1 || true
else
    printf '{"stage":"error","pct":0,"msg":"Ошибка обновления. Лог: /tmp/vpn-update.log"}' > "$PROG"
fi
rm -f /tmp/.vpn-update.sh
]]

    local f = io.open("/tmp/.vpn-update.sh", "w")
    if not f then
        http.prepare_content("application/json")
        http.write('{"ok":false,"error":"Cannot write script"}')
        return
    end
    f:write(script)
    f:close()

    -- Пишем начальный прогресс до фонового запуска — избегаем race в JS polling
    local pf = io.open("/tmp/vpn-progress", "w")
    if pf then
        pf:write('{"stage":"setup","pct":5,"msg":"Запуск обновления..."}')
        pf:close()
    end

    os.execute("chmod +x /tmp/.vpn-update.sh && (sh /tmp/.vpn-update.sh > /dev/null 2>&1) &")
    http.prepare_content("application/json")
    http.write('{"ok":true}')
end

function action_status()
    local registered = fs.access("/etc/vpn/token") ~= nil
    local config_data = fs.readfile("/etc/vpn/config")
    local connected = config_data ~= nil and #config_data > 0

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

    -- WAN IP (адрес на маршруте к 8.8.8.8)
    local wan_ip = ""
    local ip_r = sys.exec("ip route get 8.8.8.8 2>/dev/null")
    if ip_r then wan_ip = ip_r:match("src%s+([%d%.]+)") or "" end

    -- Timestamp запуска VPN для подсчёта uptime на клиенте
    local vpn_since = 0
    local since_f = fs.readfile("/etc/vpn/vpn_started")
    if since_f then vpn_since = tonumber(since_f:gsub("%s+", "")) or 0 end

    http.prepare_content("application/json")
    http.write(string.format(
        '{"registered":%s,"connected":%s,"vpn_up":%s,"device_id":"%s","wan_ip":"%s","vpn_since":%d}',
        registered and "true" or "false",
        connected and "true" or "false",
        vpn_up and "true" or "false",
        device_id,
        wan_ip,
        vpn_since
    ))
end
