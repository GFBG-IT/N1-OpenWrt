#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
git clone https://github.com/sbwml/autocore-arm --depth=1 --branch openwrt-25.12 clone/autocore-arm
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2 --depth=1 clone/passwall2
git clone https://github.com/Openwrt-Passwall/openwrt-passwall-packages --depth=1 clone/passwall-deps
git clone https://github.com/sbwml/luci-app-mosdns --depth=1 --branch v5 clone/mosdns
git clone https://github.com/linkease/ddnstox-openwrt-package --depth=1 clone/ddnstox
git clone https://github.com/nikkinikki-org/OpenWrt-nikki --depth=1 clone/nikki
git clone https://github.com/timsaya/luci-app-bandix --depth=1 clone/luci-bandix 
git clone https://github.com/timsaya/openwrt-bandix --depth=1 clone/core-bandix 
git clone https://github.com/sbwml/luci-app-openlist2 --depth=1 clone/openlist2

# Adjust packages 

# System utilities
rm -rf feeds/packages/utils/autocore
cp -rf clone/autocore-arm/* feeds/packages/utils/autocore/

# LuCI applications 
rm -rf feeds/luci/applications/luci-app-amlogic
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-passwall2
cp -rf clone/passwall2/luci-app-passwall2 feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-mosdns
cp -rf clone/mosdns/luci-app-mosdns feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-ddnstox
cp -rf clone/ddnstox/luci-app-ddnstox feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-nikki
cp -rf clone/nikki/luci-app-nikki feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-bandix
cp -rf clone/luci-bandix/luci-app-bandix feeds/luci/applications/

rm -rf feeds/luci/applications/luci-app-openlist2
cp -rf clone/openlist2/luci-app-openlist2 feeds/luci/applications/

# PassWall2 dependencies 
cp -rf clone/passwall-deps/geoview       feeds/packages/utils/
cp -rf clone/passwall-deps/shadowsocks-rust feeds/packages/net/
cp -rf clone/passwall-deps/tcping        feeds/packages/net/
cp -rf clone/passwall-deps/sing-box      feeds/packages/net/
cp -rf clone/passwall-deps/v2ray-geodata feeds/packages/net/
cp -rf clone/passwall-deps/xray-core     feeds/packages/net/

# ddnstox core package
rm -rf feeds/packages/net/ddnstox
cp -rf clone/ddnstox feeds/packages/net/ddnstox

# Nikki core package
rm -rf feeds/packages/net/nikki
cp -rf clone/nikki feeds/packages/net/nikki

# Bandix core package
rm -rf feeds/packages/net/openwrt-bandix
cp -rf clone/core-bandix feeds/packages/net/openwrt-bandix 

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean temporary clones
rm -rf clone
