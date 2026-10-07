// SPDX-License-Identifier: GPL-2.0
/*
 * The to2610-gpu chip on an SPI port: tiny-gpu with its program and data memories behind
 * the management protocol shared with to2610-switch and to2610-router.
 *
 * The done pin need not be wired to this board, so a run polls the status word; a kernel
 * of a few hundred threads finishes in microseconds and the SPI traffic dominates anyway.
 * The slot is shared with the network card and spidev, so the device is bound by
 * driver_override (spimode gpu) as well as by compatible.
 */
#include <linux/delay.h>
#include <linux/jiffies.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/spi/spi.h>
#include <linux/uaccess.h>
#include <linux/unaligned.h>

#include "tgpu.h"

#define BASE		0x10000000
#define CTRL		0x000
#define THREADS		0x004
#define STATUS		0x008
#define CYCLES		0x00c
#define ID		0x010
#define CONFIG		0x014
#define VCTRL		0x018
#define VFMT		0x01c
#define PROG		0x400
#define DATA		0x800
#define MAGIC		0x54475055

struct tgpu {
	struct spi_device *spi;
	struct miscdevice misc;
	struct mutex lock;
	u32 cores, tpb, threads;
	u8 *buf;
	u32 w[TGPU_WORDS];
};

static int tgpu_wr(struct tgpu *g, u32 addr, const u32 *w, unsigned int n)
{
	unsigned int i;

	g->buf[0] = 0x02;
	put_unaligned_be32(BASE + addr, g->buf + 1);
	for (i = 0; i < n; i++)
		put_unaligned_be32(w[i], g->buf + 5 + 4 * i);
	return spi_write(g->spi, g->buf, 5 + 4 * n);
}

static int tgpu_wr1(struct tgpu *g, u32 addr, u32 v)
{
	return tgpu_wr(g, addr, &v, 1);
}

static int tgpu_rd(struct tgpu *g, u32 addr, u32 *w, unsigned int n)
{
	u8 cmd[7] = { 0x0b };
	unsigned int i;
	int ret;

	put_unaligned_be32(BASE + addr, cmd + 1);
	cmd[5] = n - 1;
	ret = spi_write_then_read(g->spi, cmd, sizeof(cmd), g->buf, 4 * n);
	if (ret)
		return ret;
	for (i = 0; i < n; i++)
		w[i] = get_unaligned_be32(g->buf + 4 * i);
	return 0;
}

static int tgpu_load(struct tgpu *g, const struct tgpu_kernel *k)
{
	unsigned int i;
	int ret;

	/* The hardware never finishes a last block that is not full. */
	if (!k->threads || k->threads > 255 || k->threads % g->tpb)
		return -EINVAL;
	ret = tgpu_wr1(g, CTRL, 0);
	for (i = 0; i < TGPU_WORDS; i++)
		g->w[i] = k->prog[i];
	ret = ret ?: tgpu_wr(g, PROG, g->w, TGPU_WORDS);
	for (i = 0; i < TGPU_WORDS; i++)
		g->w[i] = k->data[i];
	ret = ret ?: tgpu_wr(g, DATA, g->w, TGPU_WORDS);
	ret = ret ?: tgpu_wr1(g, THREADS, k->threads);
	if (!ret)
		g->threads = k->threads;
	return ret;
}

static int tgpu_run(struct tgpu *g, struct tgpu_run *r)
{
	unsigned long end = jiffies + msecs_to_jiffies(r->timeout_ms ?: 1000);
	u32 st;
	int ret;

	if (!g->threads)
		return -ENOEXEC;
	ret = tgpu_wr1(g, CTRL, 1);
	while (!ret) {
		ret = tgpu_rd(g, STATUS, &st, 1);
		if (ret || st & 1)
			break;
		if (time_after(jiffies, end)) {
			tgpu_wr1(g, CTRL, 0);
			return -ETIMEDOUT;
		}
		usleep_range(200, 1000);
	}
	return ret ?: tgpu_rd(g, CYCLES, &r->cycles, 1);
}

static int tgpu_video(struct tgpu *g, const struct tgpu_video *v)
{
	u32 w[2];

	if (!v->w || !v->h || v->at + v->w * v->h > TGPU_WORDS)
		return -EINVAL;
	w[0] = v->at | v->w << 8 | v->h << 16;
	w[1] = (640 / v->w) | (480 / v->h) << 16;
	return tgpu_wr(g, VFMT, w, 2) ?: tgpu_wr1(g, VCTRL, v->flags & (TGPU_VIDEO_ON | TGPU_VIDEO_RGB));
}

