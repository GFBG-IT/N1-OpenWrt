#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
git clone https://github.com/sbwml/autocore-arm --depth=1 --branch openwrt-24.10 clone/autocore-arm
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages --depth=1 clone/passwall-packages
git clone https://github.com/Openwrt-Passwall/openwrt-passwall --depth=1 clone/passwall
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2 --depth=1 clone/passwall2
git clone https://github.com/sbwml/luci-app-mosdns --depth=1 clone/mosdns
git clone https://github.com/sbwml/luci-app-openlist2 --depth=1 clone/openlist2
git clone https://github.com/timsaya/luci-app-bandix --depth=1 clone/bandix

# Remove conflicting official packages 
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}

# Adjust packages
rm -rf feeds/luci/applications/luci-app-passwall/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/autocore-arm package/autocore-arm/
cp -rf clone/passwall/luci-app-passwall feeds/luci/applications/
cp -rf clone/passwall2/luci-app-passwall2 feeds/luci/applications/
cp -rf clone/mosdns/luci-app-mosdns feeds/luci/applications/
cp -rf clone/openlist2/luci-app-openlist2 feeds/luci/applications/
cp -rf clone/bandix/luci-app-bandix feeds/luci/applications/
cp -rf clone/passwall-packages/* feeds/packages/net/

sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean packages
rm -rf clone
