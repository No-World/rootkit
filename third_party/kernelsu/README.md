# KernelSU LKM — GPL-2.0 合规材料

本目录是 `assets/ksu_template.ko(.gz)` 的**对应源码与许可证说明**。

`assets/ksu_template.ko` 是 KernelSU v3.3.1 的官方预编译 LKM，按 **GPL-2.0** 分发；
本目录下的 `source/kernel/` 是该 LKM 的完整内核模块源码。

> ⚠️ **许可范围**：本目录下的 KernelSU 源码与 `COPYING` 是 **GPL-2.0**，
> 不是仓库根目录的 MIT。仓库其余原创代码仍按根 `LICENSE`（MIT）授权。

---

## 1. 分发的二进制

| 文件 | 说明 |
|---|---|
| `assets/ksu_template.ko` | KernelSU v3.3.1 官方 LKM，未修改 |
| `assets/ksu_template.ko.gz` | 上述文件的 gzip 压缩版（APK 内使用） |

- 上游 Release：<https://github.com/tiann/KernelSU/releases/tag/v3.3.1>
- 官方资产：`lkm-aarch64-android16-6.12_kernelsu.ko`
- 官方资产 SHA256：`7e25d68419d08535d35e3630d9f0ff1a08e97a7026d36e878991eecb13554d9f`
- 本仓库的 `assets/ksu_template.ko` 与该资产**逐字节一致**（可用 `sha256sum` 核对）。

## 2. 对应源码

- 上游 tag：`v3.3.1`
- commit：`0c0fdb960178fa12d80d6cbcfdcb6ad8be6a865d`
- 源码 tarball：<https://github.com/tiann/KernelSU/archive/refs/tags/v3.3.1.tar.gz>
- tarball SHA256：`c5fae490867afe789b15805b3839578db0e295ea59a75040b95829ec7e475c52`
- 本目录 `source/kernel/` = 上述 tarball 中的 `kernel/` 目录（完整 LKM 源码，未修改）。
- `COPYING` = 上游 `kernel/LICENSE`（GPL-2.0）。

> **可移植性说明**：上游 `kernel/include/uapi` 是指向 `../../uapi` 的符号链接。
> 为了让 Windows 检出也能直接构建，本仓库把它落成了真实目录，
> 内容与上游 `uapi/` 逐文件一致（未改代码）。

## 3. 运行期修改

`assets/ksu_template.ko` 本身未修改。运行期由：

- `tools/ksupatch.c`（MIT）把 LKM 的 UND 符号改成目标内核
  `/proc/kallsyms` / 离线符号表里的绝对地址（`SHN_ABS`）；
- `tools/modload.c`（MIT）调用 `finit_module` 加载（产物名 `ml2`）。

这两个工具是 RootKit 的原创代码，不是 KernelSU 的一部分；它们只负责在设备上
把官方 LKM 适配到目标内核。`tools/koquery.c`（读取 `.ko` 的 vermagic /
`module_layout` CRC）同样是 MIT。

## 4. 重新构建

见 [`BUILD.md`](BUILD.md)。官方 Release 资产由上游 CI 构建；本地重建需要
DDK + Android 16 / 6.12 KMI，不保证与官方资产逐字节相同。

## 5. 源码提供承诺

见 [`SOURCE_OFFER.md`](SOURCE_OFFER.md)。本目录已包含对应源码；如仍需书面提供，
可通过 GitHub Issues 联系。

## 6. 文件清单

```
third_party/kernelsu/
├── README.md          本文件
├── COPYING            GPL-2.0 全文（来自上游 kernel/LICENSE）
├── NOTICE             来源、版本、哈希、修改说明
├── BUILD.md           从源码构建 LKM 的步骤
├── SOURCE_OFFER.md    GPL-2.0 §3(b) 源码提供承诺
├── SHA256SUMS         分发二进制的哈希
├── source/
│   ├── LICENSE        GPL-2.0（副本）
│   └── kernel/        v3.3.1 的完整 LKM 源码
└── tools/
    ├── README.md      运行期工具的 MIT 说明
    ├── ksupatch.c     UND → SHN_ABS
    ├── modload.c      finit_module 加载器
    └── koquery.c      .ko 元信息读取
```
