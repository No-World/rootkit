#!/bin/bash
# prepare_assets.sh — 本地生成 APK 需要的原生载荷（这些文件不入公开仓库）
#
# 依赖（相对本仓库）：../cve-2026-64560/ 下的源码与二进制
#   exploit_64560_arw.c → x645        （CVE-2026-64560 利用器）
#   probe_cand.c        → pc          （候选进程探针：perf 抓 cred + 自加载模块）
#   pwn_mod.c           → module*.ko  （自制内核模块：uid=0 + 恢复 selinux initialized）
#                         ↑ 常量参数化：-D 覆盖 cred 偏移 / struct module 布局 /
#                           vermagic / module_layout CRC（每内核一套，见下方两段）
#   modload.c           → ml2         （finit_module 加载器）
#   ksupatch.c          → ksupatch    （UND→kallsyms 绝对地址 / 离线表）
#   koquery.c           → koquery     （读 .ko 的 vermagic / module_layout CRC）
#   ksu_template*.ko    → 官方 KSU LKM（v3.3.1：android16-6.12 / android15-6.6）
#   kallsyms_*.bin.gz   → 离线符号表（scripts/mk_symtab.py 生成，_text 锚定）
set -eu
cd "$(dirname "$0")/.."
LAB=../cve-2026-64560
A=assets
mkdir -p "$A"
CC=${CC:-aarch64-linux-gnu-gcc}
FLAGS="-O2 -static -pthread"
MODFLAGS="-c -DMODNAME='\"pwn4\"' -O2 -fno-pic -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-unwind-tables -march=armv8-a"

echo "[1/4] 编译 exploit / 探针 / 工具"
$CC $FLAGS -o "$A/x645" "$LAB/exploit_64560_arw.c"
$CC $FLAGS -o "$A/pc" "$LAB/probe_cand.c"
$CC $FLAGS -o "$A/ml2" "$LAB/modload.c"
$CC -O2 -static -o "$A/ksupatch" "$LAB/ksupatch.c"
$CC -O2 -static -o "$A/koquery" "$LAB/koquery.c"

echo "[2/4] 内核模块（每内核一套常量，来源见 lib/known_kernels.dart 注释）"
# —— Magic9 (MLY-AN00) · 6.12.58-android16-6 ——
$CC $MODFLAGS \
    -DVERMAGIC_STR='"6.12.58-android16-6-g3a7ac1674240-abogki541502914-4k SMP preempt mod_unload modversions aarch64"' \
    -o "$A/module.ko" "$LAB/pwn_mod.c"
# —— Honor 600 (C901E4H) · 6.6.118-android15-8（issue #1）——
# 常量来源：C901 全量固件 boot.img BTF/kallsyms + vendor_boot 504×.ko 众数
$CC $MODFLAGS \
    -DOFF_TASK_CRED=0x820 -DOFF_TASK_REAL_CRED=0x818 \
    -DMODULE_SIZE=1536 -DMOD_LAYOUT_CRC=0x4e276f37UL \
    -DVERMAGIC_STR='"6.6.118-android15-8-gc901ea41aa32-ab15981388-4k SMP preempt mod_unload modversions aarch64"' \
    -o "$A/module_6.6.ko" "$LAB/pwn_mod.c"

echo "[3/4] KSU LKM 模板（按内核世代）"
cp "$LAB/ksu_template.ko" "$A/ksu_template.ko"                       # android16-6.12（MLY）
cp "$LAB/ksu_official_331_android15-6.6.ko" "$A/ksu_template_6.6.ko"  # android15-6.6（C901 等）

echo "[4/4] gzip（APK 内以 .gz 存放）"
for f in x645 pc ml2 ksupatch koquery ksu_template.ko ksu_template_6.6.ko; do
  gzip -9 -kf "$A/$f"
done

echo "[5/5] 离线符号表（按当前 KSU LKM 的 UND 清单裁剪）"
bash scripts/build_symtabs.sh

echo "完成。"
echo "符号表全量源：assets/symtab_src/<ver>.txt.xz（重新生成见 README §6.1 ②）："
echo "  运行时 dump:  python3 scripts/mk_symtab.py kallsyms_<ver>.txt \$A/kallsyms_<ver>.bin.gz"
echo "  镜像恢复 dump: GHOSTLOCK_NO_PROC_KALLSYMS=1 ghostlock-extract <img> --dump-kallsyms k.txt"
echo "                （必须设该变量：否则会读到宿主 /proc/kallsyms，静默用错内核的符号）"
ls -la "$A" | tail -20
