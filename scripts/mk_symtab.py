#!/usr/bin/env python3
"""mk_symtab.py — 从 kallsyms 转储生成离线符号表（相对 _text 链接地址的偏移）

用法: python3 mk_symtab.py <kallsyms.txt> <out.bin.gz> [--need FILE] [--need-only]

输入格式（两种都支持）:
  1) /proc/kallsyms 运行时转储:  "地址 类型 名字"，行尾可能带 "\\[modname\\]"
  2) 镜像恢复转储(ghostlock-extract --dump-kallsyms):  "地址 名字"（无类型列）

锚点:  偏移 = addr − _text（从转储自身解析 _text，无任何硬编码链接基址；
       KASLR slide 在减法中自然消去）。ksupatch 侧用 --link <该内核链接 _text>
       --slide <泄漏 slide> 还原绝对地址。
过滤:
  * 运行时转储(带类型列)：保留全局 T/D/B/R 类型 + --need 名单
  * 镜像恢复转储(无类型列)：导出符号（自转储自身的 __ksymtab_* 推导）∪ --need
    原理：模块只能合法导入导出符号；KSU 模板额外绑定的未导出符号由 need
    名单先期兜底 —— 不用 BTF linkage（厂商管线可能丢）。同名 static 遮蔽
    全局导出的风险因此被限定在 need 名单内。
  * --need-only：只保留 --need 名单里的名字。用于构建时按当前 KSU LKM 的
    UND 清单裁剪出最小表（几 KB）；全量源仍存档在 assets/symtab_src/。
"""
import re, sys, gzip, os

def load(path):
    """返回 (name -> addr 首见, _text_addr or None)"""
    syms, text = {}, None
    for line in open(path, errors='ignore'):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        # 跳过模块符号: "addr t name [modname]"（镜像恢复转储不会有，但无害）
        if '[' in s:
            continue
        m = re.match(r'^([0-9a-fA-F]{8,16})\s+(?:([A-Za-z?])\s+)?(\S+)$', s)
        if not m:
            continue
        a = int(m.group(1), 16)
        t = m.group(2) or ''   # 无类型列 = 镜像恢复转储
        n = m.group(3)
        if a == 0:
            continue
        if n == '_text' and text is None:
            text = a
        syms.setdefault(n, (a, t))   # 首见优先（与 /proc/kallsyms 顺序一致）
    return syms, text

def main():
    argv = sys.argv[1:]
    need_only = '--need-only' in argv
    argv = [a for a in argv if a != '--need-only']
    if '--need' in argv:
        i = argv.index('--need')
        os.environ['KSYMS_NEED'] = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) < 2:
        sys.exit('用法: mk_symtab.py <kallsyms.txt> <out.bin.gz> [--need FILE] [--need-only]')
    src, out = argv[0], argv[1]
    syms, text = load(src)
    if not text:
        sys.exit('未找到 _text，dump 可能不完整（需要包含 _text 符号）')

    typed = any(v[1] for v in syms.values())
    keep = set('TDBR')
    need = set()
    need_file = os.environ.get('KSYMS_NEED')
    if need_file and os.path.exists(need_file):
        need = {l.strip() for l in open(need_file) if l.strip()}

    # 镜像恢复转储：导出集从转储自身的 __ksymtab_* 自推导
    exports = {n[len('__ksymtab_'):] for n in syms if n.startswith('__ksymtab_')}

    rows = []
    for n, (a, t) in syms.items():
        off = a - text
        if not (0 <= off < 2**32):
            continue
        if need_only:
            # 构建时裁剪：只保留当前模块实际导入的名字
            if n in need:
                rows.append((n, off))
        elif typed:
            # 运行时转储: 只保留全局 TDBR + need（模块常用导出）
            if t.upper() in keep and (t.isupper() or n in need):
                rows.append((n, off))
        else:
            # 镜像恢复转储: 导出符号（全局唯一，无遮蔽风险）∪ need 名单
            if n in exports or n in need:
                rows.append((n, off))
    rows.sort()
    blob = ('\n'.join(f'{n}\t{o:x}' for n, o in rows) + '\n').encode()
    gz = gzip.compress(blob, 9)
    open(out, 'wb').write(gz)
    print(f'typed={typed} need_only={need_only} symbols={len(rows)} '
          f'raw={len(blob)/1048576:.2f}MB gz={len(gz)/1024:.0f}KB '
          f'anchor=_text@{text:#x} exports={len(exports)} need={len(need)} -> {out}')
    d = dict(rows)
    print('self-check: _stext=%s selinux_state=%s memstart_addr=%s' % (
        hex(d.get('_stext', -1)), hex(d.get('selinux_state', -1)),
        hex(d.get('memstart_addr', -1))))

if __name__ == '__main__':
    main()
