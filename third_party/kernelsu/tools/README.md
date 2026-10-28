# RootKit runtime tools (MIT)

These files are original RootKit code, licensed **MIT** (see the repository
root `LICENSE`). They are included here because they are the "scripts used to
control installation" of the GPL-2.0 KernelSU LKM.

| 文件 | 产物 | 作用 |
|---|---|---|
| `ksupatch.c` | `assets/ksupatch` | 把 LKM 的 UND 符号改成 `SHN_ABS` 绝对地址 |
| `modload.c` | `assets/ml2` | `finit_module` 加载器 |
| `koquery.c` | `assets/koquery` | 读取 `.ko` 的 vermagic / `module_layout` CRC |

构建（静态 aarch64）：

```bash
aarch64-linux-gnu-gcc -O2 -static -o ksupatch ksupatch.c
aarch64-linux-gnu-gcc -O2 -static -o ml2 modload.c
aarch64-linux-gnu-gcc -O2 -static -o koquery koquery.c
```

这些工具只修改运行期的 LKM 映像，不改变 KernelSU 源码的 GPL-2.0 许可。
