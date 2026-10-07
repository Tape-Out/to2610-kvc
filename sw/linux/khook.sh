#!/usr/bin/env bash
# 把 to2610-gpu 的驱动放进内核源码树：源文件与头文件拷进 drivers/misc，Makefile 与 Kconfig 各追加一条。
# 追加在文件末尾，不依赖上下文，内核换版本也套得上。用法：khook.sh <内核源码目录>
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
L=$(realpath "$1")
cp "$H/to2610_gpu.c" "$H/tgpu.h" "$L/drivers/misc/"
grep -q TO2610_GPU "$L/drivers/misc/Makefile" || echo 'obj-$(CONFIG_TO2610_GPU) += to2610_gpu.o' >> "$L/drivers/misc/Makefile"
grep -q TO2610_GPU "$L/drivers/misc/Kconfig" || cat >> "$L/drivers/misc/Kconfig" <<'K'

config TO2610_GPU
	tristate "to2610-gpu on an SPI port"
	depends on SPI
	help
	  Loads, runs and reads back kernels on the to2610-gpu chip through
	  /dev/tgpu, and sets up its video scan-out.
K
