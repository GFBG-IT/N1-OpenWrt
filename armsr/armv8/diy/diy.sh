#!/bin/bash
#
# N1（斐讯 N1 / s905d）编译前准备
# 调用位置：workflow 的 "Prepare & Install feeds" 步骤；工作目录：openwrt 源码根目录
# 版本号：环境变量 FW_VERSION（手动输入优先，未输入时由 workflow 自动取上游 25.12 系列最新稳定 tag，取不到则回退 25.12）
#

set -euo pipefail

log() { printf '[diy] %s\n' "$*"; }

# 第 4 参为稀疏检出目录列表（空格分隔，用于包多的大仓库）
clone_repo() {
    local repo="$1" dest="$2" branch="${3:-}" sparse_dirs="${4:-}" i
    local args=(--depth=1 --single-branch -q)

    [ -n "$branch" ] && args+=(-b "$branch")
    [ -n "$sparse_dirs" ] && args+=(--filter=blob:none --sparse)

    for i in 1 2 3; do
        rm -rf "$dest"
        if git clone "${args[@]}" "$repo" "$dest" \
            && { [ -z "$sparse_dirs" ] || git -C "$dest" sparse-checkout set $sparse_dirs; }; then
            return 0
        fi
        log "WARN: 克隆 ${repo} 失败（第 ${i}/3 次），重试 ..."
        sleep 3
    done

    log "ERROR: 克隆 ${repo} 三次均失败"
    return 1
}

CLONE_PIDS=()

clone_bg() {
    clone_repo "$@" &
    CLONE_PIDS+=($!)
}

wait_clones() {
    local pid fail=0

    for pid in "${CLONE_PIDS[@]}"; do
        wait "$pid" || fail=1
    done

    if [ "$fail" -ne 0 ]; then
        log "ERROR: 存在克隆失败的仓库，中止"
        exit 1
    fi
}

github_latest_tag() {
    local repo="$1"
    local glob="$2"
    local regex="$3"
    local i t
    for i in 1 2 3; do
        t="$(git ls-remote --tags --refs "$repo" "$glob" 2>/dev/null \
            | sed -n 's#.*refs/tags/##p' \
            | grep -E "$regex" \
            | sort -V \
            | tail -n1)"
        if [ -n "$t" ]; then
            printf '%s\n' "$t"
            return 0
        fi
        log "WARN: 第 ${i}/3 次解析 ${repo} 的 tag 失败"
        sleep 2
    done
    return 1
}

fetch_sha256() {
    local url="$1"
    local tmp hash
    tmp="$(mktemp)"
    if ! curl -fsSL --retry 3 --retry-all-errors "$url" -o "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    hash="$(sha256sum "$tmp" | awk '{print $1}')"
    rm -f "$tmp"
    printf '%s\n' "$hash"
}

install_pkg() {
    rm -rf "$2"
    cp -rf "$1" "$2"
}

update_pkg_version() {
    local name="$1" repo="$2" glob="$3" regex="$4" mk="$5" hash_tpl="$6" critical="$7"
    local tag ver hash

    tag="$(github_latest_tag "$repo" "$glob" "$regex" || true)"
    if [ -z "$tag" ]; then
        if [ "$critical" = 1 ]; then
            log "ERROR: 无法获取 ${name} 版本"
            exit 1
        fi
        log "WARN: 无法获取 ${name} 版本，保留仓库自带版本"
        return 1
    fi

    ver="${tag#v}"
    hash="$(fetch_sha256 "${hash_tpl//%s/${ver}}" || true)"
    if [ -z "$hash" ]; then
        if [ "$critical" = 1 ]; then
            log "ERROR: ${name} 源码下载失败"
            exit 1
        fi
        log "WARN: ${name} 源码下载失败，保留仓库自带版本"
        return 1
    fi

    sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${ver}|" "$mk"
    sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${hash}|" "$mk"
    log "${name} -> ${tag}"
}

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

# 版本描述插入源码最后提交日期：%D %V <提交日期> %C；%V/%R 不动，不影响版本号校验
build_date="$(git log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || true)"
case "$build_date" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) log "WARN: 无法获取源码最后提交日期，回退为构建当天日期"; build_date="$(date +%Y%m%d)" ;;
esac

# 版本描述统一以小写 openwrt 开头（LuCI 固件版本行取自 os-release 的 OPENWRT_RELEASE）；发行版标识 NAME/ID/DISTRIB_ID 仍是 ImmortalWrt
rel_file="package/base-files/files/etc/openwrt_release"
if [ -f "$rel_file" ] && grep -q "^DISTRIB_DESCRIPTION='%D %V %C'$" "$rel_file"; then
    sed -i "s|^DISTRIB_DESCRIPTION='%D %V %C'$|DISTRIB_DESCRIPTION='openwrt %V ${build_date} %C'|" "$rel_file"
else
    log "WARN: openwrt_release 模板格式不符，跳过版本描述修改"
fi

os_file="package/base-files/files/usr/lib/os-release"
if [ -f "$os_file" ] && grep -q '^OPENWRT_RELEASE="%D %V %C"$' "$os_file"; then
    sed -i "s|^OPENWRT_RELEASE=\"%D %V %C\"$|OPENWRT_RELEASE=\"openwrt %V ${build_date} %C\"|" "$os_file"
