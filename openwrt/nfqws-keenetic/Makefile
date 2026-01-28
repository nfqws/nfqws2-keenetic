include $(TOPDIR)/rules.mk

PKG_NAME:=nfqws2-keenetic
PKG_VERSION:=$(shell cat ../../VERSION)
PKG_RELEASE:=1
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/nfqws2-keenetic
  TITLE:=nfqws2-keenetic
  SECTION:=net
  CATEGORY:=Networking
  DEPENDS:=+iptables +iptables-mod-extra +iptables-mod-nfqueue +iptables-mod-filter +iptables-mod-ipopt +iptables-mod-conntrack-extra +ip6tables +ip6tables-mod-nat +ip6tables-extra
  CONFLICTS:=tpws-keenetic, nfqws-keenetic
  PKGARCH:=all
  URL:=https://github.com/nfqws/nfqws2-keenetic
  VERSION:=$(PKG_VERSION)
endef

define Package/nfqws2-keenetic/description
  NFQWS2 service
endef

define Package/nfqws2-keenetic-web
  TITLE:=nfqws2-keenetic-web
  SECTION:=net
  CATEGORY:=Networking
  DEPENDS:=+nfqws2-keenetic +php8-cgi +php8-mod-session +lighttpd +lighttpd-mod-cgi +lighttpd-mod-setenv +lighttpd-mod-rewrite +lighttpd-mod-redirect
  PKGARCH:=all
  URL:=https://github.com/nfqws/nfqws2-keenetic
  VERSION:=$(PKG_VERSION)
endef

define Package/nfqws2-keenetic-web/description
  NFQWS2 service web interface
endef

define Build/Prepare
		$(Build/Prepare/Default)
		cp -r ../../* $(PKG_BUILD_DIR)
		$(Build/Patch)
endef

define Build/Compile
		cd $(PKG_BUILD_DIR) && make openwrt && make web-openwrt
endef

define Package/nfqws2-keenetic/install
		$(INSTALL_DIR) $(1)/{etc,tmp,usr,var}
		$(CP) $(PKG_BUILD_DIR)/out/openwrt/data/{etc,tmp,usr,var} $(1)/
endef

define Package/nfqws2-keenetic/conffiles
$(file <$(PKG_BUILD_DIR)/out/openwrt/control/conffiles)
endef

define Package/nfqws2-keenetic/preinst
$(file <$(PKG_BUILD_DIR)/out/openwrt/control/preinst)
endef

define Package/nfqws2-keenetic/postinst
$(file <$(PKG_BUILD_DIR)/out/openwrt/control/postinst)
endef

define Package/nfqws2-keenetic/postrm
$(file <$(PKG_BUILD_DIR)/out/openwrt/control/postrm)
endef

define Package/nfqws2-keenetic-web/install
		$(INSTALL_DIR) $(1)/{etc,www}
		$(CP) $(PKG_BUILD_DIR)/out/web-openwrt/data/{etc,www} $(1)/
endef

define Package/nfqws2-keenetic-web/postinst
$(file <$(PKG_BUILD_DIR)/out/web-openwrt/control/postinst)
endef


$(eval $(call BuildPackage,nfqws2-keenetic))
$(eval $(call BuildPackage,nfqws2-keenetic-web))

