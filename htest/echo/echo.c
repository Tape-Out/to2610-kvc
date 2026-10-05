/* 引导测试用的载荷：报到之后把串口收到的字原样发回去。串口的分频引导程序已经设好 */
#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)

static void putch(char c) {
  while (!(LSR & 0x60)) {}
  REG(0x10000000) = c;
}

void main(void) {
  for (const char *s = "payload up\n"; *s; s++) putch(*s);
  for (;;) {
    /* 没收到字时读出来是全 1 */
    uint32_t v = REG(0x10000000);
    if (v != 0xffffffff) putch(v);
  }
}
