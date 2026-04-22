include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-vpnbot
PKG_VERSION:=1.2.0
PKG_RELEASE:=2

PKG_MAINTAINER:=VPN Bot <admin@self-music.online>
PKG_LICENSE:=MIT

# Используем package.mk вместо luci.mk.
# luci.mk генерирует postinst с default_postinst, который пересобирает LuCI cache
# через Lua — это вызывает OOM на роутерах с 32-64MB RAM.
include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI - VPN Bot
  # curl и ca-bundle намеренно убраны из Depends:
  # opkg резолвит их через opkg update, который загружает 10-20MB индекса пакетов.
  # Вместо этого они устанавливаются в фоновом postinst-скрипте после того,
  # как opkg завершился и освободил память.
  DEPENDS:=+luci-base +jsonfilter
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  VPN Bot — подключает роутер к VPN через Telegram-код.
  Поддерживает PassWall, auto-setup, bypass-листы, heartbeat и обновления конфига.
endef

define Package/$(PKG_NAME)/conffiles
/etc/vpn/
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/vpn-connect.sh $(1)/usr/bin/vpn-connect.sh
	$(INSTALL_BIN) ./files/usr/bin/vpn-agent.sh   $(1)/usr/bin/vpn-agent.sh
	$(INSTALL_BIN) ./files/usr/bin/vpn-apply.sh   $(1)/usr/bin/vpn-apply.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/vpn-agent $(1)/etc/init.d/vpn-agent

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/controller/vpn.lua \
	                $(1)/usr/lib/lua/luci/controller/vpn.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/vpn
	$(INSTALL_DATA) ./files/usr/lib/lua/luci/view/vpn/index.htm \
	                $(1)/usr/lib/lua/luci/view/vpn/index.htm

	$(INSTALL_DIR) $(1)/etc/vpn
	$(INSTALL_DATA) ./files/etc/vpn/bypass_ips.txt     $(1)/etc/vpn/bypass_ips.txt
	$(INSTALL_DATA) ./files/etc/vpn/bypass_domains.txt $(1)/etc/vpn/bypass_domains.txt

	$(INSTALL_DIR) $(1)/etc/vpn-agent
	echo "$(PKG_VERSION)-r$(PKG_RELEASE)" > $(1)/etc/vpn-agent/version
endef

# postinst: минимальный — сразу выходит и запускает тяжёлую работу в фоне.
# Фоновый скрипт стартует через 5 секунд, когда opkg уже вышел и освободил RAM.
# Логика установки зависимостей — последовательная, по одному пакету за раз,
# с очисткой page cache между вызовами opkg.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
[ "$${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -n "$${IPKG_INSTROOT}" ] && exit 0
SETUP=/tmp/.vpn-setup.sh
cat > "$$SETUP" << 'ENDSETUP'
#!/bin/sh
sleep 5
LOG=/tmp/vpn-install.log
echo "[$(date '+%H:%M:%S')] vpn-setup: start" >> "$$LOG"
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
for P in curl ca-bundle jsonfilter; do
    opkg list-installed 2>/dev/null | grep -q "^$$P " && continue
    echo "[$$(date '+%H:%M:%S')] vpn-setup: installing $$P" >> "$$LOG"
    opkg install "$$P" >> "$$LOG" 2>&1 && {
        sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        continue
    }
    opkg update >> "$$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    opkg install "$$P" >> "$$LOG" 2>&1 || true
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
done
if ! command -v xray > /dev/null 2>&1 && [ ! -x /tmp/xray ]; then
    OWRT_ARCH=$$(opkg print-architecture 2>/dev/null | awk '$$1=="arch" && $$3>=10 {print $$2}' | grep -v 'all\|noarch' | tail -1)
    if [ -n "$$OWRT_ARCH" ]; then
        echo "[$$(date '+%H:%M:%S')] vpn-setup: downloading xray for $${OWRT_ARCH}" >> "$$LOG"
        curl -fsSL --connect-timeout 15 --max-time 120 \
            -o /tmp/xray "https://self-music.online/packages/latest/$${OWRT_ARCH}/xray" >> "$$LOG" 2>&1 && \
            [ -s /tmp/xray ] && chmod +x /tmp/xray
    fi
fi
mkdir -p /etc/uci-defaults
cat > /etc/uci-defaults/99-xray-fetch << 'UCID'
#!/bin/sh
[ -x /usr/bin/xray ] && exit 0
[ -x /tmp/xray ]     && exit 0
ARCH=$$(opkg print-architecture 2>/dev/null | awk '$$1=="arch" && $$3>=10 {print $$2}' | grep -v 'all\|noarch' | tail -1)
[ -z "$$ARCH" ] && exit 0
curl -fsSL --connect-timeout 15 --max-time 120 \
    -o /tmp/xray "https://self-music.online/packages/latest/$${ARCH}/xray" \
    && [ -s /tmp/xray ] && chmod +x /tmp/xray
exit 0
UCID
chmod +x /etc/uci-defaults/99-xray-fetch
chmod +x /usr/bin/vpn-connect.sh /usr/bin/vpn-agent.sh /usr/bin/vpn-apply.sh 2>/dev/null
/etc/init.d/vpn-agent enable 2>/dev/null
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
echo "[$$(date '+%H:%M:%S')] vpn-setup: done" >> "$$LOG"
rm -f "$$SETUP"
ENDSETUP
chmod +x "$$SETUP"
(sh "$$SETUP" > /dev/null 2>&1) &
exit 0
endef

define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -z "$${IPKG_INSTROOT}" ] && {
	/etc/init.d/vpn-agent stop 2>/dev/null
	/etc/init.d/vpn-agent disable 2>/dev/null
}
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
