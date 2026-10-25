# RootKit 架构（Flutter + Shizuku）

## 1. 总体分层

```
┌──────────────────────────────────────────────┐
│ Flutter UI（lib/main.dart）                   │
│  · 单屏不滚动：状态卡 / 建议卡 / 日志卡        │
│  · 阶段进度=弹窗；日志=全屏(从卡片放大动效)     │
│  · 选项：自动点屏 / 常亮 / 关 WiFi·蓝牙 / 清理  │
└───────────────┬──────────────────────────────┘
                │ MethodChannel("rootkit/shizuku")
┌───────────────▼──────────────────────────────┐
│ Kotlin 通道（MainActivity.kt）                │
│  · run(cmd, stdinB64, timeoutMs) → {code,out,err,via}│
│  · 双接口自动适配（见 §2）                     │
│  · saveImage(asset,name)：assets → MediaStore  │
│  · filesDir / getPref / setPref / openApp      │
└───────────────┬──────────────────────────────┘
                │ Shizuku（shell, uid 2000）
┌───────────────▼──────────────────────────────┐
│ 设备侧（/data/local/tmp/rk）                   │
│  x645  exploit        pc  候选探针             │
│  module.ko 自制模块   ml2 finit 加载器          │
│  ksupatch / koquery  KSU 打补丁 / 读 CRC        │
│  ksu_template.ko 官方 LKM  ksyms.bin.gz 符号表 │
└──────────────────────────────────────────────┘
```

## 2. Shizuku 双接口

| 路径 | 说明 |
|---|---|
| `Shizuku.newProcess()`（反射调用，13.1.5 里是 private） | 首选；返回标准 `Process`，流读写简单 |
| `IShizukuService.newProcess()` → `IRemoteProcess`（AIDL 直连） | 兜底；注意不同 Shizuku 版本的 `waitForTimeout` 签名可能不兼容（曾出现 `No enum constant TimeUnit`） |

`run()` 依次尝试，成功即把 `via` 字段回传，界面/日志可显示当前走的是哪条路径。
失败信息（含异常栈前 3 行）原样回传，便于定位是权限、版本还是命令本身的问题。

## 3. 阶段机（lib/chain.dart）

```
env(部署+校准) → ①permissive → ②probe cred → ③零写 cap_bset
        → ④指针写 cap_effective → ⑤模块→uid0 → ⑥KSU → ⑦su 验证
```

设计要点：

- **每阶段独立状态**：`pending / running / ok / failed`，带 `tries/hits/runs` 与明细；
- **`guarded()` 包裹**：阶段抛异常只标该阶段失败；函数正常返回却没置状态 ⇒ 记为「未完成」，
  不会静默停在 pending（否则界面会一直显示“执行中”且无错误）；
- **判据一律来自目标进程自报**（如候选进程自己读 `/proc/self/status`），不依赖外部 oracle；
- **重启感知**：每步比对 `boot_id`，一旦变化立即停止并提示；
- **重复执行安全**：模块名每轮随机（`pwn4` → `pwnX`）、日志文件名带毫秒+序号、
  起候选前 `pkill -x pc`、每发前后 `pkill -x x645`。

## 4. 资产流水线

1. 构建期：二进制放 `assets/`，除 `module.ko` 外都 `gzip -9`（APK 内体积 17.9MB → 见 §6）；
2. 运行期（env 阶段）：`cat > 文件`（stdin 传 base64 二进制）→ `chmod 755` → `wc -c` 校验字节数
   （只校验文件名会把“半截文件”判成成功）；
3. 目录权限 `755`：该目录里的二进制会被 **root shell 以 root 执行**，
   若为 `777`，任何 App 都能替换 `ksupatch`/`ksu_template.ko` 实现提权；
4. 成功后（可选）：停 5556 root shell、删除原生件与 `/tmp` 临时文件，仅保留日志。

## 5. 5 项自动校准（lib/calib.dart + lib/known_kernels.dart）

| # | 项 | 来源 | 失败兜底 |
|---|---|---|---|
| 1 | vermagic | `/proc/version` | 用默认值并标红 |
| 2 | tracepoint id | `/sys/kernel/tracing/events/kmem/kmem_cache_alloc/id` | 沿用 324 |
| 3 | cred 布局 | **真 BTF 解析** `/sys/kernel/btf/vmlinux`（扫 STRUCT `cred` 成员） | `cred_jar` objsize + 标准布局 |
| 4 | module_layout CRC | 任意 vendor `.ko` 的 `__versions`（`koquery`） | 用内置值 |
| 5 | 内核物理基址 → selinux 别名 | **按内核版本命中内置记录**（`known_kernels.dart`） | `su -c 'grep "Kernel code" /proc/iomem'` → 成功则存为该版本记录；否则**阻止运行**，提示手填 |

- 校准结果持久化（含 `bootId`）；启动时若「首次 / 换 boot / 有失败项」自动重探；
- 别名算式：`alias = PAGE_OFFSET - memstart + physBase + 0x10000 + selinux_state_offset`
  （`0x10000` 是 `_stext - _text`），并用 `/proc/kallsyms` 的 `selinux_state` 交叉校验，不符即标红；
- 手填物理基址会按内核版本存成自定义记录，下次同内核直接命中。

## 6. 体积

| 阶段 | APK |
|---|---|
| `flutter create` 默认（3 ABI + 未压缩资产） | 43.6MB |
| 仅 arm64 + 资产 gzip | 16.5MB |
| + 离线符号表（1.07MB gz） | 19.1MB |
| 符号表瘦身到 394KB（只留 `T/D/B/R` + KSU 所需 225 个白名单） | **17.5MB** |
| + 收款码（2 张 512×512） | 17.9MB |

## 7. 失败面与提示

| 现象 | 根因 | App 的处理 |
|---|---|---|
| `Shizuku 未授权` | 未在 Shizuku 弹窗里允许 | 徽章可点，触发授权；Kotlin 侧 10s、Dart 侧 20s 双超时，避免永久挂起 |
| `资产部署失败` | 目录不可写 / 传输截断 | 逐文件 `wc -c` 比对字节数 |
| 阶段① 长时间不命中 | 息屏/doze、机身过热、射频干扰 | 每轮自动点屏；健康卡显示温度/唤醒/内存/posix slab；建议卡给出可操作项 |
| ⑥ `kernelsu 未加载` | kallsyms 不可读 / 符号缺失 / 版本不符 | 先真地址、失败自动切离线表+slide；失败时把 `PATCH_RC / LOAD_RC` 写进阶段明细 |
| 命中后设备重启 | timerqueue 被写坏的固有副作用（5–9 分钟） | 检测 `boot_id` 变化并提示；界面提供「重启」按钮做正常重启 |
