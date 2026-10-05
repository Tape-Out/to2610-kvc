# to2610-kvc

A single-core chip that boots Linux, for the ECOS 2610 shuttle: Hirosh Dabui's KianV RV32IMA core with Sv32, a UART, an SD card port, a network SPI port and an SDRAM controller. Program and memory are off the chip: an SPI flash and a 32 MiB SDRAM.

![maturity](https://img.shields.io/badge/maturity-simulated-yellow) ![license](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0%20OR%20MulanPSL--2.0-blue)

The chip is [`gf180mcu-kianv-rv32ima-sv32`](https://github.com/Tape-Out/gf180mcu-kianv-rv32ima-sv32), the SoC upstream taped out on GF180MCU with the one-line patch that repository carries, taken whole and wrapped by [`xirang`](https://github.com/Tape-Out/xirang) into the five-port top of MPC-Frame. There is no RTL of its own; the software under `sw/` is.

The functions, the memory map, the board wiring down to the part numbers, the chip tests and the limits are in [`docs/流片说明.md`](docs/流片说明.md); the tape-out report is generated from that file.

## Software

```console
$ bash sw/linux/build.sh                  # toolchain, OpenSBI, Linux and root file system, from upstream's buildroot recipe
$ make -C sw/boot                         # the boot loader that runs in place from the flash
$ python3 sw/pack.py sw/boot/build/boot.bin build/linux/fw_payload.bin flash.bin
$ bash sw/flash.sh flash.bin              # write the flash with a CH341A
$ bash sw/console.sh /dev/ttyUSB0         # 115200 8N1
```

The flash holds the boot loader at 1 MiB and the payload, behind a 16-byte header, 64 KiB after it. After reset the core fetches from the flash at `0x2010_0000`; the boot loader copies the payload to the start of the SDRAM, checks its sum and jumps.

## Testing and tape-out

```console
$ ran test to2610-kvc                   # the chip tests, on the Verilog file that goes to the shuttle
$ ran asic to2610-kvc                   # to2610_kvc.v, ecc at 50 MHz, report.json
$ ran asic to2610-kvc --no-run          # only the Verilog file and ecc.toml
```

The chip tests run on Verilator with pin-level models of the SDRAM, the flash and the UART: a bare-metal memory check, the boot loader with an echo payload, and Linux up to a shell.

## License

任选其一：

- [MIT](LICENSE-MIT)
- [Apache 2.0](LICENSE-APACHE)
- [木兰宽松许可证 第2版](LICENSE-MULAN)

`SPDX-License-Identifier: MIT OR Apache-2.0 OR MulanPSL-2.0`

除非另行说明，你提交的贡献按上述三者同时授权，不附加其他条件。
