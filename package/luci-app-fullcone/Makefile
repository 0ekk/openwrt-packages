include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-fullcone
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-fullcone
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI page for UDP full cone NAT
  DEPENDS:=+fullcone
  # The SDK has no luci feed, so luci-base is a plain runtime dependency.
  EXTRA_DEPENDS:=luci-base (>=0)
  PKGARCH:=all
endef

define Build/Compile
endef

define Package/luci-app-fullcone/install
	$(CP) ./files/* $(1)/
endef

define Package/luci-app-fullcone/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || /etc/init.d/rpcd reload
exit 0
endef

$(eval $(call BuildPackage,luci-app-fullcone))
