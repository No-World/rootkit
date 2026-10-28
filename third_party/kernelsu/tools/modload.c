/* SPDX-License-Identifier: MIT
 * Copyright (c) 2026 No-World
 *
 * RootKit runtime tool for the GPL-2.0 KernelSU LKM. This file is not part
 * of KernelSU; see third_party/kernelsu/NOTICE.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/syscall.h>
#include <sys/stat.h>
int main(int argc, char**argv){
    if(argc<2){printf("usage: modload file.ko\n");return 2;}
    int fd=open(argv[1],O_RDONLY|O_CLOEXEC);
    if(fd<0){printf("open fail errno=%d\n",errno);return 1;}
    const char *uargs = argc>2 ? argv[2] : "";
    long r=syscall(SYS_finit_module,fd,uargs,0);
    int e=errno;
    printf("finit ret=%ld errno=%d\n",r,e);
    if(argc>2){ printf("(uargs=%s)\n", uargs); }
    if(r!=0){
        struct stat st; fstat(fd,&st);
        void *b=malloc(st.st_size);
        if(b&&pread(fd,b,st.st_size,0)==st.st_size){
            r=syscall(SYS_init_module,b,st.st_size,"");
            printf("init_module ret=%ld errno=%d\n",r,errno);
        }
    }
    return r?1:0;
}
