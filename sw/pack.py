"""拼 Flash 镜像：引导程序在 1 MiB，载荷带 16 字节的头放在它后面 64 KiB 处。

载荷紧跟着放：Flash 的窗口只有 16 MiB，而载荷里 OpenSBI 到内核之间的空白就占 4 MiB。

用法：pack.py <boot.bin> <载荷> <输出>
"""
import pathlib
import struct
import sys

BOOT, PAYLOAD, MAGIC = 0x100000, 0x110000, 0x4C50564B

boot = pathlib.Path(sys.argv[1]).read_bytes()
load = pathlib.Path(sys.argv[2]).read_bytes()
if len(boot) > PAYLOAD - BOOT:
    sys.exit(f"引导程序 {len(boot)} 字节，放不进 64 KiB")
body = load + b"\0" * (-len(load) % 4)
total = sum(struct.unpack(f"<{len(body) // 4}I", body)) & 0xFFFFFFFF
img = bytearray(b"\xff" * (PAYLOAD + 16 + len(body)))
img[BOOT:BOOT + len(boot)] = boot
img[PAYLOAD:PAYLOAD + 16] = struct.pack("<4I", MAGIC, len(load), total, 0)
img[PAYLOAD + 16:] = body
if len(img) > 16 << 20:
    sys.exit(f"镜像 {len(img)} 字节，超过 16 MiB 的 Flash 窗口")
pathlib.Path(sys.argv[3]).write_bytes(img)
print(f"{sys.argv[3]}：引导程序 {len(boot)} 字节，载荷 {len(load)} 字节，共 {len(img)} 字节")
