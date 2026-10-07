#!/usr/bin/env bash
# Linux 起到 shell 之后的各层，都从整片测试 linux 段存下的断点起，不再从 Flash 引导一遍：
#   sdcard   SPI0 上插一张 SD 卡（FAT16，镜像由黑盒仓的 htest/sdimg.py 出）：mmc_spi 认卡、挂载、读文件核 md5、写文件、
#            重挂再读；跑完从卡的镜像里取出芯片写的那个文件核对
#   network  SPI1 上接 W5500：spimode net 重新探测网卡、改 MAC、udhcpc 向测试台里的主机要地址、ping 它
#   netjoin  同一颗 W5500 的网线接到 switch 与 router 的联合仿真上（to2610-router 的 htest/with-kvc.sh），
#            照 future-work/04 的 L4 一字不差：定 MAC、配地址与 MTU、加路由，ping 同网段的 A0 与另一网段的 B0
#   netinet  同上，但 B0 换成宿主机的 TAP 网卡（真的 TCP/IP，替它做 NAT）：ping 宿主机、TCP 取一个文件核 md5、
#            经 NAT 向 8.8.8.8 查 DNS、按名字取 example.com 的页面。要 sudo
#   gpujoin  SPI1 上接一整颗 to2610-gpu，照 future-work/07 的 G7：主机侧用它的 gpu.py 把装载、起跑、查状态、读回、
#            开视频录成 SPI 收发放在卡上，Linux 里 spimode dev 之后用 spix 重放；读回的数据存储与软件模型逐字节比
#   gpudrv   同一颗 gpu 走内核驱动：spimode gpu 绑上 to2610-gpu 驱动，tgpu 装载 gpu.py build 出的 .tgk，渲染（shade）与
#            推理（mlp）各跑一遍、读回与软件模型逐字节比，再经驱动设两种视频格式
# 断点、编好的仿真器与 Flash 镜像在 build/ckpt（整片测试留下的，流水线上由前一个作业交过来）；CKPT 给了就用那里的
# （to2610-soc 的接力留在它的 build/linux-run）。
# LAYERS 给要跑的段名，空格分隔；net 是前四段、gpu 是后两段，不给就六段全跑。流水线上分几个作业同时跑，一个作业放不下。
# 用法：linux-layers.sh <输出目录> <黑盒仓> <to2610-router 仓> [<to2610-gpu 仓>]（只跑 net 时不要 gpu）
set -euo pipefail
cd "$(dirname "$0")/.."
O=$(realpath -m "$1")
K=$(realpath "$2")
RT=$(realpath "$3")
GP=${4:+$(realpath "$4")}
C=${CKPT:-$PWD/build/ckpt}
rm -rf "$O"
mkdir -p "$O"
for f in linux.ckpt linux.ckpt.tb Vtb linux.flash; do
  [ -s "$C/$f" ] || { echo "build/ckpt 里没有 $f：先跑整片测试的 linux 段"; exit 1; }
done
chmod +x "$C/Vtb"

res=()
run() {
  local name=$1 what=$2 t0=$SECONDS rc=0
  shift 2
  "$C/Vtb" +flash="$C/linux.flash@0" +restore="$C/linux.ckpt" +pace=600000 +max=6000000000 +beat=500000000 "$@" \
    > "$O/$name.log" 2> "$O/$name.err" || rc=$?
  tail -n 3 "$O/$name.err"
  res+=("$name=$rc:$((SECONDS - t0)):$what")
  return $rc
}

# 网线接到 switch 与 router 的联合仿真上：那一半先起，放下 ready 再起 kvc 这一半；这一半跑完放下 stop。
# 其后的参数是给那一半的环境变量
join() {
  local name=$1 what=$2 script=$3 b=$O/$1.bridge n=0 net
  shift 3
  mkdir -p "$b"
  (cd "$RT" && env "$@" bash htest/with-kvc.sh "$O/$name.net" "$b" > "$O/$name.net.log" 2>&1) &
  net=$!
  until [ -f "$b/ready" ] || ! kill -0 $net 2> /dev/null || [ $n -ge 720 ]; do
    sleep 5
    n=$((n + 1))
  done
  if [ -f "$b/ready" ]; then
    run "$name" "$what" +nicpipe="$b" +script="$script" || true
    touch "$b/stop"
    if ! wait $net; then
      echo "交换机与路由器那一半没过："
      tail -n 8 "$O/$name.net.log"
      res[-1]="$name=1:${res[-1]#*:}"
    fi
  else
    touch "$b/stop"
    wait $net || true
    tail -n 8 "$O/$name.net.log"
    res+=("$name=1:0:交换机与路由器那一半没起来")
  fi
}

