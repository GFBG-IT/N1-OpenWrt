#!/bin/bash
#
# ============================================================================
# N1（斐讯 N1 / s905d）编译前准备脚本
#
# 调用位置：workflow 的 “Prepare & Install feeds” 步骤
# 工作目录：openwrt 源码根目录
# 版本号：由环境变量 FW_VERSION 传入，默认值见 workflow 的 env.FW_VERSION
# ============================================================================
#

set -euo pipefail

log() { printf '[diy] %s\n' "$*"; }

if [ ! -x ./scripts/feeds ]; then
    log "ERROR: 请在 openwrt 源码根目录执行"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1/7 写入固件版本号
# ---------------------------------------------------------------------------
version="${FW_VERSION:-}"

if [ -z "${version}" ]; then
    log "ERROR: 缺少环境变量 FW_VERSION"
    exit 1
fi

case "${version}" in
    *[!0-9A-Za-z._+-]*)
        log "ERROR: 版本号 ${version} 含非法字符"
        exit 1
        ;;
esac

# include/version.mk 中的默认值行，只替换结尾的版本号
# shellcheck disable=SC2016
prefix='VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),'
line="${prefix}${version})"

if ! grep -q "^${prefix}" include/version.mk; then
    log "ERROR: include/version.mk 中找不到 VERSION_NUMBER 默认值行"
    exit 1
fi

sed -i "s|^${prefix}.*)\$|${line}|" include/version.mk

if ! grep -qxF "${line}" include/version.mk; then
    log "ERROR: 版本号写入失败"
    exit 1
fi

log "固件版本号写入成功: ${version}"

# ---------------------------------------------------------------------------
# 2/7 更新 feeds
# ---------------------------------------------------------------------------
log "更新 feeds ..."
./scripts/feeds update -a
log "feeds 更新完成"

# ---------------------------------------------------------------------------
# 3/7 删除 feeds 中与自定义包重名的旧版本
# ---------------------------------------------------------------------------
log "删除 feeds 中的同名旧包"
for pkg in mosdns xray-core sing-box v2ray-geodata tcping geoview chinadns-ng; do
    rm -rf "feeds/packages/net/${pkg}"
done
log "旧包删除完成（geo 数据使用 passwall_packages 的 v2ray-geodata）"

# ---------------------------------------------------------------------------
# 4/7 引入组件
# ---------------------------------------------------------------------------
# 4.1 mosdns
log "引入 mosdns"
rm -rf package/mosdns
git clone --depth=1 --single-branch -b v5 https://github.com/sbwml/luci-app-mosdns clone/mosdns
cp -rf clone/mosdns package/mosdns
log "mosdns 引入成功"

# 4.2 openlist2
log "引入 openlist2"
rm -rf package/openlist2
git clone --depth=1 --single-branch https://github.com/sbwml/luci-app-openlist2 clone/openlist2
cp -rf clone/openlist2 package/openlist2
log "openlist2 引入成功"

# 4.3 ddnstox
log "引入 ddnstox"
rm -rf package/ddnstox
git clone --depth=1 --single-branch https://github.com/linkease/ddnstox-openwrt-package clone/ddnstox
cp -rf clone/ddnstox package/ddnstox
log "ddnstox 引入成功"

# 4.4 passwall2
log "引入 passwall2"
rm -rf package/passwall2
git clone --depth=1 --single-branch https://github.com/Openwrt-Passwall/openwrt-passwall2 clone/passwall2
cp -rf clone/passwall2 package/passwall2
log "passwall2 引入成功"

# 4.5 passwall_packages
log "引入 passwall_packages"
rm -rf package/passwall_packages
git clone --depth=1 --single-branch https://github.com/Openwrt-Passwall/openwrt-passwall-packages clone/passwall_packages
cp -rf clone/passwall_packages package/passwall_packages
log "passwall_packages 引入成功"

# 4.6 golang
log "引入 golang 1.27.x"
rm -rf feeds/packages/lang/golang
git clone --depth=1 --single-branch -b 27.x https://github.com/sbwml/packages_lang_golang clone/golang
cp -rf clone/golang feeds/packages/lang/golang
log "golang 引入成功"

# 4.7 autocore
log "引入 autocore"
rm -rf feeds/packages/utils/autocore
git clone --depth=1 --single-branch --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore
mkdir -p feeds/packages/utils
cp -rf clone/autocore feeds/packages/utils/autocore
log "autocore 引入成功"

# 4.8 luci-app-amlogic
log "引入 luci-app-amlogic"
rm -rf feeds/luci/applications/luci-app-amlogic
git clone --depth=1 --single-branch https://github.com/ophub/luci-app-amlogic clone/amlogic
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
log "luci-app-amlogic 引入成功"

# 4.9 luci-app-daed
log "引入 luci-app-daed"
rm -rf feeds/luci/applications/luci-app-daed
git clone --depth=1 --single-branch https://github.com/QiuSimons/luci-app-daed clone/daed
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
log "luci-app-daed 引入成功"

# 4.10 argon 主题
log "引入 argon 主题"
rm -rf feeds/luci/themes/luci-theme-argon feeds/luci/applications/luci-app-argon-config
git clone --depth=1 --single-branch https://github.com/jerrykuku/luci-theme-argon clone/argon
cp -rf clone/argon feeds/luci/themes/luci-theme-argon
cp -rf clone/argon/compat/luci-app-argon-config feeds/luci/applications/
log "argon 主题引入成功"

# ---------------------------------------------------------------------------
# 5/7 应用补丁
# ---------------------------------------------------------------------------
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile
log "补丁应用完成"

# ---------------------------------------------------------------------------
# 6/7 重建索引
# ---------------------------------------------------------------------------
log "重建 feed 索引 ..."
./scripts/feeds update -i
log "feed 索引重建完成"

# ---------------------------------------------------------------------------
# 7/7 清理临时目录
# ---------------------------------------------------------------------------
rm -rf clone
log "diy.sh 执行完成"
