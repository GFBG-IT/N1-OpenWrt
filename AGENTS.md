# N1-OpenWrt 项目规范（AGENTS.md）

本文件是本仓库所有改动（人工或 AI 会话）的统一规范。**任何改动前先通读本文；与本文冲突的做法，先与用户确认再执行。**
本文由历次会话沉淀整理，随项目演进更新；修改本文本身也需经用户确认。

---

## 1. 项目定位

- 为 **斐讯 N1（s905d，armsr/armv8）** 编译 **ImmortalWrt 25.12** 旁路由固件。
- 构建链：GitHub Actions（`.github/workflows/armsr_armv8.yml`）→ diy.sh 定制源码 → rootfs.tar.gz → flippy 打包脚本 + ophub 内核（`6.12.y`）→ `.img.gz` 发布。
- 设备定位：**轻量旁路由** —— 静态 IP `192.168.5.3`，主路由（`192.168.5.1`）负责拨号/DHCP/IPv6 网关；N1 只负责 DNS 与透明代理。**不做 PPPoE、WiFi、主路由网关、Docker。**
- 代理与 DNS 架构（改动网络相关内容前必须理解）：
  ```
  局域网设备 DNS → AdGuardHome:53 → mosdns:5335（分流/去广告）→ 上游
  passwall2 + xray 透明代理；dnsmasq 监听 1745（53 只留给 AdGuardHome）
  bandix（eBPF）监控 eth0 的流量/连接/DNS，API 只监听 127.0.0.1:8686
  WireGuard 服务端：kmod-wireguard + wireguard-tools + luci-proto-wireguard，接口与密钥在 LuCI 建
  ```

## 2. 核心文件地图

| 文件 | 作用 |
|---|---|
| `armsr/armv8/diy/diy.sh` | 编译前源码定制（feeds、第三方组件、版本、运行时文件），workflow 中执行于 openwrt 源码根目录 |
| `armsr/armv8/N1/.config` | OpenWrt 包选择配置，`### N. SECTION ###` 共 9 个分区 |
| `.github/workflows/armsr_armv8.yml` | CI：手动触发 + 每月 1、16 号定时；含 Verify 步骤与发布 |
| `armsr/armv8/N1/files/` | 静态系统文件（network / amlogic / crontabs / rc.d / ssh） |
| `diy.sh` 生成的运行时文件 | `files/etc/{sysctl.d,uci-defaults,hotplug.d/net,apk/keys}`、`files/root/.bashrc`，均由 diy.sh 每次构建时写入 |

## 3. 架构红线（不可违背）

1. **内核级优化不引入**：内核由 ophub/flippy 打包阶段整体替换，`CONFIG_KERNEL_*`（BBRv3/LRNG/SFE/超频/THP 之外的调优）改了也无效，禁止添加。
2. **包管理是 apk 不是 opkg**（25.12）：写 hold、源、密钥相关逻辑时只能用 apk 语义（如 `99-hold-core-packages` 改写 `/etc/apk/world`）。
3. **全 nftables**：禁止引入任何 iptables-legacy / ipset 旧栈组件。
4. **Argon 3.0 合一**：主题与设置已合一，**禁止引入 `luci-app-argon-config`**（apk 会报文件冲突）。
5. **双 init 禁止**：AdGuardHome 服务管理归 `luci-app-adguardhome-tk`，feeds adguardhome 包只保留纯二进制。
6. **中文环境必须保留**：`luci-i18n-base-zh-cn=y` 与 `CONFIG_LUCI_LANG_zh_Hans=y`，删掉 LuCI 会变英文。
7. **不替换 uhttpd 为 nginx**，不引入 nginx。
8. **轻量原则**：拒绝重量级组件（如 ddns-go）；同等功能优先纯 shell / 轻量方案。
9. **`packet_steering` 保持 `'2'`**：25.12 的 ucode 版 steering 脚本语义为"RPS 掩码全核、软中断按流哈希分散到 4 核"（与旧版 shell 脚本相反，旧版 `'2'` 是绑核且仅适合 SQM；流内无乱序——RPS 按流哈希选核）。`'1'` 为单核绑定，仅低载缓存亲和有微小理论优势。
10. **用户明确锁定不动**：network 中的 fe80 IPv6 地址、workflow action 版本引用、`mitigations=off`。动这些必须先获明确同意。
11. **mosdns 必须配 `redirect='0'`**，避免与其他 DNS 组件抢 53 端口形成回环。
12. **WireGuard 必须随固件保留**：`kmod-wireguard` / `wireguard-tools` / `luci-proto-wireguard` 三件套缺一不可——少 kmod 内核不支持，少 tools 没有 wg/wg-quick，少 luci-proto 在 LuCI 里建不了接口。

## 4. 各文件修改规范

### 4.1 diy.sh

