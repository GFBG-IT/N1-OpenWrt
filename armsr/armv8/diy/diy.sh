#!/bin/bash
#
# ============================================================================
# N1（斐讯 N1 / s905d）编译前的准备脚本
#
# 调用位置：workflow 的 “Prepare & Install feeds” 步骤
# 工作目录：openwrt 源码根目录（脚本内部会调用 ./scripts/feeds）
#
# 执行顺序：
#   1) 写入固件版本号
#   2) 登记额外 feed（mosdns / openlist2 / ddnstox / passwall2 / passwall 核心包）
#   3) 更新 feeds
#   4) 调整 feeds 内容：删除重名旧包、替换 golang/rust、替换 autocore 等
#   5) 重建 feed 索引（让第 4 步的删除和替换生效）
#   6) 清理临时目录
#
# 版本号：只读环境变量 FW_VERSION，本脚本不设默认值；
#         默认值见 .github/workflows/armsr_armv8.yml 的 env.FW_VERSION。
# ============================================================================
#

set -euo pipefail

log() { printf '[diy] %s\n' "$*"; }

if [ ! -x ./scripts/feeds ]; then
    log "ERROR: 当前目录不是 openwrt 源码根目录（找不到 ./scripts/feeds）"
    exit 1
fi

# ----------------------------------------------------------------------------
# 1/6 写入固件版本号
# ----------------------------------------------------------------------------
version="${FW_VERSION:-}"

if [ -z "${version}" ]; then
    log "ERROR: 没有收到环境变量 FW_VERSION（本脚本不提供默认版本号）"
    log "       默认值请到 .github/workflows/armsr_armv8.yml 的 env.FW_VERSION 修改"
    exit 1
fi

# 版本号最终会写进 Makefile，只允许安全字符，防止写坏文件
case "${version}" in
    *[!0-9A-Za-z._+-]*)
        log "ERROR: 版本号 '${version}' 含非法字符，只允许 0-9、A-Z、a-z、.、_、+、-"
        exit 1
        ;;
esac

# 上游 include/version.mk 中的默认值行（只替换结尾那一段）：
#   VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),<上游默认版本号>)
# 也就是把结尾的 <上游默认版本号> 换成环境变量 FW_VERSION
#
# 注意：这里的 $(...) 是 Makefile 的语法，不是 shell 命令替换，所以故意用单引号保持原样
# shellcheck disable=SC2016
version_prefix='VERSION_NUMBER:=$(if $(VERSION_NUMBER),$(VERSION_NUMBER),'
version_line="${version_prefix}${version})"

if ! grep -q "^${version_prefix}" include/version.mk; then
    log "ERROR: include/version.mk 中找不到 VERSION_NUMBER 默认值行，上游可能改了写法"
    exit 1
fi

# 只替换默认值，保留上游的 $(if ...) 结构：命令行 make VERSION_NUMBER=... 仍可临时覆盖
sed -i "s|^${version_prefix}.*)\$|${version_line}|" include/version.mk

if ! grep -qxF "${version_line}" include/version.mk; then
    log "ERROR: 版本号写入后校验失败，include/version.mk 实际内容："
    grep -n '^VERSION_NUMBER:=' include/version.mk || true
    exit 1
fi

log "固件版本号 = ${version}"
grep -n '^VERSION_NUMBER:=' include/version.mk

# ----------------------------------------------------------------------------
# 2/6 登记额外 feed
# ----------------------------------------------------------------------------
# 各 feed 提供的包：
#   mosdns            luci-app-mosdns / mosdns / geo2txt
#   openlist2         luci-app-openlist2 / openlist2
#   ddnstox           luci-app-ddnstox / ddnstox
#   passwall2         luci-app-passwall2
#   passwall_packages xray-core / sing-box / shadowsocks-rust / tcping /
#                     geoview / chinadns-ng 等 passwall2 核心组件，
#                     以及 v2ray-geoip / v2ray-geosite（geo 数据）
#
# geo 数据统一用 passwall_packages 提供的 v2ray-geodata：
# mosdns 和 passwall2 依赖的是同一个 v2ray-geoip / v2ray-geosite 包，
# 第 4 步只删掉 feeds/packages 里的同名旧版本，保留 passwall 这份。
FEEDS_CONF="feeds.conf.default"

add_feed() {
    name="$1"
    url="$2"

    # 幂等：已经登记过就跳过，重复执行不会重复追加
    if grep -q "^src-git ${name} " "${FEEDS_CONF}"; then
        return 0
    fi

    echo "src-git ${name} ${url}" >>"${FEEDS_CONF}"
    log "登记 feed: ${name}"
}

add_feed mosdns            "https://github.com/sbwml/luci-app-mosdns.git;v5"
add_feed openlist2         "https://github.com/sbwml/luci-app-openlist2.git;main"
add_feed ddnstox           "https://github.com/linkease/ddnstox-openwrt-package.git;master"
add_feed passwall2         "https://github.com/Openwrt-Passwall/openwrt-passwall2.git;main"
add_feed passwall_packages "https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git;main"

# ----------------------------------------------------------------------------
# 3/6 更新 feeds
# ----------------------------------------------------------------------------
log "更新 feeds（首次会克隆上面 5 个源）"
./scripts/feeds update -a

