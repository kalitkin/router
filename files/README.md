# Инструкция по установке

## Что в этом пакете

```
delivery/
├── deploy.sh              ← ЗАПУСТИ ЭТО НА СЕРВЕРЕ (делает всё ниже автоматически)
├── install.sh             ← скрипт для роутера (клиент скачивает через curl)
├── router/
│   ├── vpn-connect.sh     ← регистрация роутера по коду
│   ├── vpn-agent.sh       ← фоновый агент (heartbeat + config polling)
│   ├── vpn-apply.sh       ← применяет конфиг в PassWall/xray
│   ├── vpn-agent.init     ← procd init.d сервис
│   ├── vpn.lua            ← LuCI контроллер (Services > VPN Setup)
│   ├── index.htm          ← LuCI страница
│   ├── bypass_ips.txt     ← 1400+ IP-диапазонов (Иран + РФ) для прямого доступа
│   └── bypass_domains.txt ← 230 доменов для прямого доступа
└── scripts/
    └── build.sh           ← сборщик xray бинарников для всех архитектур
```

---

## Шаг 1. Загрузить на сервер

С локальной машины:

```bash
scp -r delivery/ root@self-music.online:/root/vpn-delivery/
```

## Шаг 2. Запустить deploy.sh

```bash
ssh root@self-music.online
cd /root/vpn-delivery
bash deploy.sh
```

deploy.sh делает:
1. Копирует install.sh в `/var/www/self-music.online/install.sh`
2. Копирует router/* в `/var/www/self-music.online/router/`
3. Копирует build.sh в `/root/vpn-scripts/build.sh`
4. Добавляет nginx locations (если нет) и делает reload
5. Запускает build.sh v1.0.0 — скачивает xray бинарники для 6 архитектур

## Шаг 3. Проверить

```bash
# На сервере — файлы доступны?
curl -sI https://self-music.online/install.sh | head -3
curl -sI https://self-music.online/router/vpn-connect.sh | head -3
curl -sI https://self-music.online/packages/latest/VERSION | head -3

# Должно быть HTTP/2 200 для всех трёх
```

---

## Установка на роутер

### Вариант 1: Одна команда (рекомендуемый)

```bash
# SSH на роутер
curl -sL https://self-music.online/install.sh | sh -s -- 123456
```

Где `123456` — 6-значный код из Telegram бота.

Что произойдёт:
1. Определит архитектуру роутера (aarch64, mipsel, arm, x86_64)
2. Установит curl, ca-bundle через opkg
3. Скачает xray бинарник с твоего сервера (sha256 проверка)
4. Установит PassWall (3 fallback-метода)
5. Установит vpn-agent скрипты
6. Установит LuCI страницу и веб-терминал (ttyd)
7. Зарегистрирует роутер по коду
8. Запустит агент

### Вариант 2: Через LuCI

После install.sh:
1. Открыть http://192.168.1.1 → Services → VPN Setup
2. Ввести 6-значный код
3. Нажать «Подключить»

### Вариант 3: Обновление

```bash
curl -sL https://self-music.online/install.sh | sh -s -- --update
```

### Вариант 4: Откат на версию

```bash
curl -sL https://self-music.online/install.sh | sh -s -- 123456 v1.0.0
```

---

## Управление версиями (на сервере)

### Новая версия xray

```bash
# Скачает xray для 6 популярных архитектур
/root/vpn-scripts/build.sh v1.1.0

# Или для ВСЕХ архитектур OpenWrt
/root/vpn-scripts/build.sh v1.1.0 --all

# Или конкретная версия xray
/root/vpn-scripts/build.sh v1.1.0 --xray v25.10.15
```

### Обновление скриптов

```bash
# Просто перезалить файлы
scp router/* root@self-music.online:/var/www/self-music.online/router/

# На роутерах — обновление подхватится при --update или при следующей установке
```

---

## Что где на сервере

```
/var/www/self-music.online/
├── install.sh                       ← curl bootstrap
├── router/
│   ├── vpn-connect.sh
│   ├── vpn-agent.sh
│   ├── vpn-apply.sh
│   ├── vpn-agent.init
│   ├── vpn.lua
│   ├── index.htm
│   ├── bypass_ips.txt
│   └── bypass_domains.txt
└── packages/
    ├── latest → v1.0.0              ← симлинк
    └── v1.0.0/
        ├── VERSION                  ← метаданные
        ├── architectures.txt
        ├── common/
        │   └── luci-app-passwall.ipk (если скачался)
        ├── aarch64_cortex-a53/
        │   ├── xray                 ← бинарник
        │   └── xray.sha256
        ├── mipsel_24kc/
        │   ├── xray
        │   └── xray.sha256
        └── ...
```

## Что где на роутере

```
/usr/bin/
├── vpn-connect.sh
├── vpn-agent.sh
├── vpn-apply.sh
└── xray                            ← бинарник (из packages/)
/etc/
├── init.d/vpn-agent                ← procd сервис
├── vpn/
│   ├── token                       ← 600
│   ├── secret                      ← 600
│   ├── device_id
│   ├── mac
│   ├── config                      ← vless:// URL
│   ├── applied_hash
│   ├── bypass_ips.txt
│   └── bypass_domains.txt
├── vpn-agent/
│   └── version                     ← v1.0.0
└── config/passwall                 ← PassWall конфиг
/tmp/vpn.log                        ← лог (авто-ротация 50KB)
/tmp/vpn-install.log                ← лог установки
```

---

## Диагностика

```bash
# На роутере
cat /tmp/vpn.log               # лог агента
cat /tmp/vpn-install.log        # лог установки
pgrep xray                      # xray жив?
/usr/bin/xray version            # какая версия
uci show passwall | head -20    # конфиг PassWall
cat /etc/vpn/config             # VPN конфиг от сервера
cat /etc/vpn-agent/version      # установленная версия

# Веб-терминал
# http://192.168.1.1 → Services → Terminal (ttyd)
```

## Удаление

```bash
/etc/init.d/vpn-agent stop
/etc/init.d/vpn-agent disable
rm -rf /etc/vpn /etc/vpn-agent /usr/bin/vpn-*.sh /etc/init.d/vpn-agent
rm -rf /usr/lib/lua/luci/controller/vpn.lua /usr/lib/lua/luci/view/vpn/
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
```
