# RAM Profile + zram Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в luci-app-vpnbot автоматическое определение профиля устройства по RAM и настройку zram-swap для экономии памяти на слабых роутерах (≤128MB).

**Architecture:** Новый `vpn-bootstrap.sh` запускается первым из postinst — определяет профиль (tiny/normal), настраивает zram, пишет sentinel. `xray-fetch.init` и `vpn-agent.sh` читают профиль для адаптации поведения. `patch-ipk.sh` включает новый файл в пакет и вызывает bootstrap до PassWall install.

**Tech Stack:** POSIX sh, OpenWrt opkg, UCI (zram-swap), patch-ipk.sh (bash-based IPK builder)

---

## Карта файлов

| Файл | Изменение |
|------|-----------|
| `files/vpn-bootstrap.sh` | **Создать** — RAM detect, profile write, zram setup, sentinel |
| `files/xray-fetch.init` | **Изменить** — читать profile, profile-aware passwall install |
| `files/vpn-agent.sh` | **Изменить** — читать profile при старте, adjust interval |
| `patch-ipk.sh` | **Изменить** — добавить bootstrap в data, вызов в postinst |

---

## Task 1: Проверить структуру passwall feed (необходимо для Task 3)

**Цель:** Убедиться что пакет `passwall` (без LuCI) существует в SourceForge feed как самостоятельная единица.

**Files:**
- Read: `files/xray-fetch.init:45-50` (URL структура feed)

- [ ] **Step 1: Получить список пакетов из passwall feed**

```bash
# Запустить на роутере или через curl
ARCH="x86_64"  # или реальная arch
REL="24.10"
SF="https://master.dl.sourceforge.net/project/openwrt-passwall-build"
curl -s "${SF}/releases/packages-${REL}/${ARCH}/passwall_packages/Packages.gz" | \
  gunzip | grep "^Package:" | sort
```

Ожидаемый вывод — список пакетов. Ищем `Package: passwall` (без префикса `luci-app-`).

- [ ] **Step 2: Зафиксировать результат**

Если `Package: passwall` есть → tiny ставит `passwall`.  
Если нет (только `luci-app-passwall`) → tiny ставит `luci-app-passwall` (без изменений vs normal).  
Записать решение в начало этого файла как комментарий.

> **Если проверить не получается прямо сейчас:** по умолчанию считаем что `passwall` существует (исторически feed содержит core + luci как отдельные единицы). При первом деплое на роутере проверить руками: `opkg update && opkg info passwall`.

---

## Task 2: Создать files/vpn-bootstrap.sh

**Files:**
- Create: `files/vpn-bootstrap.sh`

- [ ] **Step 1: Создать файл**

```sh
#!/bin/sh
# /usr/bin/vpn-bootstrap.sh
# Определяет RAM-профиль устройства, настраивает zram-swap.
# Запускается один раз из postinst ДО установки PassWall.
# Идемпотентный: если profile уже есть — не перезаписывает.

DIR="/etc/vpn"
LOG="/tmp/vpn-install.log"
PROFILE_FILE="$DIR/profile"
SENTINEL="$DIR/.bootstrap_done"

log() { echo "[$(date '+%H:%M:%S')] bootstrap: $1" >> "$LOG"; }

mkdir -p "$DIR"

# ── 1. RAM профиль (immutable) ─────────────────────────────────────────────

if [ -f "$PROFILE_FILE" ]; then
    PROFILE=$(cat "$PROFILE_FILE")
    log "profile already set: $PROFILE (skipping detection)"
else
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)
    if [ "$MEM_KB" -le 65536 ]; then
        PROFILE="tiny"
    else
        PROFILE="normal"
    fi
    echo "$PROFILE" > "$PROFILE_FILE"
    log "profile detected: $PROFILE (MemTotal=${MEM_KB}kB)"
fi

# ── 2. zram-swap (только для ≤128MB) ─────────────────────────────────────

MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 999999)

if [ "$MEM_KB" -le 131072 ]; then
    # Процент от RAM: ≤32MB→35%, ≤64MB→30%, ≤128MB→15%
    if [ "$MEM_KB" -le 32768 ]; then
        ZRAM_PCT=35
    elif [ "$MEM_KB" -le 65536 ]; then
        ZRAM_PCT=30
    else
        ZRAM_PCT=15
    fi
    ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
    [ "$ZRAM_MB" -lt 4 ] && ZRAM_MB=4

    log "zram: MEM=${MEM_KB}kB pct=${ZRAM_PCT}% size=${ZRAM_MB}MB"

    if ! opkg list-installed 2>/dev/null | grep -q "^zram-swap "; then
        log "zram: installing zram-swap"
        opkg install zram-swap >> "$LOG" 2>&1 || {
            log "zram: install failed, skipping"
            touch "$SENTINEL"
            exit 0
        }
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    fi

    if [ -f /etc/init.d/zram-swap ]; then
        /etc/init.d/zram-swap stop 2>/dev/null || true
        uci set zram-swap.@zram-swap[0].size="$ZRAM_MB" 2>/dev/null && \
            uci commit zram-swap 2>/dev/null || true
        /etc/init.d/zram-swap start 2>/dev/null || true
        /etc/init.d/zram-swap enable 2>/dev/null || true
        log "zram: configured ${ZRAM_MB}MB and started"
    else
        log "zram: init script not found, skipping"
    fi
else
    log "zram: skipping (MEM=${MEM_KB}kB > 128MB)"
fi

# ── 3. Sentinel ───────────────────────────────────────────────────────────
touch "$SENTINEL"
log "bootstrap done (profile=$PROFILE)"
```