# ----------------------------------------------------------------------------
# 4/6 调整 feeds 内容
# ----------------------------------------------------------------------------
# 4.1 删除与自定义包重名的旧版本 ---------------------------------------------
# feeds/packages 自带 mosdns / xray-core / sing-box / shadowsocks-rust / tcping /
# geoview / chinadns-ng / v2ray-geodata。feeds install 会优先使用排在前面的 feed，
# 所以先删掉这些旧包，第 5 步重建索引后它们才不会再被安装。
# shadowsocks-rust 反过来处理：保留 feeds/packages 自带的 1.24.0，删掉 passwall 的
# 1.25.0。因为 1.25.0 的加密后端换成了 aws-lc-rs，交叉编译到 aarch64 musl 时
# 链接会报 aws_lc_0_44_0_* 未定义符号；1.24.0 用的是 ring 后端，可以正常编过。
log "删除 feeds 里的同名旧包"
for pkg in mosdns xray-core sing-box \
           v2ray-geodata tcping geoview chinadns-ng; do
    rm -rf "feeds/packages/net/${pkg}"
done

# shadowsocks-rust：用 feeds/packages 的 1.24.0（ring），不用 passwall 的 1.25.0（aws-lc）
rm -rf feeds/passwall_packages/shadowsocks-rust

if [ ! -d feeds/packages/net/shadowsocks-rust ]; then
    log "ERROR: feeds/packages 里找不到 shadowsocks-rust，无法使用 1.24.0（ring）"
    exit 1
fi

ss_version="$(sed -n 's/^PKG_VERSION:=//p' feeds/packages/net/shadowsocks-rust/Makefile)"
case "${ss_version}" in
    1.24.*)
        log "shadowsocks-rust 使用 ${ss_version}（ring 后端）"
        ;;
    *)
        log "WARN: shadowsocks-rust 版本为 ${ss_version}，不是 1.24.x；"
        log "      1.25+ 改用 aws-lc 后端，aarch64 musl 交叉编译可能在链接阶段失败"
        ;;
esac

# geo 数据（v2ray-geoip / v2ray-geosite）统一用 passwall_packages 里的
# v2ray-geodata：数据版本固定、带 hash，mosdns 与 passwall2 共用同一份。
# feeds/packages 里的旧版本已在上面的循环里删除，这里保留 passwall 的即可，
# 不再引入 sbwml/v2ray-geodata，避免第二份同名的 geo 数据包。
log "geo 数据使用 passwall_packages 的 v2ray-geodata"

# 4.2 替换 golang -----------------------------------------------------------
# mosdns / xray-core / sing-box / geoview / openlist2 需要较新的 Go 版本
log "替换 golang"
rm -rf feeds/packages/lang/golang
git clone --depth=1 --single-branch -b 27.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang

# 4.3 替换 rust -------------------------------------------------------------
# OpenWrt 自带的 rust 在 host 编译阶段会从 ci-artifacts.rust-lang.org 下载预编译
# LLVM，旧版本产物被上游清理后会报 “failed to download llvm from ci”。
# 换成 sbwml 维护的 rust feed（版本更新、LLVM 产物可用），同时保证 rustc 版本
# 满足 shadowsocks-rust 的 rust-version 要求（1.24 需要 >= 1.88）。
#
# 如果仍遇到上面的下载错误，把 RUST_DOWNLOAD_CI_LLVM 改成 0：
# 让 LLVM 在本地编译（多花 30~60 分钟，但不依赖上游产物）。
RUST_DOWNLOAD_CI_LLVM=1

log "替换 rust"
rm -rf feeds/packages/lang/rust
git clone --depth=1 --single-branch -b main https://github.com/sbwml/packages_lang_rust feeds/packages/lang/rust

if [ "${RUST_DOWNLOAD_CI_LLVM}" = "0" ]; then
    sed -i 's|llvm\.download-ci-llvm=true|llvm.download-ci-llvm=false|' feeds/packages/lang/rust/Makefile
fi

# 4.4 替换 autocore / amlogic / daed / argon 主题 ---------------------------
log "删除 feeds 中将被替换的软件包"
rm -rf feeds/luci/applications/luci-app-daed
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/themes/luci-theme-argon

log "克隆替换用的软件包"
git clone --depth=1 --single-branch --branch openwrt-25.12 https://github.com/sbwml/autocore-arm clone/autocore-arm
git clone --depth=1 --single-branch https://github.com/ophub/luci-app-amlogic clone/amlogic
git clone --depth=1 --single-branch https://github.com/QiuSimons/luci-app-daed clone/daed
git clone --depth=1 --single-branch https://github.com/jerrykuku/luci-theme-argon clone/luci-theme-argon

log "覆盖 feeds 中的软件包"
cp -rf clone/autocore-arm feeds/packages/utils/autocore/
cp -rf clone/amlogic/luci-app-amlogic feeds/luci/applications/
cp -rf clone/daed/luci-app-daed feeds/luci/applications/
cp -rf clone/luci-theme-argon feeds/luci/themes/
cp -rf clone/luci-theme-argon/compat/luci-app-argon-config feeds/luci/applications/

# 4.5 其它补丁 -------------------------------------------------------------
log "应用补丁"
# 从 luci 集合里去掉与 luci-app-attendedsysupgrade 冲突的包
sed -i '/luci-app-attendedsysupgrade/d' feeds/luci/collections/luci/Makefile

# ----------------------------------------------------------------------------
# 5/6 重建 feed 索引
# ----------------------------------------------------------------------------
# 只重建索引、不联网；这样第 4 步删掉/替换的包才会按新内容安装
log "重建 feed 索引"
./scripts/feeds update -i

# ----------------------------------------------------------------------------
# 6/6 清理临时目录
# ----------------------------------------------------------------------------
rm -rf clone

log "diy.sh 执行完成"