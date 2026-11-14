#!/bin/bash
#
# N1（斐讯 N1 / s905d）编译前准备
# 调用位置：workflow 的 "Prepare & Install feeds" 步骤；工作目录：openwrt 源码根目录
# 版本号：环境变量 FW_VERSION（手动输入优先，未输入时由 workflow 自动取上游 25.12 系列最新稳定 tag，取不到则回退 25.12）
#

set -euo pipefail

log() { printf '[diy] %s\n' "$*"; }

# 克隆第三方仓库，失败重试 3 次；第 4 参为稀疏检出目录列表（空格分隔，用于包多的大仓库）
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

# easytier 回退自洽组合：包内默认版本与写死资产 hash 必须成对，§4.2 改造与 §4.3 回退共用此单一来源；
# 上游新 tag 的资产缺失/校验失败时整体回退到该组合编译，不做无校验下载
EASYTIER_FALLBACK_VER="2.7.0"
EASYTIER_FALLBACK_HASH="8abc5d850ad140cd071475a2dd2b4b135f7e0e8b7271897f01fc08a5c0a9c1b0"

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
# vlmcsd 官方 feed 版本停更于 2020（Wind4 死源），由 OneNAS 版替代
for pkg in mosdns xray-core sing-box v2ray-geodata tcping geoview chinadns-ng vlmcsd; do
    rm -rf "feeds/packages/net/${pkg}"
done

# LuCI 在线用户数只统计 br-lan，N1 的 LAN 是 eth0，导致统计恒为 0
luci_online="feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
if [ -f "$luci_online" ]; then
    if grep -q 'br-lan)' "$luci_online"; then
        sed -i 's#br-lan)#br-lan|eth0|lan[0-9]*)#' "$luci_online"
        log "在线用户数统计已兼容 eth0/lan"
    fi
else
    log "WARN: 未找到 LuCI getOnlineUsers，跳过在线用户数修复"
fi

# process_list() 旧实现 popen 读 busybox top 有竞态且 VSZ 缩写丢进程，改为 /proc 直读
luci_sys="feeds/luci/modules/luci-base/ucode/sys.uc"
if [ -f "$luci_sys" ] && grep -q '^export function process_list() {' "$luci_sys"; then
    python3 - "$luci_sys" <<'PY'
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

	/* 第一次采样：各进程 CPU ticks 与系统总 ticks */
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

	/* 第二次采样：组装进程表 */
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
    log "process_list 已替换为 /proc 直读实现"
else
    log "WARN: 未找到 LuCI sys.uc 的 process_list，跳过替换"
fi

# 进程页 RPC 加 reject: true：调用失败弹错误提示，不再被 expect 默认值吞成空列表
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
clone_bg https://github.com/sbwml/luci-app-mosdns clone/mosdns ""
clone_bg https://github.com/sbwml/luci-app-openlist2 clone/openlist2 ""
clone_bg https://github.com/linkease/ddnstox-openwrt-package clone/ddnstox ""
clone_bg https://github.com/nikkinikki-org/OpenWrt-nikki clone/nikki ""
clone_bg https://github.com/sbwml/autocore-arm clone/autocore openwrt-25.12
clone_bg https://github.com/ophub/luci-app-amlogic clone/amlogic ""
clone_bg https://github.com/jerrykuku/luci-theme-argon clone/argon ""
clone_bg https://github.com/w9315273/luci-app-adguardhome clone/aghluci ""
# bandix 动态克隆上游最新 tag（含 -rN 包修订后缀）；核心二进制资产随版本发布在 timsaya/bandix，
# tag 与资产可能短暂不同步——aarch64 资产可下载才采用该 tag，失败回退已知自洽 tag v0.12.12
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
clone_bg https://github.com/EasyTier/luci-app-easytier clone/easytier ""
clone_bg https://github.com/OneNAS-space/vlmcsd clone/vlmcsd ""
clone_bg https://github.com/OneNAS-space/luci-app-vlmcsd clone/vlmcsdluci ""
clone_bg https://github.com/sbwml/luci-app-airconnect clone/airconnect ""
clone_bg https://github.com/sbwml/package_libs_ngtcp2 clone/ngtcp2 ""
clone_bg https://github.com/sbwml/package_libs_nghttp3 clone/nghttp3 ""
wait_clones
log "仓库克隆完成（${#CLONE_PIDS[@]} 个）"

