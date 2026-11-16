#!/bin/sh
# refresh-ll.sh —— ND 邻居表自动校正设备 IPv6 LL: 补录观测到的真实 LL(一机多地址
# 不翻转) + 证伪删除从未被 ND/查询日志使用的 EUI-64 推算记录; 仅确有变化才 commit+reload
# 数据来自 dhcp host 节 + ND 表, 无需配置文件
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# 单实例保护; AGH_LOCK_HELD=1 表示由 restore-static-leases.sh 调用(其已持锁), 跳过防死锁
if command -v flock >/dev/null 2>&1 && [ "${AGH_LOCK_HELD:-0}" != "1" ]; then
	exec 9>/var/lock/agh-naming.lock
	flock 9
fi
LOG=/var/log/refresh-ll.log
Q=/etc/adguardhome/data/querylog.json
CHANGED=0
MAP=/tmp/llmap.$$.txt
DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
DEV=${DEV:-eth0}
: > "$MAP"

for d in $(uci show dhcp | grep '=domain$' | cut -d. -f2 | cut -d= -f1); do
	_n=$(uci -q get dhcp.$d.name); _i=$(uci -q get dhcp.$d.ip | tr 'A-F' 'a-f')
	[ -n "$_n" ] && [ -n "$_i" ] && echo "$_n|$_i" >> "$MAP"
done

eui64() {  # $1=mac -> 输出 EUI-64 LL
	m1=${1:0:2}; m2=${1:3:2}; m3=${1:6:2}; m4=${1:9:2}; m5=${1:12:2}; m6=${1:15:2}
	f1=$(printf '%02x' $(( 0x$m1 ^ 0x02 )))
	echo "fe80::${f1}${m2}:${m3}ff:fe${m4}:${m5}${m6}"
}

# /etc/hosts 映射块存在性: 缺失时 LL 仅写 UCI(dnsmasq domain 兜底), hosts 层待 restore 重建
if grep -qE 'AGH-DEVICE-MAP[- ]END' /etc/hosts; then
	HOSTS_OK=1
else
	HOSTS_OK=0
	echo "$(date '+%F %T')  /etc/hosts 无设备映射块, LL 仅写 UCI (先跑 restore-static-leases.sh)" >> "$LOG"
fi

# 1) 补录观测到的 LL
for s in $(uci show dhcp | grep '=host$' | cut -d. -f2 | cut -d= -f1); do
	nm=$(uci -q get dhcp.$s.name); mac=$(uci -q get dhcp.$s.mac | awk '{print tolower($1)}')
	[ -z "$nm" ] && continue; [ -z "$mac" ] && continue
	for obs in $(ip -6 neigh show dev "$DEV" 2>/dev/null | grep -i "$mac" | grep -v FAILED | awk '{print tolower($1)}' | sort -u); do
		grep -qixF "$nm|$obs" "$MAP" && continue
		uci -q add dhcp domain >/dev/null
		uci set dhcp.@domain[-1].name="$nm"
		uci set dhcp.@domain[-1].ip="$obs"
		echo "$nm|$obs" >> "$MAP"
		[ "$HOSTS_OK" = 1 ] && sed -i "/AGH-DEVICE-MAP[- ]END/i $obs $nm.ll.lan" /etc/hosts
		echo "$(date '+%F %T')  $nm: 新增 $obs" >> "$LOG"
		CHANGED=1
	done
done

# 2) 删除被证伪的 EUI-64 记录
for s in $(uci show dhcp | grep '=host$' | cut -d. -f2 | cut -d= -f1); do
	nm=$(uci -q get dhcp.$s.name); mac=$(uci -q get dhcp.$s.mac | awk '{print tolower($1)}')
	[ -z "$nm" ] && continue; [ -z "$mac" ] && continue
	eui=$(eui64 "$mac")
	obslist=$(ip -6 neigh show dev "$DEV" 2>/dev/null | grep -i "$mac" | grep -v FAILED | awk '{print tolower($1)}' | sort -u)
	[ -z "$obslist" ] && continue                        # 当前无观测 → 不动
	echo "$obslist" | grep -qx "$eui" && continue        # ND中出现过 → 它是真的
	grep -qixF "$nm|$eui" "$MAP" || continue             # 没有这条记录 → 跳过
	grep -qi "$eui" "$Q" 2>/dev/null && continue         # 曾被实际使用 → 保留

	# 删除 UCI 记录(按索引降序, 避免位移)
	IDX=""
	for d in $(uci show dhcp | grep '=domain$' | cut -d. -f2 | cut -d= -f1); do
		_dn=$(uci -q get dhcp.$d.name); _di=$(uci -q get dhcp.$d.ip | tr 'A-F' 'a-f')
		if [ "$_dn" = "$nm" ] && [ "$_di" = "$eui" ]; then
			IDX="$IDX $(echo "$d" | sed 's/.*\[\([0-9]*\)\]/\1/')"
		fi
	done
	for i in $(echo $IDX | tr ' ' '\n' | sort -rn); do
		uci -q delete "dhcp.@domain[$i]"
	done
	sed -i "/^$eui $nm\.ll\.lan\$/d" /etc/hosts
	sed -i "\|^$nm|$eui\$|d" "$MAP"
	echo "$(date '+%F %T')  $nm: 删除伪造地址 $eui (实际使用: $(echo $obslist | tr '\n' ' '))" >> "$LOG"
	CHANGED=1
done

if [ "$CHANGED" = "1" ]; then
	uci commit dhcp
	/etc/init.d/dnsmasq reload 2>/dev/null
	/etc/init.d/AdGuardHome restart >/dev/null 2>&1
	echo "$(date '+%F %T')  已应用变更并重新加载服务" >> "$LOG"
else
	echo "$(date '+%F %T')  无变化" >> "$LOG"
fi
rm -f "$MAP"
