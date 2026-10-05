#!/usr/bin/env bash
# buildroot 在打包根文件系统前调它：用刚编好的交叉编译器把 spix 编进去。第一个参数是 TARGET_DIR，HOST_DIR 在环境里
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
"$HOST_DIR/bin/riscv32-buildroot-linux-gnu-gcc" -O2 -Wall -o "$1/usr/bin/spix" "$H/spix.c"
