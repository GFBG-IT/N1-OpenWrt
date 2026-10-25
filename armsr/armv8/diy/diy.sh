#!/bin/bash
#
# N1（斐讯 N1 / s905d）编译前准备
# 调用位置：workflow 的 “Prepare & Install feeds” 步骤
# 工作目录：openwrt 源码根目录
# 版本号：环境变量 FW_VERSION，默认值见 workflow 的 env.FW_VERSION
#

set -euo pipefail

log() { printf '[diy] %s\n' "$*"; }

[ -x ./scripts/feeds ] || { log "ERROR: 请在 openwrt 源码根目录执行"; exit 1; }

# ---------------------------------------------------------------------------
# 1/9 写入固件版本号
# ---------------------------------------------------------------------------
version="${FW_VERSION:-}"
[ -n "${version}" ] || { log "ERROR: 缺少环境变量 FW_VERSION"; exit 1; }

case "${version}" in
    *[!0-9A-Za-z._+-]*)
        log "ERROR: 版本号 ${version} 含非法字符"
        exit 1
        ;;
esac

# shellcheck disable=SC2016
prefix='VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),'
line="${prefix}${version})"

grep -q "^${prefix}" include/version.mk || { log "ERROR: 找不到 VERSION_NUMBER 默认值行"; exit 1; }
sed -i "s|^${prefix}.*)\$|${line}|" include/version.mk
grep -qxF "${line}" include/version.mk || { log "ERROR: 版本号写入失败"; exit 1; }
log "固件版本号: ${version}"

# ---------------------------------------------------------------------------
# 2/9 更新 feeds
# ---------------------------------------------------------------------------
log "更新 feeds ..."
./scripts/feeds update -a
log "feeds 更新完成"

# ---------------------------------------------------------------------------
# 3/9 调整 feeds
# ---------------------------------------------------------------------------
log "删除 feeds 里的同名旧包"
for pkg in mosdns xray-core sing-box v2ray-geodata tcping geoview chinadns-ng tailscale dae daed; do
    rm -rf "feeds/packages/net/${pkg}"
done

# telegraf 未选中；把版本化 Go 依赖改成 golang/host，避免编译日志 warning
if [ -f feeds/packages/utils/telegraf/Makefile ]; then
    sed -i 's|golang1\.27/host|golang/host|' feeds/packages/utils/telegraf/Makefile
fi

# N1 的 LAN 是 eth0，没有 br-lan；LuCI 的 getOnlineUsers 只统计 br-lan，导致在线用户数恒为 0
luci_online="feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
if [ -f "$luci_online" ]; then
    if grep -q 'br-lan)' "$luci_online"; then
        sed -i 's#br-lan)#br-lan|eth0|lan[0-9]*)#' "$luci_online"
        log "在线用户数统计已兼容 eth0/lan"
    fi
else
    log "WARN: 未找到 LuCI getOnlineUsers，跳过在线用户数修复"
fi

# BusyBox top 1.3x 在 VSZ/%VSZ 后增加了 CPU 列，LuCI 旧正则解析不到进程
luci_sys="feeds/luci/modules/luci-base/ucode/sys.uc"
if [ -f "$luci_sys" ] && grep -qF '+([0-9]+%) +([0-9]+%) +(.+)$' "$luci_sys"; then
    python3 - "$luci_sys" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

old_re = "+([0-9]+%) +([0-9]+%) +(.+)$/"
new_re = "+([0-9]+%) +([0-9-]+ +)?([0-9]+%) +(.+)$/"
if old_re not in text:
    sys.exit("process_list regex not found")

replacements = [
    ("if (m && m[8] != '/bin/busybox top -bn1')",
     "if (m && m[9] != '/bin/busybox top -bn1')"),
    ("'%CPU': m[7],", "'%CPU': m[8],"),
    ("COMMAND: m[8]", "COMMAND: m[9]"),
]
for old, new in replacements:
    if old not in text:
        sys.exit("process_list field not found: " + old)
    text = text.replace(old, new, 1)

