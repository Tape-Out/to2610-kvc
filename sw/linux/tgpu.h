/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
/*
 * /dev/tgpu: the to2610-gpu chip on an SPI port. Shared by the driver and user space.
 *
 * A kernel is the whole program memory and data memory plus a thread count: LOAD writes
 * both memories, RUN starts it and waits for done, READ returns the data memory, VIDEO
 * sets which block of the data memory is scanned out to VGA and HDMI.
 */
#ifndef TGPU_H
#define TGPU_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define TGPU_WORDS 256

struct tgpu_info {
	__u32 cores;
	__u32 tpb;
};

struct tgpu_kernel {
	__u32 threads;
	__u16 prog[TGPU_WORDS];
	__u8 data[TGPU_WORDS];
};

struct tgpu_run {
	__u32 timeout_ms;
	__u32 cycles;
};

struct tgpu_mem {
	__u8 data[TGPU_WORDS];
};

#define TGPU_VIDEO_ON	1
#define TGPU_VIDEO_RGB	2

struct tgpu_video {
	__u8 at;
	__u8 w;
	__u8 h;
	__u8 flags;
};

#define TGPU_IOC_INFO	_IOR('G', 0, struct tgpu_info)
#define TGPU_IOC_LOAD	_IOW('G', 1, struct tgpu_kernel)
#define TGPU_IOC_RUN	_IOWR('G', 2, struct tgpu_run)
#define TGPU_IOC_READ	_IOR('G', 3, struct tgpu_mem)
#define TGPU_IOC_VIDEO	_IOW('G', 4, struct tgpu_video)

#endif
