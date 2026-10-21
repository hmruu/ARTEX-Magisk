/*
 * libsysv-shim.so —— 用 mmap 伪造 SysV 共享内存
 *
 * Android 内核（GKI）通常关闭了 CONFIG_SYSVIPC，shmget() 直接返回 ENOSYS，
 * 而 PostgreSQL 的 initdb/bootstrap 阶段硬编码使用 SysV 共享内存，无法用
 * shared_memory_type=mmap 绕过（该 GUC 在 --boot 模式读不到）。
 *
 * 这个极小的 LD_PRELOAD 垫片只用于 initdb：把 shmget/shmat/shmdt/shmctl
 * 映射到 MAP_SHARED|MAP_ANONYMOUS 的匿名内存上。fork 出来的子进程会共享同一
 * 块内存，语义与 SysV 段一致，足够 bootstrap 使用。
 *
 * 运行期不需要它：postgresql.conf 里 shared_memory_type=mmap 即可。
 *
 * 编译： gcc -shared -fPIC -O2 -o libsysv-shim.so shimsysv.c
 */
#define _GNU_SOURCE
#include <sys/types.h>
#include <sys/mman.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

#define MAX_SEG 8

struct seg {
    int used;
    int id;
    size_t size;
    void *addr;
};

static struct seg segs[MAX_SEG];
static int next_id = 0x20000000;

int shmget(key_t key, size_t size, int shmflg)
{
    (void)key;
    (void)shmflg;

    if (size == 0)
        size = 4096;
    size = (size + 4095) & ~(size_t)4095;

    for (int i = 0; i < MAX_SEG; i++) {
        if (segs[i].used)
            continue;
        void *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                       MAP_SHARED | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) {
            errno = ENOMEM;
            return -1;
        }
        segs[i].used = 1;
        segs[i].id = next_id++;
        segs[i].size = size;
        segs[i].addr = p;
        return segs[i].id;
    }
    errno = ENOSPC;
    return -1;
}

static struct seg *find_seg(int id)
{
    for (int i = 0; i < MAX_SEG; i++)
        if (segs[i].used && segs[i].id == id)
            return &segs[i];
    return NULL;
}

void *shmat(int shmid, const void *shmaddr, int shmflg)
{
    struct seg *s = find_seg(shmid);
    (void)shmflg;
    if (!s) {
        errno = EINVAL;
        return (void *)-1;
    }
    if (shmaddr == NULL)
        return s->addr;
    void *q = mmap((void *)shmaddr, s->size, PROT_READ | PROT_WRITE,
                   MAP_SHARED | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (q == MAP_FAILED)
        return s->addr;
    return q;
}

int shmdt(const void *shmaddr)
{
    (void)shmaddr;
    return 0;
}

int shmctl(int shmid, int cmd, struct shmid_ds *buf)
{
    struct seg *s = find_seg(shmid);
    if (!s) {
        errno = EINVAL;
        return -1;
    }
    switch (cmd) {
    case IPC_STAT:
        if (buf) {
            memset(buf, 0, sizeof(*buf));
            buf->shm_segsz = s->size;
            buf->shm_nattch = 1;
        }
        return 0;
    case IPC_SET:
        return 0;
    case IPC_RMID:
        munmap(s->addr, s->size);
        s->used = 0;
        return 0;
    default:
        return 0;
    }
}