text = text.replace(old_re, new_re, 1)
open(path, "w", encoding="utf-8").write(text)
PY
    log "进程列表已兼容 BusyBox top 的 CPU 列"
fi

luci_config="feeds/luci/modules/luci-base/root/etc/config/luci"
if [ -f "$luci_config" ]; then
    sed -i "s|option lang 'auto'|option lang 'zh_cn'|" "$luci_config"
fi
log "feeds 调整完成"

# ---------------------------------------------------------------------------
# 4/9 引入组件
# ---------------------------------------------------------------------------
# 4.1 golang
log "引入 golang 1.27.x"
rm -rf feeds/packages/lang/golang
git clone --depth=1 --single-branch -b 27.x https://github.com/sbwml/packages_lang_golang clone/golang
cp -rf clone/golang feeds/packages/lang/golang
log "golang 引入成功"

# 4.2 passwall_packages
log "引入 passwall_packages"
rm -rf package/passwall_packages
git clone --depth=1 --single-branch https://github.com/Openwrt-Passwall/openwrt-passwall-packages clone/passwall_packages
cp -rf clone/passwall_packages package/passwall_packages

# xray-core 自动取 XTLS 最新 tag 并同步 tarball 哈希
log "获取 xray-core 最新版本 ..."
xray_tag="$(git ls-remote --tags --refs https://github.com/XTLS/Xray-core.git 'v*' \
    | sed -n 's#.*refs/tags/v##p' \
    | grep -E '^[0-9]+(\.[0-9]+)+$' \
    | sort -V | tail -n1)"

[ -n "${xray_tag}" ] || { log "ERROR: 无法获取 xray-core 版本"; exit 1; }

xray_tar="$(mktemp)"
curl -fsSL "https://codeload.github.com/XTLS/Xray-core/tar.gz/v${xray_tag}?" -o "${xray_tar}"
xray_hash="$(sha256sum "${xray_tar}" | awk '{print $1}')"
rm -f "${xray_tar}"

[ "${#xray_hash}" -eq 64 ] || { log "ERROR: xray-core 源码下载失败"; exit 1; }

sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${xray_tag}|" package/passwall_packages/xray-core/Makefile
sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${xray_hash}|" package/passwall_packages/xray-core/Makefile
log "xray-core 版本: ${xray_tag}"
log "passwall_packages 引入成功"

# 4.3 passwall2
log "引入 passwall2"
rm -rf package/passwall2
git clone --depth=1 --single-branch https://github.com/Openwrt-Passwall/openwrt-passwall2 clone/passwall2
cp -rf clone/passwall2 package/passwall2
rm -rf package/passwall_packages/chinadns-ng
# chinadns-ng 非必需：passwall2 没有它时会回退到 dnsmasq
sed -i '/^[[:space:]]*select PACKAGE_chinadns-ng$/d' package/passwall2/luci-app-passwall2/Makefile
log "passwall2 引入成功"

# 4.4 mosdns
log "引入 mosdns"
rm -rf package/mosdns
git clone --depth=1 --single-branch -b v5 https://github.com/sbwml/luci-app-mosdns clone/mosdns
cp -rf clone/mosdns package/mosdns
# 去掉调试符号，减小 mosdns 二进制
if ! grep -q '^GO_PKG_LDFLAGS:=' package/mosdns/mosdns/Makefile; then
    sed -i '/^GO_PKG_LDFLAGS_X:=/i GO_PKG_LDFLAGS:=-s -w' package/mosdns/mosdns/Makefile
fi
log "mosdns 引入成功"

# 4.5 openlist2
log "引入 openlist2"
rm -rf package/openlist2
git clone --depth=1 --single-branch https://github.com/sbwml/luci-app-openlist2 clone/openlist2
cp -rf clone/openlist2 package/openlist2
log "openlist2 引入成功"

# 4.6 ddnstox
log "引入 ddnstox"
rm -rf package/ddnstox
git clone --depth=1 --single-branch https://github.com/linkease/ddnstox-openwrt-package clone/ddnstox
cp -rf clone/ddnstox package/ddnstox
log "ddnstox 引入成功"