# ---- 4.2 落盘与目录特例 -----------------------------------------------------
# golang 工具链最先落盘 -> feeds：后续 Go 组件（mosdns/openlist2/ddnstox 等）编译时依赖最新工具链
install_pkg clone/golang feeds/packages/lang/golang

# passwall 组件
install_pkg clone/passwall_packages package/passwall_packages
install_pkg clone/passwall2 package/passwall2
rm -rf package/passwall_packages/chinadns-ng
# chinadns-ng 非必需：passwall2 没有它时会回退到 dnsmasq
sed -i '/^[[:space:]]*select PACKAGE_chinadns-ng$/d' package/passwall2/luci-app-passwall2/Makefile

# mosdns
install_pkg clone/mosdns package/mosdns

# openlist2（网盘挂载）
install_pkg clone/openlist2 package/openlist2

# ddnstox（内网穿透）
install_pkg clone/ddnstox package/ddnstox

# nikki（mihomo 使用稳定版 mihomo-meta，不引入 alpha）
install_pkg clone/nikki/nikki package/nikki
install_pkg clone/nikki/luci-app-nikki package/luci-app-nikki
install_pkg clone/nikki/mihomo-meta package/mihomo-meta

# autocore（CPU 信息展示）
mkdir -p feeds/packages/utils
install_pkg clone/autocore feeds/packages/utils/autocore

# luci-app-amlogic（晶晨宝盒）
install_pkg clone/amlogic/luci-app-amlogic feeds/luci/applications/luci-app-amlogic

# argon 3.0 已内置设置，不再引入旧版 argon-config（与主题包文件冲突）
rm -rf feeds/luci/applications/luci-app-argon-config
install_pkg clone/argon feeds/luci/themes/luci-theme-argon

# luci-app-adguardhome-tk：路径对齐实机（核心 /usr/bin/AdGuardHome，配置/数据 /etc/adguardhome）
install_pkg clone/aghluci package/luci-app-adguardhome-tk
agh_tk_uci="package/luci-app-adguardhome-tk/root/etc/config/AdGuardHome"
sed -i "s|option binpath '/usr/bin/AdGuardHome/AdGuardHome'|option binpath '/usr/bin/AdGuardHome'|" "$agh_tk_uci"
sed -i "s|option configpath '/etc/AdGuardHome.yaml'|option configpath '/etc/adguardhome/adguardhome.yaml'|" "$agh_tk_uci"
sed -i "s|option workdir '/tmp/AdGuardHome'|option workdir '/etc/adguardhome'|" "$agh_tk_uci"
if grep -q "option binpath '/usr/bin/AdGuardHome'$" "$agh_tk_uci" \
    && grep -q "option configpath '/etc/adguardhome/adguardhome.yaml'" "$agh_tk_uci" \
    && grep -q "option workdir '/etc/adguardhome'" "$agh_tk_uci"; then
    log "adguardhome-tk 路径已对齐：核心 /usr/bin/AdGuardHome，配置与数据 /etc/adguardhome"
else
    log "ERROR: adguardhome-tk UCI 路径改造失败，请检查上游 config 文件格式"
    exit 1
fi
# keep.d 只保留配置文件：核心随固件升级更新，防止保留配置升级时旧二进制覆盖新编译版
agh_tk_init="package/luci-app-adguardhome-tk/root/etc/init.d/AdGuardHome"
if [ -f "$agh_tk_init" ] && grep -qF '"$binpath" "$configpath"' "$agh_tk_init"; then
    sed -i 's|"\$binpath" "\$configpath"|"\$configpath"|' "$agh_tk_init"
fi
# init 的 config_get 兜底默认值也是目录式布局，UCI 缺失/丢失时会在设备上建出 /usr/bin/AdGuardHome 目录
sed -i 's|binpath "/usr/bin/AdGuardHome/AdGuardHome"|binpath "/usr/bin/AdGuardHome"|g' "$agh_tk_init"
sed -i 's|workdir "/usr/bin/AdGuardHome"|workdir "/etc/adguardhome"|g' "$agh_tk_init"
if grep -Eq 'binpath "/usr/bin/AdGuardHome/AdGuardHome"|workdir "/usr/bin/AdGuardHome"' "$agh_tk_init"; then
    log "ERROR: adguardhome-tk init 兜底默认值对齐失败，仍存在目录式路径"
    exit 1
