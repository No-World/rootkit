# 路线与风险评估

> 状态：整链在本机（MLY-AN00 / 6.12.58）已跑通并**在 App 内自动完成**（permissive → cred 两阶段写 →
> 自制模块 uid=0 → KSU 装载 → `su -c id` 返回 `uid=0 … context=u:r:ksu:s0` → 自动跳转 KernelSU）。

## 1. 已完成（可复现）

| 能力 | 判据 |
|---|---|
| 零写 / 指针写原语 | `*(T)=0`（mode 4）、`*(P+8)=C`（mode 3） |
| cred 两阶段 | 目标进程自报 `CAPBND_ZERO` / `CAPEFF_OK` |
| 自制内核模块加载 | `finit ret=0`、`/proc/modules` 出现模块、`uid=0` |
| KSU 装载 | `/proc/modules` 出现 `kernelsu`、`su -c id` 通过 |
| 跨内核适配基建 | 5 项自动校准 + 内核版本记录表 + 离线符号表 |

## 2. 近期路线

### 2.1 适配其他内核（按工作量排序）

| 步骤 | 需要什么 | 工具 |
|---|---|---|
| 生成该内核的离线符号表 | 一次 `/proc/kallsyms` 转储（或从镜像提取） | `scripts/mk_symtab.py` |
| 登记物理基址 | 该机 `boot.img` 推导，或 root 下 `/proc/iomem` 的 `Kernel code` | `known_kernels.dart` 加一条 / App 内手填 |
| 校验 cred 布局 | 有 `/sys/kernel/btf/vmlinux` 则自动；无则看 `cred_jar` objsize | 校准项 ③ |
| 校验模块门槛 | kCFI typeid、`.plt`、`module_layout` CRC | 校准项 ④ + `koquery` |
| 其它 | `selinux_state` 偏移、`task_struct->cred/real_cred` 偏移 | BTF 或镜像反汇编 |

> 未登记的内核会在「环境检查」被**拦住**（不会盲写错误地址）。

### 2.2 rootless 装载路径

现状：`ksupatch` 读 `/proc/kallsyms` 需要 root；离线表模式需要 KASLR slide。
slide 目前只在有 root 时取（`_stext`）。若要完全脱离 root：

1. `slide` 由 tracefs `sched_blocked_reason` 的 caller 地址推导（该通道对 shell 可写，已在本机验证过可行性）；
2. 推导结果与离线表配合即可在**仅有 CAP_SYS_MODULE**（第④步之后）时装载 KSU。

收益：不依赖 5556 root shell，减少一个失败面；风险：tracefs 输出格式随内核版本变化，需要兜底。

### 2.3 稳定性

- 命中后 5–9 分钟的延迟 panic 是**固有副作用**（timerqueue 被写坏）。可选缓解：
  命中后立即主动 `reboot`（牺牲一轮），或让最后一次写不破坏 `root->rb_node`。
- 设备重启后 `pm install` 的包可能消失（系统侧回滚 `/data/system` 类状态，连用户卸载的预装应用也会恢复）。
  对策：APK 常驻 `/data/local/tmp/rk_latest.apk`，重启后 `pm install -r` 即可。

### 2.4 体验

- 已做：阶段弹窗、日志全屏（从卡片放大）、历史日志、成功后清理、选项自动还原、免责声明、收款码
- 待做：命中率曲线可视化（按温度/唤醒状态分组统计）、失败原因归类报表

## 3. 风险表

| 风险 | 等级 | 现状 / 缓解 |
|---|---|---|
| 命中后 panic 重启 | 高（固有） | 明确提示；链设计为跨 boot 可重来 |
| permissive 破坏 SELinux context | 高 | 模块 init 写回 `initialized=1`；App 提前提示「中断请用正常重启」 |
| 未知内核写错地址 | 高 | 环境检查**拦截**；别名与 kallsyms 交叉校验 |
| 目录 `777` 导致任何 App 可替换原生件提权 | 中 | 已收紧为 `755`，并在执行前做字节校验 |
| KSU 管理器与 LKM 版本不匹配 | 中 | 判据是 `/proc/modules` + `su`；不匹配直接失败并提示 |
| 公开仓库泄露载荷/私钥 | 中 | 载荷与 keystore 均不入库；私钥已从历史清除；CI 走 Secrets |
| Shizuku 未运行 / 未授权 | 中 | 双超时 + 徽章可点；支持用 `libshizuku.so` 免 WiFi 启动 |

## 4. 明确不做 / 不可达

- **不碰 boot/系统分区**：BL 锁定 + dm-verity，无法做持久化 root（KSU 为 LKM 模式，重启即失效）。
- **不修改 KSU 源码**：只用官方 LKM + 符号绑定，避免长期维护 fork。
- **不做静默提权**：成功判据必须由目标进程自报，避免“判据污染”类误判。

## 5. 三个高代价问题的归类

1. **判据被污染**（用会被副作用影响的量作为 oracle）⇒ 得出的结论整体失真，而表面上呈“成功”状态。
2. **停止/清理不可靠**（`pkill -f` 自匹配）⇒ 残留进程持续运行，污染后续轮次，被误读为命中率下降。
3. **段表被工具改坏**（`objcopy --update-section`）⇒ 报 relocation 错误，但符号表看起来完全正常。

应对：判据只用目标自报；`pkill -x` 精确匹配；模板一律用原始 `.ko`。
