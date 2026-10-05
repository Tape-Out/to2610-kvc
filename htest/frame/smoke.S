# mpc-frame 两个测试台用的程序：从 Flash 就地执行，把串口的分频值写成 16，发一个 K。
# 不碰 SDRAM，测试台就不必带 SDRAM 的模型
# expect: 4b
.section .text
.global _start
_start:
    li t0, 0x1000000c
    li t1, 16
    sw t1, 0(t0)
    li t0, 0x10000000
    li t1, 0x4b
    sw t1, 0(t0)
1:  j 1b
