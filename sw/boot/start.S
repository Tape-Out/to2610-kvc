# 引导程序就地在 Flash 里跑。栈放在 SDRAM 顶上往下 8 KiB 处，顶上那 4 KiB 留给搬进内存的拷贝例程
.section .text.start
.global _start
_start:
    li t0, 0x10000018
    lw t1, 0(t0)
    li t2, 0x80000000
    add sp, t1, t2
    li t3, 0x2000
    sub sp, sp, t3
    call main
1:  j 1b