else
    log "WARN: os-release 模板格式不符，跳过版本描述修改"
fi
if [ -f "$os_file" ] && grep -q '^PRETTY_NAME="%D %V"$' "$os_file"; then
    sed -i 's|^PRETTY_NAME="%D %V"$|PRETTY_NAME="openwrt %V"|' "$os_file"
else
    log "WARN: os-release PRETTY_NAME 模板格式不符，跳过版本描述修改"
fi

log "版本描述编译日期: ${build_date}"

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
# vlmcsd
for pkg in xray-core sing-box v2ray-geodata tcping geoview chinadns-ng vlmcsd; do
    rm -rf "feeds/packages/net/${pkg}"
done

# LuCI 在线用户数统计兼容 eth0
luci_online="feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
if [ -f "$luci_online" ]; then
    if grep -q 'br-lan)' "$luci_online"; then
        sed -i 's#br-lan)#br-lan|eth0|lan[0-9]*)#' "$luci_online"
        log "在线用户数统计已兼容 eth0/lan"
    fi
else
    log "WARN: 未找到 LuCI getOnlineUsers，跳过在线用户数修复"
fi

# process_list 改为 /proc 直读（busybox top 有竞态）
luci_sys="feeds/luci/modules/luci-base/ucode/sys.uc"
if [ -f "$luci_sys" ] && grep -q '^export function process_list() {' "$luci_sys"; then
    if python3 - "$luci_sys" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

old_import = "import { basename, readlink, readfile, open, popen, stat, glob } from 'fs';"
new_import = "import { basename, readlink, readfile, open, popen, stat, glob, lsdir } from 'fs';"
if old_import in text:
    text = text.replace(old_import, new_import, 1)
elif new_import not in text:
    sys.exit("fs import line not found")

new_func = r'''export function process_list() {
	const list = [];
	const users = {};
	let memtotal = 0;

	for (let line in split(readfile('/etc/passwd') ?? '', '\n')) {
		const f = split(line, ':');

		if (length(f) >= 3 && f[0] != '')
			users[f[2]] = f[0];
	}

	const mm = match(readfile('/proc/meminfo') ?? '', /MemTotal:[ \t]+([0-9]+)/);

	if (mm)
		memtotal = +mm[1];

	const cpu_total = () => {
		const cm = match(readfile('/proc/stat') ?? '', /^cpu ([0-9 ]+)/);
		let sum = 0;

		if (cm)
			for (let v in split(trim(cm[1]), ' '))
				sum += +v;

		return sum;
	};

	const pid_ticks = (pid) => {
		const s = readfile(`/proc/${pid}/stat`);

		if (!s)
			return null;

		const m = match(s, /^([0-9]+) \(.*\) (.*)$/);

		if (!m)
			return null;

		const f = split(m[2], ' ');

		return (+f[11] ?? 0) + (+f[12] ?? 0);
	};

	const first = {};

	for (let pid in lsdir('/proc') ?? [])
		if (match(pid, /^[0-9]+$/)) {
			const t = pid_ticks(pid);

			if (t != null)
				first[pid] = t;
		}

	const t0 = cpu_total();

	/* 间隔一个短窗口，让 %CPU 有差分可算（busybox sleep 不支持小数，改用 uptime 忙等） */
	const up0 = +(split(readfile('/proc/uptime'), ' ')[0]);
	let upn = up0;

	while (upn - up0 < 0.2)
		upn = +(split(readfile('/proc/uptime'), ' ')[0]);

	const dtot = (cpu_total() - t0) || 1;

	for (let pid in lsdir('/proc') ?? []) {
		if (!match(pid, /^[0-9]+$/))
			continue;

		const s = readfile(`/proc/${pid}/stat`);

		if (!s)
			continue;

		const m = match(s, /^([0-9]+) \((.*)\) (.*)$/);

		if (!m)
			continue;

		const f = split(m[3], ' ');
		const utime = +f[11] ?? 0;
		const stime = +f[12] ?? 0;
		const vsize = +f[20] ?? 0;
		const cmdline = readfile(`/proc/${pid}/cmdline`);
		let command = null;

		if (length(cmdline)) {
			const args = split(cmdline, uchr(0));

			for (let arg in args)
				if (length(arg))
					command = (command == null) ? arg : command + ' ' + arg;
		}

		if (command == null)
			command = `[${m[2]}]`;

		const st = readfile(`/proc/${pid}/status`);
		const um = st ? match(st, /Uid:\x09([0-9]+)/) : null;
		const user = um ? (users[um[1]] ?? um[1]) : 'root';

		const dcpu = (utime + stime) - (first[pid] ?? (utime + stime));

		push(list, {
			PID: pid,
			PPID: f[1],
			USER: user,
			STAT: f[0],
			VSZ: int(vsize / 1024),
			'%MEM': (memtotal ? int((vsize / 1024) * 100 / memtotal) : 0) + '%',
			'%CPU': (dcpu > 0 ? int(dcpu * 100 / dtot) : 0) + '%',
			COMMAND: command
		});
	}

	return list;
};'''

