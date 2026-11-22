#!/bin/sh
# =====================================================================
# AGH/cron 配套调优恢复(固件内置 /usr/bin/, 重置恢复第 2 步):
# 前置 = AGH 完成向导接管 53 + 先跑 restore-static-leases.sh 重建租约(持久客户端依赖 host 节)
# 恢复 = AGH(ratelimit=0 / timeout=5s / 反向解析开关+local_ptr / querylog 加量 /
#        hostsfile_enabled / 上游 arpa 分行路由 / bootstrap 置空 / 按MAC持久客户端)
#        + cron(每 6h refresh-ll)
# 注意: 跑完之后不要在AGH界面再改"私人反向DNS解析器"和"客户端反向解析"开关
# =====================================================================

command -v uci >/dev/null 2>&1 || { echo "错误: 请在 OpenWrt 路由器上运行本脚本"; exit 1; }
TS=$(date +%Y%m%d-%H%M%S)
BLOCK="/tmp/agh_clients.$$.block"
ARPA="/tmp/agh_arpa.$$.list"
RLL="${AGH_REFRESH_LL:-/usr/bin/refresh-ll.sh}"

# 单实例保护: 与另两个设备命名脚本串行化
if command -v flock >/dev/null 2>&1; then
	exec 9>/var/lock/agh-naming.lock
	flock 9
fi

# ---- AdGuardHome ----
YAML=/etc/adguardhome/adguardhome.yaml
if [ -f "$YAML" ]; then
	cp "$YAML" "$YAML.bak-$TS"
	for old in $(ls -1t "$YAML".bak-* 2>/dev/null | tail -n +4); do rm -f "$old"; done
	echo ">> AGH 配置已备份: $YAML.bak-$TS"

	sed -i 's/  ratelimit: .*/  ratelimit: 0/' "$YAML"
	sed -i 's/  upstream_timeout: .*/  upstream_timeout: 5s/' "$YAML"
	sed -i 's/  use_private_ptr_resolvers: .*/  use_private_ptr_resolvers: true/' "$YAML"
	sed -i 's/^    rdns: .*/    rdns: true/' "$YAML"
	sed -i 's/  size_memory: .*/  size_memory: 10000/' "$YAML"
	sed -i 's/  interval: .*/  interval: 7d/' "$YAML"

	if grep -q 'local_ptr_upstreams: \[\]' "$YAML"; then
		LN=$(grep -n 'local_ptr_upstreams: \[\]' "$YAML" | head -n 1 | cut -d: -f1)
		{
			head -n $((LN - 1)) "$YAML"
			echo '  local_ptr_upstreams:'
			echo '    - 127.0.0.1:1745'
			tail -n +$((LN + 1)) "$YAML"
		} > "$YAML.tmp" && mv "$YAML.tmp" "$YAML"
		echo ">> local_ptr_upstreams 已设为 127.0.0.1:1745"
	elif grep -q '127.0.0.1:1745' "$YAML"; then
		echo ">> local_ptr_upstreams 已是 127.0.0.1:1745, 跳过"
	else
		echo "!! local_ptr_upstreams 格式非预期, 请在AGH界面手动设置:"
		echo "   DNS设置 -> 私人反向DNS解析器 -> 127.0.0.1:1745"
	fi

	# hostsfile 层开关: /etc/hosts 设备映射块由 AGH 直答 PTR 的前提
	if grep -q '  hostsfile_enabled:' "$YAML"; then
		sed -i 's/  hostsfile_enabled: .*/  hostsfile_enabled: true/' "$YAML"
		echo ">> hostsfile_enabled 已确保为 true"
	elif grep -q '  serve_plain_dns:' "$YAML"; then
		LN=$(grep -n '  serve_plain_dns:' "$YAML" | head -n 1 | cut -d: -f1)
		{ head -n "$LN" "$YAML"; echo '  hostsfile_enabled: true'; tail -n +$((LN + 1)) "$YAML"; } > "$YAML.tmp" && mv "$YAML.tmp" "$YAML"
		echo ">> hostsfile_enabled: true 已插入"
	else
		echo "!! yaml 中无 hostsfile_enabled/serve_plain_dns 锚点, 请在 AGH 界面 DNS 设置里手动开启"
	fi

	# 上游分行 arpa 路由: 私网 PTR 逐段指向 1745 (合并写法对 PTR 查询无效, 必须逐段分行)
	if grep -q '\[/f\.f\.ip6\.arpa/\]' "$YAML"; then
		echo ">> 上游 arpa 分行路由已配置, 跳过"
	else
		cat > "$ARPA" <<'ARPA'
    - 127.0.0.1:5335
    - '[/lan/]127.0.0.1:1745'
    - '[/0.in-addr.arpa/]127.0.0.1:1745'
    - '[/10.in-addr.arpa/]127.0.0.1:1745'
    - '[/127.in-addr.arpa/]127.0.0.1:1745'
    - '[/254.169.in-addr.arpa/]127.0.0.1:1745'
    - '[/16.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/17.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/18.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/19.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/20.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/21.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/22.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/23.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/24.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/25.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/26.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/27.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/28.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/29.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/30.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/31.172.in-addr.arpa/]127.0.0.1:1745'
    - '[/168.192.in-addr.arpa/]127.0.0.1:1745'
    - '[/18.198.in-addr.arpa/]127.0.0.1:1745'
    - '[/19.198.in-addr.arpa/]127.0.0.1:1745'
    - '[/c.f.ip6.arpa/]127.0.0.1:1745'
    - '[/d.f.ip6.arpa/]127.0.0.1:1745'
    - '[/e.f.ip6.arpa/]127.0.0.1:1745'
    - '[/f.f.ip6.arpa/]127.0.0.1:1745'
