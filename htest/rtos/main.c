/* FreeRTOS 冒烟：两个任务经一条队列传数，一个按节拍发、一个收了从串口报；再用一把互斥量护着串口。
 * 走得通就说明计时器中断、ecall 让出、抢占与上下文切换在这颗片子上都对。
 */
#include <stdint.h>
#include <stddef.h>

#include "FreeRTOS.h"
#include "queue.h"
#include "semphr.h"
#include "task.h"

#define REG(a) (*(volatile uint32_t *)(a))
#define LSR (*(volatile uint8_t *)0x10000005)

static QueueHandle_t box;
static SemaphoreHandle_t line;
static volatile uint32_t spins;

static void putch(char c) {
  while (!(LSR & 0x60)) {}
  REG(0x10000000) = c;
}

static void say(const char *s) {
  while (*s) putch(*s++);
}

static void dec(uint32_t v) {
  char b[10];
  int n = 0;
  do b[n++] = '0' + v % 10; while (v /= 10);
  while (n) putch(b[--n]);
}

void rtos_assert(const char *file, int line_no) {
  say("\nassert ");
  say(file);
  putch(':');
  dec(line_no);
  putch('\n');
  for (;;) {}
}

void *memset(void *d, int c, size_t n) {
  for (uint8_t *p = d; n--;) *p++ = c;
  return d;
}

void *memcpy(void *d, const void *s, size_t n) {
  const uint8_t *q = s;
  for (uint8_t *p = d; n--;) *p++ = *q++;
  return d;
}

static void sender(void *arg) {
  (void)arg;
  for (uint32_t i = 1; i <= 5; i++) {
    vTaskDelay(3);
    xQueueSend(box, &i, portMAX_DELAY);
  }
  for (;;) vTaskDelay(1000);
}

static void receiver(void *arg) {
  (void)arg;
  uint32_t v, sum = 0;
  TickType_t t0 = xTaskGetTickCount();
  for (int k = 0; k < 5; k++) {
    xQueueReceive(box, &v, portMAX_DELAY);
    sum += v;
    xSemaphoreTake(line, portMAX_DELAY);
    say("rtos got ");
    dec(v);
    putch('\n');
    xSemaphoreGive(line);
  }
  /* 发的那边每 3 拍发一个，五个至少过了 15 拍；低优先级的那个任务这期间被抢占着也转过 */
  uint32_t ticks = xTaskGetTickCount() - t0;
  xSemaphoreTake(line, portMAX_DELAY);
  say(sum == 15 && ticks >= 12 && ticks < 40 && spins > 0 ? "rtos done\n" : "rtos BAD\n");
  xSemaphoreGive(line);
  for (;;) vTaskDelay(1000);
}

/* 最低优先级，不让出：只有抢占起作用，上面两个才轮得到 */
static void spinner(void *arg) {
  (void)arg;
  for (;;) spins++;
}

int main(void) {
  uint32_t hz = (REG(0x10000014) & 0xffff) * 15625 / 4;
  REG(0x1000000c) = hz / 115200;
  say("FreeRTOS on to2610-kvc\n");
  box = xQueueCreate(4, sizeof(uint32_t));
  line = xSemaphoreCreateMutex();
  xTaskCreate(sender, "send", 256, NULL, 2, NULL);
  xTaskCreate(receiver, "recv", 256, NULL, 3, NULL);
  xTaskCreate(spinner, "spin", 256, NULL, 1, NULL);
  vTaskStartScheduler();
  say("scheduler returned\n");
  for (;;) {}
}
