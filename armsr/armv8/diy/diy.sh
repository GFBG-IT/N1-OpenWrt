#!/bin/bash

# Adjust source code
patch -p1 -f < $(dirname "$0")/luci.patch

# Clone packages
git clone https://github.com/ophub/luci-app-amlogic --depth=1 clone/amlogic
git clone https://github.com/sbwml/autocore-arm --depth=1 --branch openwrt-25.12 clone/autocore-arm

# Adjust packages
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/autocore-arm feeds/luci/applications/autocore

sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# Clean packages
rm -rf clone