# 4.7 tailscale
log "引入 tailscale"
rm -rf package/tailscale
git clone --depth=1 --single-branch https://github.com/GuNanOvO/openwrt-tailscale clone/tailscale
cp -rf clone/tailscale/package/tailscale package/tailscale
# 上游 Makefile 缺少 golang/host 构建依赖
if ! grep -q 'PKG_BUILD_DEPENDS.*golang/host' package/tailscale/Makefile; then
    sed -i '/^PKG_BUILD_DIR:=/a PKG_BUILD_DEPENDS+=golang/host' package/tailscale/Makefile
fi
log "tailscale 引入成功"

# 4.8 tailscale LuCI
log "引入 luci-app-tailscale-community"
rm -rf package/luci-app-tailscale-community
git clone --depth=1 --single-branch https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community clone/tailscale-luci
cp -rf clone/tailscale-luci/luci-app-tailscale-community package/luci-app-tailscale-community
log "luci-app-tailscale-community 引入成功"

# 4.9 nikki（mihomo 使用稳定版 mihomo-meta，不引入 alpha）
log "引入 nikki"
rm -rf package/nikki package/luci-app-nikki package/mihomo-meta
git clone --depth=1 --single-branch https://github.com/nikkinikki-org/OpenWrt-nikki clone/nikki
cp -rf clone/nikki/nikki package/nikki
cp -rf clone/nikki/luci-app-nikki package/luci-app-nikki
cp -rf clone/nikki/mihomo-meta package/mihomo-meta

# mihomo 使用官方源码的最新稳定版（排除 alpha / rc）
log "获取 mihomo 最新稳定版 ..."
mihomo_tag="$(git ls-remote --tags --refs https://github.com/MetaCubeX/mihomo.git 'v*' \
    | sed -n 's#.*refs/tags/##p' \
    | grep -E '^v[0-9]+(\.[0-9]+)+$' \
    | sort -V | tail -n1)"

[ -n "${mihomo_tag}" ] || { log "ERROR: 无法获取 mihomo 版本"; exit 1; }

mihomo_ver="${mihomo_tag#v}"
sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${mihomo_ver}|" package/mihomo-meta/Makefile
sed -i "s|^PKG_SOURCE_VERSION:=.*$|PKG_SOURCE_VERSION:=${mihomo_tag}|" package/mihomo-meta/Makefile
sed -i "s|^PKG_BUILD_VERSION:=.*$|PKG_BUILD_VERSION:=${mihomo_tag}|" package/mihomo-meta/Makefile
sed -i "s|^PKG_MIRROR_HASH:=.*$|PKG_MIRROR_HASH:=skip|" package/mihomo-meta/Makefile
log "mihomo 版本: ${mihomo_tag}"
log "nikki 引入成功"

# 4.10 momo（sing-box 复用 passwall_packages）
log "引入 momo"
rm -rf package/momo package/luci-app-momo
git clone --depth=1 --single-branch https://github.com/nikkinikki-org/OpenWrt-momo clone/momo
cp -rf clone/momo/momo package/momo
cp -rf clone/momo/luci-app-momo package/luci-app-momo
log "momo 引入成功"

# 4.11 autocore
log "引入 autocore"
rm -rf feeds/packages/utils/autocore
git clone --depth=1 --single-branch --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore
mkdir -p feeds/packages/utils
cp -rf clone/autocore feeds/packages/utils/autocore
log "autocore 引入成功"

# 4.12 luci-app-amlogic
log "引入 luci-app-amlogic"
rm -rf feeds/luci/applications/luci-app-amlogic
git clone --depth=1 --single-branch https://github.com/ophub/luci-app-amlogic clone/amlogic
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
log "luci-app-amlogic 引入成功"

# 4.13 dae
log "引入 dae"
rm -rf package/dae feeds/luci/applications/luci-app-dae feeds/luci/applications/luci-app-daed
git clone --depth=1 --single-branch https://github.com/QiuSimons/luci-app-dae clone/dae
cp -rf clone/dae/dae package/dae
cp -rf clone/dae/luci-app-dae feeds/luci/applications/luci-app-dae
# 显式依赖 geo 数据，复用 passwall_packages 的 v2ray-geodata
sed -i 's|^LUCI_DEPENDS:=.*$|LUCI_DEPENDS:=+dae +luci-compat +v2ray-geoip +v2ray-geosite|' \
    feeds/luci/applications/luci-app-dae/Makefile
