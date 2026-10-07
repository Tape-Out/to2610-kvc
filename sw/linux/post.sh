#!/usr/bin/env bash
# buildroot 在打包根文件系统前调它：用刚编好的交叉编译器把 spix、tgpu 与 apptest 编进去。第一个参数是 TARGET_DIR，HOST_DIR 在环境里
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
"$HOST_DIR/bin/riscv32-buildroot-linux-gnu-gcc" -O2 -Wall -o "$1/usr/bin/spix" "$H/spix.c"
"$HOST_DIR/bin/riscv32-buildroot-linux-gnu-gcc" -O2 -Wall -I"$H" -o "$1/usr/bin/tgpu" "$H/tgpu.c"
"$HOST_DIR/bin/riscv32-buildroot-linux-gnu-gcc" -std=gnu2x -O2 -Wall -Wextra -o "$1/usr/bin/apptest" "$H/apptest.c" -lpthread
# overlay 照磁盘上的权限拷进来，在 Windows 侧改过的脚本会丢掉可执行位（image-4 的 spimode 就是这样）
chmod 755 "$1/usr/bin/spimode" "$1/usr/bin/sdcard" "$1/etc/init.d/rcS"
