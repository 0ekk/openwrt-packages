include $(TOPDIR)/rules.mk

PKG_NAME:=fullcone
PKG_RELEASE:=3
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/fullcone
  SECTION:=net
  CATEGORY:=Network
  TITLE:=UDP full cone NAT for firewall4 (xt_FULLCONENAT via iptables-nft)
  DEPENDS:=+kmod-ipt-fullconenat +iptables-mod-fullconenat +iptables-nft
  PKGARCH:=all
endef

define Package/fullcone/conffiles
/etc/config/fullcone
endef

define Build/Compile
endef

define Package/fullcone/install
	$(CP) ./files/* $(1)/
endef

define Package/fullcone/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/firewall reload
exit 0
endef

define Package/fullcone/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/usr/share/fullcone/fullcone.sh stop
uci -q delete firewall.fullcone && uci commit firewall
exit 0
endef

define Package/fullcone/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/firewall reload
# fw4 reload flushes the table but keeps set objects; nothing references them any more.
nft delete set inet fw4 fullcone_lan 2>/dev/null
nft delete set inet fw4 fullcone_wan 2>/dev/null
exit 0
endef

$(eval $(call BuildPackage,fullcone))