ARPA
		awk '
			FNR==NR { if (NF) lines[++n] = $0; next }
			/^  upstream_dns:/ { line = $0; sub(/:.*$/, ":", line); print line; for (i = 1; i <= n; i++) print lines[i]; skip = 1; next }
			skip == 1 && /^    - / { next }
			skip == 1 { skip = 0 }
			{ print }
		' "$ARPA" "$YAML" > "$YAML.tmp" && mv "$YAML.tmp" "$YAML"
		echo ">> 上游已重写为 oxidns 分流 + 私网 arpa 分行路由 (原有上游列表被替换, 自定义上游请在 AGH 界面重加)"
	fi

	# bootstrap/fallback 置空: 主上游(oxidns)故障时干净失败, 不回退公网 DNS
	awk '
		/^  (bootstrap_dns|fallback_dns):/ {
			if ($0 ~ /\[\][ \t]*$/) { print; next }
			sub(/:.*$/, ": []"); print; skip = 1; next
		}
		skip == 1 && /^    - / { next }
		skip == 1 { skip = 0 }
		{ print }
	' "$YAML" > "$YAML.tmp" && mv "$YAML.tmp" "$YAML"
	echo ">> bootstrap/fallback 已确保为空"

	# 按MAC的持久客户端 (依赖租约脚本先运行, 从 host 节提取 MAC+名称)
	EXISTING=$(grep -c 'use_global_settings' "$YAML" 2>/dev/null)
	NHOST=$(uci show dhcp 2>/dev/null | grep -c '=host$')
	if [ "$NHOST" -ge 1 ] && [ "${EXISTING:-0}" -eq 0 ]; then
		{
			echo '  persistent:'
			for s in $(uci show dhcp | grep '=host$' | cut -d. -f2 | cut -d= -f1); do
				NAME=$(uci -q get dhcp.$s.name)
				MAC=$(uci -q get dhcp.$s.mac | awk '{print tolower($1)}')
				[ -z "$NAME" ] && continue
				[ -z "$MAC" ] && continue
				UIDV=$(cat /proc/sys/kernel/random/uuid)
				echo "    - ids:"
				echo "        - $MAC"
				if [ "$NAME" = "OpenWrt" ]; then
					echo "        - 127.0.0.1"
					echo "        - ::1"
				fi
				echo "      name: $NAME"
				echo "      uid: $UIDV"
				echo "      use_global_settings: true"
				echo "      filtering_enabled: true"
				echo "      parental_enabled: false"
				echo "      safebrowsing_enabled: false"
				echo "      use_global_safe_search: true"
				echo "      safe_search:"
				echo "        enabled: false"
				echo "      blocked_services:"
				echo "        schedule:"
				echo "          time_zone: UTC"
				echo "        ids: []"
			done
		} > "$BLOCK"
		LN=$(grep -n '  persistent: \[\]' "$YAML" | head -n 1 | cut -d: -f1)
		if [ -n "$LN" ]; then
			head -n $((LN - 1)) "$YAML" > "$YAML.tmp"
			cat "$BLOCK" >> "$YAML.tmp"
			tail -n +$((LN + 1)) "$YAML" >> "$YAML.tmp"
			mv "$YAML.tmp" "$YAML"
			echo ">> 持久客户端已生成: $(grep -c 'use_global_settings' "$YAML") 个 (按MAC, 覆盖v4/v6/LL)"
		else
			echo "!! 未找到 persistent: [], 持久客户端跳过"
		fi
	elif [ "${EXISTING:-0}" -gt 0 ]; then
		echo ">> 持久客户端已存在 $EXISTING 个, 跳过"
	else
		echo "!! dhcp 中无 host 节 — 请先运行 restore-static-leases.sh"
	fi

	if ps w | grep -q '[A]dGuardHome'; then
		/etc/init.d/AdGuardHome restart
		sleep 5
		echo ">> AdGuardHome 已重启"
		ps w | grep -q '[A]dGuardHome' && echo "   进程: 运行中, 53端口: $(netstat -ntlp | grep -c ':53 ')条监听" || echo "   !! AGH未启动, 回滚: cp $YAML.bak-$TS $YAML && /etc/init.d/AdGuardHome restart"
	fi

	echo ">> AGH 关键值确认 (期望 0/5s/true/true/1745/10000/7d/true):"
	grep -E '  ratelimit:|  upstream_timeout:|  use_private_ptr_resolvers:|    rdns:|  size_memory:|  hostsfile_enabled:' "$YAML"
	grep -E '  interval:' "$YAML" | head -1
	grep -A1 '  local_ptr_upstreams:' "$YAML"
	echo "   上游 arpa 分行路由: $(grep -c '\[/.*\.arpa/\]' "$YAML") 行"
else
	echo "!! 未找到 $YAML — AdGuardHome 尚未安装/配置, 本部分跳过"
	echo "   请先完成 AGH 安装向导并接管 53 端口 (dnsmasq 退到 1745) 后再运行"
fi

# ---- cron: refresh-ll 自动校正 LL ----
CRON=/etc/crontabs/root
touch "$CRON"
if [ -x "$RLL" ]; then
	if ! grep -q "refresh-ll.sh" "$CRON"; then
		echo "0 */6 * * * $RLL >/dev/null 2>&1" >> "$CRON"
		/etc/init.d/cron restart
		echo ">> 已添加 LL 自动校正 cron (每6小时): $RLL"
	else
		echo ">> LL 自动校正 cron 已存在"
	fi
else
	echo "!! 未找到 refresh-ll.sh ($RLL) — 请先复制并 chmod +x"
	echo "   (它会从ND表自动把设备记录改成真实LL, 尤其是iPhone/安卓/Mac的RFC7217隐私地址)"
fi

rm -f "$BLOCK" "$ARPA" "$YAML.tmp" 2>/dev/null
echo ">> extras 完成。"
