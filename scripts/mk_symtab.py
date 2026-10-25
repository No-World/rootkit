#!/usr/bin/env python3
"""mk_symtab.py — 从 /proc/kallsyms 转储生成离线符号表（相对 _text 链接地址的偏移）

用法: python3 mk_symtab.py <kallsyms.txt> <out.bin.gz>

原理：dump 里的地址 = 链接地址 + KASLR slide，用 _stext 反推 slide
      （_stext 链接地址固定 0xffffffc080010000），再换算成相对 _text(0xffffffc080000000) 的偏移。
保留类型 T/D/B/R（模块常用导出）以及 --need 指定的额外符号（例如 KSU 用到的）。
"""
import re, sys, gzip, struct, os

LINK_TEXT = 0xffffffc080000000
LINK_STEXT = 0xffffffc080010000


def load(path):
    syms, stext = {}, None
    for line in open(path, errors='ignore'):
        m = re.match(r'^([0-9a-f]{16})\s+(\S)\s+(\S+)$', line.strip())
        if not m:
            continue
        a, t, n = int(m.group(1), 16), m.group(2), m.group(3)
        if a == 0:
            continue
        if n == '_stext' and stext is None:
            stext = a
        syms.setdefault(n, (a, t))
    return syms, stext


def main():
    src, out = sys.argv[1], sys.argv[2]
    syms, stext = load(src)
    if not stext:
        sys.exit('未找到 _stext，dump 可能不完整')
    slide = stext - LINK_STEXT
    keep = set('TDBR')
    need = set()
    need_file = os.environ.get('KSYMS_NEED')
    if need_file and os.path.exists(need_file):
        need = {l.strip() for l in open(need_file) if l.strip()}
    rows = []
    for n, (a, t) in syms.items():
        off = a - slide - LINK_TEXT
        if 0 <= off < 2**32 and (t in keep or n in need):
            rows.append((n, off))
    rows.sort()
    blob = ('\n'.join(f'{n}\t{o:x}' for n, o in rows) + '\n').encode()
    gz = gzip.compress(blob, 9)
    open(out, 'wb').write(gz)
    print(f'symbols={len(rows)} raw={len(blob)/1048576:.2f}MB gz={len(gz)/1024:.0f}KB slide={hex(slide)} -> {out}')
    d = dict(rows)
    print('self-check: _stext=%s selinux_state=%s' % (
        hex(d.get('_stext', -1)), hex(d.get('selinux_state', -1))))


if __name__ == '__main__':
    main()