fi
log "adguardhome-tk init 兜底默认值已对齐文件式布局"

# bandix（eBPF 流量监控）+ LuCI 前端；两个仓库的 Makefile 在 <仓库>/<同名子目录>/ 下
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
# luci.mk 的 findrev 在无 .git 的拷贝目录回退 0，i18n 包版本会变成 0-r<N>
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

# easytier 主程序（预编译 aarch64 二进制）+ Lua 版 LuCI 前端
install_pkg clone/easytier/easytier package/easytier
install_pkg clone/easytier/luci-app-easytier package/luci-app-easytier

# 上游 Makefile 用裸 wget 下载二进制，改造为标准 PKG_SOURCE/PKG_HASH（make download 阶段缓存 + sha256 校验）；
# 架构必须字面写 aarch64：上游的 APP_ARCH 由包内 ifeq $(ARCH) 定义，仅编译期子 make 生效，download/metadata 阶段展开为空（曾致 CI 下载 easytier-linux--v2.7.0.zip 404）；
# PKG_HASH 为回退自洽组合的资产值，正常构建会被 §4.3 按当前 tag 覆盖
easytier_mk="package/easytier/Makefile"
if [ -f "$easytier_mk" ]; then
    EASYTIER_FALLBACK_HASH="$EASYTIER_FALLBACK_HASH" python3 - "$easytier_mk" <<'PY'
import os
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

pkg_hash = os.environ["EASYTIER_FALLBACK_HASH"]
src_lines = [
    "PKG_SOURCE:=easytier-linux-aarch64-v$(PKG_VERSION).zip",
    "PKG_SOURCE_URL:=https://github.com/EasyTier/EasyTier/releases/download/v$(PKG_VERSION)/",
    "PKG_HASH:=" + pkg_hash,
]
new_prepare = (
    "define Build/Prepare\n"
    "\tmkdir -p $(PKG_BUILD_DIR)\n"
    "\tunzip -o -j $(DL_DIR)/$(PKG_SOURCE) -d $(PKG_BUILD_DIR)\n"
    "endef"
)

if "PKG_SOURCE_URL" not in text:
    out = []
    for line in text.split("\n"):
        out.append(line)
        if line.startswith("PKG_VERSION:="):
            out.extend(src_lines)
    text = "\n".join(out)

if "wget" in text:
    start = text.index("define Build/Prepare")
    end = text.index("endef", start) + len("endef")
    text = text[:start] + new_prepare + text[end:]

open(path, "w", encoding="utf-8").write(text)
PY
    if grep -q 'PKG_SOURCE_URL' "$easytier_mk" && grep -q '^PKG_HASH:=' "$easytier_mk" \
        && ! grep -q 'wget' "$easytier_mk"; then
        log "easytier 二进制下载已改造为标准 PKG_SOURCE/PKG_HASH"
    else
        log "WARN: easytier Makefile 下载改造未完全生效，请人工核对"
    fi
fi

# vlmcsd（KMS 激活）+ LuCI 前端
install_pkg clone/vlmcsd package/vlmcsd
install_pkg clone/vlmcsdluci package/luci-app-vlmcsd

# airconnect（AirPlay 音频桥接）：仓库内包目录与包名同名
install_pkg clone/airconnect/airconnect package/airconnect
install_pkg clone/airconnect/luci-app-airconnect package/luci-app-airconnect

# ngtcp2 / nghttp3（curl HTTP3 的 QUIC 栈）：官方 feed 版本旧，必须成对替换（ngtcp2 依赖新版 libnghttp3）
install_pkg clone/ngtcp2 feeds/packages/libs/ngtcp2
install_pkg clone/nghttp3 feeds/packages/libs/nghttp3

# ophub 的 remake 打包时从官方仓库实时下载插件脚本覆盖 /usr/sbin，构建期对 feeds 层的补丁不生效；
# 升级后的自愈由 99-adguardhome-paths 在首启完成（见 §6），此处不再打 ophub 脚本补丁

