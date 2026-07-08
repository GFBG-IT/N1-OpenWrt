#!/bin/bash

# =========================================================
# N1-OpenWrt Custom Packages Integration Script
# =========================================================

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# ---- Remove conflicting / outdated packages from feeds ----
rm -rf feeds/packages/lang/golang
rm -rf feeds/luci/applications/luci-app-daed
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/packages/net/xray-core
rm -rf feeds/packages/net/v2ray-geodata
rm -rf feeds/packages/net/v2ray-plugin
rm -rf feeds/packages/net/xray-plugin
rm -rf feeds/packages/net/chinadns-ng
rm -rf feeds/packages/net/dns2socks
rm -rf feeds/packages/net/sing-box
rm -rf feeds/packages/net/hysteria
rm -rf feeds/packages/net/ipt2socks
rm -rf feeds/packages/net/microsocks
rm -rf feeds/packages/net/naiveproxy
rm -rf feeds/packages/net/shadowsocks-rust
rm -rf feeds/packages/net/shadowsocksr-libev
rm -rf feeds/packages/net/simple-obfs
rm -rf feeds/packages/net/tcping
rm -rf feeds/packages/net/geoview
rm -rf feeds/packages/net/shadow-tls
rm -rf feeds/packages/net/mosdns

# ---- Clone original packages (existing) ----
git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
git clone --depth=1 --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore-arm
git clone --depth=1 https://github.com/ophub/luci-app-amlogic clone/amlogic
git clone --depth=1 https://github.com/QiuSimons/luci-app-daed clone/daed

# ---- Clone NEW packages ----
# mosdns + v2ray-geodata
git clone --depth=1 https://github.com/sbwml/luci-app-mosdns clone/mosdns
git clone --depth=1 https://github.com/sbwml/v2ray-geodata clone/v2ray-geodata

# passwall (core packages + luci)
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages clone/passwall-packages
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall clone/passwall-luci

# ddnstox
git clone --depth=1 https://github.com/linkease/ddnstox-openwrt-package clone/ddnstox

# bandix (backend + luci, luci depends on backend)
git clone --depth=1 https://github.com/timsaya/openwrt-bandix clone/openwrt-bandix
git clone --depth=1 https://github.com/timsaya/luci-app-bandix clone/luci-app-bandix

# ---- Integrate packages into feeds ----

# Original packages
cp -rf clone/autocore-arm feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/daed/luci-app-daed feeds/luci/applications/

# mosdns
cp -rf clone/mosdns/mosdns feeds/packages/net/
cp -rf clone/mosdns/luci-app-mosdns feeds/luci/applications/
cp -rf clone/mosdns/v2dat feeds/packages/net/

# v2ray-geodata (sbwml version, replaces upstream)
cp -rf clone/v2ray-geodata feeds/packages/net/v2ray-geodata

# passwall (exclude v2ray-geodata, use sbwml version instead)
for pkg in clone/passwall-packages/*/; do
    pkg_name=$(basename "$pkg")
    if [ "$pkg_name" != "v2ray-geodata" ]; then
        cp -rf "$pkg" feeds/packages/net/
    fi
done
cp -rf clone/passwall-luci/luci-app-passwall feeds/luci/applications/

# Fix shadowsocks-rust missing OpenSSL dependency for cross-compilation
sed -i '/Package\/shadowsocks-rust\/Default/,/endef/{s/DEPENDS:=\$$(RUST_ARCH_DEPENDS)/DEPENDS:=+$$(RUST_ARCH_DEPENDS) +libopenssl/}' feeds/packages/net/shadowsocks-rust/Makefile

# ddnstox
cp -rf clone/ddnstox/ddnstox feeds/packages/net/
cp -rf clone/ddnstox/luci-app-ddnstox feeds/luci/applications/

# bandix
cp -rf clone/openwrt-bandix/openwrt-bandix feeds/packages/net/
cp -rf clone/luci-app-bandix/luci-app-bandix feeds/luci/applications/

# ---- Remove conflicting package ----
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# ---- Clean temporary clones ----
rm -rf clone
