// 在 Linux 里经 spidev 重放 spirec.py 录下的 SPI 收发：标准输入每行一次传输（十六进制），
// 片选拉低、全双工收发、片选拉高，把收到的字节按同样的格式打到标准输出。
//
//   spix /dev/spidev1.0 2000000 < router.spi
//
// 模式 0，高位先出。速率不超过对面芯片主频的八分之一。

#include <fcntl.h>
#include <linux/spi/spidev.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX 2048

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <spidev> [hz] < transfers\n", argv[0]);
    return 2;
  }
  uint32_t hz = argc > 2 ? (uint32_t)strtoul(argv[2], 0, 0) : 2000000;
  uint8_t mode = SPI_MODE_0, bits = 8;
  int fd = open(argv[1], O_RDWR);
  if (fd < 0 || ioctl(fd, SPI_IOC_WR_MODE, &mode) < 0 || ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &bits) < 0
      || ioctl(fd, SPI_IOC_WR_MAX_SPEED_HZ, &hz) < 0) {
    perror(argv[1]);
    return 1;
  }
  static char line[2 * MAX + 4];
  static uint8_t tx[MAX], rx[MAX];
  while (fgets(line, sizeof line, stdin)) {
    size_t n = 0;
    for (char *p = line; p[0] && p[1] && p[0] != '\n' && n < MAX; p += 2) {
      unsigned v;
      if (sscanf(p, "%2x", &v) != 1) break;
      tx[n++] = (uint8_t)v;
    }
    if (!n) continue;
    struct spi_ioc_transfer t;
    memset(&t, 0, sizeof t);
    t.tx_buf = (unsigned long)tx;
    t.rx_buf = (unsigned long)rx;
    t.len = (uint32_t)n;
    t.speed_hz = hz;
    t.bits_per_word = 8;
    if (ioctl(fd, SPI_IOC_MESSAGE(1), &t) < 0) {
      perror("transfer");
      return 1;
    }
    for (size_t i = 0; i < n; i++) printf("%02x", rx[i]);
    putchar('\n');
  }
  close(fd);
  return 0;
}
