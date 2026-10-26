# 变更记录

## v1.0.17 — 2026-10-26
- **★ 修 panic 率过高（真凶：跑链期间还在每 3 秒做重活）**
  实测统计（App 自己的 app.log，同一台机器同一天）：
  · v1.0.16：8 次开打 → 7 次拿到判据（有泄漏/有 verdict），1 次中断
  · v1.0.17 测试版：**7 次开打 → 7 次全部在开打后中断（panic）**
  温度不是原因（用户是在降温后跑的，且 v1.0.16 反而是 panic 重启后直接跑）。
  差异在 v1.0.17 新增的重活：
  · `detectStatus` 被 `_pollShizuku` **每 3 秒**调一次，而它新增了 `pm list packages`
    （枚举全部包）与 `dumpsys package me.weishu.kernelsu`（整包 dump，几百毫秒 + 大量分配）；
  · `refreshHealth` 每 5 秒还会读 `/proc/slabinfo`（要拿 slab 锁）与 `dumpsys power`。
  这些在竞态窗口里反复分配/持锁 ⇒ 被 UAF 释放的 `posix_timers_cache` 页更容易被重新占用、
  写入垃圾 ⇒ 删除循环读到垃圾指针 ⇒ panic。
  修法：**跑链期间彻底静默**（3s 探测、5s 健康轮询全部跳过；`refreshHealth` 里也加 `running` 早退），
  并把 `detectStatus` 的 KSU 探测改轻量（`pm path` 代替 `pm list packages`；`dumpsys package`
  只在还没拿到版本时查一次）。
- **修「打开 App / 授权后不自动开始检测」**：5s 轮询的守卫是 `if (!shizukuOk) return`，
  而 `shizukuOk` 只在 `refreshHealth` 成功时才置位 ⇒ 死锁，永远不轮询。改成用
  `ShizukuShell.checkPermission()`（binder，不 spawn 进程）先翻状态；授权后立即刷一次。
- **防连点/连跑**：点一次「开始」后按钮立刻不可用；一轮结束进入冷却
  （成功 0s / 未成功 90s / **本轮检测到重启 180s**），按钮显示 `冷却中 123s` 倒计时，
  冷却期内 `start()` 也会直接拒绝。理由：每次 panic 重启都在重新加热机身，
  连点只会让设备在 68°C 上反复崩。
- **双包共存提醒**：`.debug` 测试包与正式包同时装着时，两个 App 各自的 3s/5s 轮询会一起往
  竞态窗口里 spawn shell（实测显著提高 panic 率）。② 预检会检测「正式包在运行」并提示：
  `am force-stop com.noworld.rootkit` 或临时卸载它。
- **开打前加温度闸（两级）**：**>40°C 只提醒**（照打，日志标 ⚠），**≥45°C 阻断**并等降温
  （10s × 30 = 最多 5 分钟）；5 分钟仍 ≥45°C **放弃本轮**并提示关屏静置 10–15 分钟。
  实测依据：连跑一小时后机身 68.2°C、load 19.7（8 核），此时连 v1.0.16 也开始 miss/panic ——
  过热硬打等于白烧一次重启。
- **「现状」并进状态条，一行看完**：原来「现状：…」单独占一行、且只有打开 App 的快照；
  现在并进温度那条状态带（`温度 · 唤醒 · 内存 · posix · cred · SELinux · KSU/模块 ·
  管理器 · su ✓/✗ · 资产 n/4 · 上次 panic · 内核`），与温度同一个 5s 轮询，不再单独占行。
- **打开 App 就显示上次重启类型**：`sys.resettype`（如 `abnormal:AP_S_PANIC`）不需要 root 就能读，
  探测时写进日志并在状态条显示「上次 panic」。
- **打开 App 就开始检测**：`shizukuOk` 之前只在「开始」时置位，导致 5s 轮询的守卫永远拦着；
  现在 `refreshHealth` 一旦拿到数据就置位，授权后立即开跑（不需要先点开始）。
- **ksud 用户态安装加两道闸**（因为测试版出现过早期 panic，怀疑与"往半加载的 KSU 模块发 prctl"有关）：
  · `/sys/module/kernelsu` 不存在 ⇒ 直接跳过（模块没真正注册，戳它会崩）
  · 每个 boot 只试一次（`/data/local/tmp/rk/.ksud_tried_<boot_id>` 标记），避免反复戳内核
