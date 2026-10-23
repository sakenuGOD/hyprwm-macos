// Client side of the channel (daemon): open /tmp/hyprwm/chan, write commands in batches,
// publish with one atomic store, set curves (bezier baking matches hyprutils, using floats),
// and read events. Loaded from Python through ctypes (hook/chan.py).
// Build: clang -O2 -dynamiclib src/chanlib.c -o build/libhyprchan.dylib
#include "chan.h"
#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static struct ch *ch;
static u32 pend;             // next free position (not yet published)
static u32 pub;              // head most recently published by us

unsigned ch_abi(void) { return (unsigned)sizeof(struct ch); }
unsigned ch_off(int what) {
    switch (what) {
    case 0: return (unsigned)sizeof(struct ch_win);
    case 1: return (unsigned)__builtin_offsetof(struct ch, win);
    case 2: return (unsigned)sizeof(struct ch_cmd);
    case 3: return (unsigned)sizeof(struct ch_var);
    case 4: return (unsigned)__builtin_offsetof(struct ch_win, pos);
    case 5: return (unsigned)__builtin_offsetof(struct ch_win, ax);
    case 6: return (unsigned)__builtin_offsetof(struct ch, traj);
    case 7: return (unsigned)sizeof(struct ch_hdr);
    case 8: return (unsigned)__builtin_offsetof(struct ch, prehide);
    case 9: return (unsigned)__builtin_offsetof(struct ch, deco);
    case 10: return (unsigned)sizeof(struct ch_deco);
    }
    return 0;
}

// create=1: create a NEW file (O_EXCL: never touch an existing channel used by a live engine);
// otherwise, connect to the live channel.
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
        ch->h.version = 6; ch->h.size = (u32)sizeof *ch;
        ch->h.idle_poll = 0.008; ch->h.settle = 1.0; ch->h.settle_px = 3.0; ch->h.phase = 0.1; ch->h.margin = 0.002;
        __atomic_store_n(&ch->h.magic, CH_MAGIC, __ATOMIC_RELEASE);
    }
    pend = pub = __atomic_load_n(&ch->h.cmd_head, __ATOMIC_ACQUIRE);
    return ch;
}

static void curve_bezier(struct ch_curve *c, float p1x, float p1y, float p2x, float p2y) {
    for (int i = 0; i < CH_BAKED; i++) {          // hyprutils setup4: t=(i+1)/255, float
        const float t = (i + 1) * (1.0f / CH_BAKED), t2 = t * t, t3 = t2 * t, u = 1 - t;
        c->bx[i] = (3 * t * u * u * p1x) + (3 * t2 * u * p2x) + t3;
        c->by[i] = (3 * t * u * u * p1y) + (3 * t2 * u * p2y) + t3;
    }
    __atomic_store_n(&c->type, CV_BEZIER, __ATOMIC_RELEASE);
}

void ch_curve_bezier(int id, float p1x, float p1y, float p2x, float p2y) {
    curve_bezier(&ch->curve[id], p1x, p1y, p2x, p2y);
}

void ch_curve_spring(int id, double mass, double k, double d) {
    struct ch_curve *c = &ch->curve[id];
    c->mass = mass; c->k = k; c->d = d;
    __atomic_store_n(&c->type, CV_SPRING, __ATOMIC_RELEASE);
}

