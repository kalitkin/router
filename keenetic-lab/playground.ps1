# Keenetic RCI API Playground — PowerShell
# Запуск: .\playground.ps1 [-Base http://localhost:8000]
param(
    [string]$Base     = "http://localhost:8000",
    [string]$Login    = "admin",
    [string]$Password = "keenetic"
)

$Cred    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${Login}:${Password}"))
$Headers = @{ Authorization = "Basic $Cred"; "Content-Type" = "application/json" }

function Sep($title) {
    Write-Host "`n─── $title ─────────────────────────────────────" -ForegroundColor Cyan
}

function RciGet($path) {
    (Invoke-RestMethod -Uri "$Base/rci/$path" -Headers $Headers) | ConvertTo-Json -Depth 10
}

function RciPost($path, $body) {
    $json = if ($body -is [string]) { $body } else { $body | ConvertTo-Json -Depth 10 }
    (Invoke-RestMethod -Uri "$Base/rci/$path" -Method POST -Headers $Headers -Body $json) |
        ConvertTo-Json -Depth 10
}

# ── 1. RCI tree ───────────────────────────────────────────────────────────────
Sep "RCI tree (карта API)"
Invoke-RestMethod -Uri "$Base/rci/" -Headers $Headers | ConvertTo-Json -Depth 6

# ── 2. Версия прошивки ────────────────────────────────────────────────────────
Sep "show/version"
$ver = Invoke-RestMethod -Uri "$Base/rci/show/version" -Headers $Headers
$ver | ConvertTo-Json -Depth 5
Write-Host "`nМодель:     $($ver.version.model)"
Write-Host "Прошивка:   $($ver.version.release)"
Write-Host "Устройство: $($ver.version.'hw-id')"

# ── 3. Интерфейсы ─────────────────────────────────────────────────────────────
Sep "show/interface — краткий список"
$ifaces = (Invoke-RestMethod -Uri "$Base/rci/show/interface" -Headers $Headers).interface
$ifaces.PSObject.Properties | ForEach-Object {
    $i = $_.Value
    Write-Host ("{0,-25} state={1,-6}  addr={2}" -f $_.Name, $i.state, ($i.address -ne "" ? $i.address : "-"))
}

Sep "show/interface/Wireguard0"
RciGet "show/interface/Wireguard0"

# ── 4. Таблица маршрутизации ──────────────────────────────────────────────────
Sep "show/ip/route"
(Invoke-RestMethod -Uri "$Base/rci/show/ip/route" -Headers $Headers).route | ForEach-Object {
    Write-Host ("{0}/{1,-3}  → {2,-20} [{3}]" -f $_.destination, $_.prefix, $_.interface, $_.proto)
}

# ── 5. Системная информация ───────────────────────────────────────────────────
Sep "show/system"
$sys = (Invoke-RestMethod -Uri "$Base/rci/show/system" -Headers $Headers).system
Write-Host "Uptime:    $($sys.uptime)s"
Write-Host "RAM total: $([math]::Round($sys.memory.total / 1MB)) MB"
Write-Host "RAM free:  $([math]::Round($sys.memory.free / 1MB)) MB"
Write-Host "CPU:       $($sys.cpu.usage)%"

# ── 6. Running config ─────────────────────────────────────────────────────────
Sep "show/rc/running"
RciGet "show/rc/running"

# ── 7. WireGuard — настройка пира ────────────────────────────────────────────
Sep "POST: настроить WireGuard пир"
RciPost "interface/Wireguard0" @{
    wireguard = @{
        peer = @{
            "public-key"           = "test-pubkey-base64=="
            endpoint               = "vpn.example.com:51820"
            "allowed-address"      = "0.0.0.0/0"
            "persistent-keepalive" = 25
        }
        address = "10.0.0.2"
    }
}

# ── 8. WireGuard — включить ───────────────────────────────────────────────────
Sep "POST: включить WireGuard (up: true)"
RciPost "interface/Wireguard0" '{"up": true}'

Sep "Wireguard0 после включения"
$wg = (Invoke-RestMethod -Uri "$Base/rci/show/interface/Wireguard0" -Headers $Headers).interface.Wireguard0
Write-Host "State: $($wg.state)  Connected: $($wg.connected)  IP: $($wg.address -ne '' ? $wg.address : '-')"

# ── 9. Маршруты после VPN UP ─────────────────────────────────────────────────
Sep "Маршруты после VPN UP"
(Invoke-RestMethod -Uri "$Base/rci/show/ip/route" -Headers $Headers).route | ForEach-Object {
    Write-Host ("{0}/{1,-3}  → {2,-20} [{3}]" -f $_.destination, $_.prefix, $_.interface, $_.proto)
}

# ── 10. WireGuard — выключить ─────────────────────────────────────────────────
Sep "POST: выключить WireGuard (up: false)"
RciPost "interface/Wireguard0" '{"up": false}'

# ── 11. Batch ─────────────────────────────────────────────────────────────────
Sep "POST /rci/ — batch: version + interface + system"
RciPost "" @{
    show = @{
        version   = @{}
        interface = @{}
        system    = @{}
    }
}

# ── 12. Auth challenge-response ───────────────────────────────────────────────
Sep "Auth: MD5 challenge-response flow"
Write-Host "Шаг 1 — получить challenge:"
try {
    Invoke-WebRequest -Uri "$Base/auth" -Method GET -ErrorAction Stop | Out-Null
} catch {
    $resp      = $_.Exception.Response
    $challenge = $resp.Headers["X-NDM-Challenge"]
    $realm     = $resp.Headers["X-NDM-Realm"]
    if (-not $challenge) { $challenge = "deadbeef12345678abcd"; $realm = "Keenetic (KN-1811)" }

    Write-Host "  Challenge: $challenge"
    Write-Host "  Realm:     $realm"

    $md5 = [System.Security.Cryptography.MD5]::Create()
    $pwMd5 = [BitConverter]::ToString(
        $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($Password))
    ).Replace("-","").ToLower()
    $final = [BitConverter]::ToString(
        $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($realm + $pwMd5 + $challenge))
    ).Replace("-","").ToLower()

    Write-Host "`nШаг 2 — вычислить hash:"
    Write-Host "  md5(password): $pwMd5"
    Write-Host "  final hash:    $final"

    Write-Host "`nШаг 3 — POST /auth:"
    $body = "{`"login`": `"$Login`", `"password`": `"$final`"}"
    Invoke-RestMethod -Uri "$Base/auth" -Method POST -ContentType "application/json" -Body $body |
        ConvertTo-Json
}

Write-Host "`nPlayground завершён. Mock API: $Base" -ForegroundColor Green
