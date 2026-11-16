#!/bin/sh
# AGH 设备命名恢复: 依据设备表重建 dnsmasq 静态租约(host/domain 节)与 /etc/hosts
# 设备映射块(hostsfile 层直答 PTR); LL 记录 = 兜底表 + ND 发现, 无观测设备按 MAC
# 推算 EUI-64(RFC7217 隐私地址不推算)。幂等: 先清空 host/domain 节再按表重建;
# conf 缺失时自举从 UCI 导出, 设备表仍为空则安全退出
# 数据文件(可用 AGH_DEVICES/AGH_LL 覆盖): 名称|MAC|IPv4 → /etc/agh-devices.conf
#   名称|fe80::地址 → /etc/agh-ll-fallback.conf; 含 MAC/内网 IP, 属用户数据不随固件发布

command -v uci >/dev/null 2>&1 || { echo "错误: 请在 OpenWrt 路由器上运行本脚本"; exit 1; }
[ -f /etc/config/dhcp ] || { echo "错误: 找不到 /etc/config/dhcp"; exit 1; }

# 单实例保护: 与 refresh-ll/restore-dns-extras 串行化 (末尾调用 refresh-ll 时以 AGH_LOCK_HELD=1 放行, 防死锁)
if command -v flock >/dev/null 2>&1 && [ "${AGH_LOCK_HELD:-0}" != "1" ]; then
	exec 9>/var/lock/agh-naming.lock
	flock 9
fi

DEVFILE="${AGH_DEVICES:-/etc/agh-devices.conf}"
LLFILE="${AGH_LL:-/etc/agh-ll-fallback.conf}"
RLL="${AGH_REFRESH_LL:-/usr/bin/refresh-ll.sh}"

TS=$(date +%Y%m%d-%H%M%S)
TMPF="/tmp/agh_dev.$$.tmp"
NDTMP="/tmp/agh_nd.$$.tmp"
LLTMP="/tmp/agh_ll.$$.tmp"
MRTMP="/tmp/agh_mr.$$.tmp"
EUITMP="/tmp/agh_eui.$$.tmp"
trap 'rm -f "$TMPF" "$NDTMP" "$LLTMP" "$MRTMP" "$EUITMP"' EXIT

cp /etc/config/dhcp "/etc/config/dhcp.bak-$TS"
# 备份轮转: 只保留最近 3 份, 防 /etc/config 所在 overlay 空间膨胀
for old in $(ls -1t /etc/config/dhcp.bak-* 2>/dev/null | tail -n +4); do rm -f "$old"; done
echo ">> 已备份当前配置: /etc/config/dhcp.bak-$TS"

# 数据自举: 数据文件缺失时从当前 UCI 导出(便于在已配置机器上直接运行)
if [ ! -s "$DEVFILE" ] && [ "$(uci show dhcp 2>/dev/null | grep -c '=host$')" -gt 0 ]; then
	echo ">> 设备表缺失, 从当前 UCI host 节导出到 $DEVFILE ..."
	: > "$DEVFILE"
	for s in $(uci show dhcp | grep '=host$' | cut -d. -f2 | cut -d= -f1); do
		n=$(uci -q get dhcp.$s.name)
		m=$(uci -q get dhcp.$s.mac | awk '{print tolower($1)}')
		i=$(uci -q get dhcp.$s.ip)
		[ -n "$n" ] && [ -n "$m" ] && [ -n "$i" ] && echo "$n|$m|$i" >> "$DEVFILE"
	done
fi
if [ ! -s "$LLFILE" ] && [ "$(uci show dhcp 2>/dev/null | grep -c '=domain$')" -gt 0 ]; then
	echo ">> LL 兜底表缺失, 从当前 UCI domain 节导出到 $LLFILE ..."
	: > "$LLFILE"
	for d in $(uci show dhcp | grep '=domain$' | cut -d. -f2 | cut -d= -f1); do
		n=$(uci -q get dhcp.$d.name); i=$(uci -q get dhcp.$d.ip)
		case "$i" in fe80:*) [ -n "$n" ] && echo "$n|$i" >> "$LLFILE" ;; esac
	done
fi

if [ ! -s "$DEVFILE" ]; then
	echo "错误: 设备表为空 ($DEVFILE), 中止"
	exit 1
fi
grep -E '^[A-Za-z][^|]*\|[0-9a-fA-F:]+\|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$DEVFILE" | tr -d ' \t' > "$TMPF"
EXPECTED_V4=$(grep -c '|' "$TMPF")
if [ "$EXPECTED_V4" -lt 1 ] 2>/dev/null; then
	echo "错误: 设备表中没有合法行 (名称|MAC|IPv4), 中止"
	exit 1
fi