marker = "export function process_list() {"
start = text.index(marker)
end = text.index("\n};", start) + len("\n};")
text = text[:start] + new_func + text[end:]
open(path, "w", encoding="utf-8").write(text)
PY
    then
        log "process_list 已替换为 /proc 直读实现"
    else
        log "WARN: process_list 替换失败（上游漂移），保留原实现"
    fi
else
    log "WARN: 未找到 LuCI sys.uc 的 process_list，跳过替换"
fi

# 进程页失败弹提示
luci_processes="feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/processes.js"
if [ -f "$luci_processes" ] && grep -q 'expect: { result: \[\] }' "$luci_processes" \
    && ! grep -q 'reject: true' "$luci_processes"; then
    sed -i 's/expect: { result: \[\] }/expect: { result: [] }, reject: true/' "$luci_processes"
    log "进程页失败可见化（reject: true）已应用"
fi

luci_config="feeds/luci/modules/luci-base/root/etc/config/luci"
if [ -f "$luci_config" ]; then
    sed -i "s|option lang 'auto'|option lang 'zh_cn'|" "$luci_config"
fi
log "feeds 调整完成"

# ---------------------------------------------------------------------------
# 4/9 引入外部组件
# ---------------------------------------------------------------------------

# ---- 4.1 并行克隆全部第三方仓库 --------------------------------------------
log "并行克隆第三方仓库 ..."
clone_bg https://github.com/sbwml/packages_lang_golang clone/golang 27.x
clone_bg https://github.com/Openwrt-Passwall/openwrt-passwall-packages clone/passwall_packages ""
clone_bg https://github.com/Openwrt-Passwall/openwrt-passwall2 clone/passwall2 ""
clone_bg https://github.com/svenshi/luci-app-oxidns clone/oxidnsluci ""
clone_bg https://github.com/sbwml/luci-app-openlist2 clone/openlist2 ""
clone_bg https://github.com/linkease/ddnstox-openwrt-package clone/ddnstox ""
clone_bg https://github.com/nikkinikki-org/OpenWrt-nikki clone/nikki ""
clone_bg https://github.com/GuNanOvO/openwrt-tailscale clone/tailscale ""
clone_bg https://github.com/Tokisaki-Galaxy/luci-app-tailscale-community clone/tailscaleluci ""
clone_bg https://github.com/ophub/luci-app-amlogic clone/amlogic ""
clone_bg https://github.com/jerrykuku/luci-theme-argon clone/argon ""
clone_bg https://github.com/sbwml/autocore-arm clone/autocore openwrt-25.12
# bandix tag 与资产可能不同步，资产可下载才采用，失败回退 v0.12.12
bandix_tag="$(github_latest_tag https://github.com/timsaya/openwrt-bandix.git 'v*' '^v[0-9]+(\.[0-9]+)+(-r[0-9]+)?$' || true)"
bandix_tag="${bandix_tag:-v0.12.12}"
bandix_core="${bandix_tag#v}"
bandix_core="${bandix_core%%-r*}"
if ! curl -fsIL --retry 2 "https://github.com/timsaya/bandix/releases/download/v${bandix_core}/bandix-${bandix_core}-aarch64-unknown-linux-musl.tar.gz" > /dev/null 2>&1; then
    log "WARN: bandix ${bandix_tag} 的核心资产不可下载，回退自洽 tag v0.12.12"
    bandix_tag="v0.12.12"
    bandix_core="0.12.12"
fi
bandixluci_tag="$(github_latest_tag https://github.com/timsaya/luci-app-bandix.git 'v*' '^v[0-9]+(\.[0-9]+)+(-r[0-9]+)?$' || true)"
bandixluci_tag="${bandixluci_tag:-v0.12.12-r5}"
log "bandix -> ${bandix_tag} / luci-app-bandix -> ${bandixluci_tag}"
clone_bg https://github.com/timsaya/openwrt-bandix clone/bandix "$bandix_tag"
clone_bg https://github.com/timsaya/luci-app-bandix clone/bandixluci "$bandixluci_tag"
clone_bg https://github.com/OneNAS-space/vlmcsd clone/vlmcsd ""
clone_bg https://github.com/OneNAS-space/luci-app-vlmcsd clone/vlmcsdluci ""
clone_bg https://github.com/sbwml/luci-app-airconnect clone/airconnect ""
clone_bg https://github.com/sbwml/package_libs_ngtcp2 clone/ngtcp2 ""
clone_bg https://github.com/sbwml/package_libs_nghttp3 clone/nghttp3 ""
wait_clones
log "仓库克隆完成（${#CLONE_PIDS[@]} 个）"

# ---- 4.2 落盘与目录特例 -----------------------------------------------------
# golang
install_pkg clone/golang feeds/packages/lang/golang

install_pkg clone/passwall_packages package/passwall_packages
install_pkg clone/passwall2 package/passwall2
rm -rf package/passwall_packages/chinadns-ng
# chinadns-ng 非必需
sed -i '/^[[:space:]]*select PACKAGE_chinadns-ng$/d' package/passwall2/luci-app-passwall2/Makefile