- **检测逻辑按"是否在跑"分流**（最终版）：
  · **空闲期**：`startHealthPolling()` 每 5s 刷健康条（温度/内存/slab/SELinux）。
    打开 App、授权成功、切回前台都会立刻刷一次（不再等第一个 5s）。
  · **运行期**：回到 v1.0.16 的行为 —— `refreshHealth` / `detectStatus` **一律不跑**，
    只剩「开打前一次温度闸（`refreshHealth(force: true)` 的等价：直接读 thermal_zone0）」
    与 20s 心跳里的 prep；跑完一轮后再统一刷一次。
  · 统一判据 `chain.busy`（= running），以后接的更新检查/网络请求也必须先看它。
- **跑链时暂停轮询**：5s 一次的 shell spawn 会干扰竞态窗口（影响命中率/panic），运行期间自动停。
- **新增「上次重启现场」采集**（`[crash]`）：拿到 root 后读 `/sys/fs/pstore/console-ramoops*`、
  `/proc/last_kmsg`、`sys.resettype`，把 `Kernel panic / Unable to handle / BUG: / Call trace`
  的尾部十几行写进日志 —— 再遇到莫名重启，日志里直接有 panic 现场。
- **CI 构建告警清理**：`compileOptions` 保持 Java 8，用 `-Xlint:-options` 关掉
  `source value 8 is obsolete / target value 8 is obsolete` 这一类警告。
  **不能**直接把它提到 17：AGP 8.1.0 + JDK 21 下 target 17 会触发 `JdkImageTransform` → `jlink`，
  而 JDK 21 移除了 jlink 的 `system-modules` 插件 ⇒ 构建直接失败（已实测踩坑，见 build.gradle 注释）；
  真要升 17 必须同时升 AGP 8.6+ / Gradle 8.7+。
  `MaterialIcons-Regular.otf was tree-shaken … 99.7%` 是**正常提示**（图标字体按需裁剪，
  1.6MB → 4.8KB），加 `--no-tree-shake-icons` 只会让包变大。
