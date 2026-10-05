O ?= build
CROSS ?= riscv64-unknown-elf-

$(O)/echo.bin: start.S echo.c link.ld
	mkdir -p $(O)
	$(CROSS)gcc -march=rv32ima_zicsr -mabi=ilp32 -Os -ffreestanding -nostdlib -Wl,-T,link.ld -o $(O)/echo.elf start.S echo.c
	$(CROSS)objcopy -O binary $(O)/echo.elf $@