log "组件落盘完成（golang / passwall×2 / mosdns / openlist2 / ddnstox / nikki / autocore / amlogic / argon / adguardhome-tk / bandix / easytier / vlmcsd / airconnect / ngtcp2+nghttp3）"

# ---- 4.3 统一确定外部组件版本 ----------------------------------------------
log "确定外部组件版本 ..."

# §4.3 各组件的上游解析相互独立，后台并行执行以重叠网络 IO；
# xray/mihomo 无回退源，任务失败中止编译；agh 获取失败回退 feed 自带版本（仅 feeds 包结构缺失才中止）；
# 其余失败保留仓库自带版本（各任务函数内已打 WARN）
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
                xray|mihomo|agh) log "ERROR: ${name} 组件版本更新失败，中止编译"; exit 1 ;;
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

# mihomo：最新稳定版，排除 alpha / rc（nikki 使用；git 源 + mirror skip）
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

# openlist2：主程序走标准更新，前端发布资产在 Download 段单独写入（取不到时保留仓库自带版本）
stage3_openlist() {
    local openlist_front_ver frontend_tag frontend_hash
    if update_pkg_version "openlist2" \
        https://github.com/OpenListTeam/OpenList.git 'v*' '^v[0-9]+(\.[0-9]+)+$' \
        package/openlist2/openlist2/Makefile \
        'https://codeload.github.com/OpenListTeam/OpenList/tar.gz/v%s?' 0; then
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
        log "openlist2 前端 -> ${openlist_front_ver:-保持原版本}"
    fi
    return 0
}
stage3_bg openlist stage3_openlist

# sing-box：最新正式 tag（passwall_packages 使用）
stage3_singbox() {
    update_pkg_version "sing-box" \
        https://github.com/SagerNet/sing-box.git 'v*' '^v[0-9]+(\.[0-9]+)+$' \
        package/passwall_packages/sing-box/Makefile \
        'https://codeload.github.com/SagerNet/sing-box/tar.gz/v%s?' 0
}
stage3_bg sing-box stage3_singbox

# geoview（geo 数据查询工具）
stage3_geoview() {
    update_pkg_version "geoview" \
        https://github.com/snowie2000/geoview.git '*' '^[0-9]+(\.[0-9]+)+$' \
        package/passwall_packages/geoview/Makefile \
        'https://codeload.github.com/snowie2000/geoview/tar.gz/%s?' 0
}
stage3_bg geoview stage3_geoview

# AdGuardHome：最新正式 tag，重试 3 次；耗尽后回退 feed 自带版本，不阻断编译
stage3_agh() {
    local agh_makefile="feeds/packages/net/adguardhome/Makefile"
    local agh_ok="" i agh_tag agh_ver agh_hash agh_front_hash
    [ -f "$agh_makefile" ] || { log "ERROR: 找不到 feeds adguardhome 包"; return 1; }
    for i in 1 2 3; do
        agh_tag="$(github_latest_tag https://github.com/AdguardTeam/AdGuardHome.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
        [ -n "$agh_tag" ] || { log "WARN: 第 ${i}/3 次获取 AdGuardHome 版本失败"; sleep 3; continue; }
        agh_ver="${agh_tag#v}"
        agh_hash="$(fetch_sha256 "https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/v${agh_ver}?" || true)"
        [ -n "$agh_hash" ] || { log "WARN: 第 ${i}/3 次下载 AdGuardHome 源码校验失败"; sleep 3; continue; }
        agh_front_hash="$(fetch_sha256 "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${agh_ver}/AdGuardHome_frontend.tar.gz" || true)"
        [ -n "$agh_front_hash" ] || { log "WARN: 第 ${i}/3 次下载 AdGuardHome 前端校验失败"; sleep 3; continue; }
        agh_ok=1
        break
    done
    if [ -n "$agh_ok" ]; then
        sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${agh_ver}|" "$agh_makefile"
        sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${agh_hash}|" "$agh_makefile"
        sed -i "s|^FRONTEND_HASH:=.*$|FRONTEND_HASH:=${agh_front_hash}|" "$agh_makefile"
        log "adguardhome -> ${agh_ver}"
        if [ -n "${GITHUB_ENV:-}" ]; then
            echo "AGH_VERSION=${agh_ver}" >> "$GITHUB_ENV"
        fi
    else
        log "WARN: AdGuardHome 重试 3 次均失败，回退 feed 自带版本编译"
    fi
    # feeds adguardhome 包只保留编译产物（/usr/bin/AdGuardHome），服务交给 luci-app-adguardhome-tk，避免双 init；
    # 与版本写入同一文件，必须留在同一任务内串行执行（主脚本并发 sed 会竞态覆盖）
    sed -i '\|./files/adguardhome.conf|d; \|./files/adguardhome.init|d; \|./files/adguardhome.defaults|d' "$agh_makefile"
    if grep -q "adguardhome.init" "$agh_makefile"; then
        log "WARN: feeds adguardhome init 清理未生效，固件可能存在双 init 脚本"
    else
        log "feeds adguardhome 已精简为纯二进制包（服务由 luci-app-adguardhome-tk 接管）"
    fi
}
stage3_bg agh stage3_agh

