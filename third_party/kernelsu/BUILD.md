# 从源码构建 KernelSU v3.3.1 LKM

`source/kernel/` 是 KernelSU v3.3.1 的完整 LKM 源码。官方 Release 资产由上游 CI
（DDK）构建；下面是等价的本地方案。

## 依赖

- Linux 构建机（x86_64）
- Android NDK / clang（与目标 KMI 匹配）
- [DDK](https://github.com/5ec1cff/ddk)
- Android 16 / 6.12 KMI（DDK 会下载对应的 GKI 内核树）

## 构建

```bash
cd source/kernel

# 方式 A：DDK
ddk build android16-6.12 "ODIR=$PWD/out" -e CONFIG_KSU=m
llvm-strip -d out/kernelsu.ko

# 方式 B：使用上游脚本
./build-all.sh android16-6.12
```

产物：`kernelsu.ko`（或 `kernelsu-android16-6.12.ko`）。

## 校验

```bash
modinfo kernelsu.ko | grep -E 'vermagic|name|license'
sha256sum ../../assets/ksu_template.ko
```

官方 v3.3.1 资产的 SHA256 为
`7e25d68419d08535d35e3630d9f0ff1a08e97a7026d36e878991eecb13554d9f`。
本地重建因工具链/内核树差异，哈希可能不同，属正常。

## 运行期适配

```bash
# 目标设备上（需能读 kallsyms，或使用离线符号表）
./ksupatch ksu_template.ko ksu_run.ko
./ml2 ksu_run.ko allow_shell=1
```

`ksupatch` / `ml2` 的源码在 `tools/`，按 MIT 授权；它们不属于 KernelSU。
