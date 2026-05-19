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
    entry({"admin", "services", "vpn", "direct"},   call("action_direct")).leaf   = true
    entry({"admin", "services", "vpn", "logs"},     call("action_logs")).leaf     = true
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

function action_direct()
    sys.exec("[ -f /etc/init.d/passwall ]  && /etc/init.d/passwall  stop 2>/dev/null; " ..
             "[ -f /etc/init.d/passwall2 ] && /etc/init.d/passwall2 stop 2>/dev/null; " ..
             "killall xray 2>/dev/null; rm -f /etc/vpn/vpn_started")
    http.prepare_content("application/json")
    http.write('{"ok":true}')
end

function action_logs()
    local log_file = "/etc/vpn/vpn-agent.log"
    local fallback = "/tmp/vpn.log"
    local path = log_file
    if not fs.access(log_file) then path = fallback end

    local lines = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            lines[#lines + 1] = line
        end
        f:close()
    end

    -- последние 50 строк
    local start = #lines > 50 and (#lines - 49) or 1
    local out = {}
    for i = start, #lines do
        out[#out + 1] = lines[i]:gsub('\\', '\\\\'):gsub('"', '\\"')
    end

    http.prepare_content("application/json")
    http.write('{"lines":["' .. table.concat(out, '","') .. '"]}')
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
    local p = io.popen("pgrep -f xray 2>/dev/null", "r")
    if p then
        local out = p:read("*l")
        p:close()
        if out and out ~= "" then vpn_up = true end
    end
    if not vpn_up then
        local p2 = io.popen("pgrep -f v2ray 2>/dev/null", "r")
        if p2 then
            local out2 = p2:read("*l")
            p2:close()
            if out2 and out2 ~= "" then vpn_up = true end
        end
    end

    local device_id = ""
    local did = fs.readfile("/etc/vpn/device_id")
    if did then device_id = did:gsub("%s+", "") end

    local wan_ip = ""
    local pr = io.popen("ip route get 8.8.8.8 2>/dev/null", "r")
    if pr then
        local ip_r = pr:read("*a") or ""
        pr:close()
        wan_ip = ip_r:match("src%s+([%d%.]+)") or ""
    end

    local vpn_since = 0
    local since_f = fs.readfile("/etc/vpn/vpn_started")
    if since_f then vpn_since = math.floor(tonumber(since_f:gsub("%s+", "")) or 0) end

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
