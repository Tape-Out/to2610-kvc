#!/usr/bin/env bash
# 整片测试：ran asic 出交付的 .v，照 report.json 的位表包上测试台的 tb，片外的 SDRAM、Flash 与串口模型来自黑盒仓。
# hello、periph、isa、arch-test、boot、rtos、linux 七段都跑在这份 .v 上，image 那一段在 QEMU 上：
#   hello  裸机程序从 Flash 就地执行，读写 SDRAM，串口报结果
#   periph 裸机程序把片上外设逐个点一遍：GPIO、两路 SPI（测试台上各挂一个回声从设备）、计时器中断、PLIC、重启
#   isa    标准 riscv-tests 逐个跑，跑法在黑盒仓的 htest/isa.sh
#   arch-test  riscv-arch-test（ACT4）的非特权部分，跑法在黑盒仓的 htest/arch-test.sh
#   boot   引导程序把 Flash 里的载荷搬进 SDRAM 并核对校验和，这里的载荷是一段回显程序
#   rtos   引导程序搬的是 FreeRTOS 的一个小程序：三个任务、队列、互斥量、节拍与抢占
#   image  载荷里的内核带着根文件系统先在 QEMU 上起到 shell：镜像坏了一分钟就知道，不必等后面那一小时
#   linux  引导程序搬的是 OpenSBI 加内核加根文件系统，起到 shell 后跑几条命令。起到 shell 时存一个断点，连同仿真器与
#          Flash 镜像放进 build/ckpt，SD 卡、网卡这几层由 htest/linux-layers.sh 从那里接着跑
# 用法：chip.sh <输出目录> <黑盒仓>。已经跑过 ran asic 的，把它的输出目录给 CHIP_ASIC。
# Linux 镜像要先用 sw/linux/build.sh 编出来，位置给 LINUX_IMAGE（默认 build/linux/fw_payload.bin）；没编过就取发布页上的那一份
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
rm -rf "$O"
mkdir -p "$O"
mkdir -p build
A=${CHIP_ASIC:-$O/asic}
[ -s "$A/report.json" ] || $XIRANG asic to2610-kvc --no-run -o "$A"
top=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['top'])" "$A/report.json")
python3 htest/shim.py "$A/report.json" > "$O/tb.v"
# 整颗 to2610-gpu 也编进测试台：htest/linux-layers.sh 的 gpujoin 段从同一个断点起，给了 +gpu 才步进它，前面各段不受拖慢
$XIRANG asic to2610-gpu --no-run -o "$O/gpu"
SIM_GPU=$O/gpu/to2610_gpu.v bash "$K/htest/sim.sh" "$O/sim" "$O/tb.v" "$A/$top.v"

res=()
run() {
  local name=$1 what=$2 t0=$SECONDS rc=0
  shift 2
  "$O/sim/Vtb" "$@" > "$O/$name.log" 2> "$O/$name.err" || rc=$?
  tail -n 3 "$O/$name.err"
  res+=("$name=$rc:$((SECONDS - t0)):$what")
}

make -s -C "$K/htest/hello" O="$O/hello"
run hello "裸机程序从 Flash 就地执行，1024 个字散在 16 MiB 里写了再读，字节与半字写不动旁边的位" \
  +flash="$O/hello/hello.bin@0x100000" +script="$K/htest/hello/script" +max=30000000

make -s -C "$K/htest/periph" O="$O/periph"
run periph "GPIO 出入与松手后的上拉；两路 SPI 各与回声从设备收发四个字节，片选重拉后从头来；计时器到点进中断；串口发字经 PLIC 进外部中断，领到 10 号；写重启寄存器后从头再起" \
  +flash="$O/periph/periph.bin@0x100000" +script="$K/htest/periph/script" +spiecho +max=30000000

t0=$SECONDS
rc=0
SIM="$O/sim" bash "$K/htest/isa.sh" "$O/isa" > "$O/isa.log" 2>&1 || rc=$?
tail -n 3 "$O/isa.log"
res+=("isa=$rc:$((SECONDS - t0)):riscv-tests 的 rv32ui、um、ua、mi、si 逐个在这份 .v 上跑，程序放进 SDRAM、测试台盯 tohost；79 个全过，不适用的 5 个（Zacas、硬件非对齐访存、PMP、调试触发器）不跑")

