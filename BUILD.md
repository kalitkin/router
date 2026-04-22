# Сборка luci-app-vpnbot через OpenWrt SDK

## Структура пакета

```
luci-app-vpnbot/
├── Makefile                              ← главный файл сборки
└── files/                                ← всё что попадёт на роутер
    ├── etc/
    │   ├── init.d/vpn-agent              ← procd сервис
    │   └── vpn/
    │       ├── bypass_ips.txt            ← 1407 IP-диапазонов
    │       └── bypass_domains.txt        ← 230 доменов
    ├── usr/
    │   ├── bin/
    │   │   ├── vpn-connect.sh            ← регистрация по коду
    │   │   ├── vpn-agent.sh              ← heartbeat + config poll
    │   │   └── vpn-apply.sh              ← применяет конфиг в PassWall
    │   └── lib/lua/luci/
    │       ├── controller/vpn.lua        ← LuCI контроллер
    │       └── view/vpn/index.htm        ← LuCI страница
    └── etc/vpn-agent/                    ← (version записывается при сборке)
```

## Шаги сборки

### 1. Скачать SDK (если ещё нет)

Для твоей целевой платформы. Пример для generic aarch64:

```bash
wget https://downloads.openwrt.org/releases/24.10.4/targets/mediatek/filogic/openwrt-sdk-24.10.4-mediatek-filogic_gcc-13.3.0_musl.Linux-x86_64.tar.zst
tar xf openwrt-sdk-*.tar.zst
cd openwrt-sdk-*/
```

### 2. Скопировать пакет

```bash
# Скопировать папку luci-app-vpnbot в package/
cp -r /path/to/luci-app-vpnbot package/
```

### 3. Обновить feeds (нужно для luci.mk)

```bash
./scripts/feeds update -a
./scripts/feeds install -a
```

### 4. Включить пакет

```bash
make menuconfig
# LuCI → Applications → luci-app-vpnbot → <M>
# Или быстро:
echo "CONFIG_PACKAGE_luci-app-vpnbot=m" >> .config
make defconfig
```

### 5. Собрать

```bash
make package/luci-app-vpnbot/compile V=s
```

### 6. Результат

```bash
ls -la bin/packages/*/base/luci-app-vpnbot_*.ipk
# → luci-app-vpnbot_1.1.0-r1_all.ipk
```

### 7. Выложить на сервер

```bash
scp bin/packages/*/base/luci-app-vpnbot_*.ipk root@self-music.online:/var/www/self-music.online/router.ipk
```

## Установка на роутере

```bash
opkg install https://self-music.online/router.ipk
```

Или в LuCI: System → Software → вставить URL → Install.

После установки: Services → VPN Bot → ввести код.

## Альтернатива: сборка без luci.mk

Если SDK не может найти `luci.mk` (нет feeds/luci), замени последнюю строку Makefile:

```makefile
# Вместо:
include $(TOPDIR)/feeds/luci/luci.mk
$(eval $(call BuildPackage,$(PKG_NAME)))

# Используй:
include $(INCLUDE_DIR)/package.mk
$(eval $(call BuildPackage,$(PKG_NAME)))
```

И добавь в начало после `include $(TOPDIR)/rules.mk`:

```makefile
define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=$(LUCI_TITLE)
  DEPENDS:=$(LUCI_DEPENDS)
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
$(LUCI_DESCRIPTION)
endef
```

## Обновление версии

Поменять в Makefile:
```makefile
PKG_VERSION:=1.2.0
PKG_RELEASE:=1
```

Пересобрать и залить.