# 固化每日 06:30 geo 更新，oxidns 内部 cron 06:45 跟随
P2_DEFAULT=package/passwall2/luci-app-passwall2/root/usr/share/passwall2/0_default_config
if [ -f "$P2_DEFAULT" ] && grep -q '^config global_rules$' "$P2_DEFAULT"; then
    if ! grep -q 'update_week_mode' "$P2_DEFAULT"; then
        sed -i "s|^\(\toption geosite_update '1'\)$|\1\n\toption update_week_mode '7'\n\toption update_time_mode '6:30'|" "$P2_DEFAULT"
    fi
    grep -q "option update_week_mode '7'" "$P2_DEFAULT" || { log "ERROR: passwall2 0_default_config 写入 geo 更新计划失败"; exit 1; }
else
    log "ERROR: passwall2 0_default_config 不存在或结构漂移"
    exit 1
fi

# luci-app-oxidns
install_pkg clone/oxidnsluci package/luci-app-oxidns

# oxidns 核心（release 预编译 aarch64，版本由 stage3_oxidns 追新，此处为自洽回退值）
mkdir -p package/oxidns
cat > package/oxidns/Makefile <<'EOF'
include $(TOPDIR)/rules.mk

PKG_NAME:=oxidns
PKG_VERSION:=1.7.1
PKG_RELEASE:=1

PKG_SOURCE:=oxidns-aarch64-unknown-linux-musl.tar.gz
PKG_SOURCE_URL:=https://github.com/svenshi/oxidns/releases/download/v$(PKG_VERSION)/
PKG_HASH:=2e58721f840c3a4f1b92ed953857f14a65d2e825f8072917c262f7e34e2f21bd
PKG_BUILD_DIR:=$(BUILD_DIR)/oxidns-$(PKG_VERSION)

PKG_MAINTAINER:=Sven Shi <isvenshi@gmail.com>
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

include $(INCLUDE_DIR)/package.mk

# 散包 tar：默认 unpack 解到 BUILD_DIR 根，必须显式解进 PKG_BUILD_DIR
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	gzip -dc "$(DL_DIR)/$(PKG_SOURCE)" | tar -C $(PKG_BUILD_DIR) -xf -
endef

define Build/Compile
	# nothing to do
endef

define Package/oxidns
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=IP Addresses and Names
  TITLE:=OxiDNS DNS server (prebuilt aarch64)
  URL:=https://github.com/svenshi/oxidns
  DEPENDS:=+ca-bundle
endef

define Package/oxidns/description
  Rust DNS server with geosite/geoip routing, DoH/DoT/DoQ upstreams and WebUI.
  Installed from the upstream release asset; configuration lives in /etc/oxidns/.
endef

define Package/oxidns/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/share/oxidns $(1)/etc/oxidns
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/oxidns $(1)/usr/bin/
	$(CP) $(PKG_BUILD_DIR)/webui $(1)/usr/share/oxidns/webui
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/config.yaml $(1)/etc/oxidns/config.yaml
	# DNS 单层架构：oxidns 直接接管 :53；官方默认 webui 路径相对 working-dir 解析
	$(SED) 's|listen: ":5335"|listen: ":53"|' $(1)/etc/oxidns/config.yaml
	$(SED) 's|root: "./webui"|root: "/usr/share/oxidns/webui"|' $(1)/etc/oxidns/config.yaml
endef

define Package/oxidns/conffiles
/etc/oxidns/config.yaml
endef

$(eval $(call BuildPackage,oxidns))
EOF

# openlist2
install_pkg clone/openlist2 package/openlist2

# ddnstox
install_pkg clone/ddnstox package/ddnstox

# nikki
install_pkg clone/nikki/nikki package/nikki
install_pkg clone/nikki/luci-app-nikki package/luci-app-nikki
install_pkg clone/nikki/mihomo-meta package/mihomo-meta

# autocore
mkdir -p feeds/packages/utils
install_pkg clone/autocore feeds/packages/utils/autocore

# tailscale（fork 替换官方 feed 包）
install_pkg clone/tailscale/package/tailscale feeds/packages/net/tailscale

# luci-app-tailscale-community
install_pkg clone/tailscaleluci/luci-app-tailscale-community package/luci-app-tailscale-community
# 无 PKG_VERSION 行，i18n 版本会回退 0
ts_luci_mk="package/luci-app-tailscale-community/Makefile"
if [ -f "$ts_luci_mk" ] && ! grep -q '^PKG_VERSION:=' "$ts_luci_mk"; then
    sed -i 's|^LUCI_TITLE:=LuCI support for Tailscale$|LUCI_TITLE:=LuCI support for Tailscale\nPKG_VERSION:=4.5.2\nPKG_PO_VERSION:=$(PKG_VERSION)|' "$ts_luci_mk"
fi
if [ -f "$ts_luci_mk" ] && grep -q '^PKG_PO_VERSION:=\$(PKG_VERSION)$' "$ts_luci_mk"; then
    log "luci-app-tailscale-community 版本号已补齐"
else
    log "WARN: luci-app-tailscale-community 的 PKG_VERSION/PKG_PO_VERSION 未补齐，i18n 包版本可能回退为 0"