- [ ] **Step 2: Проверить синтаксис**

```bash
bash -n files/vpn-bootstrap.sh
```

Ожидаемый вывод: пусто (нет ошибок).

- [ ] **Step 3: Быстрый логический тест профиля**

```bash
# Мокаем /proc/meminfo и проверяем логику
MEM_KB=32768
if [ "$MEM_KB" -le 65536 ]; then echo "tiny"; else echo "normal"; fi
# Ожидаем: tiny

MEM_KB=262144
if [ "$MEM_KB" -le 65536 ]; then echo "tiny"; else echo "normal"; fi
# Ожидаем: normal
```

- [ ] **Step 4: Быстрый логический тест zram размера**

```bash
# 32MB роутер
MEM_KB=32768; ZRAM_PCT=35
ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
echo "32MB→ ${ZRAM_MB}MB"
# Ожидаем: 11MB

# 64MB роутер  
MEM_KB=65536; ZRAM_PCT=30
ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
echo "64MB→ ${ZRAM_MB}MB"
# Ожидаем: 19MB

# 128MB роутер
MEM_KB=131072; ZRAM_PCT=15
ZRAM_MB=$(( MEM_KB * ZRAM_PCT / 100 / 1024 ))
echo "128MB→ ${ZRAM_MB}MB"
# Ожидаем: 19MB
```

- [ ] **Step 5: Commit**

```bash
git add files/vpn-bootstrap.sh
git commit -m "feat(bootstrap): add vpn-bootstrap.sh — RAM profile detection + zram setup"
```

---

## Task 3: Обновить files/xray-fetch.init — profile-aware passwall install

**Files:**
- Modify: `files/xray-fetch.init:31-65` (функция start)

Текущий код функции `start()` (строки 31-65 в xray-fetch.init):
```sh
start() {
    passwall_ok=0
    xray_ok=0
    passwall_present && passwall_ok=1
    xray_present    && xray_ok=1
    ...
    if [ "$passwall_ok" -eq 0 ]; then
        echo "[...] xray-fetch: installing luci-app-passwall" >> "$LOG"
        if opkg install luci-app-passwall >> "$LOG" 2>&1; then
            echo "[...] xray-fetch: PassWall installed ok" >> "$LOG"
        else
            echo "[...] xray-fetch: PassWall install failed" >> "$LOG"
        fi
```

- [ ] **Step 1: Добавить чтение профиля в начало start()**

Вставить **после** строки `START=95` / `STOP=10` блок и **в начало** функции `start()` строку:

```sh
start() {
    PROFILE=$(cat /etc/vpn/profile 2>/dev/null || echo "normal")
    passwall_ok=0
    xray_ok=0
```

- [ ] **Step 2: Изменить блок установки PassWall**

Найти блок:
```sh
    if [ "$passwall_ok" -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] xray-fetch: installing luci-app-passwall" >> "$LOG"
        if opkg install luci-app-passwall >> "$LOG" 2>&1; then
            echo "[$(date '+%H:%M:%S')] xray-fetch: PassWall installed ok" >> "$LOG"
        else
            echo "[$(date '+%H:%M:%S')] xray-fetch: PassWall install failed" >> "$LOG"
        fi
```

Заменить на:
```sh
    if [ "$passwall_ok" -eq 0 ]; then
        if [ "$PROFILE" = "tiny" ]; then
            PW_PKG="passwall"
        else
            PW_PKG="luci-app-passwall"
        fi
        echo "[$(date '+%H:%M:%S')] xray-fetch: installing $PW_PKG (profile=$PROFILE)" >> "$LOG"
        if opkg install "$PW_PKG" >> "$LOG" 2>&1; then
            echo "[$(date '+%H:%M:%S')] xray-fetch: PassWall installed ok" >> "$LOG"
        else
            echo "[$(date '+%H:%M:%S')] xray-fetch: PassWall install failed" >> "$LOG"
        fi
```

