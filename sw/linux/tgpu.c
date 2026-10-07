// /dev/tgpu 的命令行：装载 gpu.py build 出的 .tgk、起跑、读回、设视频。
//
//   tgpu info
//   tgpu run shade.tgk [超时毫秒]      拍数打到标准错误，数据存储的 256 个字节按十六进制打到标准输出
//   tgpu read
//   tgpu video 64 8x8 [rgb|off]
//
// .tgk 是小端：'TGK1'、线程数、程序条数、数据字节数、两个字节的空，然后是程序（每条 16 位）与数据。

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "tgpu.h"

static int usage(void) {
  fprintf(stderr, "usage: tgpu info | run <kernel.tgk> [timeout_ms] | read | video <at> <w>x<h> [rgb|off]\n");
  return 2;
}

static int dump(int fd) {
  struct tgpu_mem m;
  if (ioctl(fd, TGPU_IOC_READ, &m) < 0) return perror("read"), 1;
  for (int i = 0; i < TGPU_WORDS; i++) printf("%02x", m.data[i]);
  putchar('\n');
  return 0;
}

static int load(int fd, const char *path) {
  static uint8_t f[12 + 2 * TGPU_WORDS + TGPU_WORDS];
  FILE *in = fopen(path, "rb");
  if (!in) return perror(path), 1;
  size_t n = fread(f, 1, sizeof f, in);
  fclose(in);
  unsigned threads = f[4] | f[5] << 8, np = f[6] | f[7] << 8, nd = f[8] | f[9] << 8;
  if (n < 12 || memcmp(f, "TGK1", 4) || np > TGPU_WORDS || nd > TGPU_WORDS || n < 12 + 2 * np + nd) {
    fprintf(stderr, "%s：不是 gpu.py build 出的 .tgk\n", path);
    return 1;
  }
  struct tgpu_kernel k;
  memset(&k, 0, sizeof k);
  k.threads = threads;
  for (unsigned i = 0; i < np; i++) k.prog[i] = f[12 + 2 * i] | f[13 + 2 * i] << 8;
  memcpy(k.data, f + 12 + 2 * np, nd);
  if (ioctl(fd, TGPU_IOC_LOAD, &k) < 0) return perror("load"), 1;
  return 0;
}

int main(int argc, char **argv) {
  if (argc < 2) return usage();
  int fd = open("/dev/tgpu", O_RDWR);
  if (fd < 0) return perror("/dev/tgpu"), 1;
  if (!strcmp(argv[1], "info")) {
    struct tgpu_info i;
    if (ioctl(fd, TGPU_IOC_INFO, &i) < 0) return perror("info"), 1;
    printf("to2610-gpu: %u cores, %u threads a block\n", i.cores, i.tpb);
    return 0;
  }
  if (!strcmp(argv[1], "run") && argc >= 3) {
    if (load(fd, argv[2])) return 1;
    struct tgpu_run r = { .timeout_ms = argc > 3 ? (uint32_t)strtoul(argv[3], 0, 0) : 1000 };
    if (ioctl(fd, TGPU_IOC_RUN, &r) < 0) return perror("run"), 1;
    fprintf(stderr, "%u cycles\n", r.cycles);
    return dump(fd);
  }
  if (!strcmp(argv[1], "read")) return dump(fd);
  if (!strcmp(argv[1], "video") && argc >= 4) {
    unsigned w, h;
    if (sscanf(argv[3], "%ux%u", &w, &h) != 2) return usage();
    struct tgpu_video v = { (uint8_t)atoi(argv[2]), (uint8_t)w, (uint8_t)h, TGPU_VIDEO_ON };
    if (argc > 4 && !strcmp(argv[4], "rgb")) v.flags |= TGPU_VIDEO_RGB;
    if (argc > 4 && !strcmp(argv[4], "off")) v.flags = 0;
    if (ioctl(fd, TGPU_IOC_VIDEO, &v) < 0) return perror("video"), 1;
    return 0;
  }
  return usage();
}