# v2ray-geodata：passwall 包 + Loyalsoldier 最新数据
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

# ddnstox 预编译二进制
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

# easytier：预编译二进制，版本号同时写死在两个 Makefile 与 init.d 兜底值里，三处必须同步；
# 版本与 hash 永远成对：新 tag 的资产获取失败时整体回退到 EASYTIER_FALLBACK 自洽组合，不做无校验下载
stage3_easytier() {
    local easytier_tag easytier_ver easytier_hash easytier_try easytier_try_hash mk easytier_init easytier_init_tag
    easytier_ver="${EASYTIER_FALLBACK_VER}"
    easytier_hash="${EASYTIER_FALLBACK_HASH}"
    easytier_tag="$(github_latest_tag https://github.com/EasyTier/EasyTier.git 'v*' '^v[0-9]+(\.[0-9]+)+$' || true)"
    if [ -n "$easytier_tag" ]; then
        easytier_try="${easytier_tag#v}"
        easytier_try_hash="$(fetch_sha256 "https://github.com/EasyTier/EasyTier/releases/download/v${easytier_try}/easytier-linux-aarch64-v${easytier_try}.zip" || true)"
        if [ -n "$easytier_try_hash" ]; then
            easytier_ver="${easytier_try}"
            easytier_hash="${easytier_try_hash}"
        else
            log "WARN: easytier ${easytier_tag} 资产获取失败，回退自洽版本 ${EASYTIER_FALLBACK_VER}"
        fi
    else
        log "WARN: 无法获取 easytier 版本，使用包内默认版本"
    fi
    for mk in package/easytier/Makefile package/luci-app-easytier/Makefile; do
        if [ -f "$mk" ]; then
            sed -i "s|^PKG_VERSION:=.*$|PKG_VERSION:=${easytier_ver}|" "$mk"
        fi
    done
    easytier_init="package/luci-app-easytier/root/etc/init.d/easytier"
    easytier_init_tag="v${easytier_ver}"
    if [ -f "$easytier_init" ]; then
        sed -i "s|tag=\"v[0-9.]*\"|tag=\"${easytier_init_tag}\"|" "$easytier_init"
    fi
    sed -i "s|^PKG_HASH:=.*$|PKG_HASH:=${easytier_hash}|" package/easytier/Makefile
    if grep -qx "PKG_VERSION:=${easytier_ver}" package/easytier/Makefile \
        && grep -qx "PKG_VERSION:=${easytier_ver}" package/luci-app-easytier/Makefile; then
        log "easytier -> ${easytier_ver}"
    else
        log "WARN: easytier 版本写入未全部生效，请人工核对两个 Makefile"
    fi
}
stage3_bg easytier stage3_easytier

# tcping：跟随 git HEAD
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
# 复制自 git 子目录的包无 .git，luci.mk findrev 回退 0，显式写入 PKG_PO_VERSION 兜底
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
fix_luci_po_version package/mosdns/luci-app-mosdns/Makefile
fix_luci_po_version package/openlist2/luci-app-openlist2/Makefile
fix_luci_po_version package/ddnstox/luci-app-ddnstox/Makefile
fix_luci_po_version package/passwall2/luci-app-passwall2/Makefile
fix_luci_po_version feeds/luci/applications/luci-app-amlogic/Makefile
fix_luci_po_version package/luci-app-airconnect/Makefile