fi
# fork 的 Makefile 只认 $(TOPDIR)/upx/upx，无则跳过压缩
if command -v upx >/dev/null 2>&1; then
    mkdir -p upx
    ln -sf "$(command -v upx)" upx/upx
fi

install_pkg clone/amlogic/luci-app-amlogic feeds/luci/applications/luci-app-amlogic

# argon 3.0 合一，禁引 argon-config（文件冲突）
rm -rf feeds/luci/applications/luci-app-argon-config
install_pkg clone/argon feeds/luci/themes/luci-theme-argon

# bandix
install_pkg clone/bandix/openwrt-bandix package/bandix
install_pkg clone/bandixluci/luci-app-bandix package/luci-app-bandix
# 上游默认监控 br-lan，N1 的 LAN 是 eth0，不改则启用监控后取不到数据
bandix_cfg="package/bandix/files/bandix.config"
if [ -f "$bandix_cfg" ]; then
    sed -i "s|option iface 'br-lan'|option iface 'eth0'|" "$bandix_cfg"
fi
if [ -f "$bandix_cfg" ] && grep -q "option iface 'eth0'" "$bandix_cfg"; then
    log "bandix 默认监控接口已对齐 eth0"
else
    log "WARN: bandix 默认监控接口仍为 br-lan，需在 LuCI 手动改为 eth0"
fi
# findrev 无 .git 回退 0
bandix_luci_mk="package/luci-app-bandix/Makefile"
if [ -f "$bandix_luci_mk" ]; then
    sed -i '/^# Rebuild language packages when a package revision changes without a PO commit\.$/d' "$bandix_luci_mk"
    sed -i 's|^PKG_PO_VERSION=.*$|PKG_PO_VERSION:=$(PKG_VERSION)|' "$bandix_luci_mk"
fi
if [ -f "$bandix_luci_mk" ] && grep -q '^PKG_PO_VERSION:=\$(PKG_VERSION)$' "$bandix_luci_mk"; then
    log "luci-app-bandix PO 版本已固定为 \$(PKG_VERSION)"
else
    log "WARN: luci-app-bandix 的 PKG_PO_VERSION 未固定，i18n 包版本可能回退为 0"
fi

# luci-app-vlmcsd
install_pkg clone/vlmcsd package/vlmcsd
install_pkg clone/vlmcsdluci package/luci-app-vlmcsd

# airconnect
install_pkg clone/airconnect/airconnect package/airconnect
install_pkg clone/airconnect/luci-app-airconnect package/luci-app-airconnect

# ngtcp2 / nghttp3 必须成对替换
install_pkg clone/ngtcp2 feeds/packages/libs/ngtcp2
install_pkg clone/nghttp3 feeds/packages/libs/nghttp3

log "组件落盘完成（golang / passwall×2 / oxidns / openlist2 / ddnstox / nikki / autocore / amlogic / argon / bandix / vlmcsd / airconnect / ngtcp2+nghttp3）"

# ---- 4.3 统一确定外部组件版本 ----------------------------------------------
log "确定外部组件版本 ..."

# 并行 stage3：xray/mihomo 失败中止编译，其余回退自带版本
stage3_bg() {  # $1=组件名 $2=任务函数名：后台执行并登记 PID:名字
    "$2" &
    BG_PIDS+=("${!}:$1")
}
wait_stage3() {
    local item pid name
    for item in "${BG_PIDS[@]}"; do
        pid="${item%%:*}"
        name="${item#*:}"
        if ! wait "$pid"; then
            case "$name" in
                xray|mihomo) log "ERROR: ${name} 组件版本更新失败，中止编译"; exit 1 ;;
                *) log "WARN: ${name} 组件版本更新任务失败，保留仓库自带版本" ;;
            esac
        fi
    done
    BG_PIDS=()
}

stage3_xray() {
    update_pkg_version "xray-core" \
        https://github.com/XTLS/Xray-core.git 'v*' '^v[0-9]+(\.[0-9]+)+$' \
        package/passwall_packages/xray-core/Makefile \
        'https://codeload.github.com/XTLS/Xray-core/tar.gz/v%s?' 1
}
BG_PIDS=()
stage3_bg xray stage3_xray

# mihomo 稳定版，排除 alpha/rc
stage3_mihomo() {
    local mihomo_tag mihomo_ver
    mihomo_tag="$(github_latest_tag https://github.com/MetaCubeX/mihomo.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
    [ -n "$mihomo_tag" ] || { log "ERROR: 无法获取 mihomo 版本"; return 1; }
    mihomo_ver="${mihomo_tag#v}"
    sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${mihomo_ver}|" package/mihomo-meta/Makefile
    sed -i "s|^PKG_SOURCE_VERSION:=.*$|PKG_SOURCE_VERSION:=${mihomo_tag}|" package/mihomo-meta/Makefile
    sed -i "s|^PKG_BUILD_VERSION:=.*$|PKG_BUILD_VERSION:=${mihomo_tag}|" package/mihomo-meta/Makefile
    sed -i "s|^PKG_MIRROR_HASH:=.*$|PKG_MIRROR_HASH:=skip|" package/mihomo-meta/Makefile
    log "mihomo -> ${mihomo_tag}"
}
stage3_bg mihomo stage3_mihomo