- [ ] **Step 3: Проверить синтаксис**

```bash
bash -n files/xray-fetch.init
```

Ожидаемый вывод: пусто.

- [ ] **Step 4: Commit**

```bash
git add files/xray-fetch.init
git commit -m "feat(xray-fetch): profile-aware passwall install (tiny→passwall, normal→luci-app-passwall)"
```

---

## Task 4: Обновить files/vpn-agent.sh — profile-aware intervals

**Files:**
- Modify: `files/vpn-agent.sh` — секция после `mkdir -p "$DIR"` (~строка 214)

Текущий код (строки 212-216):
```sh
MAC_ENCODED=$(echo "$MAC" | sed 's/:/%3A/g')
mkdir -p "$DIR"
log "started pid=$$ mac=$MAC"
```

- [ ] **Step 1: Вставить чтение профиля после mkdir**

```sh
MAC_ENCODED=$(echo "$MAC" | sed 's/:/%3A/g')
mkdir -p "$DIR"

PROFILE=$(cat "$DIR/profile" 2>/dev/null || echo "normal")
[ "$PROFILE" = "tiny" ] && BYPASS_CHECK_INTERVAL=21600
log "started pid=$$ mac=$MAC profile=$PROFILE bypass_interval=$BYPASS_CHECK_INTERVAL"
```

- [ ] **Step 2: Проверить синтаксис**

```bash
bash -n files/vpn-agent.sh
```

Ожидаемый вывод: пусто.

- [ ] **Step 3: Commit**

```bash
git add files/vpn-agent.sh
git commit -m "feat(agent): read RAM profile, set BYPASS_CHECK_INTERVAL=21600 on tiny"
```

---

## Task 5: Обновить patch-ipk.sh — включить bootstrap в пакет и вызов из postinst

**Files:**
- Modify: `patch-ipk.sh` — секция [1/4] (~строка 38-41) и postinst ENDSETUP (~строки 127-185)

### Часть A: добавить bootstrap в data.tar.gz

- [ ] **Step 1: Добавить install строку**

В секции `[1/4] Shell-скрипты` после строки:
```sh
install -D -m 755 "$FILES_DIR/vpn-apply.sh"   "$TMPDIR/data/usr/bin/vpn-apply.sh"
```

Вставить:
```sh
install -D -m 755 "$FILES_DIR/vpn-bootstrap.sh" "$TMPDIR/data/usr/bin/vpn-bootstrap.sh"
```

### Часть B: вызов bootstrap из postinst

- [ ] **Step 2: Добавить bootstrap call перед PassWall install**

Найти в heredoc ENDSETUP строку:
```sh
    if ! [ -f /etc/init.d/passwall ]; then
        progress "setup" 50 "Устанавливаем PassWall..."
        echo "[$(date '+%H:%M:%S')] vpn-setup: installing luci-app-passwall" >> "$LOG"
        if opkg install luci-app-passwall >> "$LOG" 2>&1; then
```

Заменить весь этот блок (включая else/fi) на:
```sh
    # Bootstrap: RAM профиль + zram (запускается до PassWall)
    if [ -x /usr/bin/vpn-bootstrap.sh ]; then
        echo "[$(date '+%H:%M:%S')] vpn-setup: running bootstrap" >> "$LOG"
        progress "setup" 40 "Настройка профиля..."
        /usr/bin/vpn-bootstrap.sh
    fi
    PROFILE=$(cat /etc/vpn/profile 2>/dev/null || echo "normal")
    echo "[$(date '+%H:%M:%S')] vpn-setup: profile=$PROFILE" >> "$LOG"

    if ! [ -f /etc/init.d/passwall ]; then
        if [ "$PROFILE" = "tiny" ]; then
            PW_PKG="passwall"
        else
            PW_PKG="luci-app-passwall"
        fi
        progress "setup" 50 "Устанавливаем PassWall ($PROFILE)..."
        echo "[$(date '+%H:%M:%S')] vpn-setup: installing $PW_PKG" >> "$LOG"
        if opkg install "$PW_PKG" >> "$LOG" 2>&1; then
            echo "[$(date '+%H:%M:%S')] vpn-setup: PassWall installed ok" >> "$LOG"
            sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        else
            echo "[$(date '+%H:%M:%S')] vpn-setup: PassWall install failed" >> "$LOG"
            sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        fi
    else
        echo "[$(date '+%H:%M:%S')] vpn-setup: PassWall already installed" >> "$LOG"
    fi
```

