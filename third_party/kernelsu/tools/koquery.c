/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 No-World
 *
 * RootKit runtime tool for the GPL-2.0 KernelSU LKM. This file is not part
 * of KernelSU; see third_party/kernelsu/NOTICE.
 */
/* koquery.c — 从任意内核模块 .ko 里读出版本/校验信息（设备侧自校准用）
 * 用法: koquery <file.ko>
 * 输出（每行一 kv）：
 *   vermagic=<str>
 *   module_layout_crc=0x........
 *   has_plt=<0|1>  has_init_plt=<0|1>  has_versions=<0|1>
 *   kcfi_typeids=<n>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <elf.h>

static unsigned char *d;
static size_t dsz;

static Elf64_Shdr *find_sh(const char *name) {
    Elf64_Ehdr *eh = (Elf64_Ehdr *)d;
    Elf64_Shdr *sh = (Elf64_Shdr *)(d + eh->e_shoff);
    const char *shstr = (const char *)(d + sh[eh->e_shstrndx].sh_offset);
    for (int i = 0; i < eh->e_shnum; i++)
        if (!strcmp(shstr + sh[i].sh_name, name)) return &sh[i];
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: koquery <file.ko>\n"); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { printf("ERR=open\n"); return 1; }
    off_t sz = lseek(fd, 0, SEEK_END); lseek(fd, 0, SEEK_SET);
    d = malloc(sz);
    if (!d || read(fd, d, sz) != sz) { printf("ERR=read\n"); return 1; }
    close(fd);
    dsz = (size_t)sz;
    if (memcmp(d, ELFMAG, 4) || d[EI_CLASS] != ELFCLASS64) { printf("ERR=not_elf64\n"); return 1; }

    /* vermagic / name */
    Elf64_Shdr *mi = find_sh(".modinfo");
    if (mi) {
        char *p = (char *)(d + mi->sh_offset);
        char *end = p + mi->sh_size;
        while (p < end) {
            size_t l = strlen(p);
            if (!strncmp(p, "vermagic=", 9)) printf("vermagic=%s\n", p + 9);
            if (!strncmp(p, "name=", 5)) printf("modname=%s\n", p + 5);
            p += l + 1;
        }
    }

    /* .plt / .init.plt / __versions 是否存在 */
    printf("has_plt=%d\n", find_sh(".plt") ? 1 : 0);
    printf("has_init_plt=%d\n", find_sh(".init.plt") ? 1 : 0);
    Elf64_Shdr *vers = find_sh("__versions");
    printf("has_versions=%d\n", (vers && vers->sh_size) ? 1 : 0);

    /* module_layout 的 CRC（MODVERSIONS） */
    if (vers && vers->sh_size) {
        for (size_t i = 0; i + 64 <= vers->sh_size; i += 64) {
            const char *nm = (const char *)(d + vers->sh_offset + i + 8);
            if (!strncmp(nm, "module_layout", 13)) {
                uint64_t crc;
                memcpy(&crc, d + vers->sh_offset + i, 8);
                printf("module_layout_crc=0x%llx\n", (unsigned long long)crc);
                break;
            }
        }
    }

    /* 统计 __kcfi_typeid_*（说明该模块是 CFI 构建） */
    Elf64_Shdr *sym = find_sh(".symtab");
    Elf64_Shdr *str = find_sh(".strtab");
    if (sym && str) {
        int n = 0;
        for (size_t i = 0; i < sym->sh_size / sizeof(Elf64_Sym); i++) {
            Elf64_Sym *s = (Elf64_Sym *)(d + sym->sh_offset + i * sizeof(Elf64_Sym));
            if (!s->st_name) continue;
            const char *nm = (const char *)(d + str->sh_offset + s->st_name);
            if (!strncmp(nm, "__kcfi_typeid_", 14)) n++;
        }
        printf("kcfi_typeids=%d\n", n);
    }
    return 0;
}