# 跟随 sbwml 自洽 pin，不做前端追新

stage3_singbox() {
    update_pkg_version "sing-box" \
        https://github.com/SagerNet/sing-box.git 'v*' '^v[0-9]+(\.[0-9]+)+$' \
        package/passwall_packages/sing-box/Makefile \
        'https://codeload.github.com/SagerNet/sing-box/tar.gz/v%s?' 0
}
stage3_bg sing-box stage3_singbox

# geoview
stage3_geoview() {
    update_pkg_version "geoview" \
        https://github.com/snowie2000/geoview.git '*' '^[0-9]+(\.[0-9]+)+$' \
        package/passwall_packages/geoview/Makefile \
        'https://codeload.github.com/snowie2000/geoview/tar.gz/%s?' 0
}
stage3_bg geoview stage3_geoview

# oxidns 追新，失败保留回退版本
stage3_oxidns() {
    local ox_tag ox_ver ox_hash
    ox_tag="$(github_latest_tag https://github.com/svenshi/oxidns.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
    [ -n "$ox_tag" ] || { log "WARN: 无法获取 oxidns 版本，保留内置回退版本"; return 0; }
    ox_ver="${ox_tag#v}"
    # 资产名按 aarch64 字面写
    ox_hash="$(fetch_sha256 "https://github.com/svenshi/oxidns/releases/download/v${ox_ver}/oxidns-aarch64-unknown-linux-musl.tar.gz" || true)"
    if [ -z "$ox_hash" ]; then
        log "WARN: oxidns ${ox_tag} 资产下载失败，保留内置回退版本"
        return 0
    fi
    sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${ox_ver}|" package/oxidns/Makefile
    sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${ox_hash}|" package/oxidns/Makefile
    log "oxidns -> ${ox_tag}"
}
stage3_bg oxidns stage3_oxidns

stage3_geodata() {
    local geoip_tag geosite_tag geoip_hash geosite_hash
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
}
stage3_bg geodata stage3_geodata

# ddnstox
stage3_ddnstox() {
    local ddnsto_html ddnsto_ver ddnsto_hash
    ddnsto_html="$(curl -fsSL --retry 3 --retry-all-errors https://fw0.koolcenter.com/binary/ddnsto/op_custom/ 2>/dev/null || true)"
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
}
stage3_bg ddnstox stage3_ddnstox

# tcping
stage3_tcping() {
    local tcping_commit
    tcping_commit="$(git ls-remote https://github.com/Lienol/tcping.git HEAD 2>/dev/null | awk '{print $1; exit}')"
    if [ -n "$tcping_commit" ]; then
        sed -i "s|^PKG_SOURCE_VERSION:=.*$|PKG_SOURCE_VERSION:=${tcping_commit}|" package/passwall_packages/tcping/Makefile
        sed -i "s|^PKG_MIRROR_HASH:=.*$|PKG_MIRROR_HASH:=skip|" package/passwall_packages/tcping/Makefile
        log "tcping -> ${tcping_commit:0:7}"
    fi
}
stage3_bg tcping stage3_tcping

wait_stage3
log "外部组件版本确定完成"

# ---- 4.4 修正独立 LuCI 包的版本号 ------------------------------------------
# findrev 回退 0，显式写 PKG_PO_VERSION
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
fix_luci_po_version package/luci-app-oxidns/Makefile
fix_luci_po_version package/openlist2/luci-app-openlist2/Makefile
fix_luci_po_version package/ddnstox/luci-app-ddnstox/Makefile
fix_luci_po_version package/passwall2/luci-app-passwall2/Makefile
fix_luci_po_version feeds/luci/applications/luci-app-amlogic/Makefile
fix_luci_po_version package/luci-app-airconnect/Makefile

# 无 PKG_VERSION 行，i18n 版本会回退 0
vlmcsd_luci_mk="package/luci-app-vlmcsd/Makefile"
if [ -f "$vlmcsd_luci_mk" ] && ! grep -q '^PKG_VERSION:=' "$vlmcsd_luci_mk"; then
    sed -i 's|^LUCI_DEPENDS:=+vlmcsd$|LUCI_DEPENDS:=+vlmcsd\nPKG_VERSION:=1.0.0\nPKG_PO_VERSION:=$(PKG_VERSION)|' "$vlmcsd_luci_mk"
fi
if [ -f "$vlmcsd_luci_mk" ] && grep -q '^PKG_PO_VERSION:=\$(PKG_VERSION)$' "$vlmcsd_luci_mk"; then
    log "luci-app-vlmcsd 版本号已补齐"
else
    log "WARN: luci-app-vlmcsd 的 PKG_VERSION/PKG_PO_VERSION 未补齐，i18n 包版本可能回退为 0"
fi
log "LuCI 包版本修正完成"

# ---------------------------------------------------------------------------
# 5/9 调整 LuCI 菜单分类
# ---------------------------------------------------------------------------
log "调整 LuCI 菜单分类"
nlbw_menu="feeds/luci/applications/luci-app-nlbwmon/root/usr/share/luci/menu.d/luci-app-nlbwmon.json"
if [ -f "$nlbw_menu" ]; then
    sed -i 's|admin/services/nlbw|admin/network/nlbw|g' "$nlbw_menu"
