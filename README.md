# VPN Router Bot

Превращает роутер в автоматически управляемый VPN-клиент. Пользователь вводит 6-значный код из Telegram-бота → роутер регистрируется на сервере, получает конфиг [sing-box](https://github.com/SagerNet/sing-box) и запускает VPN. Всё управление — с сервера: смена узла, обновление конфига, перезапуск — без доступа к роутеру.

**Поддерживаемые платформы:** OpenWrt · Keenetic (Entware)

---

## Как это работает

```
Ввод 6-значного кода → регистрация на сервере → получение конфига sing-box
    ↓
vpnd (Go-демон) → heartbeat каждые 45с → reconcile конфига каждые 5 мин
    └── health-мониторинг sing-box → автовосстановление при сбоях
```

Российские сайты (Яндекс, ВКонтакте, банки, госпорталы) идут напрямую — без VPN.  
Всё остальное — через VPN-туннель.

---

## OpenWrt

### Требования

- OpenWrt 21.02 или новее
- Минимум 32 МБ RAM (рекомендуется 64+ МБ)
- Свободное место в `/` или overlay: ~5 МБ (бинарники скачиваются в `/usr/bin/`)
- Доступ к интернету с роутера

### Установка

SSH на роутер и выполнить одну команду:

```sh
opkg install https://self-music.online/router.ipk
```

После запуска opkg завершится быстро — установка продолжается в фоне.  
Следить за прогрессом:

```sh
tail -f /tmp/vpnd-install.log
```

Процесс занимает 1–3 минуты (скачивание vpnd и sing-box с CDN).  
Когда в логе появится `bootstrap done` — установка завершена.

### Регистрация

1. Получите 6-значный код в Telegram-боте
2. Откройте браузер: **LuCI → Services → VPN Setup**
3. Введите код в форму → нажмите **Подключить**
4. Дождитесь статуса **VPN активен**

Или через SSH:

```sh
/usr/bin/vpn-connect.sh 123456
```

### Проверка

```sh
/etc/init.d/vpnd status
logread | grep vpnd | tail -20
```

### Обновление пакета

```sh
opkg install --force-reinstall https://self-music.online/router.ipk
rm -rf /tmp/luci-*
/etc/init.d/vpnd restart
```

Или через UI: **Services → VPN Setup → Обновить пакет**.

### Чистая переустановка

```sh
opkg remove luci-app-vpnbot --autoremove 2>/dev/null
rm -f /usr/bin/vpnd /usr/bin/sing-box
rm -f /etc/vpn/token /etc/vpn/config /etc/vpn/profile /etc/vpn/.bootstrap_done
rm -f /etc/sing-box/config.json
rm -f /tmp/vpnd-install.log /tmp/vpn-progress
opkg install https://self-music.online/router.ipk
tail -f /tmp/vpnd-install.log
```

### Совместимость с архитектурами

Бинарники собираются для всех основных архитектур OpenWrt:

| Архитектура | Устройства |
|-------------|-----------|
| `mipsel_24kc` | TP-Link Archer, старые ASUS |
| `mipsle-softfloat` | Netcraze, часть Zyxel |
| `armv7` | TP-Link Archer AX, Netgear |
| `aarch64_cortex-a53` | Xiaomi AX3000, Redmi AX6 |
| `aarch64_generic` | Keenetic Giga (aarch64) |

Архитектура определяется автоматически через `opkg print-architecture`.

### RAM и профили

Установщик автоматически настраивает zram-swap под объём памяти:

| RAM | Профиль | zram |
|-----|---------|------|
| ≤ 32 МБ | tiny | 35% RAM |
| ≤ 64 МБ | tiny | 30% RAM |
| ≤ 128 МБ | normal | 15% RAM |
| > 128 МБ | normal | нет |

---

## Keenetic

### Требования

- Прошивка Keenetic OS 3.x / OS 4.x / OS 5.x
- USB-накопитель в формате **EXT4** (FAT и NTFS не подойдут) **или** встроенная NAND-память
- Минимум 50 МБ свободного места для Entware

> **Критично:** Аппаратное ускорение трафика (PPE / Fast Path) **должно быть выключено** — иначе iptables не перехватывает пакеты и TPROXY не работает.

### Поддерживаемые модели

| Модель | Архитектура | Примечание |
|--------|-------------|-----------|
| Netcraze Viva (NC-1913) / Keenetic Viva (KN-1910) | mipsel | Проверено |
| Keenetic Ultra (KN-1810 / NC-1812) | ARM | — |
| Keenetic Giga (KN-1011) / Hero (KN-1812) | armv7 | — |
| Keenetic Hero 4 (KN-2410) | aarch64 | — |

---

### Шаг 1 — Подготовка роутера

#### 1.1 Отключить аппаратное ускорение

Через веб-интерфейс:
**Система → Ускорение сети** → выключить (или **Интернет → Подключения** → активное WAN → снять «Аппаратное ускорение»).

Через SSH (NDM CLI):

```
no ppe enable
system configuration save
```

#### 1.2 Активировать нужные компоненты

В веб-интерфейсе: **Общие настройки → Обновления и компоненты → Изменить набор компонентов**

Включить оба компонента:
- ✓ **Поддержка открытых пакетов** (OPKG)
- ✓ **Файловая система Ext** (для EXT4 на USB)

После этого в интерфейсе появится раздел **OPKG / Менеджер пакетов**.

#### 1.3 Подключиться по SSH

```sh
ssh admin@192.168.1.1
```

Порт 22, логин `admin`. Попадёте в NDM CLI — выполните `exec sh` чтобы войти в BusyBox-shell.

---

### Шаг 2 — Установка Entware

#### Вариант A — через веб-интерфейс (рекомендуется)

1. Вставить USB-накопитель в EXT4 в роутер
2. **Управление → Компоненты** → найти **Менеджер пакетов Entware** → установить
3. В Менеджере пакетов OPKG выбрать накопитель EXT4

После установки Entware доступен в `/opt/`.

#### Вариант B — через NDM CLI (SSH, онлайн-установка)

Подключиться по SSH (порт 22, логин `admin`). В NDM CLI выполнить одну команду — она одновременно указывает диск и скачивает+устанавливает Entware:

**Встроенная NAND-память (mipsel):**
```
(config)> opkg disk storage:/ https://bin.entware.net/mipselsf-k3.4/installer/mipsel-installer.tar.gz
```

**Встроенная NAND-память (aarch64):**
```
(config)> opkg disk storage:/ https://bin.entware.net/aarch64-k3.10/installer/aarch64-installer.tar.gz
```

**USB-накопитель (вручную):**
1. Создать папку `install/` в корне накопителя
2. Скачать и положить туда нужный `*-installer.tar.gz`
3. В NDM CLI: `(config)> opkg disk storage:/`

Установка занимает 2–5 минут. Прогресс виден в **Системный журнал**.

#### Проверить установку

После установки Entware в NDM CLI:

```
(config)> exec sh
```

Вы попадёте в BusyBox-shell. Сразу сменить пароль root:

```sh
passwd root
```

Обновить списки пакетов:

```sh
opkg update
opkg upgrade
```

---

### Шаг 3 — Установка VPN

Из BusyBox-shell (`exec sh` уже выполнен):

```sh
opkg update && opkg install curl && curl -s https://self-music.online/router/keenetic-install.sh | sh
```

`curl` нужен чтобы скачать установщик — в базовом Entware его нет, сначала обновляем списки пакетов (`opkg update`). Скрипт дальше сам установит `iptables`, скачает `vpnd` и `sing-box`, настроит автозапуск.

Следить за прогрессом:

```sh
tail -f /tmp/vpn-keenetic-install.log
```

---

### Шаг 4 — Регистрация

Получите 6-значный код в Telegram-боте, затем:

```sh
/opt/etc/vpn-connect.sh 123456
```

---

### Шаг 5 — Запуск VPN

```sh
/opt/etc/init.d/S99vpnd start
```

Проверить статус:

```sh
tail -f /tmp/vpnd.log
```

В логе должно появиться:

```
vpnd started (pid XXXX)
[vpnd] heartbeat OK — status=OK
```

---

### Автозапуск

Скрипт установки автоматически создаёт NDM-хук `/opt/etc/ndm/fs.d/010-entware.sh`.  
VPN запускается автоматически при каждой загрузке роутера после монтирования Entware.

---

### Обновление Keenetic

```sh
curl -s https://self-music.online/router/keenetic-install.sh | sh
/opt/etc/init.d/S99vpnd restart
```

### Переустановка с нуля

```sh
/opt/etc/init.d/S99vpnd stop
rm -f /opt/etc/vpn/token /opt/etc/vpn/config /opt/etc/vpn/applied_hash
rm -f /opt/etc/sing-box/config.json
rm -f /tmp/vpnd.log /tmp/vpn-keenetic-install.log

opkg update && opkg install curl && curl -s https://self-music.online/router/keenetic-install.sh | sh
/opt/etc/vpn-connect.sh 123456
/opt/etc/init.d/S99vpnd start
```

---

## Диагностика

### OpenWrt

```sh
# Статус процессов
pgrep -la vpnd
pgrep -la sing-box

# Логи vpnd
logread | grep vpnd | tail -30

# Лог установки
cat /tmp/vpnd-install.log

# Текущий конфиг
cat /etc/vpn/token      # токен устройства
cat /etc/vpn/profile    # tiny / normal
```

### Keenetic

```sh
# Логи vpnd
tail -100 /tmp/vpnd.log

# Статус процессов
ps | grep -E 'vpnd|sing-box'

# Версия бинарников
/opt/usr/bin/vpnd -version 2>/dev/null || ls -lh /opt/usr/bin/vpnd

# Проверить TPROXY-правила
iptables -t mangle -L VPNBOT_PREROUTE -n 2>/dev/null
ip rule list
```

### Известные предупреждения в логах (не ошибки)

| Сообщение | Причина |
|-----------|---------|
| `heartbeat fail #N` | Временная потеря связи, норма до 7 подряд |
| `sing-box restart` | L2-fallback при недоступности Clash API |
| `rollback: no backup available` | Первый запуск, конфиг ещё не был применён |

---

## Архитектура

```
heartbeatLoop (45с)  ──→ configCh ──→ reconcileLoop ──→ Apply() если конфиг изменился
                     ──→ cmdCh   ──→ commandLoop   ──→ switch / restart / update / status

healthLoop (180с)
  L1: pgrep sing-box          → restart если процесс мёртв
  L2: Clash API delay test    → restart после 3 подряд неудач
```

**Bypass:** российские домены (~210) и IP-подсети (~60 ASN) идут напрямую через ISP.  
Списки обновляются автоматически при каждом применении конфига.

**Rollback guard:** более 3 откатов за 10 минут → safe mode на 1 час.

---

## Сборка из исходников

```sh
# Собрать IPK (только shell-файлы, без OpenWrt SDK)
bash patch-ipk.sh

# Собрать vpnd для всех архитектур
bash build.sh dist

# Задеплоить на сервер
cd /root/router && git pull && bash patch-ipk.sh && bash files/deploy.sh
```

CI/CD через GitHub Actions: пуш в `main` автоматически пересобирает IPK и/или бинарники vpnd при изменении соответствующих файлов.
