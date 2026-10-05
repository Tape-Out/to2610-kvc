"""载荷里的内核与根文件系统先在 QEMU 的 virt 机器上起一遍。

一分钟内知道镜像本身是不是好的，再去跑小时级的整片仿真：根文件系统没嵌进去、init 起不来这一类，
在这里就拦下。验的只是软件；引导程序、SDRAM、片上外设在整片仿真里验。
脚本的写法同测试台的：expect 等一段字出现，send 往串口发字。

用法：qemu.py <fw_payload.bin> <脚本> <输出目录>
"""
import os
import pathlib
import selectors
import subprocess
import sys
import time

# RV32 的载荷里内核在 4 MiB 处；OpenSBI 用 QEMU 自带的，机器的设备树也用它给的
OFFSET = 4 << 20
LIMIT = 120


def unesc(s: str) -> bytes:
    return s.encode().decode("unicode_escape").encode()


def main() -> int:
    payload, script, out = (pathlib.Path(a) for a in sys.argv[1:4])
    out.mkdir(parents=True, exist_ok=True)
    image = out / "Image"
    image.write_bytes(payload.read_bytes()[OFFSET:])
    steps = []
    for ln in script.read_text(encoding="utf-8").splitlines():
        kind, _, text = ln.partition(" ")
        if kind in ("expect", "send"):
            steps.append((kind, unesc(text)))
    q = subprocess.Popen(
        ["qemu-system-riscv32", "-M", "virt", "-m", "32M", "-nographic", "-kernel", str(image),
         "-append", "earlycon=sbi console=ttyS0"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert q.stdin and q.stdout
    os.set_blocking(q.stdout.fileno(), False)
    sel = selectors.DefaultSelector()
    sel.register(q.stdout, selectors.EVENT_READ)
    seen, at, t0 = b"", 0, time.monotonic()
    try:
        for i, (kind, text) in enumerate(steps):
            if kind == "send":
                q.stdin.write(text)
                q.stdin.flush()
                continue
            while (k := seen.find(text, at)) < 0:
                if time.monotonic() - t0 > LIMIT or q.poll() is not None:
                    (out / "qemu.log").write_bytes(seen)
                    print(f"QEMU 上没等到第 {i + 1} 步的 {text.decode()!r}，日志在 {out / 'qemu.log'}")
                    print(seen[-600:].decode(errors="replace"))
                    return 1
                if sel.select(timeout=1):
                    seen += q.stdout.read() or b""
            at = k + len(text)
    finally:
        q.kill()
        q.wait()
    (out / "qemu.log").write_bytes(seen)
    print(f"QEMU 上 {len(steps)} 步走完，{time.monotonic() - t0:.0f} 秒")
    return 0


if __name__ == "__main__":
    sys.exit(main())