- **测试包签名固定生效**：上一发验证 APK 的 `Signer #1 SHA-256` = `8F:CD:CE:47:…:D8:03:ED`，
  从此 PR 测试包可直接覆盖安装（`adb install -r`），不再 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`。
- **状态区（温度/唤醒/内存/slab/SELinux）改成每 5 秒主动刷新**
  之前只在「运行中」的 20s 心跳里刷，空闲时温度一直是打开 App 时的旧值。
  现在：前台每 5s 轮询（值没变化就不重绘整屏），回到前台立即刷一次，退到后台暂停；
  同理修复了「温度显示不跟着变」导致的误判（机身已经 60°C，界面还显示 42°C）。
- **测试包签名固定**（可覆盖安装）：见下条 commit 说明。
- **日志一键复制**：日志卡片头部新增「复制全部日志」，全屏/历史日志的复制按钮也统一走同一逻辑。
  复制内容是**自带上下文**的一段文本，直接贴进 Issue 就能定位：
  ```
  === 越狱助手 v1.0.17 日志 ===
  时间: 2026-10-26 14:03:21
  设备: SELinux=Enforcing · KSU 未加载 · KSU 管理器 v3.3.1 · su 不可用 · 资产 0/4
  失败阶段: ⑧ su 验证=su 不存在 | …
  lastError: …
  阶段: ①=ok ②=ok … ⑧=failed
  --- 日志 137 行 ---
  …
  ```
- **修 `vv3.3.1`**：Honor 的 `dumpsys package` 输出自带 `v` 前缀（`versionName=v3.3.1`），
  拼成 `" v$ver"` 就成了 `vv3.3.1`，还会让「管理器版本 ≠ 模板版本」假报警。现在统一规范化。
- 原设置快照的日志把 `null` 显示成 `(未记录)`（Shizuku 尚未授权时取不到值，属正常）。
- **⑦ 之后自动补做 KernelSU 的「用户态安装」**（这是本次真正的功能修复）
  依据 KernelSU 源码，`su` 是**虚拟**的：`kernel/feature/sucompat.c` 把 `/system/bin/su`
  在 `faccessat/newfstatat/execve` 上劫持到 **`/data/adb/ksud`**，且只有 `is_ksud_exists()`
  为真才劫持 ⇒ 没有 `/data/adb/ksud` 时 `su` 就是 `ENOENT`（用户日志里那句
  `su: inaccessible or not found`）。
  而 `/data/adb/ksud` 是**管理器**跑 `libksud.so install --libadbroot … --data-path …` 生成的
  （`userspace/ksud/src/utils.rs::install()`：把自己拷到 `/data/adb/ksud`、解 assets、建软链）。
  本版在加载完模块后**自己跑这一条**（我们此时已有 root），
  因此 **不需要点管理器的「安装」（那是解锁后改 boot.img 的注入流程）、也不需要解锁 BL**。
  流程：等 su → 仍无则跑 ksud install → 仍无才拉起一次管理器 → 复查，每步都记日志。
- **环境预检提前到 ② 一开始**（原来要跑到 ⑧ 才失败）：
  · **没装 KernelSU 管理器 ⇒ 直接拦下**并说明（`su` 由管理器释放，不装它整条链到 ⑧ 必没有 su，
    白跑 3–6 分钟）。要求 **KernelSU v3.3.1**（与本仓库 `ksu_template.ko` 同源），版本不同只警告。
  · 打印 `/data/adb/ksu` 是否已初始化、`su` 当前路径。
  · 启动探测（打开 App 即跑）的现状行也带上 `KSU 管理器 vX` / `su=路径`。
- **⑦ 的"模块是否真的加载成功"改成三元判定**（用户反馈：模块在 /proc/modules 里但 KSU 不可用）：
  · `/proc/modules` 有 `kernelsu`
  · `/sys/module/kernelsu` 存在（区分"载入即退出"的假成功）
  · `su` 是否存在（由管理器释放，与上两条无关）
  三者分别打日志，⑧ 失败时按三元组合给出不同结论。
- **新增分阶段自检日志（远程排障用）**：`[diag:env] / [diag:ksu] / [diag:verify-fail]`
  与 `[diag-root:*]`（走自己的 root shell），一次截图就能定位：
  · `ver= / zero= / alias= / phys=`：版本与零写落点（区分新旧版的关键）
  · 机型指纹、`uname -r`、`getenforce`、`id -Z`
  · 模块现状（`pwn*` / `kernelsu`）、KernelSU 管理器是否安装、`/data/adb/ksu` 是否存在
  · `su` 在 4 条候选路径上的 `ls -l` 结果
  · **内核镜像核对**：取 `_stext` 与 `selinux_state / init_task / commit_creds /
    prepare_kernel_cred / init_cred`，算相对偏移与内置标定比对，打印 `5/5 一致` 或逐个不一致项
    ⇒ 其它机型是否真的同一镜像，不用猜
- **⑧ 修复：su 不再只在 PATH 里找**。KernelSU 的 su 由管理器释放到 `/data/adb/ksu/bin/su`，
  有的机型在 `/system/xbin/su` 或 `/debug_ramdisk/su`；现在逐个试并记录每一条结果。
- **⑧ 失败原因直接写清楚**（不再只报「su 不可用」）：
  · 模块在、`/data/adb/ksu` 不存在 ⇒ 管理器没初始化（打开 KernelSU 按提示装一次）
  · 模块在、管理器没装 ⇒ 装管理器
  · 模块不在 ⇒ ⑦ 其实没成功
- **⑦ 之后等 su 最多 10s**（管理器释放 su 有延迟），并把 `[diag:ksu]` 落进日志。
- 版本号收口到 `lib/version.dart`（`chain.dart` 的日志也要用，避免循环 import）。

## v1.0.16 — 2026-10-25
- **修复：跑完链后相机崩溃 / 系统服务连环崩（本次核心）**
  根因：零写原语是 8 字节 store，之前直接写 `selinux_state` 基址，会连带清零 +1 的 `initialized`
  ⇒ 内核报 `security_sid_to_context_core: called before initializing` ⇒ **binder 取不到安全上下文**，
  于是系统服务成片失效：相机 HAL `CamX::Actuator::AcquireResources` 空指针（provider 段错误→
  `cameraserver` 把 22 个 device 全摘→相机 App 闪退）、`com.android.phone` 报
  `selinux_android_setcontext failed` 自杀、输入法/应用 `start timeout` 被 AM 杀。
  且**软重启不清内核**，所以「重启也修不好」，必须硬重启。
- 修法：零写落点从 `selinux_state` 改为 **`selinux_state − 7`**，8 字节覆盖 `[base−7 … base]`，
  最后一个字节恰好是 `enforcing`，`initialized`(+1) 与 `status_page`(+8) 完好；
  base−7…base−1 是 `avc_latest_notif_update.notif_lock`（未持锁全 0，本机未开 DEBUG_SPINLOCK/LOCKDEP）
  ⇒ 零写对它是 no-op。**做完仍是 Permissive（`getenforce`=Permissive），但 binder/AVC 正常工作。**
- 真机验证：同 boot 内 `dmesg` 的 `before initializing|failed to get security context` 从「成片」降到 **0**，
  相机正常出预览（devices=23），后续阶段与整链不受影响。

## v1.0.14 — 2026-10-25
- **GitHub 图标改用 flutter_svg 真 SVG 渲染**：`assets/github.svg`（simple-icons 的 GitHub mark）
  + `SvgPicture.asset(colorFilter: srcIn)`，跟随主题色、任意尺寸清晰（替代手写的 CustomPainter 解析器）
- 验证踩坑：`pm install -r` 后如果旧进程还活着，界面仍是旧代码 ⇒ 验证前必须 `am force-stop`
  （本次直接 uninstall + 重装确认）

## v1.0.13 — 2026-10-25
- **新增 GitHub 入口**：顶栏加 GitHub 图标按钮；「选项」弹窗底部也有一行「GitHub 项目主页」
  （用系统浏览器打开 `https://github.com/No-World/rootkit`，走 `Intent.ACTION_VIEW`，不加依赖）
