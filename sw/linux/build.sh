#!/usr/bin/env bash
# 编 to2610-kvc 的镜像：工具链、OpenSBI、Linux 与根文件系统，出 build/linux/fw_payload.bin。
# 配方是上游 kianRiscV 仓里的 buildroot 外挂（组织的 kianriscv 仓把它挂成子模块），内核与 OpenSBI 的补丁、
# 内核配置、busybox 配置都原样用。这里只换六处：
#   根文件系统只留 busybox，并嵌进内核：整份载荷放得进 Flash，不插 SD 卡也起得来
#   设备树用本目录的 to2610-kvc.dts：片上只有一路串口、两路 SPI 与一位 GPIO
#   不编宿主的 QEMU 与 ccache
#   内核在上游的补丁之后再打本目录 patches/ 下的：SPI 控制器的驱动认 SPI_CS_HIGH，SD 卡上电时要在片选抬高的
#   情况下送时钟，原来每探一次卡报两行错；GPIO 驱动照片上那一位口子读写（上游的是按 FPGA 版每线一位写的）
#   根文件系统里多一个 spix（post.sh 编进去）与 spimode、SD 卡上的 boot.sh 这两样脚本（overlay）
#   内核配置加 linux.fragment 里的几项：spidev 与 FAT 是给上面那几样用的。另外两项：SBI 的早期控制台：上游的启动参数里写着 earlycon=sbi 而配置没开，
#   串口驱动起来之前内核停在哪就一个字也看不见。根文件系统不压缩：这颗核每秒两百多万条指令，
#   解 gzip 要二十多秒，照原样拷只要一两秒，Flash 也放得下
# 用法：build.sh [<kianriscv 仓>]，默认与本仓并排的 ../kianriscv
# 宿主的 GCC 到了 15 就改用 docker.sh，它在容器里跑这个脚本
#
# 在这一颗上加东西的芯片（to2610-npu 多一个引擎）不改这份脚本，从环境给：
#   TO2610_DTS      换设备树，里面可以 /include/ "to2610-kvc.dts"
#   TO2610_OVERLAY  再叠一层根文件系统
#   TO2610_KCONFIG  内核配置的增补片段
#   TO2610_KHOOK    内核源码解开并打完补丁后跑的脚本，参数是源码目录（往里放驱动）
#   TO2610_POST     根文件系统打包前跑的脚本，buildroot 给它 TARGET_DIR 作参数、HOST_DIR 在环境里（往里编用户程序）
#   TO2610_OUT      镜像放哪，默认本仓的 build/linux
#   TO2610_BUILDROOT  buildroot 的树，默认在 TO2610_OUT 下；指到已经编过的一棵，工具链就不重编
#   TO2610_DL       下载的源码包放哪，默认在 buildroot 里
set -euo pipefail
H=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$H/../.." && pwd)
K=$(realpath "${1:-$R/../kianriscv}")
S=$K/third_party/kianriscv/linux_socs/kianv_mc_rv32ima_sv32/os/linux/buildroot-kianv-soc/bldroot
[ -d "$S" ] || { echo "找不到上游配方 $S：kianriscv 仓的子模块取了吗"; exit 1; }
# 上游配方钉的 buildroot 提交
REV=256aa8ed85f8fd65ea0f0f242adb55f95a13eb2b
W=${TO2610_OUT:-$R/build/linux}
B=${TO2610_BUILDROOT:-$W/buildroot}
# buildroot 不收带空格的 PATH（WSL 会把 Windows 的路径并进来）；它钉的几个宿主包还写着 CMake 3.5 以前的最低版本
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export CMAKE_POLICY_VERSION_MINIMUM=3.5
[ -n "${TO2610_DL:-}" ] && export BR2_DL_DIR=$TO2610_DL
mkdir -p "$W"
if [ ! -f "$B/Makefile" ]; then
  # 只清里面的残留：这个目录在容器里可能是挂载点，本身删不得
  mkdir -p "$B"
  find "$B" -mindepth 1 -delete
  # 只取钉住的那一个提交，不要全部历史
  wget -q -O "$W/buildroot.tar.gz" "https://github.com/buildroot/buildroot/archive/$REV.tar.gz"
  tar -xzf "$W/buildroot.tar.gz" -C "$B" --strip-components 1
  rm "$W/buildroot.tar.gz"
fi
cp -a "$S/board/kianv" "$B/board/"
cp -a "$S/boot" "$S/package" "$B/"
dtc -I dts -O dtb -S 4096 -i "$H" -o "$B/board/kianv/rv32ima_sv32/kianv.dtb" "${TO2610_DTS:-$H/to2610-kvc.dts}"
C=$B/configs/to2610_kvc_defconfig
sed -e "s|@OVERLAY@|$H/overlay${TO2610_OVERLAY:+ $TO2610_OVERLAY}|" -e "s|@PATCHES@|$H/patches|" "$H/defconfig" > "$C"
echo "BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES=\"$H/linux.fragment${TO2610_KCONFIG:+ $TO2610_KCONFIG}\"" >> "$C"
echo "BR2_ROOTFS_POST_BUILD_SCRIPT=\"$H/post.sh${TO2610_POST:+ $TO2610_POST}\"" >> "$C"
make -C "$B" to2610_kvc_defconfig
(cd "$B" && patch -p1 --forward < "$S/patches/0001-fix-make-parameter.patch" || true)
# 下载偶尔断，断了接着下
for i in 1 2 3 4 5 6; do make -C "$B" source && break; echo "下载第 $i 次没齐"; sleep 10; done
# 内核与 OpenSBI 每次重来：设备树、配置片段、往内核里放的驱动 buildroot 都不跟踪，树里上一次编的可能是另一颗芯片的
for p in linux opensbi; do
  ! compgen -G "$B/output/build/$p-*" > /dev/null || make -C "$B" "$p-dirclean"
done
# 根文件系统也每次重来（照 buildroot 手册的做法）：上一颗叠进去的文件不能留给下一颗
if [ -d "$B/output/target" ]; then
  rm -rf "$B/output/target"
  find "$B/output/build" -maxdepth 2 -name .stamp_target_installed -delete
  rm -f "$B"/output/build/host-gcc-final-*/.stamp_host_installed
fi
if [ -n "${TO2610_KHOOK:-}" ]; then
  make -C "$B" linux-patch
  bash "$TO2610_KHOOK" "$B"/output/build/linux-[0-9]*/
fi
make -C "$B"
# 根文件系统打完包，buildroot 才把内核重编一遍嵌进去；OpenSBI 的载荷在那之前就拼好了，里面的内核带的是
# 上一次的根文件系统，头一次是空的。所以载荷再拼一遍，并核对它里面就是最后那份内核（RV32 的载荷在 4 MiB 处）
make -C "$B" opensbi-rebuild
I=$B/output/images
cmp -s -i 4194304:0 -n "$(stat -c %s "$I/Image")" "$I/fw_payload.bin" "$I/Image" ||
  { echo "载荷里的内核不是最后那一份"; exit 1; }
cp "$I/fw_payload.bin" "$W/fw_payload.bin"
ls -la "$W/fw_payload.bin"
