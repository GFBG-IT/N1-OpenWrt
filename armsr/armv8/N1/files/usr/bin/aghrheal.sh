#!/bin/sh
# AGH 自愈：ophub 的 remake 打包、在线升级、晶晨宝盒“更新插件”都会用原版脚本
# 覆盖 /usr/sbin/openwrt-*，并把 /usr/bin/AdGuardHome 顶成指向数据分区的符号链接
# （核心丢失）。本脚本挂 S90（先于 S95AdGuardHome），每次开机自愈：
#   - 核心在位（缺失时从数据分区找回）
#   - 升级脚本的 AGH 迁移块移除
#   - ophub 备份清单扩展
#   - UCI 路径钉死（与 diy.sh build 期对齐一致）
# 幂等：所有操作带状态判断，重复执行无副作用

# 1) 符号链接/目录残留 → 清除；核心缺失 → 从数据分区找回
[ -L /usr/bin/AdGuardHome ] && rm -f /usr/bin/AdGuardHome
[ -d /usr/bin/AdGuardHome ] && rm -rf /usr/bin/AdGuardHome
[ -f /usr/bin/AdGuardHome ] || cp -f /mnt/mmcblk2p4/AdGuardHome/AdGuardHome /usr/bin/AdGuardHome 2>/dev/null

# 2) ophub 升级脚本的 AGH 迁移块（会把核心顶成数据分区目录）→ 删除
UPD=/usr/sbin/openwrt-update-amlogic
if [ -f "$UPD" ] && grep -q 'ln -sf /mnt/${EMMC_NAME}${PARTITION_NAME}4/AdGuardHome' "$UPD"; then
	sed -i '/^if \[ -f \/mnt\/${NEW_ROOT_NAME}\/etc\/config\/AdGuardHome \]; then$/,/^fi$/d' "$UPD"
fi

# 3) ophub 备份清单扩展（升级保留：AGH 数据/oxidns 配置/nlbwmon/bandix/AGH 命名套件）
BKP=/usr/sbin/openwrt-backup
if [ -f "$BKP" ]; then
	if ! grep -q '\./etc/adguardhome/' "$BKP"; then
		sed -i 's|\./etc/AdGuardHome\.yaml \\|&\n./etc/adguardhome/ \\\n./etc/oxidns/ \\\n./usr/share/nlbwmon/ \\|' "$BKP"
	fi
	grep -q '\./usr/share/bandix/' "$BKP" || \
		sed -i 's|\./etc/adguardhome/ \\|&\n./usr/share/bandix/ \\|' "$BKP"
	grep -q '\./etc/agh-devices\.conf' "$BKP" || \
		sed -i 's|\./usr/share/bandix/ \\|&\n./etc/agh-devices.conf \\\n./etc/agh-ll-fallback.conf \\|' "$BKP"
fi

# 4) UCI 路径钉死（tk 选项名 binpath/workdir/configpath；AGH 尚未配置过则跳过）
uci -q get AdGuardHome.AdGuardHome >/dev/null 2>&1 || exit 0
uci -q set AdGuardHome.AdGuardHome.binpath='/usr/bin/AdGuardHome'
uci -q set AdGuardHome.AdGuardHome.workdir='/etc/adguardhome'
uci -q set AdGuardHome.AdGuardHome.configpath='/etc/adguardhome/adguardhome.yaml'
uci -q commit AdGuardHome
exit 0
