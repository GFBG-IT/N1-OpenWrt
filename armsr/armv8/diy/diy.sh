#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Remove
rm -rf feeds/packages/lang/golang
rm -rf feeds/luci/applications/luci-app-daed

# Clone packages
git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
git clone --depth=1 --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore-arm
git clone --depth=1 https://github.com/ophub/luci-app-amlogic clone/amlogic
git clone --depth=1 https://github.com/QiuSimons/luci-app-daed clone/daed
git clone --depth=1 https://github.com/Zerogiven-OpenWRT-Packages/luci-app-podman clone/podman

# Adjust packages 
cp -rf clone/autocore-arm feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
cp -rf clone/podman feeds/luci/applications/luci-app-podman

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean temporary clones
rm -rf clone