# 防呆: UCI 已有租约数与设备表不一致 = 存在未同步进设备表的手工租约, 清空重建会抹掉它们
UCI_V4=$(uci show dhcp 2>/dev/null | grep -c '=host$')
if [ "$UCI_V4" -gt 0 ] && [ "$UCI_V4" != "$EXPECTED_V4" ] && [ "${FORCE:-0}" != "1" ]; then
	echo "!! UCI 现有 $UCI_V4 条静态租约, 设备表 $EXPECTED_V4 条, 数量不一致"
	echo "   继续将抹掉未同步进设备表的租约; 确认覆盖请以 FORCE=1 环境变量重新运行"
	exit 1
fi

echo ">> 清空现有 静态租约(host) 与 主机名(domain) 节..."
while uci -q delete dhcp.@host[-1]; do :; done
while uci -q delete dhcp.@domain[-1]; do :; done

echo ">> 写入 $EXPECTED_V4 台设备的静态租约..."
while IFS='|' read -r NAME MAC IP; do
	uci -q add dhcp host >/dev/null || { echo "  !! 添加失败: $NAME"; continue; }
	uci set dhcp.@host[-1].name="$NAME"
	uci add_list dhcp.@host[-1].mac="$MAC"
	uci set dhcp.@host[-1].ip="$IP"
	uci set dhcp.@host[-1].dns='1'
done < "$TMPF"

# 运行时 ND 发现: LL↔MAC 对照设备表
: > "$LLTMP"
if command -v ip >/dev/null 2>&1; then
	DEV=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
	DEV=${DEV:-eth0}
	ip -6 neigh show dev "$DEV" > "$NDTMP" 2>/dev/null
	while read -r ADDR REST; do
		case "$ADDR" in fe80:*) ;; *) continue ;; esac
		case "$REST" in lladdr\ *) ;; *) continue ;; esac
		MAC=$(echo "$REST" | awk '{print tolower($2)}')
		HIT=$(grep -i "|$MAC|" "$TMPF" | head -n 1)
		[ -n "$HIT" ] || continue
		NAME=${HIT%%|*}
		ADDR=$(echo "$ADDR" | tr 'A-F' 'a-f')
		echo "$NAME|$ADDR" >> "$LLTMP"
	done < "$NDTMP"
fi

# 合并 LL 记录: 兜底表 + ND发现, 按地址去重
: > "$MRTMP"
ll_exists() {  # $1=地址(小写) → MRTMP 第2列是否已存在
	awk -F'|' -v a="$1" 'tolower($2)==a{f=1} END{exit !f}' "$MRTMP" 2>/dev/null
}
name_exists() {  # $1=名称 → MRTMP 第1列是否已存在
	awk -F'|' -v n="$1" 'tolower($1)==tolower(n){f=1} END{exit !f}' "$MRTMP" 2>/dev/null
}
add_ll() {  # $1=来源 $2=名称 $3=地址
	ADDR_L=$(echo "$3" | tr 'A-F' 'a-f')
	if ll_exists "$ADDR_L"; then
		echo "  - $1 跳过重复: $2 $ADDR_L"
		return
	fi
	echo "$2|$ADDR_L" >> "$MRTMP"
	echo "  + $1: $2 $ADDR_L"
}
[ -s "$LLFILE" ] && while IFS='|' read -r NAME ADDR; do
	NAME=$(echo "$NAME" | tr -d ' \t'); ADDR=$(echo "$ADDR" | tr -d ' \t')
	[ -z "$NAME" ] && continue
	case "$NAME" in '#'*) continue ;; esac
	add_ll "LL表" "$NAME" "$ADDR"
done < "$LLFILE"
[ -s "$LLTMP" ] && while IFS='|' read -r NAME ADDR; do
	add_ll "ND发现" "$NAME" "$ADDR"
done < "$LLTMP"

# EUI-64 只为无观测 LL 的设备推算: iOS/安卓/Windows/macOS 走 RFC7217 隐私地址, 强推造出假地址
: > "$EUITMP"
while IFS='|' read -r NAME MAC IP; do
	[ -z "$NAME" ] && continue
	name_exists "$NAME" && continue
	m1=${MAC:0:2}; m2=${MAC:3:2}; m3=${MAC:6:2}; m4=${MAC:9:2}; m5=${MAC:12:2}; m6=${MAC:15:2}
	f1=$(printf '%02x' $(( 0x$m1 ^ 0x02 )))
	LL="fe80::${f1}${m2}:${m3}ff:fe${m4}:${m5}${m6}"
	LL_L=$(echo "$LL" | tr 'A-F' 'a-f')
	ll_exists "$LL_L" && continue
	echo "$NAME|${LL_L}" >> "$EUITMP"
done < "$TMPF"
[ -s "$EUITMP" ] && cat "$EUITMP" >> "$MRTMP"

echo ">> 写入 LL 记录..."
N_LL=0
while IFS='|' read -r NAME ADDR; do
	uci -q add dhcp domain >/dev/null || { echo "  !! 添加失败: $NAME"; continue; }
	uci set dhcp.@domain[-1].name="$NAME"
	uci set dhcp.@domain[-1].ip="$ADDR"
	N_LL=$((N_LL + 1))
