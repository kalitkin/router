# Design: RAM Profile Detection + zram-swap

**Date:** 2026-05-24  
**Status:** Approved  
**Scope:** luci-app-vpnbot — bootstrap layer

---

## Цель

Сделать пакет адаптивным к объёму RAM роутера:
- На слабых устройствах (≤64MB) — экономить память: zram + облегчённая установка
- На нормальных (≥65MB) — полный стек как сейчас
- zram ставить на всех, где RAM ≤ 128MB (опционально)

---

## Архитектура

```
postinst (background fork)
  └── /usr/bin/vpn-bootstrap.sh   ← НОВЫЙ, запускается ПЕРВЫМ
        ├── detect RAM (MemTotal)
        ├── write /etc/vpn/profile (tiny | normal)
        ├── setup zram-swap (если нужен)
        ├── touch /etc/vpn/.bootstrap_done
        └── exit

  └── xray-fetch.init (boot-time, START=95)
        ├── check /etc/vpn/profile
        ├── tiny  → passwall (daemon only, NO luci-app-passwall)
        └── normal → luci-app-passwall (текущее поведение)

  └── vpn-agent.sh
        ├── читает profile при старте
        └── tiny → BYPASS_CHECK_INTERVAL=21600 (6ч вместо 1ч)
```

---

## Компонент 1: vpn-bootstrap.sh

**Путь:** `/usr/bin/vpn-bootstrap.sh`  
**Вызов:** из postinst, до установки PassWall

### Логика определения профиля

```sh
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
if [ "$MEM_KB" -le 65536 ]; then
    PROFILE="tiny"
else
    PROFILE="normal"
fi
```

Используем `MemTotal` (физический RAM устройства), не `MemAvailable`.  
`MemAvailable` во время postinst — случайное значение, зависит от текущего состояния.

### Immutable profile

Если `/etc/vpn/profile` уже существует — **не перезаписываем**.  
Профиль устанавливается один раз при первой установке.

### zram setup

| MemTotal | zram | Размер |
|----------|------|--------|
| ≤32MB   | ДА   | 50% RAM |
| ≤64MB   | ДА   | 35% RAM |
| ≤128MB  | ДА   | 15% RAM |
| >128MB  | НЕТ  | — |

Перед установкой — проверка:
```sh
opkg list-installed 2>/dev/null | grep -q "^zram-swap" || opkg install zram-swap
```

Размер zram задаётся через UCI:
```sh
uci set zram-swap.@zram-swap[0].size="$ZRAM_MB"
uci commit zram-swap
/etc/init.d/zram-swap restart
/etc/init.d/zram-swap enable
```

### Sentinel файл

После успешного завершения:
```sh
touch /etc/vpn/.bootstrap_done
```

xray-fetch.init при загрузке не ждёт этот файл (boot и install — разные временные контексты), но другие компоненты могут использовать его для проверки.

---

## Компонент 2: xray-fetch.init (изменения)

Добавить в начало функции `start()`:

```sh
PROFILE=$(cat /etc/vpn/profile 2>/dev/null || echo "normal")
```

Условие установки PassWall:
```sh
if [ "$passwall_ok" -eq 0 ]; then
    if [ "$PROFILE" = "tiny" ]; then
        # Tiny: ставим passwall daemon без LuCI UI
        opkg install passwall >> "$LOG" 2>&1 || true
    else
        # Normal: полный стек с LuCI
        opkg install luci-app-passwall >> "$LOG" 2>&1 || true
    fi
fi
```

> **Важно:** PassWall daemon даже на tiny остаётся (он управляет routing).  
> Экономия — только на LuCI-компонентах (~5-10MB). Полностью без PassWall — отдельный этап.
>
> **Требует проверки перед impl:** в passwall feed пакет `passwall` (core без LuCI) — отдельная единица или только как зависимость `luci-app-passwall`? Если отдельного нет — tiny ставит `luci-app-passwall` так же как normal, только без `--cache-refresh` LuCI (экономия меньше).

---

## Компонент 3: vpn-agent.sh (изменения)

Добавить в секцию инициализации (после credentials):

```sh
PROFILE=$(cat "$DIR/profile" 2>/dev/null || echo "normal")
[ "$PROFILE" = "tiny" ] && BYPASS_CHECK_INTERVAL=21600  # 6ч
```

Fallback обеспечен `|| echo "normal"`.

---

## Компонент 4: patch-ipk.sh (изменения)

Добавить `vpn-bootstrap.sh` в список файлов пакета.  
В postinst — вызов до установки PassWall:

```sh
/usr/bin/vpn-bootstrap.sh >> /tmp/vpn-install.log 2>&1
PROFILE=$(cat /etc/vpn/profile 2>/dev/null || echo "normal")
```

Дальнейшая логика установки PassWall использует `$PROFILE`.

---

## Что НЕ входит в scope

- PassWall-free tiny mode (raw xray + nftables) — отдельный этап
- capability flags (CAP_ZRAM, CAP_PASSWALL) — избыточно сейчас
- Изменение concurrency/buffer в агенте — нет явных параметров в shell

---

## Файлы затронутые изменениями

| Файл | Тип изменения |
|------|--------------|
| `files/vpn-bootstrap.sh` | Новый |
| `files/xray-fetch.init` | Правка (profile-aware install) |
| `files/vpn-agent.sh` | Правка (profile-aware intervals) |
| `patch-ipk.sh` | Правка (добавить bootstrap в пакет + вызов из postinst) |

---

## Тестирование

1. Установка на роутере с 32MB RAM → профиль `tiny`, zram поднимается, luci-app-passwall не ставится
2. Установка на роутере с 256MB RAM → профиль `normal`, zram не ставится, passwall full
3. Повторная установка (`--force-reinstall`) → профиль не перезаписывается
4. Агент: на tiny `BYPASS_CHECK_INTERVAL` = 21600, на normal = 3600
