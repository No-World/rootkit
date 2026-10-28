#!/bin/bash
# prepare_assets.sh — 本地生成 APK 需要的原生载荷
#
# 原生源码在 ../cve-2026-64560/（未随本仓库发布）；仓库内保留预编译产物，
# 便于 CI/直接构建。第三方许可见 third_party/kernelsu/。
#
# 依赖（相对本仓库）：../cve-2026-64560/ 下的源码与二进制
#   exploit_64560_arw.c → x645        （CVE-2026-64560 利用器）
#   probe_cand.c        → pc          （候选进程探针：perf 抓 cred + 自加载模块）
#   pwn_mod.c           → module.ko   （自制内核模块：uid=0 + 恢复 selinux initialized）
#   modload.c           → ml2         （finit_module 加载器）
#   ksupatch.c          → ksupatch    （UND→kallsyms 绝对地址 / 离线表）
#   koquery.c           → koquery     （读 .ko 的 vermagic / module_layout CRC）
#   ksu_template.ko     → 官方 KSU LKM（v3.3.1 lkm-aarch64-android16-6.12）
#   kallsyms_6.12.58.bin.gz → 离线符号表（scripts/mk_symtab.py 生成）
set -eu
cd "$(dirname "$0")/.."
LAB=../cve-2026-64560
A=assets
mkdir -p "$A"
CC=${CC:-aarch64-linux-gnu-gcc}
FLAGS="-O2 -static -pthread"

echo "[1/4] 编译 exploit / 探针 / 工具"
$CC $FLAGS -o "$A/x645" "$LAB/exploit_64560_arw.c"
$CC $FLAGS -o "$A/pc" "$LAB/probe_cand.c"
$CC $FLAGS -o "$A/ml2" "$LAB/modload.c"
$CC -O2 -static -o "$A/ksupatch" "$LAB/ksupatch.c"
$CC -O2 -static -o "$A/koquery" "$LAB/koquery.c"

echo "[2/4] 内核模块"
$CC -c -DMODNAME='"pwn4"' -O2 -fno-pic -fno-stack-protector \
    -fno-asynchronous-unwind-tables -fno-unwind-tables -march=armv8-a \
    -o "$A/module.ko" "$LAB/pwn_mod.c"

echo "[3/4] KSU LKM 模板"
cp "$LAB/ksu_template.ko" "$A/ksu_template.ko"

echo "[4/4] gzip（APK 内以 .gz 存放）"
for f in x645 pc ml2 ksupatch ksu_template.ko koquery; do
  gzip -9 -kf "$A/$f"
done

echo "完成。若缺离线符号表，请运行：python3 scripts/mk_symtab.py <kallsyms_dump> $A/kallsyms_6.12.58.bin.gz"
ls -la "$A" | tail -20