log "dae 引入成功"

# 4.14 argon 主题
log "引入 argon 主题"
rm -rf feeds/luci/themes/luci-theme-argon feeds/luci/applications/luci-app-argon-config
git clone --depth=1 --single-branch https://github.com/jerrykuku/luci-theme-argon clone/argon
cp -rf clone/argon feeds/luci/themes/luci-theme-argon
cp -rf clone/argon/compat/luci-app-argon-config feeds/luci/applications/
log "argon 主题引入成功"

# 4.15 自动更新外部组件版本
github_latest_tag() {
    local repo="$1"
    local glob="$2"
    local regex="$3"
    git ls-remote --tags --refs "$repo" "$glob" 2>/dev/null \
        | sed -n 's#.*refs/tags/##p' \
        | grep -E "$regex" \
        | sort -V \
        | tail -n1
}

fetch_sha256() {
    local url="$1"
    local tmp hash
    tmp="$(mktemp)"
    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    hash="$(sha256sum "$tmp" | awk '{print $1}')"
    rm -f "$tmp"
    printf '%s\n' "$hash"
}

log "自动更新外部组件版本 ..."

# openlist2：主程序 + 前端
openlist_tag="$(github_latest_tag https://github.com/OpenListTeam/OpenList.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
if [ -n "$openlist_tag" ]; then
    openlist_ver="${openlist_tag#v}"
    openlist_hash="$(fetch_sha256 "https://codeload.github.com/OpenListTeam/OpenList/tar.gz/v${openlist_ver}?" || true)"
    if [ -n "$openlist_hash" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${openlist_ver}|" package/openlist2/openlist2/Makefile
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${openlist_hash}|" package/openlist2/openlist2/Makefile

        openlist_front_ver=""
        frontend_tag="$(github_latest_tag https://github.com/OpenListTeam/OpenList-Frontend.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
        if [ -n "$frontend_tag" ]; then
            openlist_front_ver="${frontend_tag#v}"
            frontend_hash="$(fetch_sha256 "https://github.com/OpenListTeam/OpenList-Frontend/releases/download/v${openlist_front_ver}/openlist-frontend-dist-lite-v${openlist_front_ver}.tar.gz" || true)"
            if [ -n "$frontend_hash" ]; then
                sed -i "s|^PKG_WEB_VERSION:=.*$|PKG_WEB_VERSION:=${openlist_front_ver}|" package/openlist2/openlist2/Makefile
                sed -i "/define Download\/openlist-frontend/,/endef/ s|^  HASH:=.*$|  HASH:=${frontend_hash}|" package/openlist2/openlist2/Makefile
            fi
        fi
        log "openlist2 -> ${openlist_ver} / 前端 ${openlist_front_ver:-保持原版本}"
    else
        log "WARN: openlist2 下载失败，保留原版本"
    fi
fi

singbox_tag="$(github_latest_tag https://github.com/SagerNet/sing-box.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
if [ -n "$singbox_tag" ]; then
    singbox_ver="${singbox_tag#v}"
    singbox_hash="$(fetch_sha256 "https://codeload.github.com/SagerNet/sing-box/tar.gz/v${singbox_ver}?" || true)"
    if [ -n "$singbox_hash" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${singbox_ver}|" package/passwall_packages/sing-box/Makefile
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${singbox_hash}|" package/passwall_packages/sing-box/Makefile
        log "sing-box -> ${singbox_ver}"
    else
        log "WARN: sing-box 下载失败，保留原版本"
    fi
fi

geoview_tag="$(github_latest_tag https://github.com/snowie2000/geoview.git '*' '^[0-9]+(\.[0-9]+)+$' || true)"
if [ -n "$geoview_tag" ]; then
    geoview_hash="$(fetch_sha256 "https://codeload.github.com/snowie2000/geoview/tar.gz/${geoview_tag}?" || true)"
    if [ -n "$geoview_hash" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${geoview_tag}|" package/passwall_packages/geoview/Makefile
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${geoview_hash}|" package/passwall_packages/geoview/Makefile
        log "geoview -> ${geoview_tag}"
    else
        log "WARN: geoview 下载失败，保留原版本"
    fi
fi

# tailscale（只取正式版，排除 -pre）
tailscale_tag="$(github_latest_tag https://github.com/tailscale/tailscale.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
if [ -n "$tailscale_tag" ]; then
    tailscale_ver="${tailscale_tag#v}"
    tailscale_hash="$(fetch_sha256 "https://codeload.github.com/tailscale/tailscale/tar.gz/v${tailscale_ver}?" || true)"
    if [ -n "$tailscale_hash" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${tailscale_ver}|" package/tailscale/Makefile
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${tailscale_hash}|" package/tailscale/Makefile
        log "tailscale -> ${tailscale_ver}"
    else
        log "WARN: tailscale 下载失败，保留原版本"
    fi
fi

# dae：跟随 olicesx/dae 的 HEAD
dae_commit="$(git ls-remote https://github.com/olicesx/dae.git HEAD 2>/dev/null | awk '{print $1; exit}')"
if [ -n "$dae_commit" ]; then
    dae_ver="$(date +%Y.%m.%d)"
    sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${dae_ver}|" package/dae/Makefile
    sed -i "s|^PKG_SOURCE_VERSION:=.*$|PKG_SOURCE_VERSION:=${dae_commit}|" package/dae/Makefile
    log "dae -> ${dae_ver} (${dae_commit:0:7})"
fi

# v2ray-geodata：passwall 包 + Loyalsoldier 最新数据
geoip_tag="$(github_latest_tag https://github.com/Loyalsoldier/geoip.git '*' '^[0-9]{12}$' || true)"
geosite_tag="$(github_latest_tag https://github.com/Loyalsoldier/v2ray-rules-dat.git '*' '^[0-9]{12}$' || true)"
if [ -n "$geoip_tag" ] && [ -n "$geosite_tag" ]; then
    geoip_hash="$(fetch_sha256 "https://github.com/Loyalsoldier/geoip/releases/download/${geoip_tag}/geoip.dat" || true)"
    geosite_hash="$(fetch_sha256 "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/${geosite_tag}/geosite.dat" || true)"
    if [ -n "$geoip_hash" ] && [ -n "$geosite_hash" ]; then
        sed -i "s|^GEOIP_VER:=.*$|GEOIP_VER:=${geoip_tag}|" package/passwall_packages/v2ray-geodata/Makefile
        sed -i "s|^GEOSITE_VER:=.*$|GEOSITE_VER:=${geosite_tag}|" package/passwall_packages/v2ray-geodata/Makefile
        sed -i "/define Download\/geoip/,/endef/ s|^  HASH:=.*$|  HASH:=${geoip_hash}|" package/passwall_packages/v2ray-geodata/Makefile
        sed -i "/define Download\/geosite/,/endef/ s|^  HASH:=.*$|  HASH:=${geosite_hash}|" package/passwall_packages/v2ray-geodata/Makefile
        log "v2ray-geodata -> geoip ${geoip_tag} / geosite ${geosite_tag}"
    else
        log "WARN: geo 数据下载失败，保留原版本"
    fi
fi

# ddnstox 预编译二进制
ddnsto_html="$(curl -fsSL https://fw0.koolcenter.com/binary/ddnsto/op_custom/ 2>/dev/null || true)"
ddnsto_ver="$(printf '%s' "$ddnsto_html" \
    | grep -oE 'ddnsto-custom-binary-[0-9.]+\.tar\.gz' \
    | sed 's|^ddnsto-custom-binary-||; s|\.tar\.gz$||' \
    | sort -Vu | tail -n1)"
if [ -n "$ddnsto_ver" ]; then
    ddnsto_hash="$(fetch_sha256 "https://fw0.koolcenter.com/binary/ddnsto/op_custom/ddnsto-custom-binary-${ddnsto_ver}.tar.gz" || true)"
    if [ -n "$ddnsto_hash" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${ddnsto_ver}|" package/ddnstox/ddnstox/Makefile
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${ddnsto_hash}|" package/ddnstox/ddnstox/Makefile
        log "ddnstox -> ${ddnsto_ver}"
    fi
fi

# tcping：跟随 git HEAD
tcping_commit="$(git ls-remote https://github.com/Lienol/tcping.git HEAD 2>/dev/null | awk '{print $1; exit}')"
if [ -n "$tcping_commit" ]; then
    sed -i "s|^PKG_SOURCE_VERSION:=.*$|PKG_SOURCE_VERSION:=${tcping_commit}|" package/passwall_packages/tcping/Makefile
    sed -i "s|^PKG_MIRROR_HASH:=.*$|PKG_MIRROR_HASH:=skip|" package/passwall_packages/tcping/Makefile
    log "tcping -> ${tcping_commit:0:7}"
fi

log "mosdns 保持 5.3.4（补丁与版本绑定，跳过自动升级）"
log "外部组件版本更新完成"

# 4.16 修正独立 LuCI 包的版本号
# 这些包是从 git 子目录复制进来的，目录里没有 .git；luci.mk 的 findrev 会回退成 0，
# apk 里就显示 0。显式写入 PKG_PO_VERSION（i18n 包用它）即可。
fix_luci_po_version() {
    makefile="$1"
    [ -f "$makefile" ] || return 0
    grep -q '^PKG_VERSION:=' "$makefile" || return 0
    if grep -q '^PKG_PO_VERSION:=' "$makefile"; then
        return 0
    fi
    sed -i "/^PKG_VERSION:=/a PKG_PO_VERSION:=\$(PKG_VERSION)" "$makefile"
}

fix_luci_po_version package/luci-app-nikki/Makefile
fix_luci_po_version package/luci-app-momo/Makefile
fix_luci_po_version package/mosdns/luci-app-mosdns/Makefile
fix_luci_po_version package/openlist2/luci-app-openlist2/Makefile
fix_luci_po_version package/ddnstox/luci-app-ddnstox/Makefile
fix_luci_po_version package/passwall2/luci-app-passwall2/Makefile
fix_luci_po_version feeds/luci/applications/luci-app-dae/Makefile
fix_luci_po_version feeds/luci/applications/luci-app-amlogic/Makefile
fix_luci_po_version feeds/luci/applications/luci-app-argon-config/Makefile

# tailscale LuCI 没有 PKG_VERSION，用源码提交日期作为版本
tailscale_luci_ver="$(git -C clone/tailscale-luci log -1 --format=%cd --date=format:%Y.%m.%d 2>/dev/null || date +%Y.%m.%d)"
[ -n "$tailscale_luci_ver" ] || tailscale_luci_ver="$(date +%Y.%m.%d)"
if ! grep -q '^PKG_VERSION:=' package/luci-app-tailscale-community/Makefile; then
    sed -i "/^LUCI_TITLE:=/i PKG_VERSION:=${tailscale_luci_ver}\nPKG_PO_VERSION:=${tailscale_luci_ver}" package/luci-app-tailscale-community/Makefile
fi
log "LuCI 包版本修正完成"

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
sed -i 's|admin/vpn/tailscale|admin/network/tailscale|g' \
    package/luci-app-tailscale-community/root/usr/share/luci/menu.d/luci-app-tailscale-community.json
log "LuCI 菜单分类调整完成"

# ---------------------------------------------------------------------------
# 6/9 写入运行时优化文件
# ---------------------------------------------------------------------------
log "写入运行时优化文件"
mkdir -p files/etc/sysctl.d files/etc/uci-defaults files/etc/hotplug.d/net files/etc/apk/keys

# nikki / momo / passwall 第三方 apk 源：构建时写入公钥，首次开机追加仓库
log "写入 nikki / momo / passwall feed 公钥"
for name in nikki momo; do
    case "$name" in
        nikki) base="https://nikkinikki.pages.dev" ;;
        momo)  base="https://momomomo.pages.dev" ;;
    esac
    curl -fsSL "${base}/public-key.pem" -o "files/etc/apk/keys/${name}.pem"
    if ! grep -q 'BEGIN PUBLIC KEY' "files/etc/apk/keys/${name}.pem"; then
        log "ERROR: ${name} feed 公钥下载失败"
        exit 1
    fi
done
curl -fsSL "https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub" \
    -o files/etc/apk/keys/openwrt-passwall-build.pem
if ! grep -q 'BEGIN PUBLIC KEY' files/etc/apk/keys/openwrt-passwall-build.pem; then
    log "ERROR: passwall feed 公钥下载失败"
    exit 1
fi
log "nikki / momo / passwall feed 公钥写入完成"

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
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_buckets=65536
net.netfilter.nf_conntrack_tcp_max_retrans=5
EOF

cat > files/etc/sysctl.d/99-zram.conf <<'EOF'
# zram 配套：优先换出到压缩内存
vm.page-cluster=0
vm.swappiness=100
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

cat > files/etc/uci-defaults/99-mosdns-tuning <<'EOF'
#!/bin/sh
# DNS 架构：dnsmasq 只保留 DHCP（port 0 关闭 DNS 监听），解析全部由 mosdns 监听 53 端口承担
[ -f /etc/config/mosdns ] || exit 0

uci -q set mosdns.config.enabled='1'
uci -q set mosdns.config.listen_port='53'
uci -q set mosdns.config.listen_address='0.0.0.0'
uci -q set mosdns.config.redirect='0'
uci -q set mosdns.config.cache_size='20480'
uci -q set mosdns.config.lazy_cache_ttl='259200'
uci -q set mosdns.config.log_level='error'
uci -q commit mosdns

if [ -f /etc/config/dhcp ] && uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
	uci -q set dhcp.@dnsmasq[0].port='0'
	uci -q commit dhcp
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-mosdns-tuning

cat > files/etc/uci-defaults/99-luci-lang <<'EOF'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q commit luci
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-luci-lang

cat > files/etc/uci-defaults/99-custom-feeds <<'EOF'
#!/bin/sh
. /etc/openwrt_release

case "$DISTRIB_RELEASE" in
    *25.12*) branch="openwrt-25.12" ;;
    *) branch="SNAPSHOT" ;;
esac
arch="$DISTRIB_ARCH"
release="$(printf '%s' "$DISTRIB_RELEASE" | cut -d. -f1-2)"
list="/etc/apk/repositories.d/customfeeds.list"

mkdir -p /etc/apk/repositories.d
touch "$list"

# 原文件末尾不是换行时先补一个，避免和新行拼在一起
if [ -s "$list" ] && [ -n "$(tail -c 1 "$list")" ]; then
    printf '\n' >> "$list"
fi

add_feed() {
    url="$1"
    grep -qxF "$url" "$list" || printf '%s\n' "$url" >> "$list"
}

add_feed "https://nikkinikki.pages.dev/${branch}/${arch}/nikki/packages.adb"
add_feed "https://momomomo.pages.dev/${branch}/${arch}/momo/packages.adb"
add_feed "https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall_luci/packages.adb"
add_feed "https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall_packages/packages.adb"
add_feed "https://master.dl.sourceforge.net/project/openwrt-passwall-build/releases/packages-${release}/${arch}/passwall2/packages.adb"

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-custom-feeds

cat > files/etc/uci-defaults/99-distfeeds-video <<'EOF'
#!/bin/sh
. /etc/openwrt_release

list="/etc/apk/repositories.d/distfeeds.list"
[ -f "$list" ] || exit 0

new="https://mirrors.ustc.edu.cn/openwrt/releases/${DISTRIB_RELEASE}/packages/${DISTRIB_ARCH}/video/packages.adb"

# 按目录名匹配 video feed 整行替换，版本号跟随固件，避免硬编码；已是目标地址时不改
if grep -q '/video/packages.adb' "$list" && ! grep -qxF "$new" "$list"; then
	sed -i "s|.*video/packages\.adb.*|$new|" "$list"
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-distfeeds-video

cat > files/etc/uci-defaults/99-mitigations-off <<'EOF'
#!/bin/sh
# 首次开机：把 mitigations=off 写入 boot 分区 uEnv.txt，下次启动生效
[ -f /boot/uEnv.txt ] || mount /boot 2>/dev/null
[ -f /boot/uEnv.txt ] || exit 0
grep -q 'mitigations=off' /boot/uEnv.txt && exit 0

cp -f /boot/uEnv.txt /boot/uEnv.txt.bak 2>/dev/null
sed -i 's/\r$//' /boot/uEnv.txt

if grep -q '^APPEND=' /boot/uEnv.txt; then
	sed -i '/^APPEND=/ s/$/ mitigations=off/' /boot/uEnv.txt
	sync
	logger -t n1-tuning "mitigations=off 已写入 /boot/uEnv.txt，重启后生效"
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-mitigations-off

cat > files/etc/uci-defaults/99-hold-core-packages <<'EOF'
#!/bin/sh
# apk 没有 hold 子命令，等价做法是把 world 里的包名改写成 名字=版本：
# DNS/防火墙关键包固定在固件内置版本，apk upgrade 不会自动升级它们
world=/etc/apk/world
db=/lib/apk/db/installed
[ -f "$world" ] && [ -f "$db" ] || exit 0

pkgver() {
	awk -v p="$1" '
		/^P:/ { n = substr($0, 3) }
		/^V:/ { if (n == p) { print substr($0, 3); exit } }
	' "$db"
}

for pkg in dnsmasq-full mosdns firewall4 luci-app-firewall; do
	grep -qx "$pkg" "$world" || continue
	ver="$(pkgver "$pkg")"
	case "$ver" in ''|*[!A-Za-z0-9.+_~-]*) continue ;; esac
	sed -i "s|^$pkg$|$pkg=$ver|" "$world"
