#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Remove
rm -rf feeds/packages/lang/golang
rm -rf feeds/luci/applications/luci-app-daed
rm -rf feeds/packages/net/v2ray-geodata
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/luci/applications/luci-app-passwall2


# Clone packages
git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
git clone --depth=1 --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore-arm
git clone --depth=1 https://github.com/ophub/luci-app-amlogic clone/amlogic
git clone --depth=1 https://github.com/QiuSimons/luci-app-daed clone/daed
git clone --depth=1 https://github.com/Zerogiven-OpenWRT-Packages/luci-app-podman clone/podman
git clone --depth=1 -b v5 https://github.com/sbwml/luci-app-mosdns clone/mosdns
git clone --depth=1 https://github.com/sbwml/v2ray-geodata clone/v2ray-geodata
git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 clone/openlist2
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2  clone/passwall2
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages clone/passwall-packages


# Adjust packages 
cp -rf clone/autocore-arm feeds/packages/utils/autocore/
cp -rf clone/v2ray-geodata feeds/packages/net/v2ray-geodata/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
cp -rf clone/podman feeds/luci/applications/luci-app-podman
cp -rf clone/mosdns feeds/luci/applications/luci-app-mosdns
cp -rf clone/openlist2 feeds/luci/applications/luci-app-openlist2
cp -rf clone/passwall2 feeds/luci/applications/luci-app-passwall2
cp -rf clone/passwall-packages feeds/packages/net/passwall-packages 

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean temporary clones
rm -rf clone
