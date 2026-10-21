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
# 1/9 写入固件版本号
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
# 2/9 更新 feeds
# ---------------------------------------------------------------------------
log "更新 feeds ..."
./scripts/feeds update -a
log "feeds 更新完成"

# ---------------------------------------------------------------------------
# 3/9 删除 feeds 中与自定义包重名的旧版本
# ---------------------------------------------------------------------------
log "删除 feeds 中的同名旧包"
for pkg in mosdns xray-core sing-box v2ray-geodata tcping geoview chinadns-ng tailscale; do
    rm -rf "feeds/packages/net/${pkg}"
done
log "旧包删除完成（geo 数据使用 passwall_packages 的 v2ray-geodata）"

# ---------------------------------------------------------------------------
# 4/9 引入组件
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

# 4.6 tailscale
log "引入 tailscale"
rm -rf package/tailscale
git clone --depth=1 --single-branch https://github.com/GuNanOvO/openwrt-tailscale clone/tailscale
cp -rf clone/tailscale/package/tailscale package/tailscale
# 上游 Makefile 没写 golang/host 构建依赖，补上，避免并发编译时 Go 还没就绪
if ! grep -q 'PKG_BUILD_DEPENDS.*golang/host' package/tailscale/Makefile; then
    sed -i '/^PKG_BUILD_DIR:=/a PKG_BUILD_DEPENDS+=golang/host' package/tailscale/Makefile
fi
log "tailscale 引入成功"

# 4.7 tailscale LuCI
log "引入 luci-app-tailscale-community"
rm -rf package/luci-app-tailscale-community
git clone --depth=1 --single-branch https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community clone/tailscale-luci
cp -rf clone/tailscale-luci/luci-app-tailscale-community package/luci-app-tailscale-community
log "luci-app-tailscale-community 引入成功"

# 4.8 golang
log "引入 golang 1.27.x"
rm -rf feeds/packages/lang/golang
git clone --depth=1 --single-branch -b 27.x https://github.com/sbwml/packages_lang_golang clone/golang
cp -rf clone/golang feeds/packages/lang/golang
log "golang 引入成功"

# 4.9 autocore
log "引入 autocore"
rm -rf feeds/packages/utils/autocore
git clone --depth=1 --single-branch --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore
mkdir -p feeds/packages/utils
cp -rf clone/autocore feeds/packages/utils/autocore
log "autocore 引入成功"

# 4.10 luci-app-amlogic
log "引入 luci-app-amlogic"
rm -rf feeds/luci/applications/luci-app-amlogic
git clone --depth=1 --single-branch https://github.com/ophub/luci-app-amlogic clone/amlogic
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
log "luci-app-amlogic 引入成功"

# 4.11 luci-app-daed
log "引入 luci-app-daed"
rm -rf feeds/luci/applications/luci-app-daed
git clone --depth=1 --single-branch https://github.com/QiuSimons/luci-app-daed clone/daed
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
log "luci-app-daed 引入成功"

# 4.12 argon 主题
log "引入 argon 主题"
rm -rf feeds/luci/themes/luci-theme-argon feeds/luci/applications/luci-app-argon-config
git clone --depth=1 --single-branch https://github.com/jerrykuku/luci-theme-argon clone/argon
cp -rf clone/argon feeds/luci/themes/luci-theme-argon
cp -rf clone/argon/compat/luci-app-argon-config feeds/luci/applications/
log "argon 主题引入成功"

# ---------------------------------------------------------------------------
# 5/9 调整 LuCI 菜单分类
# ---------------------------------------------------------------------------
log "调整 LuCI 菜单分类"
sed -i 's|admin/services/nlbw|admin/network/nlbw|g' \
    feeds/luci/applications/luci-app-nlbwmon/root/usr/share/luci/menu.d/luci-app-nlbwmon.json
sed -i 's|admin/services/irqbalance|admin/system/irqbalance|g' \
    feeds/luci/applications/luci-app-irqbalance/root/usr/share/luci/menu.d/luci-app-irqbalance.json
sed -i 's|admin/services/openlist2|admin/nas/openlist2|g' \
    package/openlist2/luci-app-openlist2/root/usr/share/luci/menu.d/luci-app-openlist2.json
sed -i 's|admin/vpn/tailscale|admin/services/tailscale|g' \
    package/luci-app-tailscale-community/root/usr/share/luci/menu.d/luci-app-tailscale-community.json
log "LuCI 菜单分类调整完成"

# ---------------------------------------------------------------------------
# 6/9 写入运行时优化文件
# ---------------------------------------------------------------------------
log "写入运行时优化文件"
mkdir -p files/etc/sysctl.d files/etc/uci-defaults

cat > files/etc/sysctl.d/20-network-tuning.conf <<'EOF'
# N1 网络性能调优：BBR 配套 fq + TCP 缓冲
net.core.default_qdisc=fq
net.core.netdev_max_backlog=2048
net.core.rmem_max=8388608
net.core.wmem_max=8388608
net.ipv4.tcp_rmem=4096 131072 8388608
net.ipv4.tcp_wmem=4096 65536 8388608
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_fastopen=3
EOF

cat > files/etc/uci-defaults/99-firewall-flow-offload <<'EOF'
#!/bin/sh
# 首次启动开启软件流量卸载（硬件卸载保持关闭）
[ -f /etc/config/firewall ] || exit 0
if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
	uci -q set firewall.@defaults[0].flow_offloading='1'
	uci -q set firewall.@defaults[0].flow_offloading_hw='0'
	uci -q commit firewall
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-firewall-flow-offload
log "运行时优化文件写入成功"

# ---------------------------------------------------------------------------
# 7/9 应用补丁
# ---------------------------------------------------------------------------
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile
log "补丁应用完成"

# ---------------------------------------------------------------------------
# 8/9 重建索引
# ---------------------------------------------------------------------------
log "重建 feed 索引 ..."
./scripts/feeds update -i
log "feed 索引重建完成"

# ---------------------------------------------------------------------------
# 9/9 清理临时目录
# ---------------------------------------------------------------------------
rm -rf clone
log "diy.sh 执行完成"
