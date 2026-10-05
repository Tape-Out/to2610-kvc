O ?= build
CROSS ?= riscv64-unknown-elf-

$(O)/boot.bin: start.S boot.c link.ld
	mkdir -p $(O)
	$(CROSS)gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -Wl,-T,link.ld -o $(O)/boot.elf start.S boot.c
	$(CROSS)objcopy -O binary $(O)/boot.elf $@