# OneNAS 的 luci-app-vlmcsd 没有 PKG_VERSION 行，无 .git 拷贝目录下 i18n 包版本会回退为 0
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
fi

# ksmbd 菜单与原 samba4 一致放到 NAS 目录
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

# easytier 是 Lua 版 LuCI，菜单在 controller 里写死 admin/vpn，改到 network 并删掉自建的 VPN 顶级分类
easytier_ctrl="package/luci-app-easytier/luasrc/controller/easytier.lua"
if [ -f "$easytier_ctrl" ]; then
    sed -i 's|"admin", "vpn", "easytier"|"admin", "network", "easytier"|g' "$easytier_ctrl"
    sed -i '/entry({"admin", "vpn"}, firstchild(), "VPN", 45)/d' "$easytier_ctrl"
    if grep -q '"admin", "network", "easytier"' "$easytier_ctrl" \
        && ! grep -q 'entry({"admin", "vpn"}, firstchild()' "$easytier_ctrl"; then
        log "easytier 菜单已移至 network 目录"
    else
        log "WARN: easytier 菜单调整未完全生效，请人工核对 controller"
    fi
else
    log "WARN: 未找到 package/luci-app-easytier controller，跳过菜单调整"
fi
log "LuCI 菜单分类调整完成"

# ---------------------------------------------------------------------------
# 6/9 写入运行时优化文件
# ---------------------------------------------------------------------------
log "写入运行时优化文件"
mkdir -p files/etc/sysctl.d files/etc/uci-defaults files/etc/hotplug.d/net files/etc/apk/keys

# nikki / passwall 第三方 apk 源公钥（首次开机由 uci-defaults 追加仓库）
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
# flippy 打包会把 system.zram_size_mb 置 0，S15zram 随即建立 0 字节设备失败（swap 恒为 0）
# 恢复为 256MB：zram 空闲时几乎不占内存，仅在内存压力时作交换兜底
if uci -q get system.@system[0] >/dev/null 2>&1; then
	uci -q set system.@system[0].zram_size_mb='256'
	uci -q commit system
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-zram-size

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


cat > files/etc/uci-defaults/99-adguardhome-paths <<'EOF'
#!/bin/sh
# ophub 的 remake 打包会从官方仓库下载原版插件脚本覆盖 /usr/sbin，升级过程也会刷新它们；
# 每次升级后的首启在此重新自愈，否则下次升级：AGH 核心被符号链接顶成数据分区目录、
# 自定义数据不随备份保留
[ -L /usr/bin/AdGuardHome ] && rm -f /usr/bin/AdGuardHome
[ -f /usr/bin/AdGuardHome ] || cp -f /mnt/mmcblk2p4/AdGuardHome/AdGuardHome /usr/bin/AdGuardHome 2>/dev/null

UPD=/usr/sbin/openwrt-update-amlogic
BKP=/usr/sbin/openwrt-backup
if [ -f "$UPD" ] && grep -q 'ln -sf /mnt/${EMMC_NAME}${PARTITION_NAME}4/AdGuardHome' "$UPD"; then
    sed -i '/^if \[ -f \/mnt\/${NEW_ROOT_NAME}\/etc\/config\/AdGuardHome \]; then$/,/^fi$/d' "$UPD"
fi
uci -q get AdGuardHome.AdGuardHome >/dev/null || exit 0
uci -q set AdGuardHome.AdGuardHome.binpath='/usr/bin/AdGuardHome'
uci -q set AdGuardHome.AdGuardHome.workdir='/etc/adguardhome'
uci -q set AdGuardHome.AdGuardHome.configpath='/etc/adguardhome/adguardhome.yaml'
uci -q commit AdGuardHome
if [ -f "$BKP" ] && ! grep -q '\./etc/adguardhome/' "$BKP"; then
    sed -i 's|\./etc/AdGuardHome\.yaml \\|&\n./etc/adguardhome/ \\\n./etc/mosdns/rule/ \\\n./usr/share/nlbwmon/ \\|' "$BKP"
