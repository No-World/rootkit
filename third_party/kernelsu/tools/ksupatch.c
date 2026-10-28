/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 No-World
 *
 * RootKit runtime tool for the GPL-2.0 KernelSU LKM. This file is not part
 * of KernelSU; see third_party/kernelsu/NOTICE.
 */
/* ksupatch.c — 在设备上把内核模块的所有符号改成 /proc/kallsyms 里的绝对地址（SHN_ABS）
 * 用法: ksupatch <in.ko> <out.ko>
 * 原理: 模块里所有 UND 符号 → st_shndx=SHN_ABS, st_value=kallsyms 真地址
 *       ⇒ 加载时不再需要内核导出这些符号，也不需要 MODVERSIONS CRC。
 * 需要 root（读 /proc/kallsyms 真地址要先 echo 0 > /proc/sys/kernel/kptr_restrict）。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <elf.h>

#define SHN_ABS_ 0xfff1
#define HSIZE (1u << 20)

typedef struct { char *name; uint64_t addr; } ent_t;
static ent_t *tab;
static uint32_t mask = HSIZE - 1;

static uint32_t hsh(const char *s) {
    uint32_t h = 2166136261u;
    while (*s) { h ^= (unsigned char)*s++; h *= 16777619u; }
    return h & mask;
}
static void put(char *name, uint64_t addr) {
    uint32_t i = hsh(name);
    for (uint32_t probe = 0; probe <= mask; probe++) {
        if (!tab[i].name) { tab[i].name = name; tab[i].addr = addr; return; }
        if (!strcmp(tab[i].name, name)) { tab[i].addr = addr; return; }
        i = (i + 1) & mask;
    }
    printf("WARN: kallsyms hash table full, dropping %s\n", name);
}
static uint64_t get(const char *name) {
    uint32_t i = hsh(name);
    for (;;) {
        if (!tab[i].name) return 0;
        if (!strcmp(tab[i].name, name)) return tab[i].addr;
        i = (i + 1) & mask;
    }
}

int main(int argc, char **argv) {
    /* 用法：
     *   ksupatch <in.ko> <out.ko>                       # 从 /proc/kallsyms 取真地址（需可读，通常要 root）
     *   ksupatch <in.ko> <out.ko> --table T --slide S    # 离线符号表 + KASLR slide（无需 root）
     *   可选 --link 0xffffffc080000000（默认本机 _text 链接地址）
     */
    if (argc < 3) {
        printf("usage: ksupatch <in.ko> <out.ko> [--table T] [--slide HEX] [--link HEX]\n");
        return 2;
    }
    const char *tablePath = NULL;
    unsigned long long slide = 0, linkBase = 0xffffffc080000000ULL;
    for (int i = 3; i + 1 < argc; i += 2) {
        if (!strcmp(argv[i], "--table")) tablePath = argv[i + 1];
        else if (!strcmp(argv[i], "--slide")) slide = strtoull(argv[i + 1], NULL, 16);
        else if (!strcmp(argv[i], "--link")) linkBase = strtoull(argv[i + 1], NULL, 16);
    }
    tab = calloc(HSIZE, sizeof(ent_t));
    if (!tab) { printf("oom\n"); return 1; }

    /* 1) 读符号来源 */
    FILE *kf = fopen("/proc/kallsyms", "r");
    if (tablePath) {
        FILE *tf = fopen(tablePath, "r");
        if (!tf) { printf("open table fail errno=%d path=%s\n", errno, tablePath); return 1; }
        char tl[512];
        long tn = 0;
        while (fgets(tl, sizeof tl, tf)) {
            char *tab = strchr(tl, '\t');
            if (!tab) continue;
            *tab = 0;
            unsigned long long off = strtoull(tab + 1, NULL, 16);
            put(strdup(tl), linkBase + slide + off);
            tn++;
        }
        fclose(tf);
        printf("table symbols=%ld slide=%#llx link=%#llx\n", tn, slide, linkBase);
        if (tn < 1000) { printf("table 太小，疑似格式不对\n"); return 1; }
        goto have_symbols;
    }
    if (!kf) { printf("open kallsyms fail errno=%d (先 kptr_restrict=0，或用 --table)\n", errno); return 1; }
    char line[512];
    long kn = 0, nonzero = 0, kn_mod = 0;
    while (fgets(line, sizeof line, kf)) {
        unsigned long long a; char t; char nm[256];
        if (sscanf(line, "%llx %c %255s", &a, &t, nm) == 3) {
            kn++;
            if (a) nonzero++;
            /* /proc/kallsyms 的模块符号形如 "addr t name\t[modname]"：
             * 跳过它们，避免同名 static 符号覆盖核心导出地址（last-wins 陷阱）。 */
            const char *br = strchr(line, '[');
            if (br && br > line) { kn_mod++; continue; }
            put(strdup(nm), (uint64_t)a);
        }
    }
    fclose(kf);
    printf("kallsyms lines=%ld nonzero=%ld module_syms_skipped=%ld\n", kn, nonzero, kn_mod);
    if (nonzero < 1000) { printf("kallsyms 地址全是 0（kptr_restrict 没关？可用 --table）\n"); return 1; }

