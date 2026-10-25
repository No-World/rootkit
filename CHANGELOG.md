# 变更记录

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