- **CI 触发时机修正**：`build-release.yml` 只在**打 tag（v*）**或手动触发时构建并发布；
  push main 的编译校验交给 `build-debug.yml`（不再每次 push 都跑签名发布流程）

## v1.0.12 — 2026-10-25
- **修：免责声明标记写不进去**。`/data/local/tmp/rk/state` 目录的 SELinux 标签被子目录曾被
  root 域进程（KSU `su`）创建时写成 `u:r:kernel:s0`，之后 shell 用户在该目录连 `touch` 都
  `Permission denied`。标记文件改为直接放 `/data/local/tmp/rk/.disclaimer_hidden`
  （读取兼容旧路径），不再依赖子目录

## v1.0.11 — 2026-10-25
- **免责声明增加醒目升级提示**：橙框告警「如果你没打算 root，请立刻把系统升级到最新版本 ——
  不运行本工具不代表别人不会利用它」
- README 顶部同样加入该提示（含判断受影响的「安全补丁级别」路径与版本说明）

## v1.0.9 — 2026-10-25
- **资产已在位时不再重复写入**：`_runEnv` 逐文件比对大小，一致就跳过（省下 ~9MB 经 Shizuku 的写入时间）；
  校准照常执行（此前整体跳过 env 会导致校准跑不到）
- env 阶段被跳过时后续阶段仍可继续（门条件改为「完成或跳过」）

## v1.0.8 — 2026-10-25
- **打开即探测 + 已越狱即全绿**：`detectStatus()` 自上而下判定
  · su 可用 ⇒ 8 个阶段全部完成、状态「已越狱成功（无需操作）」、建议栏给 KernelSU/撤销指引
  · `/proc/modules` 有 `pwn*` 但无 `kernelsu` ⇒ ①–⑤ 置完成，从 ⑥ 起跑
- **Shizuku 授权状态主动轮询**（3 秒一次，掉线时用真实命令复核防抖）；切回前台立即刷新
- Shizuku 授权后自动探测一次设备现状，无需点「开始」
- 顶部按钮紧凑化（选项/重启内边距归零、Shizuku 宽 chip → 19px 盾牌图标）
- 去掉「设备状态读取中…」空壳占位

## v1.0.6 — 2026-10-24
- **跳过 = 完成态**：进度统计计入 skipped；图标改为对勾（略淡）；副标题「已满足（跳过）· 原因」；
  全部 ok/skipped 且空闲时顶部显示「已完成（含跳过）」

