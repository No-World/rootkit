# RootKit · 越狱助手（Flutter + Shizuku）

> ## ⚠️ 先看这一条：不打算 root 的话，请直接升级系统
>
> 本工具利用的是内核漏洞 **CVE-2026-64560**（`posix-cpu-timers` 在 exec 竞态下的 use-after-free）。
> **只要系统没打补丁，任何一个普通 App 都能拿它提权** —— 也就是说：
> **你不运行本工具，不代表别人不会用它。**
>
> | 你的情况 | 该做什么 |
> |---|---|
> | 只是好奇 / 不打算长期 root | **立刻升级系统**（设置 → 系统和更新 → 软件更新），升级后本工具失效 —— 这正是你要的结果 |
> | 明确要 root、并接受风险 | 继续往下读；但请**先备份数据**，并知道这里记录的全部副作用 |
>
> - 判断是否受影响：设置 → 关于手机 → **Android 安全补丁级别**。本项目实测机型为
>   MagicOS 11.0.0.110 / **ASB-2026-09**，**该版本仍受影响**；厂商通常在此之后的补丁里修复。
> - 升级后一般无法回退到低版本，root 状态也会一并消失（这属于"恢复原厂安全状态"）。
> - 本工具会把设备置为 `SELinux=Permissive` 并加载自制内核模块，**这会削弱整机安全性**，
>   请只在自有设备、且清楚后果的前提下使用；公共设备、他人设备一律不要用。

---

把本项目的 root 链（CVE-2026-64560 → cred 两阶段写 → 自制内核模块 → KernelSU LKM）
打包成手机端 App：**Shizuku 提供 shell 身份，App 负责编排、显示阶段/状态/成功率/建议**，
KSU 加载成功后自动跳转 KernelSU。

| 关键指标（实测） | 数值 |
|---|---|
| 单发命中率 | ① permissive **77%**（24/31）· ③④ cred 写 **59%**（57/96） |
| 单轮（一次运行）成功率 | **≈65%**（唯一损失是命中后 landing 失败导致的内核 panic 重启） |
| 3 轮内成功率 | **≈96%** |
| 一次提权耗时 | 顺利 ≈3 分钟 · 中位 **≈4 分钟** · 不顺 ≈6 分钟（每发爆破固定 16.4 秒） |
| 已知副作用 | 命中后 5–9 分钟内有概率 panic 重启；`selinux_state.initialized` 被清零（模块加载后恢复） |

---

## 1. 它做什么

```
   环境检查 · 资产部署   （x645 / pc / module.ko / ml2 / ksupatch / ksu_template.ko → /data/local/tmp/rk；
                          资产已在位时逐文件比对大小跳过写入，校准照跑）
① SELinux → Permissive   （零写 selinux alias，最多 4 轮 × 4 发，单发 77%）
② 候选进程捕获 cred      （perf kmem_cache_alloc(324) + 一次成功 capset）
③ 零写 cap_bset          （cred+0x48 = 0，最多 3 轮 × 8 发，按 bit16 排序目标）
④ 指针写 cap_effective    （cred+0x40；必须 mode 4，mode 3 在 parent=0 时会写 0x8 触发 panic）
⑤ 加载模块 → uid=0       （候选自己 finit_module；模块做 uid=0 + 全 caps + 恢复 selinux initialized + 起 5556 root shell）
⑥ 补丁 + 加载 KernelSU   （ksupatch 写 kallsyms 绝对地址 + ml2 装载 LKM，allow_shell=1）
⑦ su 验证 · 跳转         （su -c id 通过 → 自动打开 KernelSU；成功后状态变为「越狱成功」）
```

界面上每个阶段有：**状态**（待执行/进行中/成功/失败）、**命中率**（tries/hits）、
**当前建议**（基于命中率、是否重启、失败阶段给出可操作提示），底部实时日志。

---

## 2. 环境要求

