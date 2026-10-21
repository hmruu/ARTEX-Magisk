#define _GNU_SOURCE
#include <execinfo.h>
#include <stdio.h>
#include <unistd.h>
#include <stdlib.h>
#include <sys/ipc.h>

int shmget(key_t key, size_t size, int shmflg)
{
    void *bt[40];
    int n = backtrace(bt, 40);
    char buf[160];
    int len = snprintf(buf, sizeof buf,
        "=== shmget(key=%d size=%zu flags=0o%o) ===\n", (int)key, size, shmflg);
    write(2, buf, len);
    backtrace_symbols_fd(bt, n, 2);
    _exit(42);
}