have_symbols:;

    /* 2) 读 .ko */
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { printf("open %s fail errno=%d\n", argv[1], errno); return 1; }
    off_t sz = lseek(fd, 0, SEEK_END); lseek(fd, 0, SEEK_SET);
    unsigned char *d = malloc(sz);
    if (!d || read(fd, d, sz) != sz) { printf("read fail\n"); return 1; }
    close(fd);
    if (memcmp(d, ELFMAG, 4) != 0 || d[EI_CLASS] != ELFCLASS64) { printf("not elf64\n"); return 1; }

    Elf64_Ehdr *eh = (Elf64_Ehdr *)d;
    Elf64_Shdr *sh = (Elf64_Shdr *)(d + eh->e_shoff);
    Elf64_Shdr *sym = NULL, *str = NULL;
    for (int i = 0; i < eh->e_shnum; i++) {
        const char *nm = (const char *)(d + sh[eh->e_shstrndx].sh_offset + sh[i].sh_name);
        if (!strcmp(nm, ".symtab")) sym = &sh[i];
        else if (!strcmp(nm, ".strtab")) str = &sh[i];
    }
    if (!sym || !str) { printf("no symtab\n"); return 1; }

    long total = 0, patched = 0, miss = 0, kcfi_skip = 0;
    long n = sym->sh_size / sizeof(Elf64_Sym);
    for (long i = 0; i < n; i++) {
        Elf64_Sym *s = (Elf64_Sym *)(d + sym->sh_offset + i * sizeof(Elf64_Sym));
        if (!s->st_name) continue;
        const char *nm = (const char *)(d + str->sh_offset + s->st_name);
        if (s->st_shndx != SHN_UNDEF &&
            !(s->st_shndx == SHN_ABS_ && s->st_value == 0)) continue;
        total++;
        /* ★ 必须先判 kcfi：kallsyms 里也存在核心的 __kcfi_typeid_*，
         * 若先查表会把模块自带的类型哈希改成代码地址 ⇒ CFI 校验 BRK。 */
        if (!strncmp(nm, "__kcfi_typeid_", 14)) { kcfi_skip++; continue; }
        uint64_t a = get(nm);
        if (!a) {
            if (miss < 40) printf("MISS[%ld] %s\n", miss, nm);
            miss++;
            continue;
        }
        s->st_shndx = SHN_ABS_;
        s->st_value = a;
        patched++;
    }
    printf("symbols(placeholders)=%ld patched=%ld missing=%ld kcfi_kept=%ld\n",
           total, patched, miss, kcfi_skip);

    int ofd = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (ofd < 0) { printf("open out fail errno=%d\n", errno); return 1; }
    if (write(ofd, d, sz) != sz) { printf("write fail\n"); return 1; }
    close(ofd);
    printf("OK -> %s (miss=%ld)\n", argv[2], miss);
    return miss ? 3 : 0;   /* 只有真正解析不了的内核符号才失败；kcfi 类型哈希保留原值 */
}