- 设备：**仅本机内核镜像** —— 荣耀 Magic9（MLY-AN00），
  `6.12.58-android16-6-g3a7ac1674240-abogki541502914`（MagicOS 11.0.0.110 / ASB-2026-09）。
  - 判据是**完整 vermagic 字符串**，不是"6.12.58"这个大版本：
    同型号 OTA 换了内核构建号、或其它荣耀机型的 6.12.58，都会因为
    `physBase` / `selinux_state` 偏移 / 模块 vermagic / 离线符号表 不同而**在「环境检查」被拦住**；
  - 想支持别的内核，按 [§6 适配其他内核](#6-适配其他内核换机型--换内核版本) 重做 5 项标定；
- **Shizuku** 已安装并运行（无线调试启动；重启后需重新启动）；
- 本 App 首次运行需在 Shizuku 弹窗里授权。

> 说明：App 以 **shell（uid 2000）** 身份执行（Shizuku 通道），与 `adb shell` 等价；
> 不需要电脑参与。

---

## 3. 构建

```bash
cd rootkit          # 本仓库根目录
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

依赖：Flutter 3.24.5、JDK 21、Android SDK（compileSdk 随 Flutter）、Shizuku AAR（Maven Central）。

```bash
bash scripts/prepare_assets.sh                              # 从 ../cve-2026-64560 生成原生载荷
cp android/key.properties.example android/key.properties    # 填自己的 keystore（本地签名用）
```
签名来源优先级：**环境变量 > `android/key.properties` > debug 签名**。

> 仓库里的 `assets/qr_wechat.png` / `assets/qr_alipay.png` 是**中性占位图**（不含任何个人信息）；
> 官方构建时由 CI 用 Secrets `QR_WECHAT_B64` / `QR_ALIPAY_B64` 覆盖成真实收款码。

关键改动点（相对 `flutter create` 模板）：
- `android/app/build.gradle`：`minSdk=26` + `dev.rikka.shizuku:api/provider:13.1.5`
- `AndroidManifest.xml`：`rikka.shizuku.ShizukuProvider`（authorities `${applicationId}.shizuku`）
- `lib/shizuku.dart`：MethodChannel（check/request/run/openApp/getPref/setPref）
- `android/.../MainActivity.kt`：`Shizuku.newProcess(["sh","-c",cmd])`，支持 stdin 传资产
- `lib/chain.dart`：阶段机 + 重试 + 命中率统计 + 建议
- `assets/`：x645(exploit)、pc(候选探针)、module.ko(pwn4 模块)、ml2(加载器)、ksupatch、ksu_template.ko

---

## 4. 使用要点

- **打开 App 会先探测现状**（Shizuku 授权后自动执行，无需点开始）：顶部显示
  `现状：SELinux=… · KSU 已/未加载 · su 可用性 · 资产 n/4`。
- **已满足的阶段自动跳过并显示为完成态**（对勾 + 「已满足（跳过）· 原因」，进度计入 n/8）：
  | 探测结果 | 跳过 |
  |---|---|
  | `su -c id -u` = 0 | **全部跳过**，状态直接「已越狱成功（无需操作）」，点开始也只弹成功窗 |
  | `/proc/modules` 有 `pwn*` 但无 `kernelsu` | ①–⑤ 全跳过，从 ⑥ 起跑 |
  | `getenforce` = Permissive | ① |
  | 资产已在 `/data/local/tmp/rk` | 重复写入（仍校验大小，校准照跑） |
- **Shizuku 授权状态每 3 秒轮询**：右上角盾牌 绿=已授权 / 橙=未授权（掉线后自动恢复）。
- **右上角重启是下拉菜单**：软重启（只重启系统框架，KSU 模块保留）/ 正常重启。
- **每次重启后**：Shizuku 会停 → 重新启动 Shizuku → 打开本 App → 点「开始越狱」。
- 单轮约 3–6 分钟；失败会按阶段重试，日志里能看到 `CAPBND_ZERO` / `CAPEFF_OK` / `ROOT_OK` 等判据。
- 中途设备若 panic 重启（命中后的延迟崩溃，历史规律 5–9 分钟），App 会提示"设备重启，需重新启动 Shizuku"。
- 成功后：`su` 可用（`allow_shell=1`，shell 免审批），App 自动跳到 KernelSU；
  KSU 面板会显示「工作中 [越狱模式]」。
- 同一个 boot 内重复运行：模块名会随机化（`pwn4` → `pwnX`），避免 EEXIST。

---

## 5. 已知限制

- **跑完链后个别系统 App 异常**（v1.0.15 及更早的已知问题，**v1.0.16 已修**）：
  相机闪退、电话自杀、输入法/应用「启动超时」。根因是 permissive 的 8 字节零写把
  `selinux_state.initialized`（+1）一起清零，导致 binder 取不到 SELinux 上下文。
  修复后零写落点改为 `selinux_state − 7`，只清 `enforcing`。
  若你用的是旧版并已中招：**硬重启**恢复（软重启只重启 zygote，内核状态不变，无效）。


- **单轮成功率 ≈65%**：唯一的统计性失败是"命中后 landing 失败 → 内核 panic 重启"（实测约 35%/轮）；
  重启后需 `pm install -r` 重装（APK 常驻 `/data/local/tmp/rk_latest.apk`，约 30 秒），然后重跑。
- 命中率受屏幕/温度/射频影响（App 每轮前会自动点屏 + 开飞行模式）；
- permissive 零写会清掉 `selinux_state.initialized`，本链用 pwn4 模块在拿到 root 后恢复；
- KSU 用的是 6.12.76 官方 LKM + kallsyms ABS 静态绑定（本机 69 个符号未导出），
  模块与内核结构体若有差异可能崩，属已知风险。


---

## 6. 适配其他内核（换机型 / 换内核版本）

App 里所有与内核强绑定的东西都集中在 5 个地方，换内核就是把这 5 处重新标定：

| # | 需要标定的东西 | 来源 | 工具/文件 | 错填的后果 |
|---|---|---|---|---|
| 1 | 内核版本 token | `/proc/version` | `lib/known_kernels.dart` | 与记录不匹配 → 环境检查阶段直接拦住 |
| 2 | **物理加载基址** | 该机 `boot.img`（`init_boot.img` **不含内核**，别拿错） | `known_kernels.dart` 加记录，或 App 内「手填物理基址」 | 别名算错 → 零写到错误地址 → 命中即 panic |
| 3 | `selinux_state` 偏移 | BTF 或镜像反汇编 | `KnownKernel.selinuxStateOffset` | 同上 |
| 4 | `module_layout` CRC | 任意 vendor `.ko` 的 `__versions` | `koquery`（App 校准项 ④）/ 内置值 | 模块装载被拒（`no symbol version`） |
| 5 | 离线符号表 | 一次 `/proc/kallsyms` 转储 | `scripts/mk_symtab.py` | ⑥ KSU 绑定失败（写不到正确函数地址） |

### 6.1 步骤

**① 取内核版本与物理基址**

```bash
# 版本
adb shell cat /proc/version
#   → 6.12.58-android16-6-g3a7ac1674240-abogki541502914-4k

# 物理基址：从 boot.img 解出 kernel，按 _text 的链接基址反推（本项目用 ghostlock-extract）
# 已知一台就够，写进记录表：
```
```dart
// lib/known_kernels.dart
KnownKernel(
  version: '6.12.58-android16-6-g3a7ac1674240-abogki541502914',
  physBase: 0xC7800000,
  selinuxStateOffset: 0x27D7A60,
  moduleLayoutCrc: 0x797f2b3e,
  note: 'MagicOS 11.0.0.110 (MLY-AN00)',
),
```
> 未登记的内核会在「环境检查」**被拦住**，不会盲写错误地址；手填后会按内核版本存成自定义记录。

**② 生成离线符号表**（⑥ 用）

```bash
adb shell su -c 'cat /proc/kallsyms' > kallsyms_<ver>.txt      # 需要一次 root，或用镜像提取
python3 scripts/mk_symtab.py kallsyms_<ver>.txt assets/kallsyms_<ver>.bin.gz
```
- 解析时**必须跳过 `[modname]` 行**：模块里的同名 static 符号会 last-wins 覆盖核心导出，
  导致 ⑥ 写到模块自己的假地址。
- 表里有 69 个**未导出**符号（`ksupatch` 用绝对地址绑定），所以符号表是必需的，不能靠 `kallsyms_lookup_name`。

**③ 校准 cred 布局 / tracepoint id**（App 自动，可在日志核对）

| 项 | 期望 | 读法 |
|---|---|---|
| `sizeof(struct cred)` | 184 | `/sys/kernel/btf/vmlinux` 的 STRUCT `cred`（BTF kind 编号易错） |
| `fsuid` / `cap_effective` / `cap_bset` | `0x20` / `0x40` / `0x48` | 同上；无 BTF 时用 `cred_jar` 的 objsize 兜底 |
| `kmem_cache_alloc` tracepoint id | 324（本机） | `/sys/kernel/tracing/events/kmem/kmem_cache_alloc/id`（不可读时用默认值） |

**④ 模块编译门槛**（`assets/module.ko`）

| 门槛 | 做法 |
|---|---|
| vermagic | 与内核完全一致（含 `-4k` 后缀，**拼接前先剥掉**，否则出现 `-4k-4k`） |
| `__versions` | **用原始 `.ko` 当模板**重写 CRC；**不要用 `objcopy` 注入 `__versions`** —— 会重排段表，链接报 `overflow in relocation type 261` |
| `__kcfi_typeid_*`（27 个） | **保留原值**；清零会让 PREL32 溢出 |
| `.plt` | 目标内核若无 PLT，需 `-fno-plt` 或用直接调用形式 |

**⑤ KernelSU LKM 绑定**（⑥）

两条路：
- **官方 LKM + `ksupatch`**（本项目在用）：`ksupatch` 把 `.ko` 里的符号重定位改成 kallsyms 绝对地址，
  `ml2` 再 `finit_module`；需 root 才能读 `/proc/kallsyms`；
- **改 vermagic 直接装**：`.modinfo` 段可搬移重写，但 MODVERSIONS CRC 必须与目标内核一致，否则 `invalid module format`。

### 6.2 验证顺序（别跳步）

1. **QEMU 离线**（里面是 root，可随便折腾）：
   - `slub_debug=FZPU` 判 UAF 是否真的发生；
   - `/proc/pagetypeinfo` 判释放页进的 migratetype 桶对不对（`page_alloc.shuffle=0` 做 A/B）；
2. **真机判据**：`/proc/sys/kernel/random/boot_id` 连读两次不同 ⇒ 零写成功（`proc_do_uuid` 的 `data==NULL` 分支）；
   > 不要用 boot_id 当 landing 判据（会被前一次的写污染），landing 看载体页里 node 自写地址能否读回。
3. **小步上真机**：先只跑 ①（permissive），确认 `getenforce` → Permissive，再跑后面的阶段。

### 6.3 常见坑

| 坑 | 后果 | 规避 |
|---|---|---|
| 用 `init_boot.img` 提内核 | 拿不到 kernel，physBase 全靠猜 | 只用 `boot.img` |
| vermagic 重复拼 `-4k` | 模块 `invalid module format` | 拼接前剥后缀 |
| `objcopy` 注入 `__versions` | 段表重排 → 重定位溢出 | 以原始 `.ko` 做模板重写 |
| 清 `__kcfi_typeid_*` | PREL32 溢出、装载崩 | 保留原值 |
| kallsyms 解析没跳 `[modname]` | 符号被模块 static 覆盖 | 过滤 `[` 开头的行 |
| `mode 3` 在 `parent=0` 时用 | 写 `*(0x8)` → NULL 解引用 panic | 指针写一律 `mode 4` |
| 资产重复写（9MB 经 Shizuku） | 拖慢且自身成为干扰源 | 逐文件比对大小，一致就跳过 |

> 更细的推导过程（每个偏移怎么来、哪些路已证伪）见 [`docs/03-roadmap.md`](docs/03-roadmap.md)
> 与 [`docs/01-cve-2026-64560.md`](docs/01-cve-2026-64560.md)。


## 依赖与来源

### 运行时 / 构建依赖

| 依赖 | 版本 | 仓库 |
|---|---|---|
| Flutter SDK | 3.24.5 | https://github.com/flutter/flutter |
| flutter_svg | ^2.1.0 | https://github.com/dnfield/flutter_svg |
| Shizuku API / Provider | 13.1.5 | https://github.com/RikkaApps/Shizuku-API |
| Shizuku（App，需用户安装） | 13.x | https://github.com/RikkaApps/Shizuku |
| KernelSU（LKM 模板） | v3.3.1（官方 6.12.76 LKM，改写 vermagic 后使用） | https://github.com/tiann/KernelSU |
| Android Gradle Plugin / SDK | minSdk 26 · targetSdk 34 | https://android.googlesource.com/platform/tools/base/ |

### 素材 / 规范

| 素材 | 用途 | 来源 |
|---|---|---|
| `assets/github.svg` | 顶栏 GitHub 猫图标 | https://github.com/simple-icons/simple-icons（CC0） |
| 漏洞编号 CVE-2026-64560 | 内核 `posix-cpu-timers` 在 exec 竞态下的 UAF | 本项目自研 PoC，见 [`docs/01-cve-2026-64560.md`](docs/01-cve-2026-64560.md) |
| `assets/` 下的原生载荷 | exploit / 候选探针 / 内核模块 / 加载器 / 符号表 | 本项目自行编译，源码在 [`../cve-2026-64560`](../cve-2026-64560)（同仓库另一目录） |

### 本项目

- 仓库：https://github.com/No-World/rootkit
- 问题反馈：https://github.com/No-World/rootkit/issues

## 贡献与分支规则

`main` **只接受 PR 合并和发版**，不接受直接推送；新功能/修复一律开分支走 PR，
CI `build-debug` 绿了才合并。发版 = 合并进 `main` → 打 tag → 发布 Release（CI 自动构建并挂 APK）。

完整流程见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 技术资料

| 文档 | 内容 |
|---|---|
| [`docs/01-cve-2026-64560.md`](docs/01-cve-2026-64560.md) | 漏洞机制、两个写原语、cred 两阶段写、模块加载三门槛、KSU 三种符号绑定、实测量化 |
| [`docs/02-architecture.md`](docs/02-architecture.md) | App 架构：Shizuku 双接口、阶段机、资产流水线、5 项自动校准、体积与失败面 |
| [`docs/03-roadmap.md`](docs/03-roadmap.md) | 适配其他内核的步骤、rootless 路径、稳定性与风险表、明确不做/不可达的项 |