# SD 卡：一个短文本、一块 64 KiB 的伪随机数据；上网那一段宿主机上放一块 8 KiB 的
mkdir -p "$O/www"
python3 - "$O" <<'EOF'
import pathlib, random, sys
d = pathlib.Path(sys.argv[1])
(d / "hello.txt").write_text("hello from the card\n")
(d / "blob.bin").write_bytes(random.Random(2610).randbytes(65536))
(d / "www" / "blob").write_bytes(random.Random(2611).randbytes(8192))
EOF
python3 "$K/htest/sdimg.py" "$O/sd.img" "$O/hello.txt" "$O/blob.bin"
md5=$(md5sum < "$O/blob.bin" | cut -c1-32)
sed "s/@MD5@/$md5/" htest/linux/sdcard.script > "$O/sdcard.script"
case "${LAYERS:-all}" in
  all) pick=" sdcard network netjoin netinet gpujoin gpudrv " ;;
  net) pick=" sdcard network netjoin netinet " ;;
  gpu) pick=" gpujoin gpudrv " ;;
  *) pick=" $LAYERS " ;;
esac
want() { [[ $pick == *" $1 "* ]]; }

rc=0
if want sdcard; then
run sdcard "SPI0 上插 SD 卡：mmc_spi 认卡、挂 FAT16、读文件与 64 KiB 的 md5、写文件、重挂再读" \
  +sd="$O/sd.img" +sdout="$O/sd.out" +script="$O/sdcard.script" || rc=$?
if [ $rc = 0 ] && [ "$(python3 "$K/htest/sdimg.py" --cat "$O/sd.out" out.txt)" != written-by-to2610 ]; then
  echo "卡上没有芯片写的那个文件"
  res[-1]="sdcard=1:${res[-1]#*:}"
fi
fi

want network && { run network "SPI1 上接 W5500：重新探测网卡、ip link 改 MAC、udhcpc 拿到 10.0.0.2、ping 网线那头的主机三次都回" \
  +w5500 +script=htest/linux/network.script || true; }

want netjoin && join netjoin "网线接到 switch 与 router 的联合仿真上，照 future-work/04 的 L4：同网段 ping A0、过路由器 ping B0（TTL 63）" \
  htest/linux/netjoin.script

if want netinet; then
md5=$(md5sum < "$O/www/blob" | cut -c1-32)
sed "s/@MD5@/$md5/" htest/linux/netinet.script > "$O/netinet.script"
join netinet "B0 换成宿主机：过路由器 ping 它、TCP 取 8 KiB 核 md5、经 NAT 查 DNS、按名字取 example.com 的页面" \
  "$O/netinet.script" NET_TAP=xr0 NET_WWW="$O/www"
fi

if want gpujoin || want gpudrv; then
# gpu：收发录在一张卡上，只有 spix 读回来的数据部分（读传输的第 7 个字节起）拿来比
mkdir -p "$O/gpu"
python3 - "$GP/sw" "$O/gpu" <<'EOF'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import gpu as G
import spis
d = pathlib.Path(sys.argv[2])

def rec(*ops):
    out = []
    for op in ops:
        spis.run(op, lambda tx: (out.append(tx.hex()), bytes(len(tx)))[1])
    return "\n".join(out) + "\n"

k = G.assemble((pathlib.Path(sys.argv[1]) / "kernels" / "shade.asm").read_text(encoding="utf-8"))
(d / "load").write_text(rec(G.load(k), G.start()))
(d / "done").write_text(rec(G.done()))
(d / "mem").write_text(rec(G.memory()))
(d / "want").write_text("".join(f"{v:08x}" for v in G.emulate(k)) + "\n")
(d / "video").write_text(rec(G.video(64, 8, 8)))
(d / "vrd").write_text(rec(spis.rd(G.BASE + G.VCTRL, 3)))
(d / "vwant").write_text("".join(f"{v:08x}" for v in (1, 64 | 8 << 8 | 8 << 16, 80 | 60 << 16)) + "\n")
for name, want in (("shade", "want8"), ("mlp", "mlp8")):
    k = G.assemble((pathlib.Path(sys.argv[1]) / "kernels" / f"{name}.asm").read_text(encoding="utf-8"))
    (d / f"{name}.tgk").write_bytes(G.tgk(k))
    (d / want).write_text(bytes(G.emulate(k)).hex() + "\n")
EOF
python3 "$K/htest/sdimg.py" "$O/gpu.img" "$O"/gpu/*
run gpujoin "SPI1 上接一整颗 to2610-gpu：spimode dev，spix 装载 shade 起跑、等 done、读回 256 字节与软件模型逐字节相同，开视频并读回三个视频寄存器" \
  +gpu +sd="$O/gpu.img" +script=htest/linux/gpujoin.script || true
run gpudrv "同一颗 gpu 走内核驱动：spimode gpu 绑上驱动，tgpu 跑渲染（shade）与推理（mlp）、读回与软件模型逐字节相同，经驱动设视频" \
  +gpu +sd="$O/gpu.img" +script=htest/linux/gpudrv.script || true
fi

python3 htest/junit.py "$O/results.xml" "${res[@]}"
printf '%s\n' "${res[@]}"
if grep -q '<failure' "$O/results.xml"; then echo "有用例没过"; exit 1; fi
echo "Linux 的各层 ${#res[@]} 段全过"