## v1.0.5 — 2026-10-24
- **启动状态探测** `detectStatus()`：SELinux / KSU 是否已加载 / su 是否可用 / root shell 在线 / 资产就位，
  顶部显示「现状：…」；已满足的阶段自动标 skip（①permissive、部署、⑤⑥、⑦）
- **重启改为下拉**：软重启（只重启框架，KSU 保留）/ 正常重启
- 成功后 `phase` 改为「越狱成功」，不再停在“验证 su”
- 版本号统一为常量 `kAppVersion`（此前标题写死 v1.0.0/v1.0.1 与实际不符）
- 校准：`module_layout CRC` 改由内核记录表提供（`koquery` 的 glob 在 Shizuku shell 下不展开）
- 长按标题可预览成功弹窗（不跑链即可验证 UI）


## v1.0.0 — 2026-10-24（首个正式版）
首个可用性达标的版本：**整链在 App 内一键完成**，从 permissive 一路到 KernelSU 自动跳转。

- 端到端：permissive → 候选 cred → 零写 cap_bset → 指针写 cap_effective → 自制模块 uid=0
  → ksupatch + KernelSU → `su -c id` 验证 → 自动打开 KernelSU
- 5 项自动校准（vermagic / tracepoint id / cred via BTF / module_layout CRC / 物理基址→别名），
  启动即校准；按内核版本记录表命中即跳过探测，未登记内核在环境检查阶段被拦住
- 离线符号表（394KB）+ KASLR slide，ksupatch 可脱离 root 使用
- 选项作用于运行前、结束自动恢复（屏幕超时 / 常亮 / 飞行 / WiFi / 蓝牙）
- 成功后清理原生件与临时文件（可关），停掉 5556 root shell
- UI：单屏不滚动、阶段进度弹窗、日志全屏（从卡片放大动效）、历史日志、首启免责声明、
  成功弹窗（含收款码，点击放大 / 长按保存到相册）
- CI：debug / release 两个 workflow，签名走 Secrets；正式版 17.9MB（arm64）

**签名指纹（v1.0.0）**：`CN=NoWorld RootKit`，SHA-256 `0e53f61ff75d021faa9abe480b3b4cba4a08bd1028e9065f3e5fdc8fce1ef866`
（keystore 不入库；升级安装必须使用同一 keystore，请自行备份）

## v0.3 — 2026-10-24
- **动效**：日志全屏改为「从日志卡片矩形放大」的自绘路由（`_ExpandFromRectRoute`，280ms/230ms，圆角+淡入，可反向收回）
- **成功弹窗**：加入微信/支付宝收款码（并排、点击放大可双指缩放、长按保存到相册 → 保存结果用**弹窗**提示，存至 `Pictures/RootKit/`）
- **成功后清理**：停 5556 root shell、删 `/data/local/tmp/rk` 原生件与 `/tmp` 临时文件（保留日志；新选项可关）
- **离线符号表**：`kallsyms_6.12.58.bin.gz` 从 1.07MB 压到 **394KB**（只留 T/D/B/R + KSU 所需 225 个白名单，缺失 0）
- **签名**：自建 release key（RSA4096，v2+v3），替代原来的 debug 签名
- **校准**：启动即自动校准；手填物理基址入口；按内核版本命中记录直接跳过探测

## v0.2 — 2026-10-24
- 5 项自动校准：vermagic / tracepoint id / cred 布局（真 BTF 解析）/ module_layout CRC / 内核物理基址→selinux 别名
- 选项作用于运行前，运行结束（成功/停止/失败）自动恢复原状
- 首次启动免责声明（含「不再显示」）
- 修 bug：别名算式 +0x10000、`pkill -x`、phase2 取最新 CRED、kcfi 判断提前、Shizuku 授权超时、部署字节校验、日志批量落盘、BTF 分块读、模块 `real_cred==cred`

## v0.1 — 2026-10-24
- 首个可运行版本：8 阶段状态机 + 命中率 + 建议 + 实时日志
- Shizuku 双接口（反射 `Shizuku.newProcess` / AIDL `IShizukuService.newProcess`）
- 资产 gz 内置（x645 / pc / module.ko / ml2 / ksupatch / ksu_template.ko / koquery）
- 包体积 43.6MB → 16.5MB（arm64 only + 资产 gzip）