fi
openlist2_menu="package/openlist2/luci-app-openlist2/root/usr/share/luci/menu.d/luci-app-openlist2.json"
if [ -f "$openlist2_menu" ]; then
    sed -i 's|admin/services/openlist2|admin/nas/openlist2|g' "$openlist2_menu"
    if grep -q 'admin/nas/openlist2' "$openlist2_menu"; then
        log "openlist2 菜单已移至 NAS 目录"
    else
        log "WARN: openlist2 菜单移动未生效，仍为 admin/services"
    fi
else
    log "WARN: 未找到 luci-app-openlist2 menu.d，跳过菜单调整"
fi

ksmbd_menu="feeds/luci/applications/luci-app-ksmbd/root/usr/share/luci/menu.d/luci-app-ksmbd.json"
if [ -f "$ksmbd_menu" ]; then
    sed -i 's|admin/services/ksmbd|admin/nas/ksmbd|g' "$ksmbd_menu"
    if grep -q 'admin/nas/ksmbd' "$ksmbd_menu"; then
        log "ksmbd 菜单已移至 NAS 目录"
    else
        log "WARN: ksmbd 菜单移动未生效，仍为 admin/services"
    fi
else
    log "WARN: 未找到 feeds luci-app-ksmbd，跳过菜单调整"
fi

# passwall2 / nikki 上游默认即在 services 目录
# tailscale 上游默认在 VPN 目录，归位到 network
ts_menu="package/luci-app-tailscale-community/root/usr/share/luci/menu.d/luci-app-tailscale-community.json"
if [ -f "$ts_menu" ]; then
    sed -i 's|admin/vpn/tailscale|admin/network/tailscale|g' "$ts_menu"
    if grep -q 'admin/network/tailscale' "$ts_menu"; then
        log "tailscale 菜单已移至 network 目录"
    else
        log "WARN: tailscale 菜单归位未生效，仍为 admin/vpn"
    fi
else
    log "WARN: 未找到 luci-app-tailscale-community menu.d，跳过菜单调整"
fi

log "LuCI 菜单分类调整完成"

# ---------------------------------------------------------------------------
# 6/9 写入运行时优化文件
# ---------------------------------------------------------------------------
log "写入运行时优化文件"
mkdir -p files/etc/sysctl.d files/etc/uci-defaults files/etc/hotplug.d/net files/etc/apk/keys

# nikki / passwall apk 源公钥
curl -fsSL --retry 3 --retry-all-errors "https://nikkinikki.pages.dev/public-key.pem" \
    -o files/etc/apk/keys/nikki.pem
if ! grep -q 'BEGIN PUBLIC KEY' files/etc/apk/keys/nikki.pem; then
    log "ERROR: nikki feed 公钥下载失败"
    exit 1
fi
curl -fsSL --retry 3 --retry-all-errors "https://master.dl.sourceforge.net/project/openwrt-passwall-build/apk.pub" \
    -o files/etc/apk/keys/openwrt-passwall-build.pem
if ! grep -q 'BEGIN PUBLIC KEY' files/etc/apk/keys/openwrt-passwall-build.pem; then
    log "ERROR: passwall feed 公钥下载失败"
    exit 1
fi
log "nikki / passwall feed 公钥写入完成"

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
net.ipv4.tcp_max_syn_backlog=8192
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_buckets=65536
net.netfilter.nf_conntrack_tcp_max_retrans=5
EOF

cat > files/etc/sysctl.d/99-zram.conf <<'EOF'
# zram 配套：优先换出到压缩内存
vm.page-cluster=0
vm.swappiness=100
EOF

cat > files/etc/uci-defaults/99-zram-size <<'EOF'
#!/bin/sh
# flippy 打包会把 system.zram_size_mb 置 0，恢复为 256MB
if uci -q get system.@system[0] >/dev/null 2>&1; then
	uci -q set system.@system[0].zram_size_mb='256'
	uci -q commit system
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-zram-size

cat > files/etc/uci-defaults/99-firewall-flow-offload <<'EOF'
#!/bin/sh
# 硬件卸载保持关闭
[ -f /etc/config/firewall ] || exit 0
if uci -q get firewall.@defaults[0] >/dev/null 2>&1; then
	uci -q set firewall.@defaults[0].flow_offloading='1'
	uci -q set firewall.@defaults[0].flow_offloading_hw='0'
	uci -q commit firewall
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-firewall-flow-offload

cat > files/etc/uci-defaults/99-firewall-include-cleanup <<'EOF'
#!/bin/sh
# /var、/tmp 运行期路径开机时不存在，保留
[ -f /etc/config/firewall ] || exit 0