fi
# bandix 的数据/限速配置在 /usr/share/bandix，同样要随 ophub 升级保留
if [ -f "$BKP" ] && ! grep -q '\./usr/share/bandix/' "$BKP"; then
    if grep -q '\./usr/share/nlbwmon/ \\' "$BKP"; then
        sed -i 's|\./usr/share/nlbwmon/ \\|&\n./usr/share/bandix/ \\|' "$BKP"
    else
        sed -i 's|\./etc/AdGuardHome\.yaml \\|&\n./usr/share/bandix/ \\|' "$BKP"
    fi
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-adguardhome-paths

cat > files/etc/uci-defaults/99-mosdns-tuning <<'EOF'
#!/bin/sh
# 与实机配置一致：AdGuardHome 占 53，mosdns 5335 为其上游，dnsmasq 监听 1745
# 不固化：自定义规则列表、DNS 服务器等隐私项
[ -f /etc/config/mosdns ] || exit 0

uci -q set mosdns.config.enabled='1'
uci -q set mosdns.config.listen_port='5335'
uci -q set mosdns.config.redirect='0'
uci -q set mosdns.config.listen_address='127.0.0.1'
uci -q set mosdns.config.configfile='/var/etc/mosdns.json'
uci -q set mosdns.config.log_level='error'
uci -q set mosdns.config.log_file='/var/log/mosdns.log'
uci -q set mosdns.config.log_size='5'
uci -q set mosdns.config.concurrent='2'
uci -q set mosdns.config.idle_timeout='30'
uci -q set mosdns.config.enable_pipeline='1'
uci -q set mosdns.config.insecure_skip_verify='0'
uci -q set mosdns.config.prefer_ipv4='1'
uci -q set mosdns.config.dns_leak='1'
uci -q set mosdns.config.enable_ecs_remote='1'
uci -q set mosdns.config.stats_collector='0'
uci -q set mosdns.config.apple_optimization='1'
uci -q set mosdns.config.reject_type65='1'
uci -q set mosdns.config.cache='0'
uci -q set mosdns.config.minimal_ttl='0'
uci -q set mosdns.config.maximum_ttl='0'
uci -q set mosdns.config.geo_auto_update='0'
uci -q set mosdns.config.geo_update_week_time='*'
uci -q set mosdns.config.geo_update_day_time='2'
uci -q set mosdns.config.geoip_type='geoip-only-cn-private'
uci -q set mosdns.config.listen_port_api='9091'
uci -q set mosdns.config.cloudflare='0'
uci -q set mosdns.config.bootstrap_dns='223.5.5.5'
uci -q commit mosdns

# dnsmasq 结构参数：监听端口让给 AdGuardHome，缓存交给上游 AdGuardHome/mosdns
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
# apk 无 hold 命令：改写 world 为 名字=版本 固定内置版本（mosdns 有意不固定）
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
# NTP 与实机一致：国内源 + cloudflare，不使用 DHCP 广播发现的 NTP
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
# openssh privilege separation 用户兜底（包正常安装时已存在，幂等）
grep -q '^sshd:' /etc/passwd || echo 'sshd:x:22:22:sshd:/var/run/sshd:/bin/false' >> /etc/passwd
grep -q '^sshd:' /etc/group  || echo 'sshd:x:22:' >> /etc/group
grep -q '^sshd:' /etc/shadow || echo 'sshd:x:0:0:99999:7:::' >> /etc/shadow
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-openssh-sshd-user

# root shell 别名与彩色 ls（sbwml/r4s_build_script 的 .bashrc，busybox 适配版：
# 去掉 dircolors 与 /etc/bashrc 引用，busybox 环境不存在这两者）
mkdir -p files/root
cat > files/root/.bashrc <<'EOF'
# root shell aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# 彩色 ls（busybox ls 原生支持 --color）
alias ls='ls --color=auto'
alias ll='ls -l --color=auto'
EOF

cat > files/root/.bash_profile <<'EOF'
# bash 登录时加载 .bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
EOF

cat > files/etc/uci-defaults/99-root-shell-bash <<'EOF'
#!/bin/sh
# root 登录 shell 固定为 /bin/bash（bash 包已随固件安装）
if [ -x /bin/bash ] && ! grep -q '^root:.*:/bin/bash$' /etc/passwd; then
	sed -i 's|^\(root:.*:\)[^:]*$|\1/bin/bash|' /etc/passwd
fi
exit 0
EOF

chmod 755 files/etc/uci-defaults/99-root-shell-bash

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