static struct ch_cmd *next_cmd(void) {
    // Start a new batch: another writer (test script) may have advanced the head; continue from it,
    // otherwise publishing would move the head backward and the engine would reapply old commands.
    if (pend == pub) pend = pub = __atomic_load_n(&ch->h.cmd_head, __ATOMIC_ACQUIRE);
    u32 tail = __atomic_load_n(&ch->h.cmd_tail, __ATOMIC_ACQUIRE);
    if (pend - tail >= CH_NCMD) return 0;       // ring full: engine is not consuming
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

int ch_birth(const struct ch_cmd *request) {
    if(!ch || !request || ch->h.magic!=CH_MAGIC || ch->h.size!=sizeof(*ch) ||
       !(ch->h.version&CH_CAP_BIRTH) || request->op!=OP_BIRTH)return -2;
    u32 action=request->flags&CH_BIRTH_ACTION_MASK;
    if(action<BIRTH_ARM || action>BIRTH_QUERY)return -2;
    struct ch_cmd *k=next_cmd();
    if(!k)return -1;
    *k=*request;
    return 0;
}

int ch_effects(unsigned flags,unsigned curve,const double *values) {
    if(!ch || !(ch->h.version&CH_CAP_EFFECTS) || !values)return -2;
    struct ch_cmd *k=next_cmd();
    if(!k)return -1;
    k->op=OP_EFFECTS;k->flags=flags;k->cpos=curve;
    k->x=values[0];k->y=values[1];k->w=values[2];k->h=values[3];
    k->fx=values[4];k->fy=values[5];k->fw=values[6];k->fh=values[7];
    k->dpos=values[8];k->dsize=values[9];k->dalpha=values[10];k->a=values[11];k->fa=values[12];
    return 0;
}
int ch_shadow(unsigned flags,unsigned curve,double duration,const double *values) {
    if(!ch||!(ch->h.version&CH_CAP_SHADOW)||!values)return -2;
    struct ch_cmd *k=next_cmd();if(!k)return -1;
    union {double d;u64 bits;} packed={.d=duration};
    k->op=OP_SHADOW;k->flags=flags;k->cpos=curve;k->pad0=(u32)packed.bits;k->pad1=(u32)(packed.bits>>32);
    k->x=values[0];k->y=values[1];k->w=values[2];k->h=values[3];
    k->fx=values[4];k->fy=values[5];k->fw=values[6];k->fh=values[7];
    k->dpos=values[8];k->dsize=values[9];k->dalpha=values[10];k->a=values[11];k->fa=values[12];
    return 0;
}

int ch_forget(unsigned wid) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_FORGET; k->wid = wid;
    return 0;
}

// Backdrop for window wid: under = backdrop window wid (0 to remove).
int ch_under(unsigned wid, unsigned under) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_UNDER; k->wid = wid; k->flags = under;
    return 0;
}

// Move a window to desktop sid (executed by the engine inside WS).
int ch_space(unsigned wid, unsigned long long sid) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_SPACE; k->wid = wid; k->x = (double)sid;
    return 0;
}

// Final window frame sent to the application through WS (OP_CFG): engine notifies its owner at batch start.
int ch_cfg_flags(unsigned wid, unsigned flags, double x, double y, double w, double h) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_CFG; k->wid = wid; k->flags = flags & F_STREAM;
    k->x = x; k->y = y; k->w = w; k->h = h;
    return 0;
}
int ch_cfg(unsigned wid, double x, double y, double w, double h) {
    return ch_cfg_flags(wid, 0, x, y, w, h);
}

// Window edge color (RGBA8, 0 = none): fills the empty band while the buffer is smaller than the visible frame.
int ch_fill(unsigned wid, unsigned rgba) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_FILL; k->wid = wid; k->flags = rgba;
    return 0;
}

// Raise the window above rel (0 = above all windows at its level) without activating the application.
int ch_raise(unsigned wid, unsigned rel) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_RAISE; k->wid = wid; k->flags = rel;
    return 0;
}

// Snapshot backdrop during motion (engine removes it when the window animation ends).
int ch_snap(unsigned wid) {
    struct ch_cmd *k = next_cmd();
    if (!k) return -1;
    k->op = OP_SNAP; k->wid = wid;
    return 0;
}

// Publish all queued commands: the engine applies them in one tick.
void ch_commit(void) {
    if (pend == pub) return; // An empty batch must not rewind another sequential writer's head.
    __atomic_store_n(&ch->h.cmd_head, pend, __ATOMIC_RELEASE); pub = pend;
}

// Next engine event: 1 = available (written to *out), 0 = none.
int ch_event(struct ch_evt *out) {
    u32 hd = __atomic_load_n(&ch->h.evt_head, __ATOMIC_ACQUIRE), tl = ch->h.evt_tail;
    if (hd - tl > CH_NEVT) tl = hd - CH_NEVT;
    if (tl == hd) return 0;
    *out = ch->evt[tl % CH_NEVT];
    __atomic_store_n(&ch->h.evt_tail, tl + 1, __ATOMIC_RELEASE);
    return 1;
}
