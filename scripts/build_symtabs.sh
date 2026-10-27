#!/bin/bash
# build_symtabs.sh — 构建时按"当前 KSU LKM 的 UND 清单"裁剪离线符号表
#
# 设计：
#   * 仓库里 assets/symtab_src/<ver>.txt.xz 存**全量** kallsyms 转储（可追溯、
#     KSU 升级或换模块时可随时重新裁剪）；
#   * APK 只需要"这个 LKM 会导入的符号" ⇒ 每次构建从 KSU 模板 .ko 读 UND，
#     生成几 KB 的 assets/kallsyms_<ver>.bin.gz；
#   * 没有全量源的内核（如 MLY 只有历史上的宽表）保持原表不动。
#
# 依赖: python3 · xz · binutils(readelf)
set -euo pipefail
cd "$(dirname "$0")/.."
A=assets
SRC=$A/symtab_src

# 内核版本  →  (全量源文件, KSU 模板 .ko.gz, 输出表)
MAP=(
  "6.6.118_c901:kallsyms_6.6.118_c901.txt.xz:ksu_template_6.6.ko.gz:kallsyms_6.6.118_c901.bin.gz"
)

echo "[symtab] 按当前 KSU LKM 的 UND 清单裁剪离线符号表"
for entry in "${MAP[@]}"; do
  IFS=':' read -r ver src ksu out <<< "$entry"
  if [ ! -f "$SRC/$src" ]; then
    echo "  - $ver: 无全量源（$SRC/$src），跳过，沿用现有表"
    continue
  fi
  if [ ! -f "$A/$ksu" ]; then
    echo "  - $ver: 缺 KSU 模板 $A/$ksu，跳过" >&2
    exit 1
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  # 1) 解压全量源
  xz -dc "$SRC/$src" > "$tmp/kallsyms.txt"
  # 2) 取 KSU 模板的 UND 名字（去重；跳过空的）
  gzip -dc "$A/$ksu" > "$tmp/ksu.ko"
  readelf -sW "$tmp/ksu.ko" \
    | awk '$7 == "UND" && $8 != "" { print $8 }' \
    | sort -u > "$tmp/need.txt"
  # 3) 裁剪：只保留 need 里的名字
  python3 scripts/mk_symtab.py "$tmp/kallsyms.txt" "$A/$out" \
      --need "$tmp/need.txt" --need-only | sed 's/^/    /'
  printf '  - %s: %s → %s (%s 个名字)\n' "$ver" "$ksu" "$out" "$(wc -l < "$tmp/need.txt")"
done
echo "[symtab] 完成"
