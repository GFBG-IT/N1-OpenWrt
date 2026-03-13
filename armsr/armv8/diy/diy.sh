#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
git clone https://github.com/sbwml/autocore-arm --depth=1 --branch openwrt-25.12 clone/autocore-arm
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2 --depth=1 clone/passwall2
git clone https://github.com/sbwml/luci-app-mosdns --depth=1 --branch v5 clone/mosdns
git clone https://github.com/linkease/ddnstox-openwrt-package --depth=1 clone/ddnstox
git clone https://github.com/nikkinikki-org/OpenWrt-nikki --depth=1 clone/nikki
git clone https://github.com/timsaya/luci-app-bandix --depth=1 clone/luci-bandix 
git clone https://github.com/timsaya/openwrt-bandix --depth=1 clone/core-bandix 

# Adjust packages 

cp -rf clone/autocore-arm/* feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
rm -rf feeds/luci/applications/luci-app-passwall2
cp -rf clone/passwall2/luci-app-passwall2 feeds/luci/applications/
rm -rf feeds/luci/applications/luci-app-mosdns
cp -rf clone/mosdns/v2dat feeds/packages/utils/v2dat
cp -rf clone/mosdns/luci-app-mosdns feeds/luci/applications/
cp -rf clone/ddnstox/luci-app-ddnstox feeds/luci/applications/
cp -rf clone/nikki/luci-app-nikki feeds/luci/applications/
cp -rf clone/luci-bandix/luci-app-bandix feeds/luci/applications/
cp -rf clone/ddnstox feeds/packages/net/ddnstox
cp -rf clone/nikki feeds/packages/net/nikki
cp -rf clone/core-bandix feeds/packages/net/openwrt-bandix 

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean temporary clones
rm -rf clone
