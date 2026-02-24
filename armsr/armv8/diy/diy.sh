#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
git clone https://github.com/Openwrt-Passwall/openwrt-passwall2 --depth=1 clone/passwall2
# Adjust packages
rm -rf feeds/luci/applications/luci-app-passwall
cp -rf clone/amlogic/luci-app-amlogic clone/passwall2/luci-app-passwall2 feeds/luci/applications/
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean packages
rm -rf clone
