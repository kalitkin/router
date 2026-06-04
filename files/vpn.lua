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
    -- Clean up TPROXY rules first so LAN traffic goes direct immediately,
    -- then stop vpnd before sing-box (vpnd would restart sing-box otherwise).
    sys.exec(
        "nft delete table inet vpnbot 2>/dev/null; " ..
        "ip rule del fwmark 0x1 priority 100 2>/dev/null; " ..
        "ip rule del fwmark 0x64 priority 500 2>/dev/null; " ..
        "/etc/init.d/vpnd stop 2>/dev/null; " ..
        "/etc/init.d/sing-box stop 2>/dev/null"
    )
    http.prepare_content("application/json")
    http.write('{"ok":true}')
end

function action_logs()
    local lines = {}

    -- Runtime logs from syslog (vpnd + sing-box)
    local raw = sys.exec("logread 2>/dev/null | grep -E '\\[vpnd\\]|\\[singbox\\]' | tail -50")
    for line in raw:gmatch("[^\n]+") do
        lines[#lines + 1] = line:gsub('\\', '\\\\'):gsub('"', '\\"')
    end

    -- Install log (useful during first setup)
    local f = io.open("/tmp/vpnd-install.log", "r")
    if f then
        for line in f:lines() do
            lines[#lines + 1] = ("[install] " .. line):gsub('\\', '\\\\'):gsub('"', '\\"')
        end
        f:close()
    end

    local start = #lines > 50 and (#lines - 49) or 1
    local out = {}
    for i = start, #lines do out[#out + 1] = lines[i] end

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
    /etc/init.d/vpnd restart >> /tmp/vpn-update.log 2>&1 || true
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
    local registered  = fs.access("/etc/vpn/token") ~= nil
    local config_data = fs.readfile("/etc/sing-box/config.json")
    local connected   = config_data ~= nil and config_data ~= ""

    local device_id = ""
    local did = fs.readfile("/etc/vpn/device_id")
    if did then device_id = did:gsub("[%s]+", "") end

    local current_server = ""
    local sv = fs.readfile("/etc/vpn/current_server")
    if sv then current_server = sv:gsub("[%s]+", "") end

    -- BusyBox pgrep -x matches full cmdline, not comm name.
    -- vpnd has no args so -x works; sing-box has args so use plain pgrep.
    local vpnd_running    = sys.exec("pgrep -x vpnd    >/dev/null 2>&1 && echo 1 || echo 0"):match("1") ~= nil
    local singbox_running = sys.exec("pgrep  sing-box  >/dev/null 2>&1 && echo 1 || echo 0"):match("1") ~= nil

    -- sing-box start time from /proc/<pid>/stat field 22 (starttime in clock ticks)
    local vpn_since = 0
    if singbox_running then
        local sb_pid = sys.exec("pgrep -x sing-box 2>/dev/null"):match("(%d+)")
        if sb_pid then
            local stat_f = io.open("/proc/" .. sb_pid .. "/stat", "r")
            if stat_f then
                local data = stat_f:read("*all")
                stat_f:close()
                -- Skip "pid (comm) " — comm may contain spaces, find the last ')'
                local rest = data:match("%)%s+(.*)")
                if rest then
                    local i = 0
                    for v in rest:gmatch("%S+") do
                        i = i + 1
                        if i == 20 then  -- starttime = field 22 overall = field 20 after pid+comm
                            local ticks = tonumber(v)
                            local uptime_f = io.open("/proc/uptime", "r")
                            if uptime_f and ticks then
                                local ud = uptime_f:read("*all")
                                uptime_f:close()
                                local uptime_sec = tonumber(ud:match("^([%d%.]+)"))
                                if uptime_sec then
                                    vpn_since = math.floor(os.time() - uptime_sec + ticks / 100)
                                end
                            end
                            break
                        end
                    end
                end
            end
        end
    end

    local vpn_up = singbox_running and connected

    -- TPROXY health: nft table active + fwmark ip rule present
    local tproxy_active = false
    if singbox_running then
        local nft_ok  = sys.exec("nft list table inet vpnbot 2>/dev/null | grep -c mangle_pre"):match("[1-9]") ~= nil
        local rule_ok = sys.exec("ip rule show 2>/dev/null | grep -c 'fwmark 0x1'"):match("[1-9]") ~= nil
        tproxy_active = nft_ok and rule_ok
    end

    local ct_count = tonumber(sys.exec("cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null") or "0") or 0
    local ct_max   = tonumber(sys.exec("cat /proc/sys/net/netfilter/nf_conntrack_max   2>/dev/null") or "0") or 0

    http.prepare_content("application/json")
    http.write(
        '{"registered":'       .. (registered      and "true" or "false") ..
        ',"connected":'        .. (connected        and "true" or "false") ..
        ',"vpn_up":'           .. (vpn_up           and "true" or "false") ..
        ',"vpnd_running":'     .. (vpnd_running      and "true" or "false") ..
        ',"singbox_running":'  .. (singbox_running   and "true" or "false") ..
        ',"tproxy_active":'    .. (tproxy_active     and "true" or "false") ..
        ',"device_id":"'       .. device_id .. '"'  ..
        ',"current_server":"'  .. current_server .. '"' ..
        ',"wan_ip":""'         ..
        ',"vpn_since":'        .. tostring(vpn_since) ..
        ',"ct_count":'         .. tostring(ct_count) ..
        ',"ct_max":'           .. tostring(ct_max) .. '}'
    )
end