- 保持 `N/9` 编号分节结构（1 版本号 / 2 feeds 更新 / 3 feeds 调整 / 4 引入外部组件 / 5 菜单分类 / 6 运行时文件 / 7 包内补丁 / 8 索引重建 / 9 清理）；新逻辑放进语义对应的小节，不另起炉灶。
- 所有 `set -euo pipefail` 下的改动要意识到**任何未兜底的命令失败都会中止编译**。
- 修改 feeds / 上游文件必须三件套：`[ -f ... ]` 存在性判断 → 修改 → `grep` 校验修改生效；失败打 `WARN`（可跳过）或 `ERROR` + `exit 1`（必须成功）。
- 对 ophub 插件脚本（`feeds/luci/applications/luci-app-amlogic/root/usr/sbin/openwrt-*`，上游 main 滚动更新）打补丁同样走三件套；锚点未命中属上游漂移，打 `WARN` 提示人工核对，不阻断编译。
- **核心组件（xray、mihomo、AdGuardHome 等编译必需项）**：获取失败重试 3 次，仍失败才 `exit 1`；**非核心（openlist2、sing-box、geoview、ddnstox、geo 数据等）**：失败回退仓库自带版本，打 WARN 不阻断。
- 外部仓库克隆统一走 `clone_bg` / `wait_clones` 并行机制（内含重试 3 次），不要新写串行 `git clone`。
- 版本号只取正式 tag（`^v[0-9]+(\.[0-9]+)+$`），排除 alpha/rc；mihomo 用稳定版不引 alpha。
- 注释遵循 4.5 注释规范：默认不加，必要才加。

### 4.2 .config

- 严格保持 `### N. SECTION ###` 九区块结构；**用户手动重排过区块，属有意为之，禁止打乱顺序**。
- 新增/修改符号必须放入语义正确的分区，并在其上加中文单行注释说明理由。
- **新符号必须先对照 ImmortalWrt 25.12 源码树核实存在**（curl 查上游 Makefile / netdevices.mk 等），死符号会被 defconfig 静默丢弃，不报错。
- 改完做重复键校验；删除符号前先 grep 确认无依赖。

### 4.3 workflow（armsr_armv8.yml）

- Verify 步骤定位是**纯信息展示**：已 `set +e` / `set +o pipefail`，任何异常只打 WARN/MISSING，**绝不阻断发布**。不要往里加会 exit 非零的逻辑。
- **新增运行时文件（uci-defaults / sysctl.d / ssh 配置等）必须同步加进 Verify 的 MISSING 清单；删除文件必须同步移除**，保持清单与 diy.sh 产物一致。
- 只校验核心组件（mosdns / passwall2 / AGH / bandix / sshd / bash / WireGuard / DDNS 等）；主题等非核心不校验。
- 发布信息（IP 192.168.5.3 / root / password）是既有公开约定，保持不动。

### 4.4 运行时文件（files/）

- **uci-defaults 一律幂等**：`uci -q`、`grep` 前置判断、`exit 0` 结尾、`chmod 755`。
- **隐私不固化**：DNS 服务器、自定义规则列表、节点/订阅信息一律不写进仓库（见 `99-mosdns-tuning` 头注释）。
- **需跨升级保留的用户数据**（mosdns 规则、nlbwmon 协议库、AGH 数据等）通过 diy.sh 扩展 ophub 备份清单（`openwrt-backup` 的 `BACKUP_LIST`）在设备本地随升级保留，不在仓库或镜像中固化内容。
- 设备上发现的问题，**修复要固化到 diy.sh / files/ 随固件生效**，同时给出设备上立即可用的过渡命令；**不直接改在线设备**。

### 4.5 注释规范（对全部文件生效）

- **注释必须是必要的，可加可不加的一律不加**。宁可没有注释，不留无信息量注释。
- 判定"必要"：注释必须承载**代码本身表达不出来、丢了会再次踩坑**的信息。满足其一才算必要：
  1. 踩坑记录：不写下来，下次改动必然重蹈覆辙（如"flippy 打包会把 system.zram_size_mb 置 0"）。
  2. 有意取舍：看似多余或非常规、实则有意为之（如"chinadns-ng 非必需：passwall2 没有它时会回退 dnsmasq"）。
  3. 隐性约束：包/服务/文件之间的分工与依赖边界（如"服务由 luci-app-adguardhome-tk 接管，避免双 init"）。
  4. 选择理由：从名字上根本看不出为什么选它或淘汰它（如"kmod-dwmac-motorcomm（YT6801 网卡驱动）"）。
- 以下一律视为非必要，禁止添加：
  - 复述代码行为的注释（"设置变量 X"、"执行 sed 替换"）。
  - 与分节标题 / 代码逻辑重复的注释。
  - 修改历史（"原来是 X，后来改成 Y"）——这是 git log 的职责。
  - 占位与口号（TODO、待优化、"此处可扩展"）。
- 形式：单行为主、中文；分节横幅（diy.sh 的 `# N/9`、.config 的 `### N. SECTION ###`）除外。
- **清理义务**：改动某个区域时，顺手删除该区域内已有的无信息量注释；不必为此专门发起改动，但动了就要清。

## 5. 提交前验证清单（逐项执行并汇报结果）

