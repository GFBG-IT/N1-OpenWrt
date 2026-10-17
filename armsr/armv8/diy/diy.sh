#!/bin/bash

# Remove
rm -rf feeds/packages/lang/golang
rm -rf feeds/luci/applications/luci-app-daed
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/themes/luci-theme-argon

# Clone packages
git clone --depth=1 --single-branch -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang
git clone --depth=1 --single-branch --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore-arm
git clone --depth=1 --single-branch https://github.com/ophub/luci-app-amlogic clone/amlogic
git clone --depth=1 --single-branch https://github.com/QiuSimons/luci-app-daed clone/daed
git clone --depth=1 --single-branch https://github.com/jerrykuku/luci-theme-argon clone/luci-theme-argon

# Adjust packages 
cp -rf clone/autocore-arm feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
cp -rf clone/luci-theme-argon feeds/luci/themes/
cp -rf clone/luci-theme-argon/compat/luci-app-argon-config feeds/luci/applications/

# Remove conflicting package
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile
sed -i 's/GO_ARM64:=v8\.0$/GO_ARM64:=v8.0,crypto/' feeds/packages/lang/golang/golang-values.mk

# Clean temporary clones
rm -rf clone 