done < "$MRTMP"
EXPECTED_V6=$N_LL

uci commit dhcp

/etc/init.d/dnsmasq restart
sleep 3

# /etc/hosts 设备映射: AGH hostsfile 层直接应答 PTR, 不经上游无竞速
HS=/etc/hosts
cp "$HS" "$HS.bak-$TS"
for old in $(ls -1t "$HS".bak-* 2>/dev/null | tail -n +4); do rm -f "$old"; done
# 宽松标记删除+孤儿清扫防旧块残留(重复块); 有 BEGIN 无 END 时范围删除会吃掉文件尾, 必须先人工处理
if grep -qE 'AGH-DEVICE-MAP[- ]BEGIN' "$HS" && ! grep -qE 'AGH-DEVICE-MAP[- ]END' "$HS"; then
	echo "!! /etc/hosts 存在未闭合的旧设备映射块, 中止改写, 请人工检查 $HS (本次备份: $HS.bak-$TS)"
	exit 1
fi
sed -i '/AGH-DEVICE-MAP[- ]BEGIN/,/AGH-DEVICE-MAP[- ]END/d' "$HS"
sed -i '/AGH-DEVICE-MAP/d' "$HS"
{
	echo "# === AGH-DEVICE-MAP BEGIN ==="
	while IFS='|' read -r NAME MAC IP; do
		[ -z "$NAME" ] && continue
		case "$NAME" in '#'*) continue ;; esac
		echo "$IP $NAME.lan"
	done < "$TMPF"
	while IFS='|' read -r NAME ADDR; do
		NAME=$(echo "$NAME" | tr -d ' \t')
		ADDR=$(echo "$ADDR" | tr -d ' \t')
		[ -z "$NAME" ] && continue
		case "$NAME" in '#'*) continue ;; esac
		echo "$ADDR $NAME.ll.lan"
	done < "$MRTMP"
	echo "# === AGH-DEVICE-MAP END ==="
} >> "$HS"
echo ">> /etc/hosts 设备映射已写入: $(grep -cE '^[0-9a-f:.]+ [A-Za-z].*\.lan$' "$HS") 条"
# 写后断言: BEGIN/END 必须恰好各一个, 异常则回滚本次备份
if [ "$(grep -cE 'AGH-DEVICE-MAP[- ]BEGIN' "$HS")" -ne 1 ] || [ "$(grep -cE 'AGH-DEVICE-MAP[- ]END' "$HS")" -ne 1 ]; then
	cp "$HS.bak-$TS" "$HS"
	echo "!! /etc/hosts 设备映射块标记异常, 已回滚到 $HS.bak-$TS"
fi

HOSTS=$(ls /tmp/hosts/dhcp.* 2>/dev/null | head -n 1)
ACTUAL_V4=$(uci show dhcp | grep -c '=host$')
ACTUAL_V6=$(uci show dhcp | grep -c '=domain$')
LOADED_V4=0
LOADED_V6=0
[ -n "$HOSTS" ] && {
	LOADED_V4=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ ' "$HOSTS")
	LOADED_V6=$(grep -ci 'fe80::' "$HOSTS")
}

echo ">> 验证:"
echo "   IPv4 静态租约   : UCI $ACTUAL_V4 / 期望 $EXPECTED_V4 ; dnsmasq已加载 $LOADED_V4"
echo "   IPv6 LL 记录    : UCI $ACTUAL_V6 / 期望 $EXPECTED_V6 ; dnsmasq已加载 $LOADED_V6"
DUP=$(grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$HOSTS" 2>/dev/null | sort | uniq -d)
if [ -z "$DUP" ]; then
	echo "   重复IP检查      : 通过"
else
	echo "   !! 重复IP: $DUP"
fi

if ps w | grep -q '[A]dGuardHome'; then
	echo ">> 重启 AdGuardHome (清空DNS负缓存, 设备名立即生效)..."
	/etc/init.d/AdGuardHome restart
	sleep 4
fi

# 用实时 ND 校正: 在线设备以真实(可能 RFC7217)LL 为准
if [ -x "$RLL" ]; then
	echo ">> 用实时 ND 邻居表校正 IPv6 地址..."
	AGH_LOCK_HELD=1 "$RLL" >/dev/null 2>&1
	grep -q "无变化" /var/log/refresh-ll.log 2>/dev/null \
		&& echo "   无需要校正的设备" \
		|| echo "   已校正(详见 /var/log/refresh-ll.log)"
fi

echo ">> 完成。AGH 面板设备名(v4与fe80::客户端)将在几分钟内陆续显示。"
echo ">> LuCI 位置: 网络 -> DHCP/DNS -> 静态租约 / 主机名"
echo "   (LuCI里\"IP不在DHCP池内\"红字提示是旁路由DHCP禁用所致, 正常忽略)"