i=0
while uci -q get firewall.@include[$i] >/dev/null 2>&1; do
	path=$(uci -q get firewall.@include[$i].path)
	case "$path" in
		""|/var/*|/tmp/*)
			i=$((i + 1))
			;;
		*)
			if [ -f "$path" ]; then
				i=$((i + 1))
			else
				uci -q delete firewall.@include[$i]
			fi
			;;
	esac
done
uci -q commit firewall
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-firewall-include-cleanup

cat > files/etc/uci-defaults/99-dnsmasq-tuning <<'EOF'
#!/bin/sh
# dnsmasq 结构参数：监听端口让给 oxidns（:53），本地名称层退居 1745
if [ -f /etc/config/dhcp ] && uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
	uci -q set dhcp.@dnsmasq[0].port='1745'
	uci -q set dhcp.@dnsmasq[0].cachesize='0'
	uci -q set dhcp.@dnsmasq[0].use_stale_cache='3600'
	uci -q set dhcp.@dnsmasq[0].nonegcache='1'
	uci -q set dhcp.@dnsmasq[0].rebind_protection='0'
	uci -q set dhcp.@dnsmasq[0].ednspacket_max='1232'
	uci -q set dhcp.@dnsmasq[0].dns_redirect='0'
	uci -q commit dhcp
fi

# 旁路由不提供 DHCP 服务，避免与主路由抢租约
if [ -f /etc/config/dhcp ] && uci -q get dhcp.lan >/dev/null 2>&1; then
	uci -q set dhcp.lan.ignore='1'
	uci -q set dhcp.lan.dynamicdhcp='0'
	uci -q set dhcp.lan.dhcpv4='disabled'
	uci -q commit dhcp
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-dnsmasq-tuning

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

# 版本跟随固件
if grep -q '/video/packages.adb' "$list" && ! grep -qxF "$new" "$list"; then
	sed -i "s|.*video/packages\.adb.*|$new|" "$list"
fi

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-distfeeds-video

cat > files/etc/uci-defaults/99-mitigations-off <<'EOF'
#!/bin/sh
# 写入 boot 分区 uEnv.txt
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
# apk 无 hold 命令：改写 world 为 名字=版本 固定内置版本
world=/etc/apk/world
db=/lib/apk/db/installed
[ -f "$world" ] && [ -f "$db" ] || exit 0

pkgver() {
	awk -v p="$1" '
		/^P:/ { n = substr($0, 3) }
		/^V:/ { if (n == p) { print substr($0, 3); exit } }
	' "$db"
}

for pkg in dnsmasq-full firewall4 luci-app-firewall; do
	grep -qx "$pkg" "$world" || continue
	ver="$(pkgver "$pkg")"
	case "$ver" in ''|*[!A-Za-z0-9.+_~-]*) continue ;; esac
	sed -i "s|^$pkg$|$pkg=$ver|" "$world"
done

exit 0
EOF

chmod 755 files/etc/uci-defaults/99-hold-core-packages

cat > files/etc/uci-defaults/99-system-ntp <<'EOF'
#!/bin/sh
# 国内源，不用 DHCP 广播 NTP
uci -q set system.ntp.use_dhcp='0'
for s in ntp.ntsc.ac.cn cn.ntp.org.cn ntp.aliyun.com ntp.tencent.com time.cloudflare.com; do
	uci -q del_list system.ntp.server="$s"
	uci -q add_list system.ntp.server="$s"
done
uci -q commit system
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-system-ntp

cat > files/etc/uci-defaults/99-openssh-sshd-user <<'EOF'
#!/bin/sh
# privilege separation 用户兜底
grep -q '^sshd:' /etc/passwd || echo 'sshd:x:22:22:sshd:/var/run/sshd:/bin/false' >> /etc/passwd
grep -q '^sshd:' /etc/group  || echo 'sshd:x:22:' >> /etc/group
grep -q '^sshd:' /etc/shadow || echo 'sshd:x:0:0:99999:7:::' >> /etc/shadow
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-openssh-sshd-user

# busybox 适配版：去掉 dircolors 与 /etc/bashrc 引用
mkdir -p files/root
cat > files/root/.bashrc <<'EOF'
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

alias ls='ls --color=auto'
alias ll='ls -l --color=auto'
EOF

cat > files/root/.bash_profile <<'EOF'
[ -f ~/.bashrc ] && . ~/.bashrc
EOF

cat > files/etc/uci-defaults/99-root-shell-bash <<'EOF'
#!/bin/sh
if [ -x /bin/bash ] && ! grep -q '^root:.*:/bin/bash$' /etc/passwd; then
	sed -i 's|^\(root:.*:\)[^:]*$|\1/bin/bash|' /etc/passwd
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-root-shell-bash

cat > files/etc/hotplug.d/net/01-maximize_nic_rx_tx_buffers <<'EOF'
#!/bin/sh
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
# 7/9 应用包内补丁
# ---------------------------------------------------------------------------
luci_coll="feeds/luci/collections/luci/Makefile"
if [ -f "$luci_coll" ]; then
    sed -i '/luci-app-attendedsysupgrade/d' "$luci_coll"
fi
log "补丁应用完成"

# ---------------------------------------------------------------------------
# 8/9 重建 feed 索引
# ---------------------------------------------------------------------------
log "重建 feed 索引 ..."
./scripts/feeds update -i
log "feed 索引重建完成"

# ---------------------------------------------------------------------------
# 9/9 清理
# ---------------------------------------------------------------------------
rm -rf clone
log "diy.sh 执行完成"