done

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-hold-core-packages

cat > files/etc/uci-defaults/99-dropbear-lan <<'EOF'
#!/bin/sh
# SSH 只监听 LAN 侧
if [ -f /etc/config/dropbear ] && uci -q get dropbear.@dropbear[0] >/dev/null 2>&1; then
	uci -q set dropbear.@dropbear[0].Interface='lan'
	uci -q commit dropbear
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-dropbear-lan

cat > files/etc/hotplug.d/net/01-maximize_nic_rx_tx_buffers <<'EOF'
#!/bin/sh
# 网卡出现时把 RX/TX ring 设到最大，失败静默跳过
[ "$ACTION" = "add" ] || exit 0
[ -z "$DEVICENAME" ] && exit 0

command -v ethtool >/dev/null 2>&1 || exit 0

NIC="$DEVICENAME"
[ ! -d "/sys/class/net/$NIC/device" ] && exit 0
[ "$(cat "/sys/class/net/$NIC/type" 2>/dev/null)" != "1" ] && exit 0

ETHTOOL_G="$(ethtool -g "$NIC" 2>/dev/null)"
[ -z "$ETHTOOL_G" ] && exit 0

RX_MAX="$(echo "$ETHTOOL_G" | awk '/RX:/ {print $2; exit}')"
TX_MAX="$(echo "$ETHTOOL_G" | awk '/TX:/ {print $2; exit}')"

[ -n "$RX_MAX" ] && [ "$RX_MAX" != "0" ] && ethtool -G "$NIC" rx "$RX_MAX" 2>/dev/null
[ -n "$TX_MAX" ] && [ "$TX_MAX" != "0" ] && ethtool -G "$NIC" tx "$TX_MAX" 2>/dev/null

if ethtool -c "$NIC" 2>/dev/null | grep -q "Adaptive RX:"; then
    ethtool -C "$NIC" adaptive-rx on adaptive-tx on >/dev/null 2>&1
fi

logger -t net-buffer "Maximized ring buffers for $NIC"
EOF

chmod 755 files/etc/hotplug.d/net/01-maximize_nic_rx_tx_buffers
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
# 9/9 清理
# ---------------------------------------------------------------------------
rm -rf clone
log "diy.sh 执行完成"