1. `bash -n armsr/armv8/diy/diy.sh` 语法检查。
2. workflow YAML：确认无 Tab 缩进、引号配对；本机没有 Python yaml 模块，可用 node 或人工核对。
3. `grep` 扫描确认删除项残留为 0（三文件都要：diy.sh / .config / yml）。
4. `.config` 重复键校验 + 新符号对照上游源码。
5. heredoc `<<'EOF'` / `EOF` 配对检查；新写的 sed 先单独测试再合入。
6. `git diff --stat` 逐文件向用户汇报增量。
7. **大文件重写时按字节从原版复制，不要凭记忆手打**——曾因抄错 `${version)})` 导致 CI 运行期失败（`bash -n` 查不出这类错误）；修复此类问题时从备份按行原样复制，并全文件扫描同类模式。

## 6. Git 与交付流程

1. **提案先行**：先给方案（含取舍），经用户确认才动手；拿不准时列出 2-3 个选项供拍板，用户自会调研后决策，尊重其结论。
2. **改动留在工作区 review**，用户过目后才提交；**commit 由用户自己做**（惯用简短信息，如 `update`），助手不擅自 commit / push。
3. **禁止 `git add .`**：仓库无 `.gitignore`，`.idea/` 未跟踪，必须逐文件 add。固件镜像（`*.img` / `*.img.gz`）与本地分析产物属临时文件，用完移出或删除，不得以任何形式入库。
4. 一次会话的改动聚焦一个主题；完成后总结改动点、验证结果与遗留事项。
5. 推送后由**用户手动触发** workflow（Actions → Build ImmortalWrt-25.12），用户会事后刷机实测验证产物。
6. 与本仓库无关的小工具（如局域网查询类脚本）放 `E:\github` 下独立目录，**不混入本仓库**。

## 7. 本机环境注意（Windows Git Bash）

- `python` / `python3` 是 Microsoft Store 占位 stub（exit 49），**必须用 `py -3`**；CI 里则是 `python3`。
- 本机无 Python yaml 模块；node（v24）可用。
- 注意 CRLF：处理 uEnv.txt 等 boot 分区文件时先 `sed -i 's/\r$//'` 去尾随回车。
- 用户设备：N1 `192.168.5.3`（root），PC `192.168.5.6`；远程操作设备走临时 SSH 脚本，**输出中不得出现节点信息与凭据**。
- **远程写设备必须走受审脚本**：写操作先落成完整脚本（幂等、带备份回滚、语法/存在性校验）再 `ssh 'sh -s' < 脚本` 执行；禁止 `cat >>` 等无界追加与未重定向的 stdin 管道；执行后必查 `df -h` 与脚本语法（根分区满会让一切写入静默截断，openwrt_size 保持 1280MiB 无余量，属既知约束）。

## 8. 踩坑备忘（改相关区域前先看）

- flippy 打包会把 `system.zram_size_mb` 置 0 → `99-zram-size` 恢复 256MB。
- irqbalance 与 flippy `S95done` 静态中断分配冲突 → 已移除，用 `S96-rps-4cpu` 做 4 核 RPS 分摊（覆盖 ophub 注入的 S95done）。
- LuCI 在线用户统计只认 `br-lan`，N1 是 eth0 → diy.sh 已修；进程页 rpcd popen 有竞态 → 已替换为 /proc 直读。
- 复制自 git 子目录的 LuCI 包无 `.git` 会让 luci.mk 回退版本号 0 → `fix_luci_po_version` 补 `PKG_PO_VERSION`。
- AdGuardHome keep.d 若保留二进制，配置升级时旧核心会覆盖新编译版 → init 已改为只带 configpath。
- luci-app-amlogic 保配置升级会保留旧版 /etc/config（目录式旧 UCI 残留）→ `99-adguardhome-paths` 首启兜底；旧版升级脚本还会用符号链接把 `/usr/bin/AdGuardHome` 顶到数据分区 → 迁移块已由 diy.sh 删除。
- ophub 升级备份清单（`openwrt-backup` 的 `BACKUP_LIST`）默认不含 `/etc/adguardhome`、`/etc/mosdns/rule`、`/usr/share/nlbwmon`、`/usr/share/bandix` → diy.sh 已打补丁补充；新增需跨升级保留的路径时同步扩展该补丁并更新 Verify 清单。
- bandix 用上游 release 的预编译 aarch64-musl 二进制，版本与 `PKG_HASH` 写死在包内；目标换成 glibc 时资产名对不上，`make download` 会直接失败。
- `kmod-ipv6`、`addition-trans-zh`、`CONFIG_DNSMASQ_NFTSET`、`CONFIG_LUCI_LANG_en` 等是死符号，勿再加回。
- 25.12 的 `LIBCURL_HTTP3` 替代了废弃的 NGHTTP3/NGTCP2 符号。
- CI 里上游 HEAD 克隆 / codeload / sourceforge 偶发抖动导致构建变红，**重跑通常自愈**，先重跑再排查。

## 9. 沟通约定

- 全程中文交流；结论 / 表格先行，再给根因与证据链（上游源码核实 + 实测数据），不接受纯理论推断。
- 涉及删除的改动：先验证再删（grep、查上游源码）。
- 用户偏好"保留而非删除"（如 devcrypto、openssl-util 等即使非必需也保留），接受固件体积小幅增加。
- 多任务指令用编号列表逐项批复、逐项汇报。
