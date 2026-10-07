// Linux 下的应用测试：进程、管道、信号、共享映射、线程与原子操作、文件、软浮点、计时、本地套接字、exec。
// 每项打一行 ok 或 FAIL，再打「apptest all=<项数> ok=<过了的>」，有没过的另打一行 apptest failed。
// 数据量取小：仿真里的 Linux 每秒只走几十万拍
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int child_status(pid_t pid) {
  int st;
  return waitpid(pid, &st, 0) == pid ? st : -1;
}

static int t_fork(void) {
  pid_t pid = fork();
  if (pid == 0) _exit(42);
  int st = child_status(pid);
  return pid > 0 && WIFEXITED(st) && WEXITSTATUS(st) == 42;
}

static uint32_t mix(uint32_t h, const uint8_t *p, size_t n) {
  while (n--) h = (h ^ *p++) * 16777619u;
  return h;
}

static int t_pipe(void) {
  enum { N = 16384 };
  static uint8_t buf[N], got[N];
  for (size_t i = 0; i < N; i++) buf[i] = (uint8_t)(i * 7 + (i >> 8));
  int fd[2];
  if (pipe(fd)) return 0;
  pid_t pid = fork();
  if (pid == 0) {
    close(fd[0]);
    for (size_t off = 0; off < N;) {
      ssize_t w = write(fd[1], buf + off, N - off);
      if (w <= 0) _exit(1);
      off += (size_t)w;
    }
    _exit(0);
  }
  close(fd[1]);
  size_t off = 0;
  for (ssize_t r; off < N && (r = read(fd[0], got + off, N - off)) > 0;) off += (size_t)r;
  close(fd[0]);
  int st = child_status(pid);
  return off == N && WIFEXITED(st) && WEXITSTATUS(st) == 0 && mix(2166136261u, buf, N) == mix(2166136261u, got, N);
}

static volatile sig_atomic_t hit;
static void on_usr1(int s) { hit = s; }

static int t_signal(void) {
  struct sigaction sa = {.sa_handler = on_usr1};
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGUSR1, &sa, nullptr)) return 0;
  hit = 0;
  kill(getpid(), SIGUSR1);
  if (hit != SIGUSR1) return 0;
  // 子进程等着被杀：父进程收到的是「被 SIGTERM 杀掉」，不是正常退出
  pid_t pid = fork();
  if (pid == 0) {
    for (;;) pause();
  }
  kill(pid, SIGTERM);
  int st = child_status(pid);
  return WIFSIGNALED(st) && WTERMSIG(st) == SIGTERM;
}

static int t_mmap(void) {
  volatile uint32_t *p = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED) return 0;
  p[0] = 1;
  pid_t pid = fork();
  if (pid == 0) {
    p[0] = 0x2610;
    p[1023] = 0xC0FFEE;
    _exit(0);
  }
  child_status(pid);
  int ok = p[0] == 0x2610 && p[1023] == 0xC0FFEE;
  return munmap((void *)p, 4096) == 0 && ok;
}

enum { THREADS = 4, ROUNDS = 1000 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t locked, atomic;

static void *worker(void *arg) {
  (void)arg;
  for (int i = 0; i < ROUNDS; i++) {
    pthread_mutex_lock(&lock);
    locked++;
    pthread_mutex_unlock(&lock);
    __atomic_fetch_add(&atomic, 1, __ATOMIC_SEQ_CST);
  }
  return nullptr;
}

static int t_threads(void) {
  pthread_t t[THREADS];
  for (int i = 0; i < THREADS; i++)
    if (pthread_create(&t[i], nullptr, worker, nullptr)) return 0;
  for (int i = 0; i < THREADS; i++) pthread_join(t[i], nullptr);
  return locked == THREADS * ROUNDS && atomic == THREADS * ROUNDS;
}

static int t_file(void) {
  const char *a = "/tmp/apptest.a", *b = "/tmp/apptest.b";
  char want[1000], got[sizeof want];
  for (size_t i = 0; i < sizeof want; i++) want[i] = (char)('a' + i % 26);
  int fd = open(a, O_CREAT | O_TRUNC | O_RDWR, 0644);
  if (fd < 0) return 0;
  int ok = write(fd, want, sizeof want) == (ssize_t)sizeof want && fsync(fd) == 0 && lseek(fd, 0, SEEK_SET) == 0 &&
           read(fd, got, sizeof got) == (ssize_t)sizeof got && memcmp(want, got, sizeof want) == 0;
  close(fd);
  struct stat st;
  ok = ok && rename(a, b) == 0 && stat(b, &st) == 0 && st.st_size == (off_t)sizeof want && access(a, F_OK) != 0;
  return unlink(b) == 0 && ok;
}

// 核没有浮点单元，double 全走软件：1/k² 的部分和逼近 π²/6，与在主机上算的同一个和逐位比
static int t_float(void) {
  double s = 0;
  for (int k = 1; k <= 1000; k++) s += 1.0 / ((double)k * k);
  char out[32];
  snprintf(out, sizeof out, "%.15f", s);
  return strcmp(out, "1.643934566681561") == 0;
}

static int t_time(void) {
  struct timespec a, b, d = {.tv_nsec = 10 * 1000 * 1000};
  clock_gettime(CLOCK_MONOTONIC, &a);
  nanosleep(&d, nullptr);
  clock_gettime(CLOCK_MONOTONIC, &b);
  long long ns = (b.tv_sec - a.tv_sec) * 1000000000LL + (b.tv_nsec - a.tv_nsec);
  return ns >= 10 * 1000 * 1000;
}

static int t_socket(void) {
  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) return 0;
  pid_t pid = fork();
  if (pid == 0) {
    char c[16];
    ssize_t n = read(sv[1], c, sizeof c);
    for (ssize_t i = 0; i < n; i++) c[i] ^= 0x20;
    _exit(write(sv[1], c, (size_t)n) == n ? 0 : 1);
  }
  char got[16] = {0};
  int ok = write(sv[0], "to2610", 6) == 6 && read(sv[0], got, sizeof got) == 6 && strcmp(got, "TO\x12\x16\x11\x10") == 0;
  child_status(pid);
  close(sv[0]);
  close(sv[1]);
  return ok;
}

static int t_exec(void) {
  pid_t pid = fork();
  if (pid == 0) {
    execl("/bin/sh", "sh", "-c", "exit 7", (char *)nullptr);
    _exit(127);
  }
  int st = child_status(pid);
  return WIFEXITED(st) && WEXITSTATUS(st) == 7;
}

int main(void) {
  static const struct {
    const char *name;
    int (*run)(void);
  } tests[] = {
      {"fork", t_fork},       {"pipe", t_pipe}, {"signal", t_signal}, {"mmap", t_mmap},     {"threads", t_threads},
      {"file", t_file},       {"float", t_float}, {"time", t_time},   {"socket", t_socket}, {"exec", t_exec},
  };
  int n = sizeof tests / sizeof tests[0], ok = 0;
  setvbuf(stdout, nullptr, _IOLBF, 0);
  for (int i = 0; i < n; i++) {
    int r = tests[i].run();
    ok += r;
    printf("apptest %s %s\n", tests[i].name, r ? "ok" : "FAIL");
  }
  printf("apptest all=%d ok=%d\n", n, ok);
  if (ok != n) puts("apptest failed");
  return ok == n ? 0 : 1;
}