- [ ] **Step 3: Добавить vpn-bootstrap.sh в chmod строку**

Найти:
```sh
chmod +x /usr/bin/vpn-connect.sh /usr/bin/vpn-agent.sh /usr/bin/vpn-apply.sh 2>/dev/null
```

Заменить на:
```sh
chmod +x /usr/bin/vpn-connect.sh /usr/bin/vpn-agent.sh /usr/bin/vpn-apply.sh /usr/bin/vpn-bootstrap.sh 2>/dev/null
```

### Часть C: проверить сборку

- [ ] **Step 4: Запустить patch-ipk.sh и проверить что bootstrap попал в пакет**

```bash
bash patch-ipk.sh /tmp/test-bootstrap.ipk
```

Ожидаемый вывод:
```
=== IPK Builder ===
...
[1/4] Сборка data.tar.gz...  OK (...)
[2/4] Сборка control.tar.gz...  OK
[3/4] Сборка IPK...  OK
...  Готово!
```

- [ ] **Step 5: Верифицировать что vpn-bootstrap.sh в архиве**

```bash
cd /tmp && mkdir ipk-check && cd ipk-check
tar xf /tmp/test-bootstrap.ipk
tar xzf data.tar.gz
ls ./usr/bin/vpn-bootstrap.sh
```

Ожидаемый вывод: `./usr/bin/vpn-bootstrap.sh`

- [ ] **Step 6: Верифицировать что bootstrap вызывается в postinst**

```bash
tar xzf control.tar.gz
grep "vpn-bootstrap" postinst
```

Ожидаемый вывод: строки с `vpn-bootstrap.sh`

- [ ] **Step 7: Cleanup**

```bash
rm -rf /tmp/ipk-check /tmp/test-bootstrap.ipk
```

- [ ] **Step 8: Commit**

```bash
git add patch-ipk.sh
git commit -m "feat(ipk): add vpn-bootstrap.sh to package, call from postinst before PassWall install"
```

---

## Task 6: Финальная сборка и проверка

- [ ] **Step 1: Финальная сборка IPK**

```bash
bash patch-ipk.sh
```

Ожидаемый вывод: `Готово! luci-app-vpnbot_1.2.0-r2_all.ipk`

- [ ] **Step 2: Проверить синтаксис всех изменённых файлов**

```bash
bash -n files/vpn-bootstrap.sh && echo "bootstrap: OK"
bash -n files/xray-fetch.init  && echo "xray-fetch: OK"
bash -n files/vpn-agent.sh     && echo "agent: OK"
bash -n patch-ipk.sh           && echo "patch-ipk: OK"
```

Ожидаемый вывод — 4 строки с OK.

- [ ] **Step 3: Проверить что файл bootstrap.sh исполняемый в IPK**

```bash
cd /tmp && mkdir ipk-final && cd ipk-final
tar xf ~/Documents/router/luci-app-vpnbot_1.2.0-r2_all.ipk
tar xzf data.tar.gz
stat ./usr/bin/vpn-bootstrap.sh | grep "Access:"
```

Ожидаемый вывод: содержит `0755` или `rwxr-xr-x`.

- [ ] **Step 4: Проверить полный flow postinst в control.tar.gz**

```bash
tar xzf control.tar.gz
cat postinst | grep -A5 "bootstrap"
```

Ожидаемый вывод:
```
if [ -x /usr/bin/vpn-bootstrap.sh ]; then
    echo "[...] vpn-setup: running bootstrap" >> "$LOG"
    progress "setup" 40 "Настройка профиля..."
    /usr/bin/vpn-bootstrap.sh
fi
```

- [ ] **Step 5: Cleanup и финальный commit**

```bash
rm -rf /tmp/ipk-final
cd ~/Documents/router
git add luci-app-vpnbot_1.2.0-r2_all.ipk
git commit -m "build: rebuild IPK v1.2.0-r2 with RAM profile + zram bootstrap"
```

---

## Примечания по деплою

После реализации — тестирование на реальном роутере:

```sh
# Чистая установка
opkg install https://self-music.online/router.ipk
tail -f /tmp/vpn-install.log | grep -E "bootstrap|profile|zram"
```

Ожидаемые строки в логе:
- `bootstrap: profile detected: tiny (MemTotal=32768kB)` — на 32MB роутере
- `bootstrap: zram: configured 11MB and started`
- `bootstrap: bootstrap done (profile=tiny)`
- `vpn-setup: profile=tiny`
- `xray-fetch: installing passwall (profile=tiny)`

Проверить zram:
```sh
cat /proc/swaps
free
```

Проверить профиль агента:
```sh
cat /etc/vpn/profile
grep "bypass_interval" /etc/vpn/vpn-agent.log
```