static long tgpu_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct tgpu *g = container_of(file->private_data, struct tgpu, misc);
	void __user *p = (void __user *)arg;
	union {
		struct tgpu_info info;
		struct tgpu_kernel k;
		struct tgpu_run r;
		struct tgpu_mem m;
		struct tgpu_video v;
	} *u;
	unsigned int i;
	long ret;

	if (_IOC_TYPE(cmd) != 'G' || _IOC_SIZE(cmd) > sizeof(*u))
		return -ENOTTY;
	u = kzalloc(sizeof(*u), GFP_KERNEL);
	if (!u)
		return -ENOMEM;
	if ((_IOC_DIR(cmd) & _IOC_WRITE) && copy_from_user(u, p, _IOC_SIZE(cmd))) {
		ret = -EFAULT;
		goto out;
	}
	mutex_lock(&g->lock);
	switch (cmd) {
	case TGPU_IOC_INFO:
		u->info.cores = g->cores;
		u->info.tpb = g->tpb;
		ret = 0;
		break;
	case TGPU_IOC_LOAD:
		ret = tgpu_load(g, &u->k);
		break;
	case TGPU_IOC_RUN:
		ret = tgpu_run(g, &u->r);
		break;
	case TGPU_IOC_READ:
		ret = tgpu_rd(g, DATA, g->w, TGPU_WORDS);
		for (i = 0; !ret && i < TGPU_WORDS; i++)
			u->m.data[i] = g->w[i];
		break;
	case TGPU_IOC_VIDEO:
		ret = tgpu_video(g, &u->v);
		break;
	default:
		ret = -ENOTTY;
	}
	mutex_unlock(&g->lock);
	if (!ret && (_IOC_DIR(cmd) & _IOC_READ) && copy_to_user(p, u, _IOC_SIZE(cmd)))
		ret = -EFAULT;
out:
	kfree(u);
	return ret;
}

static const struct file_operations tgpu_fops = {
	.owner = THIS_MODULE,
	.unlocked_ioctl = tgpu_ioctl,
};

static int tgpu_probe(struct spi_device *spi)
{
	struct tgpu *g;
	u32 w[2];
	int ret;

	spi->mode = SPI_MODE_0;
	spi->bits_per_word = 8;
	/* The management port samples SCK with the chip clock: an eighth of 50 MHz at most. */
	if (!spi->max_speed_hz || spi->max_speed_hz > 2000000)
		spi->max_speed_hz = 2000000;
	ret = spi_setup(spi);
	if (ret)
		return ret;

	g = devm_kzalloc(&spi->dev, sizeof(*g), GFP_KERNEL);
	if (!g)
		return -ENOMEM;
	g->buf = devm_kmalloc(&spi->dev, 5 + 4 * TGPU_WORDS, GFP_KERNEL);
	if (!g->buf)
		return -ENOMEM;
	g->spi = spi;
	mutex_init(&g->lock);

	ret = tgpu_rd(g, ID, w, 2);
	if (ret)
		return ret;
	if (w[0] != MAGIC) {
		dev_info(&spi->dev, "no to2610-gpu here (id %08x)\n", w[0]);
		return -ENODEV;
	}
	g->cores = w[1] >> 8 & 0xff;
	g->tpb = w[1] & 0xff;
	if (!g->tpb)
		return -ENODEV;

	g->misc.minor = MISC_DYNAMIC_MINOR;
	g->misc.name = "tgpu";
	g->misc.fops = &tgpu_fops;
	g->misc.parent = &spi->dev;
	ret = misc_register(&g->misc);
	if (ret)
		return ret;
	spi_set_drvdata(spi, g);
	dev_info(&spi->dev, "to2610-gpu: %u cores, %u threads a block, /dev/tgpu\n", g->cores, g->tpb);
	return 0;
}

static void tgpu_remove(struct spi_device *spi)
{
	struct tgpu *g = spi_get_drvdata(spi);

	misc_deregister(&g->misc);
}

static const struct of_device_id tgpu_of[] = {
	{ .compatible = "tapeout,to2610-gpu" },
	{ }
};
MODULE_DEVICE_TABLE(of, tgpu_of);

static const struct spi_device_id tgpu_ids[] = {
	{ "to2610-gpu" },
	{ }
};
MODULE_DEVICE_TABLE(spi, tgpu_ids);

static struct spi_driver tgpu_driver = {
	.driver = {
		.name = "to2610-gpu",
		.of_match_table = tgpu_of,
	},
	.id_table = tgpu_ids,
	.probe = tgpu_probe,
	.remove = tgpu_remove,
};
module_spi_driver(tgpu_driver);

MODULE_DESCRIPTION("to2610-gpu over SPI");
MODULE_LICENSE("GPL");
