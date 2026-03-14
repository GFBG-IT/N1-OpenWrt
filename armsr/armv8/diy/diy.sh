#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
rm -rf feeds/packages/lang/golang
git clone https://github.com/sbwml/packages_lang_golang -b 26.x feeds/packages/lang/golang
git clone https://github.com/sbwml/autocore-arm --depth=1 --branch openwrt-25.12 clone/autocore-arm
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic

# Adjust packages 
cp -rf clone/autocore-arm/* feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean temporary clones
rm -rf clone
