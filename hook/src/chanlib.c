// Клиентская сторона канала (демон): открыть /tmp/hyprwm/chan, писать команды пачкой и
// публиковать одним атомарным store, задавать кривые (запекание безье — 1:1 hyprutils, во float),
// читать события. Грузится из Python через ctypes (hook/chan.py).
// Сборка: clang -O2 -dynamiclib src/chanlib.c -o build/libhyprchan.dylib
#include "chan.h"
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static struct ch *ch;
static u32 pend;             // следующая свободная позиция (ещё не опубликована)

unsigned ch_abi(void) { return (unsigned)sizeof(struct ch); }
unsigned ch_off(int what) {
    switch (what) {
    case 0: return (unsigned)sizeof(struct ch_win);
    case 1: return (unsigned)__builtin_offsetof(struct ch, win);
    case 2: return (unsigned)sizeof(struct ch_cmd);
    case 3: return (unsigned)sizeof(struct ch_var);
    case 4: return (unsigned)__builtin_offsetof(struct ch_win, pos);
    case 5: return (unsigned)__builtin_offsetof(struct ch_win, ax);
    }
    return 0;
}

// create=1: создать НОВЫЙ файл (O_EXCL: существующий канал под живым движком не трогаем никогда);
// иначе — подключиться к живому.
void *ch_open(const char *path, int create) {
    size_t sz = (sizeof(struct ch) + 0x3fff) & ~(size_t)0x3fff;
    int fd = open(path, O_RDWR | (create ? O_CREAT | O_EXCL : 0), 0666);
    if (fd < 0) return 0;
    if (create) { fchmod(fd, 0666); if (ftruncate(fd, (off_t)sz)) { close(fd); return 0; } }
    void *p = mmap(0, sz, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return 0;
    ch = p;
    if (create) {
        memset(ch, 0, sizeof *ch);
        ch->h.version = 5; ch->h.size = (u32)sizeof *ch;
        ch->h.idle_poll = 0.008; ch->h.settle = 1.0; ch->h.settle_px = 3.0; ch->h.phase = 0.1; ch->h.margin = 0.002;
        __atomic_store_n(&ch->h.magic, CH_MAGIC, __ATOMIC_RELEASE);
    }
    pend = __atomic_load_n(&ch->h.cmd_head, __ATOMIC_ACQUIRE);
    return ch;
}

void ch_curve_bezier(int id, float p1x, float p1y, float p2x, float p2y) {
    struct ch_curve *c = &ch->curve[id];
    for (int i = 0; i < CH_BAKED; i++) {          // hyprutils setup4: t=(i+1)/255, float
        const float t = (i + 1) * (1.0f / CH_BAKED), t2 = t * t, t3 = t2 * t, u = 1 - t;
        c->bx[i] = (3 * t * u * u * p1x) + (3 * t2 * u * p2x) + t3;
        c->by[i] = (3 * t * u * u * p1y) + (3 * t2 * u * p2y) + t3;
    }
    __atomic_store_n(&c->type, CV_BEZIER, __ATOMIC_RELEASE);
}

void ch_curve_spring(int id, double mass, double k, double d) {
    struct ch_curve *c = &ch->curve[id];
    c->mass = mass; c->k = k; c->d = d;
    __atomic_store_n(&c->type, CV_SPRING, __ATOMIC_RELEASE);
}

static struct ch_cmd *next_cmd(void) {
    u32 tail = __atomic_load_n(&ch->h.cmd_tail, __ATOMIC_ACQUIRE);
    if (pend - tail >= CH_NCMD) return 0;       // кольцо полно: движок не забирает
    struct ch_cmd *k = &ch->cmd[pend % CH_NCMD];
    memset(k, 0, sizeof *k);
    pend++;
    return k;
}

int ch_geom(int op, unsigned wid, unsigned flags, double x, double y, double w, double h,
            double fx, double fy, double fw, double fh, unsigned cpos, unsigned csize, double dpos, double dsize) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = (u32)op; k->wid = wid; k->flags = flags;
    k->x = x; k->y = y; k->w = w; k->h = h; k->fx = fx; k->fy = fy; k->fw = fw; k->fh = fh;
    k->cpos = cpos; k->csize = csize; k->dpos = dpos; k->dsize = dsize;
    return 0;
}

int ch_alpha(unsigned wid, unsigned flags, double a, double fa, unsigned calpha, double dalpha) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_ALPHA; k->wid = wid; k->flags = flags; k->a = a; k->fa = fa;
    k->calpha = calpha; k->dalpha = dalpha;
    return 0;
}

int ch_forget(unsigned wid) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_FORGET; k->wid = wid;
    return 0;
}

// Подложка окна wid: under = wid окна-подложки (0 — убрать).
int ch_under(unsigned wid, unsigned under) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_UNDER; k->wid = wid; k->flags = under;
    return 0;
}

// Опубликовать всё записанное: движок применит это в одном тике.
void ch_commit(void) { __atomic_store_n(&ch->h.cmd_head, pend, __ATOMIC_RELEASE); }

// Следующее событие от движка: 1 — есть (записано в *out), 0 — нет.
int ch_event(struct ch_evt *out) {
    u32 hd = __atomic_load_n(&ch->h.evt_head, __ATOMIC_ACQUIRE), tl = ch->h.evt_tail;
    if (hd - tl > CH_NEVT) tl = hd - CH_NEVT;
    if (tl == hd) return 0;
    *out = ch->evt[tl % CH_NEVT];
    __atomic_store_n(&ch->h.evt_tail, tl + 1, __ATOMIC_RELEASE);
    return 1;
}