t0=$SECONDS
rc=0
SIM="$O/sim" bash "$K/htest/arch-test.sh" "$O/arch-test" > "$O/arch-test.log" 2>&1 || rc=$?
tail -n 3 "$O/arch-test.log"
res+=("arch-test=$rc:$((SECONDS - t0)):riscv-arch-test（ACT4）的 I、M、Zmmul、Zaamo、Zalrsc、Zicsr、Zifencei、Zicntr 共 71 个自检程序逐个在这份 .v 上跑，期望值出自 Sail 模型")

make -s -C sw/boot O="$O/boot"
make -s -C htest/echo O="$O/echo"
python3 sw/pack.py "$O/boot/boot.bin" "$O/echo/echo.bin" "$O/echo.flash"
run boot "引导程序把载荷从 Flash 搬进 SDRAM、校验和对上后跳过去；载荷回显串口收到的字" \
  +flash="$O/echo.flash@0" +script=htest/echo/script +max=60000000

make -s -C htest/rtos O="$O/rtos"
python3 sw/pack.py "$O/boot/boot.bin" "$O/rtos/rtos.bin" "$O/rtos.flash"
run rtos "FreeRTOS 由引导程序搬进 SDRAM 后起来：一个任务按节拍往队列里发数，一个收了从串口报，一个最低优先级的不让出；计时器中断、ecall 让出、抢占与互斥量都走到" \
  +flash="$O/rtos.flash@0" +script=htest/rtos/script +max=20000000

L=${LINUX_IMAGE:-build/linux/fw_payload.bin}
# 没在本机编过（流水线上）：取发布页上的那一份，地址与摘要钉在 sw/linux/image.pin，摘要对不上就不用
if [ ! -s "$L" ] && [ -s sw/linux/image.pin ]; then
  read -r url sum < sw/linux/image.pin
  mkdir -p "$(dirname "$L")"
  if curl -fsSL --retry 5 -o "$L.part" "$url" && echo "$sum  $L.part" | sha256sum -c - > /dev/null; then
    mv "$L.part" "$L"
  else
    rm -f "$L.part"
    echo "取不到镜像 $url，或摘要不是 $sum"
  fi
fi
if [ -s "$L" ]; then
  t0=$SECONDS
  rc=0
  python3 htest/qemu.py "$L" htest/image.script "$O/qemu" > "$O/image.log" 2>&1 || rc=$?
  tail -n 3 "$O/image.log"
  res+=("image=$rc:$((SECONDS - t0)):载荷里的内核带着根文件系统在 QEMU 的 virt 机器上起到 shell；只验软件，拦坏镜像")
  if [ $rc = 0 ]; then
    python3 sw/pack.py "$O/boot/boot.bin" "$L" "$O/linux.flash"
    rm -rf build/ckpt
    mkdir -p build/ckpt
    # 发字节的间隔 60 万拍（12 毫秒）：串口没有接收缓冲，内核往控制台打一行要关中断五毫秒多，
    # 间隔比它短，那一行里到的第二个字就丢了
    run linux "从 Flash 引导 OpenSBI 与 Linux，起到 shell 后跑 uname、读 /proc/cpuinfo、算 md5、读写文件，再跑 apptest 的十项" \
      +flash="$O/linux.flash@0" +script=htest/linux.script +pace=600000 +max="${LINUX_MAX:-8000000000}" +beat=1000000000
    # 断点只认存它的那个仿真器：一起留下
    [ -s build/ckpt/linux.ckpt ] && cp "$O/sim/Vtb" "$O/linux.flash" build/ckpt/
  else
    res+=("linux=1:0:镜像没过 QEMU 那一关，没跑")
  fi
else
  echo "没有 Linux 镜像 $L：第三段没跑（先跑 sw/linux/build.sh）"
  res+=("image=1:0:没有镜像，没跑" "linux=1:0:没有镜像，没跑")
fi

python3 htest/junit.py "$O/results.xml" "${res[@]}"
printf '%s\n' "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "整片测试 ${#res[@]} 段全过"
