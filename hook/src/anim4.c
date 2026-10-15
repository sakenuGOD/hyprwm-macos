// Animation engine v4 inside WindowServer: central per-frame tick, as in Hyprland.
//
// Each tick (once per frame, on the WS main thread):
// 1. consumes all published commands from shared memory and applies them with one t0;
// 2. advances all window variables (position, size, alpha) along Hyprland curves:
// spring uses analytic hyprutils advanceSpring; bezier uses 255 baked points and getYForPoint;
// 3. reads actual frame A. Legacy visual mode displays it in B(t);
//      F_NATIVE sends the central intermediate geometry to the app, while real A
//      owns presentation/ring/input. Native app handler has no second animation clock.
// When window animations end and the application accepts the size (or waiting times out),
// apply identity; the server removes the transform slot and draws the window as is.
//
// The main-thread timer ticks in phase with the selected WS display's vblank.
// anim_frame is not installed in metalCallbacks: rescheduling would break the phase.
// Build: build_anim4.sh (flat __TEXT image, no relocations or __DATA references).
#include "chan.h"
#include "live_edge.h"
#include "../effects/config_command.h"

typedef struct { double x, y, w, h; } rect;
struct rect4_ { double x, y, w, h; };
typedef void (*set_xform_fn)(void *conn, unsigned *wid, unsigned *key, double *m);
typedef void (*resched_fn)(void *queue, void *fn, void *ctx, void *session, int policy, int nodelay, double at);
typedef void *(*by_id_fn)(unsigned wid);
typedef rect (*bbox_fn)(void *region);
typedef void (*move_fn)(void *conn, unsigned *wids, int n, long flags, float dx, float dy);
typedef void (*alpha_fn)(void *conn, void *win, float a, float dur);
typedef double (*d1_fn)(double);
typedef void (*vbl_fn)(unsigned display, double *prev, double *next);
typedef void (*clip_fn)(void *conn, void *region, unsigned *wids, unsigned n);
typedef void *(*rgn_fn)(rect r);
typedef void (*rel_fn)(void *cf);

struct ctx {
    set_xform_fn set_xform;  // 0x00 all function pointers signed IA/0
    resched_fn   resched;    // 0x08
    void        *self;       // 0x10  anim_tick
    void        *queue;      // 0x18  &gMainThreadQueue
    void        *session;    // 0x20
    by_id_fn     by_id;      // 0x28  CGXWindowByID
    bbox_fn      bbox;       // 0x30  CGRegionGetBoundingBox
    move_fn      move;       // 0x38  CGXMoveWindowList
    alpha_fn     set_alpha;  // 0x40  CGXSetWindowListAlpha (x1 = CGXWindow*)
    d1_fn        f_exp, f_sin, f_cos;  // 0x48 0x50 0x58
    struct ch   *ch;         // 0x60
    u32          key, running;        // 0x68 0x6c
    u32          shape_off, dead;     // 0x70 window shape offset in CGXWindow (0x170); dead: removed by installer
    vbl_fn       vbl;                 // 0x78 WSDisplayScheduleGetPrevNextVBL (display vblank cache)
    u32          display, pad2;       // 0x80 CGDirectDisplayID of main display
    clip_fn      clip;                // 0x88  CGXWindow::set_window_list_global_clip_shape(conn, region, wids, n)
    rgn_fn       rgn;                 // 0x90  CGRegionCreateWithRect
    rel_fn       release;             // 0x98  CFRelease
    double     (*corner)(void *win);  // 0xa0  CGXWindow::resolved_corner_radius() const
    void      *(*rdiff)(void *a, void *b);   // 0xa8  CGRegionCreateDifferenceWithRegion (a − b)
    u64        (*mabs)(void);         // 0xb0 mach_absolute_time (measures tick cost)
    double       mabs_us;             // 0xb8 microseconds per mach tick (timebase)
    // P4: ObjC/CA inside WS. ONE WS transaction per call (ctor -> addContextToCommit -> properties -> dtor):
    // WS commits only explicitly listed contexts (setCommittingContexts: in ~WSCAContextScopeTransaction).
    void        *msg;                 // 0xc0 objc_msgSend (called through cast types)
    void      *(*sel)(const char *);  // 0xc8  sel_registerName
    void      *(*cls)(const char *);  // 0xd0  objc_getClass
    void      *(*srgb)(double, double, double, double);   // 0xd8  CGColorCreateSRGB
    void       (*tx_ctor)(void *tx, unsigned params);     // 0xe0  WSCAContextScopeTransaction(WSCAScopeParameters)
    void       (*tx_add)(void *tx, void *cactx);          // 0xe8  addContextToCommit(CAContext*)
    void       (*tx_dtor)(void *tx);                      // 0xf0  ~WSCAContextScopeTransaction (commit)
    void        *black;               // 0xf8 CGColor (cached)
    void        *s_layer, *s_retain, *s_release, *s_frame, *s_radius, *s_bg, *s_mask;   // 0x100.. selectors (cached)
    void        *c_layer;             // 0x138 CALayer class
    void        *s_bounds;            // 0x140
    // Move window to desktop like server __XMoveWindowsToManagedSpace, using the window owner's connection.
    void      *(*space_for_id)(u64 sid);                                  // 0x148 PKGSpaceForID
    void      *(*wlist)(void *conn, const unsigned *wids, unsigned n);    // 0x150 window_ordering_group_list_create_from_window_id_array
    void       (*wmove)(void *conn, void *list, void *managed);           // 0x158 PKGWindowsMoveToManagedSpace
    void       (*xfree)(void *p);                                         // 0x160 free
    // P6: focus border (selectors and classes cached by deco_ready)
    void        *s_bwidth, *s_bcolor, *s_colors, *s_start, *s_end, *s_opacity;   // 0x168..0x190
    void        *s_addsub, *s_remove, *s_convert, *s_arr, *s_getmask, *s_curve;  // 0x198..0x1c0
    void        *c_grad, *c_array, *str_cont;                                    // 0x1c8 0x1d0 0x1d8
    void        *s_shpath, *s_shcolor, *s_shrad, *s_shoff, *s_shop, *s_insert, *s_bwidth2;   // 0x1e0..0x210
    void      *(*path_rr)(struct rect4_ r, double cw, double ch, const void *t);           // 0x218 CGPathCreateWithRoundedRect
    void       (*path_rel)(void *p);                                                    // 0x220 CGPathRelease
    void       (*dbg_radius)(void *win, double r);                                     // 0x228 CGXWindow::set_debug_corner_radius
    void       (*dbg_clear)(void *win);                                                // 0x230 CGXWindow::clear_debug_corner_radius
    // Fill empty band B-A (edge extension): CAShapeLayer with even-odd path
    void      *(*path_mut)(void);                                                       // 0x238 CGPathCreateMutable
    void       (*path_addrr)(void *p, const void *t, struct rect4_ r, double cw, double ch);   // 0x240 CGPathAddRoundedRect
    void       (*path_addrect)(void *p, const void *t, struct rect4_ r);               // 0x248 CGPathAddRect
    void        *s_path, *s_fillcolor, *s_fillrule, *s_hidden, *c_shape, *str_eo;      // 0x250..0x278
    // After our CA transaction, request redraw of window displays: WS composites independently and may
    // not show an external layer commit until another event (click); crossfades previously stuttered or stalled.
    void       (*sched_win)(void *conn, void *win);                                     // 0x280 CGXScheduleUpdateDisplaysIntersectingWindow
    // Crossfade via CABasicAnimation (CA interpolates at render time, without per-frame commits)
    void        *c_basic, *s_akp, *s_from, *s_to, *s_adur, *s_tf, *s_addanim, *s_pres;  // 0x288..0x2c0
    void        *s_opget, *s_shopget, *c_num, *s_numf, *c_tfn, *s_tfcp, *str_op, *str_shop; // 0x2c8..0x300
    u64          cleaned;                                                               // 0x308 layers removed on stop
    void        *s_subl, *s_count, *s_objat, *s_iskind, *s_shpathget;                   // 0x310..0x330
    void       (*order)(void *conn, unsigned wid, int op, unsigned rel);                // 0x338 CGXOrderWindow
    // P8: close snapshot (notes/research/close_clone.md)
    void      *(*clone)(void *src, rect frame, const void *disp, int server_owned);     // 0x340 CreateCloneOfWindow
    rect       (*srr)(void *win, rect r);                                               // 0x348 screen_rect_from_rect
    void      *(*win_disp)(void *win);                                                  // 0x350 PKGWindowGetDisplay
    void      *(*main_disp)(void);                                                      // 0x358 PKGDisplayGetMain
    void       (*set_level)(void *win, void *conn, int lvl, short sub);                 // 0x360 set_level_internal
    void       (*rel_win)(void *conn, void *win);                                       // 0x368 release_window
    void       (*add_cb)(void *fn, unsigned type, void *ctx);                           // 0x370 WSAddNotificationCallback
    void       (*rm_cb)(void *fn, unsigned type, void *ctx);                            // 0x378 WSRemoveNotificationCallback
    void        *cb;                                                                    // 0x380 anim_will_release (IA/0)
    unsigned   (*get_id)(void *win);                                                    // 0x388 WSWindowGetID
    u32          cb_on, in_cb;                                                          // 0x390
    u32          nclone, nskip;                                                         // 0x398
    void        *s_curveget, *cur_curve;                                               // 0x3a0 0x3a8 window corner shape
    void       (*tags)(void *conn, void **wins, u64 mask, int clear);                  // 0x3b0 set_window_list_tags (one window; clear=1 removes)
    void        *str_circ;                                                              // 0x3b8 "circular"
    // Application configure (native_hooks section 1): WS notifies window owner; hyprforce module applies it
    void       (*post)(void *conn, unsigned type, const void *data, unsigned len);      // 0x3c0 WSPostNotificationToConnection
    void      *(*owner)(void *win);                                                     // 0x3c8 CGXWindowGetOwner
    void        *s_arm;                                                                 // 0x3d0 setAutoresizingMask:
    // Invisible system shadow via override (beyond_bounds.md section 1.7): WS keeps it invisible across
    // activity changes, while the window drawing clip stays expanded for our ring/shadow
    void       (*wm_shadow)(void *win, const void *act, const void *inact);             // 0x3d8 WSWindowSetWindowManagerShadowProperties
    void       (*sh_inval)(void *conn, void *win);                                      // 0x3e0 WSWindowInvalidateShadowFrame
    void       (*sh_sched)(void *win, void *conn);                                      // 0x3e8 CGXWindow::invalidate_shadow_and_schedule_update
    unsigned   (*display_id)(void *win);                                               // 0x3f0 WSWindowGetDisplayID [V native getter]
    void        *s_name, *s_setname, *layer_name, *s_equal;                              // 0x3f8..0x410 ownership of our CALayers
    double       scan_t;                                                               // 0x418 last new-window scan
    void        *s_colorsget, *str_colors;                                             // 0x420..0x428 single-ring focus animation
    void        *s_removeanim;                                                        // 0x430
    struct edge_api *edge_api;                                                       // 0x438
    struct edge_state *edges;                                                       // 0x440 private, 64 owned helpers
    const struct hy_effects_api *effects_api;                                        // 0x448 optional separately loaded module
    void *effects_runtime;                                                          // 0x450 separately owned heap state
    u64 pending_edge_generation[CH_NW];                                             // 0x458..0x658 private prepare requests
};

_Static_assert(__builtin_offsetof(struct ctx, msg) == 0xc0, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, c_layer) == 0x138, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, s_bounds) == 0x140, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, space_for_id) == 0x148, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, xfree) == 0x160, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, s_bwidth) == 0x168, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, str_cont) == 0x1d8, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, path_rr) == 0x218, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, path_rel) == 0x220, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, dbg_clear) == 0x230, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, path_addrect) == 0x248, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, str_eo) == 0x278, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, sched_win) == 0x280, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, str_shop) == 0x300, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, post) == 0x3c0, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, owner) == 0x3c8, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, s_arm) == 0x3d0, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, sh_sched) == 0x3e8, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, display_id) == 0x3f0, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, scan_t) == 0x418, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, edge_api) == 0x438, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, effects_api) == 0x448, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, effects_runtime) == 0x450, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, pending_edge_generation) == 0x458, "ctx pending prepare");
_Static_assert(sizeof(struct ctx) == 0x658, "ctx pending prepare extent");
struct edge_lease { u32 wid, on; double generation, expires; }; // on:1=device/prepare,3=ACKed grant
_Static_assert(512 + CH_NW * (sizeof(struct edge_state) + sizeof(struct edge_lease)) <= 16384, "edge mapping overflow");
_Static_assert(sizeof(struct ctx) <= 0x800, "ctx overlaps P8_TAB");
_Static_assert(__builtin_offsetof(struct ctx, s_shpathget) == 0x330, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, order) == 0x338, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, cb) == 0x380, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, nskip) == 0x39c, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, cur_curve) == 0x3a8, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, tags) == 0x3b0, "ctx");

static int effects_ready(struct ctx *c) {
    const struct hy_effects_api *a=c->effects_api;
    return c->effects_runtime && a && a->magic==HY_EFFECTS_MAGIC && a->size==sizeof(*a) && a->version==1 &&
        a->configure && a->frame && a->drop && a->destroy && a->flags && a->suspend && a->eligible;
}

// Private state belongs to this installation, not the shared channel. P8 uses
// 0x800..0xb00 and 0xc00..0xc40; 64 saved records fit in the installer's 16KB ctx.
struct saved_window {
    u64 original_mask, shadow[16]; u32 mask_set, shadow_set; u64 deco_hash;
    double cfg_rect[4], cfg_stamp;
    u32 cfg_sent, cfg_bridge;    // sent: 0=no sample, 1=intermediate, 2=final; bridge: separate SCFG owner
};
#define SAVED_TAB(c) ((struct saved_window *)((char *)(c) + 0xd00))
_Static_assert(0xd00 + CH_NW * sizeof(struct saved_window) <= 0x4000, "saved window state outside ctx mapping");
static struct saved_window *saved_window(struct ctx *c, struct ch_win *w) { return &SAVED_TAB(c)[w - c->ch->win]; }
struct p8c { u32 wid, src; double t0; u32 live, pending; };
#define P8_TAB(c) ((struct p8c *)((char *)(c) + 0x800))
#define P8_N 32
#define P8_SOURCE(c) ((u64 *)((char *)(c) + 0xb00))
#define P8_EPOCH(c) ((u32 *)((char *)(c) + 0xc40))
#define SNAP_SEQUENCE(c) (*(u32 *)((char *)(c) + 0xcc0))
_Static_assert(0x800+P8_N*sizeof(struct p8c)==0xb00,"P8 table fence");
_Static_assert(0xb00+P8_N*sizeof(u64)==0xc00,"P8 source fence");
_Static_assert(0xc40+P8_N*sizeof(u32)==0xcc0 && 0xcc4<=0xd00,"snapshot epoch fence");
static int cover_index(struct ctx *c, unsigned wid, int source) {
    for(int i=0;i<P8_N;i++) {
        struct p8c *e=&P8_TAB(c)[i];
        if(e->live && e->pending==3 && (source?e->src:e->wid)==wid)return i;
    }
    return -1;
}
static unsigned presentation_wid(struct ctx *c, struct ch_win *w) {
    int i=cover_index(c,w->wid,0);
    return i>=0?P8_TAB(c)[i].src:w->wid;
}
static void cover_retire(struct ctx *c,int index,int result,double now);
static void cover_cancel_source(struct ctx *c,unsigned wid,double now) {
    int index=cover_index(c,wid,1);
    if(index>=0)cover_retire(c,index,SNAP_CANCELLED,now);
}
static struct edge_lease *live_edge_lease(struct ctx *c, struct ch_win *w) {
    return c->edges ? &((struct edge_lease *)(c->edges + CH_NW))[w-c->ch->win] : 0;
}
static void live_edge_drop(struct ctx *c, struct ch_win *w) {
    if(c->edge_api && c->edges) {
        struct edge_lease *lease=live_edge_lease(c,w);
        void *source=c->edges[w-c->ch->win].source_window;
        u32 was=c->in_cb;c->in_cb=1;
        edge_remove(c->edge_api,&c->edges[w-c->ch->win]);c->in_cb=was;
        // Keep the exact source birth fence while an ACKed grant survives a
        // helper teardown/retarget. Never silently transfer it to a reused WID.
        if(lease && lease->on && lease->expires>0) c->edges[w-c->ch->win].source_window=source;
    }
}
static int live_edge_granted(struct ctx *c, struct ch_win *w) {
    if(!c->edge_api || !c->edges || c->ch->h.pad_t!=CH_EDGE_PERMISSION || w->geo==2) return 0;
    struct edge_lease *lease=live_edge_lease(c,w);
    void *source=c->edges[w-c->ch->win].source_window;
    return source && lease->wid==w->wid && lease->on==3 &&
        c->ch->h.now<lease->expires && source==c->by_id(w->wid);
}
static int effects_owns_corner(struct ctx *c,struct ch_win *w) {
    if(!effects_ready(c)||!live_edge_granted(c,w)||w->wid==c->ch->deco.nofull||
       !(c->effects_api->flags(c->effects_runtime)&HY_EFFECTS_ROUNDING))return 0;
    void *win=c->by_id(w->wid),*cwc=win?*(void**)((char*)win+0x18):0;
    struct hy_effects_frame identity={0};
    identity.slot=(unsigned)(w-c->ch->win);identity.wid=w->wid;
    identity.generation=(u64)live_edge_lease(c,w)->generation;identity.source_window=(u64)win;
    identity.source_context=cwc?(u64)*(void**)((char*)cwc+0x38):0;
    return c->effects_api->eligible(c->effects_runtime,&identity);
}

static int live_edge_enabled(struct ctx *c, struct ch_win *w) {
    if(!c->edge_api || !c->edges || !c->ch->h.pad_t) return 0;
    if(c->ch->h.pad_t!=CH_EDGE_PERMISSION) return c->ch->h.pad_t==w->wid;
    return w->geo==3 && live_edge_granted(c,w);
}
static int live_edge_primed(struct ctx *c, struct ch_win *w) {
    if(!c->edge_api || !c->edges || c->ch->h.pad_t!=CH_EDGE_PERMISSION ||
       (w->geo!=1 && !(w->geo==0 && effects_ready(c)))) return 0;
    struct edge_lease *lease=live_edge_lease(c,w);
    void *source=c->edges[w-c->ch->win].source_window;
    return source && source==c->by_id(w->wid) && lease->wid==w->wid &&
        (lease->on==1 || lease->on==3) && c->ch->h.now<lease->expires;
}
static void live_edge_client(struct ctx *c, struct ch_win *w, int on) {
    struct edge_lease *lease=live_edge_lease(c,w);
    if(!lease || (!on && (!lease->on || lease->wid!=w->wid))) return;
    // Production renewal requires another genuine client ACK. Posting a
    // notification alone must not extend its grant or replace its request nonce.
    if(on && c->ch->h.pad_t==CH_EDGE_PERMISSION) return;
    unsigned index=(unsigned)(w-c->ch->win);
    u64 pending=c->pending_edge_generation[index];
    void *win=c->by_id(w->wid), *owner=win && c->owner ? c->owner(win) : 0;
    // An ended source can be replaced under the same WID. Its capability is
    // revoked locally; never send the old lease-end to the replacement owner.
    if(!on && lease->expires>0 && c->edges[w-c->ch->win].source_window!=win) owner=0;
    if(owner && c->post) {
        struct { u32 magic,wid,enabled,reserved; double generation; } m=
            {0x50525948u,w->wid,on!=0,0,(!on && lease->expires>0)?
                (pending?(double)pending:lease->generation):c->ch->h.now};
        c->post(owner,0x7f19,&m,sizeof m);
    }
    lease->wid=w->wid;lease->on=on!=0;lease->generation=c->ch->h.now;
    if(!on) {
        c->pending_edge_generation[index]=0;
        // Ending authorization is distinct from a nonce renewal. Restore both
        // retained FX owners before another prepare/ACK can arrive this tick.
        if(effects_ready(c)) {
            unsigned i=(unsigned)(w-c->ch->win);
            c->effects_api->drop(c->effects_runtime,i,0);
            c->effects_api->drop(c->effects_runtime,i,1);
        }
        lease->expires=0; c->edges[w-c->ch->win].source_window=0;
        if(w->geo==3) w->geo=1;
    }
}

static inline double dabs(double x) { return x < 0 ? -x : x; }
static inline int finite(double x) { return x == x && dabs(x) < 1e7; }

// Curves
static double bezier_y(const struct ch_curve *c, double x) {      // hyprutils getYForPoint
    if (x >= 1.0) return 1.0;
    if (x <= 0.0) return 0.0;
    int index = 0, below = 1;
    for (int step = (CH_BAKED + 1) / 2; step > 0; step /= 2) {
        index += below ? step : -step;
        if (index < 0) index = 0;
        else if (index > CH_BAKED - 1) index = CH_BAKED - 1;
        below = c->bx[index] < x;
    }
    int lo = index - (!below || index == CH_BAKED - 1);
    if (lo < 0) lo = 0;
    else if (lo > CH_BAKED - 2) lo = CH_BAKED - 2;
    double dx = c->bx[lo + 1] - c->bx[lo];
    if (dx <= 1e-6) return c->by[lo];
    double p = (x - c->bx[lo]) / dx;
    if (!finite(p)) return c->by[lo];
    return c->by[lo] + (c->by[lo + 1] - c->by[lo]) * p;
}

static void spring_adv(struct ctx *c, const struct ch_curve *sp, double *value, double *vel, double dt) {
    if (!(dt > 0)) return;                                          // hyprutils advanceSpring
    double m = sp->mass > 1e-4 ? sp->mass : 1e-4;
    double k = sp->k > 1e-4 ? sp->k : 1e-4;
    double d = sp->d > 0 ? sp->d : 0;
    double disp = *value - 1.0, w0 = __builtin_sqrt(k / m), g = d / (2.0 * m), v = *vel;
    if (g < w0) {
        double wd = __builtin_sqrt(w0 * w0 - g * g);
        double e = c->f_exp(-g * dt), s = c->f_sin(wd * dt), co = c->f_cos(wd * dt);
        *value = 1.0 + e * (disp * co + ((v + g * disp) / wd) * s);
        *vel = e * (v * co - ((g * v + w0 * w0 * disp) / wd) * s);
        return;
    }
    double ce = (w0 > 1.0 ? w0 : 1.0) * 1e-4;
    if (dabs(g - w0) <= ce) {
        double e = c->f_exp(-g * dt), b = v + g * disp;
        *value = 1.0 + e * (disp + b * dt);
        *vel = e * (v - g * b * dt);
        return;
    }
    double r = __builtin_sqrt(g * g - w0 * w0), r1 = -g + r, r2 = -g - r;
    double a = (v - r2 * disp) / (r1 - r2), b = disp - a;
    double e1 = c->f_exp(r1 * dt), e2 = c->f_exp(r2 * dt);
    *value = 1.0 + a * e1 + b * e2;
    *vel = a * r1 * e1 + b * r2 * e2;
}

static int is_spring(struct ch *ch, u32 cv) { return cv < CH_NCURVE && ch->curve[cv].type == CV_SPRING; }
static int step(struct ctx *c, struct ch_var *v, int n, double now);

// Retarget from the current visible sample. Project the old physical velocity
// onto the new displacement so a reversal doesn't instantaneously reverse it.
// One scalar spring represents a vector trajectory; projection is the closest
// representable continuation when the new target changes direction.
static void retarget(struct ctx *c, struct ch_var *v, int n, const double *g, u32 cv, double dur, double now) {
    struct ch *ch = c->ch;
    int same = 1;
    for (int i = 0; i < n; i++) same &= v->g[i] == g[i];
    if (same) return;
    int was = v->active && is_spring(ch, v->curve), sp = is_spring(ch, cv);
    double scale = 1.0;
    if (was && sp) {
        double dot = 0.0, norm = 0.0;
        for (int i = 0; i < n; i++) {
            double od = v->g[i] - v->b[i], nd = g[i] - v->v[i];
            dot += od * nd;
            norm += nd * nd;
        }
        scale = norm > 1e-12 ? dot / norm : 0.0;
    }
    for (int i = 0; i < n; i++) { v->g[i] = g[i]; v->b[i] = v->v[i]; }
    v->curve = cv; v->dur = dur;
    if (sp) {
        v->sv = 0.0;
        v->svel = (was && sp) ? v->svel * scale : 0.0;
        v->last = now;
    }
    v->t0 = now;
    v->active = 1;
}

static void warp(struct ch_var *v, int n, const double *x) {        // setValueAndWarp
    for (int i = 0; i < n; i++) v->b[i] = v->g[i] = v->v[i] = x[i];
    v->active = 0; v->sv = 1.0; v->svel = 0.0;
}

// Advance a variable; return 1 while still animating.
static int step(struct ctx *c, struct ch_var *v, int n, double now) {
    if (!v->active) return 0;
    struct ch *ch = c->ch;
    double y; int fin;
    if (is_spring(ch, v->curve)) {
        double dt = now - v->last;
        if (dt > 0) v->last = now;
        spring_adv(c, &ch->curve[v->curve], &v->sv, &v->svel, dt);
        fin = dabs(1.0 - v->sv) <= 0.001 && dabs(v->svel) <= 0.001;
        if (fin) { v->sv = 1.0; v->svel = 0.0; }
        y = v->sv;
    } else {
        // Double time (Hyprland uses integer ms: negligible at 180 Hz; up to +/-4% unevenness at 60 Hz, P25)
        double pct = v->dur > 0 ? (now - v->t0) / v->dur : 1.0;
        fin = pct >= 1.0 || v->curve >= CH_NCURVE || ch->curve[v->curve].type != CV_BEZIER;
        y = fin ? 1.0 : bezier_y(&ch->curve[v->curve], pct);
    }
    for (int i = 0; i < n; i++) v->v[i] = fin ? v->g[i] : v->b[i] + (v->g[i] - v->b[i]) * y;
    if (fin) v->active = 0;
    return !fin;
}

// Windows
static void post_evt(struct ch *ch, u32 type, u32 wid, double now, double x, double y, double w, double h) {
    u32 hd = ch->h.evt_head;
    struct ch_evt *e = &ch->evt[hd % CH_NEVT];
    e->type = type; e->wid = wid; e->t = now; e->x = x; e->y = y; e->w = w; e->h = h;
    __atomic_store_n(&ch->h.evt_head, hd + 1, __ATOMIC_RELEASE);
}
static void record_error(struct ch *ch, u32 opcode, u32 wid, u32 reason) {
    ch->h.errors++;
    // Fixed-size event ring; overwritten diagnostics never recursively add an
    // error or touch reserved[4], which owns stale layer teardown statistics.
    post_evt(ch,EV_ERROR,wid,ch->h.now,opcode,reason,ch->h.errors,0);
}

static int actual(struct ctx *c, struct ch_win *w, void **winp) {
    void *win = c->by_id(w->wid);
    *winp = win;
    if (!win) return 0;
    void *shape = *(void **)((char *)win + c->shape_off);
    if (!shape) return 0;
    rect r = c->bbox(shape);
    if (!finite(r.x) || !finite(r.y) || !(r.w >= 1) || !(r.h >= 1)) return 0;
    w->ax = r.x; w->ay = r.y; w->aw = r.w; w->ah = r.h;
    return 1;
}

// A parked system panel must not admit future banners on its connection.
// Keep registration only when another currently native normal window is managed.
static void prehide_forget(struct ctx *c, struct ch_win *forgot, void *win) {
    if (!win || *(int *)((char *)win + 0x20) == 0) return;
    u64 cn = (u64)*(void **)((char *)win + 0x30);
    if (!cn) return;
    for (int i = 0; i < CH_NW; i++) {
        struct ch_win *w = &c->ch->win[i];
        if (w == forgot || !w->used || !w->geo) continue;
        void *sibling = c->by_id(w->wid);
        if (sibling && *(int *)((char *)sibling + 0x20) == 0 &&
            (u64)*(void **)((char *)sibling + 0x30) == cn) return;
    }
    for (int i = 0; i < CH_NCONN; i++) if (c->ch->conn[i] == cn) c->ch->conn[i] = 0;
}

// Explicit CAP6 or additive bridge transport. Stamps order application receipts;
// they must be WS current time, never the future presentation sample time.
static int native_post_frame(struct ctx *c, struct ch_win *w, void *win, const double *r) {
    void *own = win && c->owner ? c->owner(win) : 0;
    if (!own || !c->post) return 0;
    int bridge = saved_window(c, w)->cfg_bridge;
    struct ch_cfgmsg m = {bridge ? CH_STREAM_MAGIC : CH_CFG_MAGIC, w->wid, r[0], r[1], r[2], r[3], c->ch->h.now};
    c->post(own, bridge ? CH_STREAM_NOTIFY : CH_CFG_NOTIFY, &m, sizeof m);
    return 1;
}

static int native_allowed(struct ctx *c, struct ch_win *w, void *win) {
    return win && c->owner && c->owner(win) && c->post &&
        *(int *)((char *)win + 0x20) == 0 &&
        ((*(u64 *)((char *)win + 0x928) >> 44) & 1);
}

static void native_cancel(struct ctx *c, struct ch_win *w, void *win) {
    if (w->geo != 2) return;
    double zero[4] = {0, 0, 0, 0};
    native_post_frame(c, w, win, zero); // invalidate application-side main queue before releasing owner
    saved_window(c, w)->cfg_sent = 0;
    w->geo = 1; w->held = w->needs = w->settling = 0;
    if (w->wait == 1) w->wait = 0;
    void *present;
    if (win && actual(c, w, &present)) {
        double p[2] = {w->ax, w->ay}, s[2] = {w->aw, w->ah};
        warp(&w->pos, 2, p); warp(&w->size, 2, s);
    } else {
        w->pos.active = w->size.active = 0;
    }
}

static void put_xform(struct ctx *c, struct ch_win *w, double sx, double sy, double tx, double ty) {
    if (dabs(sx - w->m[0]) < 1e-6 && dabs(sy - w->m[1]) < 1e-6 &&
        dabs(tx - w->m[2]) < 1e-4 && dabs(ty - w->m[3]) < 1e-4) return;
    w->m[0] = sx; w->m[1] = sy; w->m[2] = tx; w->m[3] = ty;
    volatile double m[16];
    for (int j = 0; j < 16; j++) m[j] = 0.0;
    m[0] = sx; m[5] = sy; m[10] = 1.0; m[15] = 1.0; m[12] = tx; m[13] = ty;
    unsigned wid = w->wid, key = c->key;
    c->set_xform(0, &wid, &key, (double *)m);
    c->ch->h.applied++;
}

// Server window clip to visible frame B (global pt): content is 1:1 from the top-left corner,
// cropped on the right/bottom, like Hyprland UV cropping on resize. on=0 removes it.
// conn = window owner: prevents the server from creating a foreign override.
static void put_clip(struct ctx *c, struct ch_win *w, void *win, int on, double x, double y, double ww, double hh) {
    if (!on && !w->clipped) return;
    if (on && w->clipped && dabs(x - w->clip[0]) < 0.25 && dabs(y - w->clip[1]) < 0.25 &&
        dabs(ww - w->clip[2]) < 0.25 && dabs(hh - w->clip[3]) < 0.25) return;
    void *reg = 0;
    if (on) {
        rect r = {x, y, ww, hh};
        reg = c->rgn(r);
        if (!reg) return;
    }
    unsigned wid = w->wid;
    c->clip(*(void **)((char *)win + 0x30), reg, &wid, 1);
    if (reg) c->release(reg);
    w->clipped = on;
    w->clip[0] = x; w->clip[1] = y; w->clip[2] = ww; w->clip[3] = hh;
}

static void put_identity(struct ctx *c, struct ch_win *w) { put_xform(c, w, 1.0, 1.0, 0.0, 0.0); }

// P4: visible frame B mask on Hosting layer in window CA tree (compositor.md sections 1b, 3)
// Mask moves with the window (transform/Space transition), rounded and antialiased by CA; screen clip could not.
struct rect4 { double x, y, w, h; };
typedef void *(*msg0_t)(void *, void *);
typedef void (*msgp_t)(void *, void *, void *);
typedef void (*msgd_t)(void *, void *, double);
typedef void (*msgr_t)(void *, void *, struct rect4);
typedef struct rect4 (*msgb_t)(void *, void *);     // CGRect return: HFA in d0-d3 (arm64, no stret)

static void layers_commit(struct ctx *c, void *tx) {
    c->tx_dtor(tx);
    // WS scope commit can be nested in an implicit transaction left by the
    // scheduler/CA getters. Its selected contexts then stay unpublished, and a
    // later window overwrites that selection. Flush the implicit outer scope
    // while THIS scope's context list is still current. Public flush deliberately
    // leaves an enclosing explicit native transaction alone; never pop it here.
    void *transaction = c->cls("CATransaction");
    if (transaction) ((void (*)(void *, void *))c->msg)(transaction, c->sel("flush"));
}

static void decoration_damage(struct ctx *c, void *win) {
    if (!win) return;
    // The gradient extends outside the application's content/dirty region.
    // A CA commit or scheduling a display is not an explicit invalidation of
    // that outer band. Use WS's native visible-frame minus opaque-interior
    // damage path (includes transformed shadow outset), before scheduling.
    // No shadow-property, geometry-seed or application redraw is changed here.
    if (c->sh_inval) c->sh_inval(0, win);
    if (c->sched_win) c->sched_win(0, win);
}

static int mask_ready(struct ctx *c) {
    if (!c->msg || !c->sel || !c->cls || !c->tx_ctor || !c->tx_add || !c->tx_dtor || !c->srgb) return 0;
    if (!c->c_layer) {
        c->s_layer = c->sel("layer"); c->s_retain = c->sel("retain"); c->s_release = c->sel("release");
        c->s_frame = c->sel("setFrame:"); c->s_radius = c->sel("setCornerRadius:");
        c->s_bg = c->sel("setBackgroundColor:"); c->s_mask = c->sel("setMask:");
        c->s_bounds = c->sel("bounds");
        c->s_arm = c->sel("setAutoresizingMask:");
        c->s_getmask = c->sel("mask");
        c->s_name = c->sel("name"); c->s_setname = c->sel("setName:"); c->s_equal = c->sel("isEqualToString:");
        void *ns = c->cls("NSString");
        c->layer_name = ns ? ((void *(*)(void *, void *, const char *))c->msg)(ns, c->sel("stringWithUTF8String:"), "hyprwm.managed.v1") : 0;
        if (c->layer_name) ((msg0_t)c->msg)(c->layer_name, c->s_retain);
        c->black = c->srgb(0, 0, 0, 1);
        c->c_layer = c->cls("CALayer");
    }
    return c->c_layer && c->black;
}

static void mark_layer(struct ctx *c, void *L) {
    if (L && c->layer_name) ((msgp_t)c->msg)(L, c->s_setname, c->layer_name);
}
static int owned_layer(struct ctx *c, void *L) {
    void *name = L && c->s_name ? ((msg0_t)c->msg)(L, c->s_name) : 0;
    return name && c->layer_name && ((unsigned char (*)(void *, void *, void *))c->msg)(name, c->s_equal, c->layer_name);
}
static void restore_mask(struct ctx *c, struct ch_win *w, void *H) {
    struct saved_window *s = saved_window(c, w);
    if (H && w->mask && ((msg0_t)c->msg)(H, c->s_getmask) == (void *)w->mask)
        ((msgp_t)c->msg)(H, c->s_mask, (void *)s->original_mask);
    if (s->original_mask) ((msg0_t)c->msg)((void *)s->original_mask, c->s_release);
    s->original_mask = 0; s->mask_set = 0;
}

// Anchor the layer to its parent's TOP edge (window layer Y axis is upward): WS updates Hosting/Server root bounds
// during ingestion one frame after our tick; masks/rings measured from the bottom moved for that frame
// by the height change. kCALayerMinYMargin (8) makes CA move them in the same transaction (resizeSublayers...
// and mask @0x18a5fde54, native_hooks section 3.3; sync_protocol.md).
typedef void (*msgu_t)(void *, void *, unsigned);
static void keep_top(struct ctx *c, void *L) {
    if (L && c->s_arm) ((msgu_t)c->msg)(L, c->s_arm, 8);
}

// on: show only (0,0,cw,chh) from buffer's top-left corner; off: remove mask.
static void put_mask(struct ctx *c, struct ch_win *w, void *win, int on, double cw, double chh) {
    struct ch *ch = c->ch;
    if (!on && !w->mask) return;
    if (!mask_ready(c)) return;
    void *cwc = *(void **)((char *)win + 0x18);
    void *H = cwc ? *(void **)((char *)cwc + 0x98) : 0;          // "Hosting"
    void *cactx = cwc ? *(void **)((char *)cwc + 0x38) : 0;      // window CAContext
    if (!H || !cactx) { ch->h.mask_errs++; return; }
    // Use the layer's own height, not the window shape: layer resizes one or two frames after the shape
    // (application already sent the new size). Shape height moved the mask beyond the layer, hiding a frame [V rec2 f_010].
    struct rect4 hb = on ? ((msgb_t)c->msg)(H, c->s_bounds) : (struct rect4){0, 0, 0, 0};
    if (on && !(hb.h >= 1 && finite(hb.h) && finite(hb.y))) { ch->h.mask_errs++; return; }
    if (on && w->mask && dabs(cw - w->mrect[0]) < 0.25 && dabs(chh - w->mrect[1]) < 0.25 &&
        dabs(hb.y - w->mhost[0]) < 0.25 && dabs(hb.h - w->mhost[1]) < 0.25) return;
    unsigned long long tx[4] = {0, 0, 0, 0};                     // {CFArray*, disableActions, began}: 16 bytes
    c->tx_ctor(tx, 1);                                           // bit0: disableActions
    c->tx_add(tx, cactx);
    if (on) {
        void *M = (void *)w->mask;
        if (!M) {
            M = ((msg0_t)c->msg)(c->c_layer, c->s_layer);
            if (M) {
                mark_layer(c, M);
                ((msg0_t)c->msg)(M, c->s_retain);
                keep_top(c, M);
                ((msgp_t)c->msg)(M, c->s_bg, c->black);
                ((msgd_t)c->msg)(M, c->s_radius, w->radius > 0 ? w->radius : 18.0);
                void *cv = c->s_curveget ? ((msg0_t)c->msg)(H, c->s_curveget) : 0;
                if (cv && c->s_curve) ((msgp_t)c->msg)(M, c->s_curve, cv);
                w->mask = (u64)M;
            }
        }
        if (M) {
            struct saved_window *s = saved_window(c, w);
            if (!s->mask_set) {
                void *original = ((msg0_t)c->msg)(H, c->s_getmask);
                if (original && original != M && !owned_layer(c, original)) {
                    ((msg0_t)c->msg)(original, c->s_retain); s->original_mask = (u64)original;
                }
                s->mask_set = 1;
            }
            double hh = chh < hb.h ? chh : hb.h;                  // buffer visible from layer's top edge
            double y = ch->h.mask_flip ? hb.y + hb.h - hh : hb.y;  // layer Y axis upward [V rec2 f_011]
            struct rect4 f = {hb.x, y, cw, hh};
            ((msgr_t)c->msg)(M, c->s_frame, f);
            ((msgd_t)c->msg)(M, c->s_radius, w->radius > 0 ? w->radius : 18.0);
            ((msgp_t)c->msg)(H, c->s_mask, M);
            w->mrect[0] = cw; w->mrect[1] = chh; w->mhost[0] = hb.y; w->mhost[1] = hb.h;
        }
    } else {
        restore_mask(c, w, H);
        ((msg0_t)c->msg)((void *)w->mask, c->s_release);
        w->mask = 0; w->mrect[0] = w->mrect[1] = 0;
    }
    layers_commit(c, tx);                                       // publish this context, including implicit outer scope
    if (c->sched_win) c->sched_win(0, win);
}

static int use_mask(struct ctx *c, struct ch_win *w) {
    return c->ch->h.use_mask && (!c->ch->h.mask_only || c->ch->h.mask_only == w->wid);
}

// P6: focus border: layers in Server root of window CA tree (compositor.md section 3 item 3)
// Inactive ring: CALayer with borderWidth/borderColor/cornerRadius. Active ring: CAGradientLayer (Hyprland gradient
// colors baked in OkLab by daemon), masked with the same ring; crossfade = active layer opacity.
// Ring outside visible frame B (Hyprland borders are outside content); outer radius = radius + width.
struct pt2 { double x, y; };
typedef void (*msgf_t)(void *, void *, float);
typedef void (*msgpt_t)(void *, void *, struct pt2);
typedef struct rect4 (*msgcv_t)(void *, void *, struct rect4, void *);
typedef void *(*msgarr_t)(void *, void *, void **, unsigned long);

static int deco_ready(struct ctx *c) {
    if (!mask_ready(c)) return 0;
    if (!c->c_grad) {
        c->s_bwidth = c->sel("setBorderWidth:"); c->s_bcolor = c->sel("setBorderColor:");
        c->s_colors = c->sel("setColors:"); c->s_start = c->sel("setStartPoint:"); c->s_end = c->sel("setEndPoint:");
        c->s_colorsget = c->sel("colors");
        c->s_opacity = c->sel("setOpacity:"); c->s_addsub = c->sel("addSublayer:");
        c->s_remove = c->sel("removeFromSuperlayer"); c->s_convert = c->sel("convertRect:toLayer:");
        c->s_arr = c->sel("arrayWithObjects:count:"); c->s_getmask = c->sel("mask"); c->s_curve = c->sel("setCornerCurve:");
        c->c_array = c->cls("NSArray");
        void *ns = c->cls("NSString");
        c->str_cont = ns ? ((void *(*)(void *, void *, const char *))c->msg)(ns, c->sel("stringWithUTF8String:"), "continuous") : 0;
        if (c->str_cont) ((msg0_t)c->msg)(c->str_cont, c->s_retain);
        c->str_circ = ns ? ((void *(*)(void *, void *, const char *))c->msg)(ns, c->sel("stringWithUTF8String:"), "circular") : 0;
        if (c->str_circ) ((msg0_t)c->msg)(c->str_circ, c->s_retain);
        c->s_shpath = c->sel("setShadowPath:"); c->s_shcolor = c->sel("setShadowColor:");
        c->s_shrad = c->sel("setShadowRadius:"); c->s_shoff = c->sel("setShadowOffset:");
        c->s_shop = c->sel("setShadowOpacity:"); c->s_insert = c->sel("insertSublayer:atIndex:");
        c->s_path = c->sel("setPath:"); c->s_fillcolor = c->sel("setFillColor:");
        c->s_fillrule = c->sel("setFillRule:"); c->s_hidden = c->sel("setHidden:");
        c->c_shape = c->cls("CAShapeLayer");
        void *ns2 = c->cls("NSString");
        c->str_eo = ns2 ? ((void *(*)(void *, void *, const char *))c->msg)(ns2, c->sel("stringWithUTF8String:"), "even-odd") : 0;
        if (c->str_eo) ((msg0_t)c->msg)(c->str_eo, c->s_retain);
        c->c_basic = c->cls("CABasicAnimation"); c->s_akp = c->sel("animationWithKeyPath:");
        c->s_from = c->sel("setFromValue:"); c->s_to = c->sel("setToValue:"); c->s_adur = c->sel("setDuration:");
        c->s_tf = c->sel("setTimingFunction:"); c->s_addanim = c->sel("addAnimation:forKey:");
        c->s_removeanim = c->sel("removeAnimationForKey:");
        c->s_pres = c->sel("presentationLayer"); c->s_opget = c->sel("opacity"); c->s_shopget = c->sel("shadowOpacity");
        c->c_num = c->cls("NSNumber"); c->s_numf = c->sel("numberWithFloat:");
        c->c_tfn = c->cls("CAMediaTimingFunction"); c->s_tfcp = c->sel("functionWithControlPoints::::");
        void *ns3 = c->cls("NSString");
        void *(*mk)(void *, void *, const char *) = (void *(*)(void *, void *, const char *))c->msg;
        void *sutf = c->sel("stringWithUTF8String:");
        c->str_op = ns3 ? mk(ns3, sutf, "opacity") : 0;
        c->str_shop = ns3 ? mk(ns3, sutf, "shadowOpacity") : 0;
        c->str_colors = ns3 ? mk(ns3, sutf, "colors") : 0;
        if (c->str_op) ((msg0_t)c->msg)(c->str_op, c->s_retain);
        if (c->str_shop) ((msg0_t)c->msg)(c->str_shop, c->s_retain);
        if (c->str_colors) ((msg0_t)c->msg)(c->str_colors, c->s_retain);
        c->s_curveget = c->sel("cornerCurve");
        c->s_subl = c->sel("sublayers"); c->s_count = c->sel("count"); c->s_objat = c->sel("objectAtIndex:");
        c->s_iskind = c->sel("isKindOfClass:"); c->s_shpathget = c->sel("shadowPath");
        c->c_grad = c->cls("CAGradientLayer");
    }
    return c->c_grad && c->c_array;
}

static void *ring(struct ctx *c, double wd, double r, void *color) {
    void *L = ((msg0_t)c->msg)(c->c_layer, c->s_layer);
    if (!L) return 0;
    mark_layer(c, L);
    ((msgd_t)c->msg)(L, c->s_bwidth, wd);
    ((msgp_t)c->msg)(L, c->s_bcolor, color);
    ((msgd_t)c->msg)(L, c->s_radius, r);
    void *cv = c->cur_curve ? c->cur_curve : c->str_cont;     // corner shape matches the window itself (Hosting)
    if (cv) ((msgp_t)c->msg)(L, c->s_curve, cv);
    return L;
}

typedef double (*msgdr_t)(void *, void *);
static void border_make(struct ctx *c, struct ch_win *w, void *root) {
    struct ch_deco *d = &c->ch->deco;
    double r = d->radius + d->width;
    void *ci = c->srgb(d->inact[0], d->inact[1], d->inact[2], d->inact[3]);
    double band = (d->sys_off == 1 ? 0.0 : d->width) + d->inset10 / 10.0;   // as in border_win: outward + inward
    if (band < 0.5) band = d->width;
    void *I = ci ? ring(c, band, r, ci) : 0;
    if (ci) c->release(ci);
    void *G = ((msg0_t)c->msg)(c->c_grad, c->s_layer);
    if (!I || !G) return;
    mark_layer(c, G);
    void *cols[8]; unsigned n = d->ngrad > 8 ? 8 : d->ngrad;
    if (n < 2) n = 2;
    for (unsigned i = 0; i < n; i++) cols[i] = c->srgb(d->inact[0], d->inact[1], d->inact[2], d->inact[3]);
    void *arr = ((msgarr_t)c->msg)(c->c_array, c->s_arr, cols, n);
    ((msgp_t)c->msg)(G, c->s_colors, arr);
    for (unsigned i = 0; i < n; i++) if (cols[i]) c->release(cols[i]);
    struct pt2 a = {d->start[0], d->start[1]}, b = {d->end[0], d->end[1]};
    ((msgpt_t)c->msg)(G, c->s_start, a);
    ((msgpt_t)c->msg)(G, c->s_end, b);
    void *M = ring(c, band, r, c->black);
    if (M) ((msgp_t)c->msg)(G, c->s_mask, M);
    // One visible ring: interpolating its colors preserves coverage throughout focus.
    // Keep the old inactive slot as a hidden compatibility layer, never composite it.
    ((msgf_t)c->msg)(I, c->s_opacity, 0.0f);
    ((msgf_t)c->msg)(G, c->s_opacity, 1.0f);
    keep_top(c, I); keep_top(c, G);
    ((msg0_t)c->msg)(I, c->s_retain); ((msg0_t)c->msg)(G, c->s_retain);
    ((msgp_t)c->msg)(root, c->s_addsub, I);
    ((msgp_t)c->msg)(root, c->s_addsub, G);
    w->bl_in = (u64)I; w->bl_act = (u64)G; w->bop = 0; w->bframe[2] = -1;
}

// Remove window border and mask (freeing slot). cactx may be 0 (window gone): use a context-free transaction
// only to keep release/removeFromSuperlayer inside a balanced WS transaction.
static void layers_drop(struct ctx *c, struct ch_win *w, void *cactx, void *H) {
    if (!w->bl_in && !w->bl_act && !w->bl_sh && !w->bl_fill && !w->mask) return;
    if (!mask_ready(c)) return;
    unsigned long long tx[4] = {0, 0, 0, 0};
    c->tx_ctor(tx, 1);
    if (cactx) c->tx_add(tx, cactx);
    void *L[4] = {(void *)w->bl_in, (void *)w->bl_act, (void *)w->bl_sh, (void *)w->bl_fill};
    for (int i = 0; i < 4; i++) if (L[i]) { ((msg0_t)c->msg)(L[i], c->s_remove); ((msg0_t)c->msg)(L[i], c->s_release); }
    restore_mask(c, w, H);
    if (w->mask) {
        ((msg0_t)c->msg)((void *)w->mask, c->s_release);
    }
    w->bl_in = w->bl_act = w->bl_sh = w->bl_fill = w->mask = 0;
    w->fkey[4] = -1;
    layers_commit(c, tx);
    if (cactx && c->by_id) decoration_damage(c, c->by_id(w->wid));
}

// WSShadowProperties (0x40): sigma, density, rimDens, rimRad, innerDens, innerRad, offY (float), flags, ..., mask
// override @+0x38 [V setter copies ldp q0..q3; beyond_bounds section 1.7.1]. on: sigma 23 (frame_bounds +65 pt),
// density 0.001 (shadow-enabled threshold keeps clip expanded; 0.26/255 is invisible), Tahoe outline 0, mask 0xfff:
// AppKit cannot override it. off: restore exact prior active/inactive overrides, preserving others' settings.
struct ws_shadow { float f[14]; u32 mask, pad; };
static void shadow_override(struct ctx *c, struct ch_win *w, void *win, int on) {
    struct saved_window *old = saved_window(c, w);
    if (on && !old->shadow_set) {
        for (int i = 0; i < 16; i++) old->shadow[i] = *(u64 *)((char *)win + 0x2d8 + 8 * i);
        old->shadow_set = 1;
    }
    struct ws_shadow s;
    for (int i = 0; i < 14; i++) s.f[i] = 0;
    s.mask = 0; s.pad = 0;
    if (on) { s.f[0] = 23.0f; s.f[1] = 0.001f; s.mask = 0xfff; }
    void *conn = c->owner ? c->owner(win) : 0;
    if (c->sh_inval) c->sh_inval(conn, win);
    if (!on && old->shadow_set) {
        c->wm_shadow(win, old->shadow, old->shadow + 8);
        old->shadow_set = 0;
    } else c->wm_shadow(win, &s, &s);
    if (c->sh_sched) c->sh_sched(win, conn);
}

static void radius_restore(struct ctx *c, struct ch_win *w, void *win) {
    if ((w->rset & 4) && win && c->wm_shadow) shadow_override(c, w, win, 0);
    if ((w->rset & 1) && win && c->dbg_clear) c->dbg_clear(win);    // application radius takes effect again
    if ((w->rset & 2) && win && c->tags) { void *a[1] = {win}; c->tags(0, a, 8, 1); }   // restore Tahoe shadow/outline
    w->rset = 0;
}

static void slot_free(struct ctx *c, struct ch_win *w, void *win) {
    live_edge_drop(c,w);
    live_edge_client(c,w,0);
    native_cancel(c, w, win);
    radius_restore(c, w, win);
    void *cwc = win ? *(void **)((char *)win + 0x18) : 0;
    layers_drop(c, w, cwc ? *(void **)((char *)cwc + 0x38) : 0, cwc ? *(void **)((char *)cwc + 0x98) : 0);
    saved_window(c, w)->shadow_set = 0;
    saved_window(c, w)->cfg_sent = 0;
    w->used = 0;
}

typedef void (*msgi_t)(void *, void *, void *, unsigned);
#define SH_E 64.0              // shadow ring mask width: visible up to SH_E pt outward (range 34 + offset 10 + margin)

// Shadow layer under system Shadow (index 0 in Server root); only shadowPath draws; ring mask
// has inner edge at bordered box, leaving no shadow inside the window (like Hyprland).
static void shadow_make(struct ctx *c, struct ch_win *w, void *root, void *shadow_sys) {
    struct ch_deco *d = &c->ch->deco;
    void *S = ((msg0_t)c->msg)(c->c_layer, c->s_layer);
    if (!S) return;
    mark_layer(c, S);
    void *black = c->black;
    ((msgp_t)c->msg)(S, c->s_shcolor, black);
    ((msgd_t)c->msg)(S, c->s_shrad, d->srad);
    struct pt2 off = {0, -d->soff};                     // layer Y axis upward: downward = negative
    ((msgpt_t)c->msg)(S, c->s_shoff, off);
    ((msgf_t)c->msg)(S, c->s_shop, 0.0f);
    void *M = ring(c, SH_E, d->radius + d->width + SH_E, black);
    if (M) ((msgp_t)c->msg)(S, c->s_mask, M);
    keep_top(c, S);
    ((msg0_t)c->msg)(S, c->s_retain);
    ((msgi_t)c->msg)(root, c->s_insert, S, 0);
    w->bl_sh = (u64)S; w->sop = -1;
    if (d->sys_off && shadow_sys) {                  // system shadow and Tahoe window outline (Shadow borderWidth 1 [V])
        ((msgf_t)c->msg)(shadow_sys, c->s_shop, 0.0f);
        ((msgd_t)c->msg)(shadow_sys, c->s_bwidth, 0.0);
    }
}

typedef float (*msgfr_t)(void *, void *);
// Animate layer float property to target using CABasicAnimation from current presentationLayer value (smooth
// mid-motion retarget), with configured cubic-bezier; model value = to. Inside an open WS transaction.
static void fade_to(struct ctx *c, void *L, void *key, void *getsel, void *setsel, double to, double dur, const double *bz) {
    if (!L) return;
    void *P = c->s_pres ? ((msg0_t)c->msg)(L, c->s_pres) : 0;
    float from = ((msgfr_t)c->msg)(P ? P : L, getsel);
    if (dur > 0.001 && key && c->c_basic && c->c_num && dabs(from - to) > 0.002) {
        void *A = ((void *(*)(void *, void *, void *))c->msg)(c->c_basic, c->s_akp, key);
        if (A) {
            void *nf = ((void *(*)(void *, void *, float))c->msg)(c->c_num, c->s_numf, from);
            void *nt = ((void *(*)(void *, void *, float))c->msg)(c->c_num, c->s_numf, (float)to);
            ((msgp_t)c->msg)(A, c->s_from, nf);
            ((msgp_t)c->msg)(A, c->s_to, nt);
            ((msgd_t)c->msg)(A, c->s_adur, dur);
            if (c->c_tfn) {
                void *T = ((void *(*)(void *, void *, float, float, float, float))c->msg)(c->c_tfn, c->s_tfcp,
                          (float)bz[0], (float)bz[1], (float)bz[2], (float)bz[3]);
                if (T) ((msgp_t)c->msg)(A, c->s_tf, T);
            }
            ((void (*)(void *, void *, void *, void *))c->msg)(L, c->s_addanim, A, key);
        }
    } else if (key && c->s_removeanim) ((msgp_t)c->msg)(L, c->s_removeanim, key);
    ((msgf_t)c->msg)(L, setsel, (float)to);
}

// CAGradientLayer.colors is an animatable NSArray<CGColorRef> (public SDK).
// QuartzCore interpolates matching arrays componentwise; no second ring contributes
// source-over coverage. A change in stop count skips interpolation rather than truncating.
static void fade_colors(struct ctx *c, void *G, double focus, double dur, const double *bz) {
    struct ch_deco *d = &c->ch->deco;
    unsigned n = d->ngrad > 8 ? 8 : d->ngrad; if (n < 2) n = 2;
    void *cols[8];
    for (unsigned i = 0; i < n; i++) {
        const double *rgba = focus > 0.5 ? d->grad[d->ngrad < 2 ? 0 : i] : d->inact;
        cols[i] = c->srgb(rgba[0], rgba[1], rgba[2], rgba[3]);
    }
    void *to = ((msgarr_t)c->msg)(c->c_array, c->s_arr, cols, n);
    for (unsigned i = 0; i < n; i++) if (cols[i]) c->release(cols[i]);
    void *P = c->s_pres ? ((msg0_t)c->msg)(G, c->s_pres) : 0;
    void *from = ((msg0_t)c->msg)(P ? P : G, c->s_colorsget);
    if (!P && c->str_colors) {
        // An uncommitted endpoint has never been displayed. Preserve the
        // pending animation's start on a reversal before the first commit.
        void *pending = ((void *(*)(void *, void *, void *))c->msg)(G, c->sel("animationForKey:"), c->str_colors);
        void *start = pending ? ((msg0_t)c->msg)(pending, c->sel("fromValue")) : 0;
        if (start) from = start;
    }
    unsigned long nf = from ? ((unsigned long (*)(void *, void *))c->msg)(from, c->s_count) : 0;
    if (to && from && nf == n && dur > 0.001 && c->c_basic && c->str_colors) {
        void *A = ((void *(*)(void *, void *, void *))c->msg)(c->c_basic, c->s_akp, c->str_colors);
        if (A) {
            ((msgp_t)c->msg)(A, c->s_from, from); ((msgp_t)c->msg)(A, c->s_to, to);
            ((msgd_t)c->msg)(A, c->s_adur, dur);
            if (c->c_tfn) {
                void *T = ((void *(*)(void *, void *, float, float, float, float))c->msg)(c->c_tfn, c->s_tfcp,
                          (float)bz[0], (float)bz[1], (float)bz[2], (float)bz[3]);
                if (T) ((msgp_t)c->msg)(A, c->s_tf, T);
            }
            ((void (*)(void *, void *, void *, void *))c->msg)(G, c->s_addanim, A, c->str_colors);
        }
    } else if (c->s_removeanim && c->str_colors) ((msgp_t)c->msg)(G, c->s_removeanim, c->str_colors);
    if (to) ((msgp_t)c->msg)(G, c->s_colors, to);
}

static u64 decoration_hash(const struct ch_deco *d) {
    // focus changes have their own animation; all remaining style fields must refresh
    // existing layers after hot reload, including border widths initialized at creation.
    const unsigned char *p = (const unsigned char *)d; u64 hash = 1469598103934665603ull;
    for (unsigned i = 8; i < sizeof *d; i++) { hash ^= p[i]; hash *= 1099511628211ull; }
    return hash;
}

static double ring_scale(struct ch_win *w) {
    double sx = w->m[0], sy = w->m[1];
    // The root transform applies after convertRect:toLayer:. Uniform popin may scale
    // the window, but its visible border width stays in screen pt. Nonuniform scaling
    // needs an anisotropic contour; do not claim a scalar width solves it.
    return sx > 0.02 && sy > 0.02 && dabs(sx - sy) < 1e-4 * sx ? sx : 1.0;
}

// Clean traces of earlier engine installs (slots lost on reinstall, layers left in window tree:
// extra ring with old geometry, two active rings, foreign Hosting mask). WS only adds Shadow to Server root;
// remove only layers bearing our name. Type/stroke width do not prove ownership:
// applications also use CAGradientLayer/CAShapeLayer and their own masks.
typedef unsigned long (*msgul_t)(void *, void *);
static void sweep_old(struct ctx *c, struct ch_win *w, void *root, void *shadow_sys, void *H) {
    if (!c->s_subl || !c->s_count || !c->s_objat || !c->s_iskind) return;
    void *subs = ((msg0_t)c->msg)(root, c->s_subl);
    unsigned long n = subs ? ((msgul_t)c->msg)(subs, c->s_count) : 0;
    void *kill[16]; int k = 0;
    for (unsigned long i = 0; i < n && i < 64 && k < 16; i++) {
        void *L = ((void *(*)(void *, void *, unsigned long))c->msg)(subs, c->s_objat, i);
        if (!L || L == shadow_sys || L == (void *)w->bl_in || L == (void *)w->bl_act || L == (void *)w->bl_sh ||
            L == (void *)w->bl_fill) continue;
        int ours = owned_layer(c, L);
        if (ours) kill[k++] = L;
    }
    for (int i = 0; i < k; i++) ((msg0_t)c->msg)(kill[i], c->s_remove);
    void *m = ((msg0_t)c->msg)(H, c->s_getmask);
    int drop_mask = m && m != (void *)w->mask && owned_layer(c, m);
    if (drop_mask) ((msgp_t)c->msg)(H, c->s_mask, 0);
    c->ch->h.reserved[4] += (u64)k + drop_mask;
}

// Draw-time projection is local to an active ordinary live resize. AppKit has
// already accepted its one final size, which can be smaller than intermediate B.
// Keep opening/native/edge/snapshot state and the shared stretch flag unchanged.
static unsigned live_resize_projection(struct ctx *c,struct ch_win *w,double bw,double bh,double *sx,double *sy) {
    *sx=*sy=1;
    // Buffer scaling is an explicit optional presentation mode. Native mode
    // redraws through the client; never silently turn live content into a zoom.
    if (!(c->ch->h.reserved[0] & (1ull<<25))) return 0;
    if((w->geo!=1&&w->geo!=4)||w->stretch||w->held||!w->size.active||
       cover_index(c,w->wid,0)>=0||cover_index(c,w->wid,1)>=0||
       !(bw>=1&&bh>=1&&w->aw>=1&&w->ah>=1)||!finite(bw)||!finite(bh)||!finite(w->aw)||!finite(w->ah))return 0;
    unsigned axes=0;
    if(w->size.g[0]<bw-.5&&dabs(w->aw-w->size.g[0])<=2&&w->aw<bw-.5&&w->aw/bw>=.02){*sx=w->aw/bw;axes|=1;}
    if(w->size.g[1]<bh-.5&&dabs(w->ah-w->size.g[1])<=2&&w->ah<bh-.5&&w->ah/bh>=.02){*sy=w->ah/bh;axes|=2;}
    return axes;
}

// One window's border for frame te. 1 = crossfade still running.
static int border_win(struct ctx *c, struct ch_win *w, double te) {
    struct ch *ch = c->ch;
    struct ch_deco *d = &ch->deco;
    struct saved_window *saved = saved_window(c, w);
    u64 dhash = decoration_hash(d);
    int style_changed = saved->deco_hash != dhash;
    if (!w->geo) return 0;
    void *win = c->by_id(w->wid);
    if (!win) return 0;
    void *cwc = *(void **)((char *)win + 0x18);
    void *root = cwc ? *(void **)((char *)cwc + 0x80) : 0;
    void *H = cwc ? *(void **)((char *)cwc + 0x98) : 0;
    void *cactx = cwc ? *(void **)((char *)cwc + 0x38) : 0;
    if (!root || !H || !cactx) return 0;
    unsigned focus_wid=presentation_wid(c,w);
    if (!d->on || focus_wid == d->nofull || (d->only && focus_wid != d->only)) {
        if (w->bl_in || w->bl_sh) layers_drop(c, w, cactx, H);
        if(!effects_owns_corner(c,w))radius_restore(c, w, win);
        return 0;
    }
    // Corner radius matches Hyprland (decoration.rounding): WS debug radius overrides application radius [V listing
    // resolved_corner_radius 187063110: bit 6 win+0x928 -> win+0x858]; otherwise Telegram/Tahoe 26, Ghostty 16
    double configured_radius=effects_owns_corner(c,w)?0:d->radius;
    if (configured_radius >= 0 && c->dbg_radius && c->corner && dabs(c->corner(win) - configured_radius) > 0.01) {
        c->dbg_radius(win, configured_radius);
        w->rset |= 1;
    }
    // Suppress system shadow and Tahoe outline through DisableShadow tag (bit 3 win+0x80): WS keeps them off across
    // activity changes (it overwrote cleared Shadow properties, making the outline appear/disappear abruptly).
    if (d->sys_off != 1 && c->tags && (w->rset & 2)) {   // mode is not "tag": restore window shadow (and expanded clip)
        void *a[1] = {win};
        c->tags(0, a, 8, 1);
        w->rset &= ~2u;
    }
    if (d->sys_off == 1 && c->tags && !(w->rset & 2) && !((*(u64 *)((char *)win + 0x80) >> 3) & 1)) {
        void *a[1] = {win};
        c->tags(0, a, 8, 0);
        w->rset |= 2;
    }
    // Mode 3: shadow override once per window; repeat only if someone overwrote the result (active density
    // win+0x35c != 0.001, practically never with mask 0xfff).
    int ovr = d->sys_off == 3 && c->wm_shadow;
    if (ovr && (!(w->rset & 4) || dabs(*(float *)((char *)win + 0x35c) - 0.001f) > 0.0005)) {
        shadow_override(c, w, win, 1);
        w->rset |= 4;
    }
    if (!ovr && (w->rset & 4) && c->wm_shadow) {
        shadow_override(c, w, win, 0);
        w->rset &= ~4u;
    }
    double rin = c->corner ? c->corner(win) : d->radius;
    int rchg = dabs(rin - w->radius) > 0.01;
    if (rchg) w->radius = rin;
    // CA runs border/shadow crossfade (fade_to); we only change targets and request redraw while running.
    double gt = focus_wid == d->focus ? 1.0 : 0.0;
    int tchg = !w->bl_in || w->act.g[0] != gt || style_changed;
    double op = gt;
    double sop = d->sh_on ? d->sop_in + (d->sop_act - d->sop_in) * gt : 0.0;
    double fend = w->act.t0 + (d->dur > d->sdur ? d->dur : d->sdur) + 2 * ch->h.period;
    int an = te < fend;                              // CA animation running: request redraw every frame
    // Border box in window coordinates: visible B from buffer top-left (popin stretches A to B, so use A then)
    double bw = w->stretch || w->geo == 2 ? w->aw : w->size.v[0];
    double bh = w->stretch || w->geo == 2 ? w->ah : w->size.v[1];
    if (!(bw >= 1) || !(bh >= 1) || !finite(bw) || !finite(bh)) return an;
    double projected_x,projected_y;
    live_resize_projection(c,w,bw,bh,&projected_x,&projected_y);
    // The window's inverse transform scales this root too. Express screen B in
    // source units so the ring follows B exactly instead of being scaled twice.
    bw*=projected_x;bh*=projected_y;
    struct rect4 hb = ((msgb_t)c->msg)(H, c->s_bounds);
    if (!(hb.h >= 1) || !finite(hb.h) || !finite(hb.y)) return an;
    if (w->geo == 2) {             // native shape and Hosting can be ingested in adjacent frames
        if (hb.w >= 1 && finite(hb.w) && hb.w < bw) bw = hb.w;
        if (hb.h < bh) bh = hb.h;
    }
    // Ring extends outward by ow (= border width like Hyprland; 0 with narrow window clip in tag mode), inward by ins
    // (covering the application's own outline); ring band width = ow + ins
    double wd = d->width, ins = d->inset10 / 10.0;
    double ow = d->sys_off == 1 ? 0.0 : wd;
    if (d->sys_off == 1 && ins > wd) ins = wd;
    double scale = ring_scale(w); ow *= scale; ins *= scale;
    struct rect4 f = {hb.x - ow, ch->h.mask_flip ? hb.y + hb.h - bh - ow : hb.y - ow, bw + 2 * ow, bh + 2 * ow};
    // Hosting can move relative to Server root without changing its local bounds.
    // Compare the converted rectangle, otherwise those ingestion updates leave a stale ring.
    struct rect4 fr = ((msgcv_t)c->msg)(H, c->s_convert, f, root);
    // Native ingestion/autoresizing owns the parent and can change our actual
    // layer frame without changing the desired rectangle or bframe cache.
    // Verify both attachment and geometry before considering this ring settled.
    void *get_parent = c->sel("superlayer"), *get_frame = c->sel("frame");
    int detached = (w->bl_in && ((msg0_t)c->msg)((void *)w->bl_in, get_parent) != root) ||
                   (w->bl_act && ((msg0_t)c->msg)((void *)w->bl_act, get_parent) != root) ||
                   (w->bl_sh && ((msg0_t)c->msg)((void *)w->bl_sh, get_parent) != root) ||
                   (w->bl_fill && ((msg0_t)c->msg)((void *)w->bl_fill, get_parent) != root);
    struct rect4 actual = w->bl_act ? ((msgb_t)c->msg)((void *)w->bl_act, get_frame) : (struct rect4){0};
    int drift = dabs(actual.x-fr.x) > 0.01 || dabs(actual.y-fr.y) > 0.01 ||
                dabs(actual.w-fr.w) > 0.01 || dabs(actual.h-fr.h) > 0.01;
    int moved = !w->bl_in || detached || drift || rchg || style_changed || dabs(fr.x - w->bframe[0]) > 0.01 || dabs(fr.y - w->bframe[1]) > 0.01 ||
                dabs(fr.w - w->bframe[2]) > 0.01 || dabs(fr.h - w->bframe[3]) > 0.01;
    // Empty band: visible B exceeds buffer layer (application has not yet redrawn at new size)
    int strip = w->geo != 2 && w->fill && c->c_shape && c->path_mut && !w->stretch && (bw > hb.w + 0.5 || bh > hb.h + 0.5);
    double fk[5] = {strip ? bw : 0, strip ? bh : 0, strip ? hb.w : 0, strip ? hb.h : 0, (double)w->fill};
    int fchg = 0;
    for (int i = 0; i < 5; i++) fchg |= dabs(fk[i] - w->fkey[i]) > 0.01;
    if (!strip && !w->bl_fill) fchg = 0;
    // Mode 2: window retains shadow status (drawing clip expanded by shadow radius, beyond_bounds.md section 1),
    // but suppress shadow and Tahoe outline on Shadow layer whenever WS restores them (on activity changes).
    void *shs = *(void **)((char *)cwc + 0x88);
    int fixsh = (d->sys_off == 2 || (d->sys_off == 3 && !c->wm_shadow)) && shs && c->s_shopget &&
                (((msgfr_t)c->msg)(shs, c->s_shopget) > 0.001f || ((msgdr_t)c->msg)(shs, c->sel("borderWidth")) > 0.001);
    if (!moved && !fchg && !tchg && !fixsh && dabs(sop - w->sop) < 0.002) {
        if (an) decoration_damage(c, win);
        return an;
    }
    unsigned long long tx[4] = {0, 0, 0, 0};
    c->tx_ctor(tx, 1);
    c->tx_add(tx, cactx);
    if (!w->bl_in) {
        // Circular corners on both window (Hosting) and rings: continuous inner/outer ring curves are not
        // concentric, making corners thicker than straight sections [report 13:15].
        // Ring corner shape matches the window (Hosting): WS maintains window corner shape; content is above the ring,
        // exposing a band between window and outer ring edge; mismatched shapes thicken corners [V 13:55].
        c->cur_curve = c->s_curveget ? ((msg0_t)c->msg)(H, c->s_curveget) : 0;
        sweep_old(c, w, root, *(void **)((char *)cwc + 0x88), H);
        border_make(c, w, root);
    }
    if (detached) {
        // Reattach only retained layers we own; preserve the native subtree.
        if (w->bl_sh) ((msgi_t)c->msg)(root, c->s_insert, (void *)w->bl_sh, 0);
        if (w->bl_fill) ((msgi_t)c->msg)(root, c->s_insert, (void *)w->bl_fill, w->bl_sh ? 1 : 0);
        if (w->bl_in) ((msgp_t)c->msg)(root, c->s_addsub, (void *)w->bl_in);
        if (w->bl_act) ((msgp_t)c->msg)(root, c->s_addsub, (void *)w->bl_act);
    }
    if (fixsh) {
        ((msgf_t)c->msg)(shs, c->s_shop, 0.0f);
        ((msgd_t)c->msg)(shs, c->s_bwidth, 0.0);
    }
    if (d->sh_on && !w->bl_sh && c->path_rr && c->path_rel)
        shadow_make(c, w, root, *(void **)((char *)cwc + 0x88));
    if (w->bl_in && w->bl_act) {
        if (moved) {
            ((msgr_t)c->msg)((void *)w->bl_in, c->s_frame, fr);
            ((msgr_t)c->msg)((void *)w->bl_act, c->s_frame, fr);
            void *M = ((msg0_t)c->msg)((void *)w->bl_act, c->s_getmask);
            struct rect4 mf = {0, 0, fr.w, fr.h};
            if (M) ((msgr_t)c->msg)(M, c->s_frame, mf);
            double band = ow + ins; if (band < 0.5 * scale) band = wd * scale;
            ((msgd_t)c->msg)((void *)w->bl_in, c->s_bwidth, band);
            if (M) ((msgd_t)c->msg)(M, c->s_bwidth, band);
            double ro = w->radius + ow;                              // outer = window radius + border protrusion (spec section 5.1)
            ((msgd_t)c->msg)((void *)w->bl_in, c->s_radius, ro);
            if (M) ((msgd_t)c->msg)(M, c->s_radius, ro);
            w->bframe[0] = fr.x; w->bframe[1] = fr.y; w->bframe[2] = fr.w; w->bframe[3] = fr.h;
        }
        if (tchg) {
            fade_colors(c, (void *)w->bl_act, op, d->dur, d->bez);
            struct pt2 a = {d->start[0], d->start[1]}, b = {d->end[0], d->end[1]};
            ((msgpt_t)c->msg)((void *)w->bl_act, c->s_start, a);
            ((msgpt_t)c->msg)((void *)w->bl_act, c->s_end, b);
        }
        w->bop = op;
    }
    if (fchg) {
        if (strip && !w->bl_fill) {
            void *F = ((msg0_t)c->msg)(c->c_shape, c->s_layer);
            if (F) {
                mark_layer(c, F);
                ((msg0_t)c->msg)(F, c->s_retain);
                keep_top(c, F);
                if (c->str_eo) ((msgp_t)c->msg)(F, c->s_fillrule, c->str_eo);
                ((msgi_t)c->msg)(root, c->s_insert, F, w->bl_sh ? 1 : 0);     // above our shadow, below window
                w->bl_fill = (u64)F;
            }
        }
        void *F = (void *)w->bl_fill;
        if (F && strip) {
            unsigned v = w->fill;
            void *col = c->srgb((v >> 24 & 255) / 255.0, (v >> 16 & 255) / 255.0, (v >> 8 & 255) / 255.0, (v & 255) / 255.0);
            if (col) { ((msgp_t)c->msg)(F, c->s_fillcolor, col); c->release(col); }
            struct rect4 bb = {hb.x, ch->h.mask_flip ? hb.y + hb.h - bh : hb.y, bw, bh};
            struct rect4 fr = ((msgcv_t)c->msg)(H, c->s_convert, bb, root);
            ((msgr_t)c->msg)(F, c->s_frame, fr);
            void *path = c->path_mut();
            if (path) {
                double r = w->radius;
                if (r > bw / 2) r = bw / 2;
                if (r > bh / 2) r = bh / 2;
                struct rect4_ rb = {0, 0, bw, bh}, ra = {hb.x - bb.x, hb.y - bb.y, hb.w, hb.h};
                c->path_addrr(path, 0, rb, r, r);
                double ar = w->radius;                                // WS rounds buffer (Hosting); cut it out
                if (ar > hb.w / 2) ar = hb.w / 2;                     // use same rounding to avoid notches at the join
                if (ar > hb.h / 2) ar = hb.h / 2;
                c->path_addrr(path, 0, ra, ar, ar);                   // even-odd: buffer cut out
                ((msgp_t)c->msg)(F, c->s_path, path);
                c->path_rel(path);
            }
            ((void (*)(void *, void *, int))c->msg)(F, c->s_hidden, 0);
        } else if (F) ((void (*)(void *, void *, int))c->msg)(F, c->s_hidden, 1);
        for (int i = 0; i < 5; i++) w->fkey[i] = fk[i];
    }
    if (w->bl_sh) {
        void *S = (void *)w->bl_sh;
        if (style_changed) {
            ((msgd_t)c->msg)(S, c->s_shrad, d->srad);
            struct pt2 offset = {0, -d->soff}; ((msgpt_t)c->msg)(S, c->s_shoff, offset);
        }
        if (moved || w->sop < 0) {
            ((msgr_t)c->msg)(S, c->s_frame, fr);
            double r = w->radius + ow;
            if (r > fr.w / 2) r = fr.w / 2;
            if (r > fr.h / 2) r = fr.h / 2;
            struct rect4_ pr = {0, 0, fr.w, fr.h};
            void *path = c->path_rr(pr, r, r, 0);
            if (path) { ((msgp_t)c->msg)(S, c->s_shpath, path); c->path_rel(path); }
            void *M = ((msg0_t)c->msg)(S, c->s_getmask);
            struct rect4 mf = {-SH_E, -SH_E, fr.w + 2 * SH_E, fr.h + 2 * SH_E};
            if (M) { ((msgr_t)c->msg)(M, c->s_frame, mf); ((msgd_t)c->msg)(M, c->s_radius, w->radius + ow + SH_E); }
        }
        if (tchg || dabs(sop - w->sop) > 0.002 || w->sop < 0)
            fade_to(c, S, c->str_shop, c->s_shopget, c->s_shop, sop, w->sop < 0 ? 0.0 : d->sdur, d->sbez);
        w->sop = sop;
    }
    layers_commit(c, tx);
    saved->deco_hash = dhash;
    if (tchg) { w->act.g[0] = gt; w->act.t0 = te; an = 1; }
    decoration_damage(c, win);
    return an;
}

// Backdrop: background window below application window (deco/hyprdeco). Visible only during animation:
// placed exactly at visible B (solid color scales without loss), with the same alpha as the window.
static int effects_render_win(struct ctx *c,struct ch_win *w,double now) {
    if(!effects_ready(c))return 0;
    const struct hy_effects_api *a=c->effects_api;unsigned i=(unsigned)(w-c->ch->win);
    unsigned flags=a->flags(c->effects_runtime);
    void *win=c->by_id(w->wid);
    if(!w->used || !flags || !live_edge_granted(c,w) || w->wid==c->ch->deco.nofull ||
       !win || !c->corner || c->corner(win)>0.01 || !c->s_bounds || !c->s_getmask) {
        // An owned alpha mask cannot recover pixels clipped upstream. Preserve
        // native radius/client leases until the separate clip/ring integration
        // is proven; never falsely count this path as accepted appearance.
        a->drop(c->effects_runtime,i,0);a->drop(c->effects_runtime,i,1);return 0;
    }
    void *cwc=*(void**)((char*)win+0x18);
    void *root=cwc?*(void**)((char*)cwc+0x80):0,*host=cwc?*(void**)((char*)cwc+0x98):0;
    void *context=cwc?*(void**)((char*)cwc+0x38):0;
    if(!root||!host||!context) {a->drop(c->effects_runtime,i,0);a->drop(c->effects_runtime,i,1);return 0;}
    struct rect4 bounds=((msgb_t)c->msg)(host,c->s_bounds);
    struct edge_lease *lease=live_edge_lease(c,w);
    struct hy_effects_frame f={0};
    f.slot=i;f.wid=w->wid;f.prepared=1;f.focus=w->wid==c->ch->deco.focus;
    f.generation=(u64)lease->generation;f.source_window=(u64)win;f.source_context=(u64)context;
    f.host=host;f.root=root;f.parent_mask=((msg0_t)c->msg)(host,c->s_getmask);
    f.border=(void*)w->bl_act;
    f.border_parent_mask=f.border?((msg0_t)c->msg)(f.border,c->s_getmask):0;
    f.border_width=c->ch->deco.width;
    f.legacy_shadow=(void*)w->bl_sh;
    f.width=bounds.w;f.height=bounds.h;f.scale=c->edge_api->resolution?c->edge_api->resolution(win):1;f.now=now;
    unsigned long long tx[4]={0};c->tx_ctor(tx,1);c->tx_add(tx,context);
    int result=a->frame(c->effects_runtime,&f);
    layers_commit(c,tx);
    if(!(result&HY_EFFECTS_APPLIED)) {
        // Failed hierarchy/GPU publication cannot leave a square native window
        // or retry that same birth each tick. The runtime quarantines identity;
        // rebuild the legal legacy ring under its accepted native radius now.
        a->drop(c->effects_runtime,i,1);
        if(c->dbg_radius && c->ch->deco.radius>=0) {
            c->dbg_radius(win,c->ch->deco.radius);w->rset|=1;
            border_win(c,w,now);
        }
        struct edge_state *failed=&c->edges[i];
        if(failed->surface&&c->s_radius)
            ((msgd_t)c->msg)(failed->surface,c->s_radius,c->ch->deco.radius);
        decoration_damage(c,win);return 0;
    }
    if(result&HY_EFFECTS_DIRTY)decoration_damage(c,win);
    int active=!!(result&HY_EFFECTS_ANIMATING);
    struct edge_state *s=&c->edges[i];
    if(s->window && s->surface && s->root && s->context && s->source_hidden) {
        f.role=1;f.host=s->surface;f.root=s->root;
        f.parent_mask=((msg0_t)c->msg)(s->surface,c->s_getmask);
        f.border=s->gradient;f.border_parent_mask=f.border?((msg0_t)c->msg)(f.border,c->s_getmask):0;
        f.legacy_shadow=s->shadow;
        struct rect4 hb=((msgb_t)c->msg)(s->surface,c->s_bounds);f.width=hb.w;f.height=hb.h;
        unsigned long long helper_tx[4]={0};c->tx_ctor(helper_tx,1);c->tx_add(helper_tx,s->context);
        int helper=a->frame(c->effects_runtime,&f);layers_commit(c,helper_tx);
        if((helper&HY_EFFECTS_DIRTY)&&c->edge_api->damage)c->edge_api->damage(0,s->window);
        active|=!!(helper&HY_EFFECTS_ANIMATING);
    } else a->drop(c->effects_runtime,i,1);
    return active;
}
static void put_under(struct ctx *c, struct ch_win *w, int on, double bx, double by, double bw, double bh, double a,
                      double cw, double chh) {
    if (!w->under) return;
    void *uw = c->by_id(w->under);
    if (!uw) { w->under = 0; return; }
    if (!on) w->ub[2] = -1;                              // recompute clip on next show
    // Only the empty band is visible: B minus visible buffer (bx,by,cw,chh); no backdrop under
    // a translucent window, so it does not darken it.
    if (on && cw >= bw - 0.5 && chh >= bh - 0.5) on = 0;
    double na = on ? a : 0.0;
    // Regions only when the band changes (P13: previously 3 CGRegions + server clip each frame)
    if (on && dabs(bx - w->ub[0]) < 0.25 && dabs(by - w->ub[1]) < 0.25 && dabs(bw - w->ub[2]) < 0.25 &&
        dabs(bh - w->ub[3]) < 0.25 && dabs(cw - w->ub[4]) < 0.25 && dabs(chh - w->ub[5]) < 0.25) {
        /* backdrop clip unchanged */
    } else if (on) {
        w->ub[0] = bx; w->ub[1] = by; w->ub[2] = bw; w->ub[3] = bh; w->ub[4] = cw; w->ub[5] = chh;
        rect rb = {bx, by, bw, bh}, ra = {bx, by, cw, chh};
        void *gb = c->rgn(rb), *ga = c->rgn(ra), *d = (gb && ga) ? c->rdiff(gb, ga) : 0;
        if (d) { unsigned uid = w->under; c->clip(*(void **)((char *)uw + 0x30), d, &uid, 1); c->release(d); }
        if (gb) c->release(gb);
        if (ga) c->release(ga);
    }
    if (on) {
        void *shape = *(void **)((char *)uw + c->shape_off);
        if (!shape) return;
        rect u = c->bbox(shape);
        if (!(u.w >= 1) || !(u.h >= 1) || !(bw >= 1) || !(bh >= 1)) return;
        double sx = u.w / bw, sy = u.h / bh, tx = (u.x - bx) * sx, ty = (u.y - by) * sy;
        if (dabs(sx - w->um[0]) > 1e-6 || dabs(sy - w->um[1]) > 1e-6 || dabs(tx - w->um[2]) > 1e-4 || dabs(ty - w->um[3]) > 1e-4) {
            w->um[0] = sx; w->um[1] = sy; w->um[2] = tx; w->um[3] = ty;
            volatile double m[16];
            for (int j = 0; j < 16; j++) m[j] = 0.0;
            m[0] = sx; m[5] = sy; m[10] = 1.0; m[15] = 1.0; m[12] = tx; m[13] = ty;
            unsigned wid = w->under, key = c->key;
            c->set_xform(0, &wid, &key, (double *)m);
        }
    }
    if (na != w->ualpha) {
        c->set_alpha(0, uw, (float)(na < 0 ? 0 : na > 1 ? 1 : na), 0.0f);
        w->ualpha = na;
    }
}

static void put_plain(struct ctx *c, struct ch_win *w, void *win) {
    live_edge_drop(c,w);
    struct edge_lease *lease=live_edge_lease(c,w);
    int preparing=lease && (live_edge_primed(c,w) || live_edge_granted(c,w));
    if(!preparing && !w->held && !w->pos.active && !w->size.active) live_edge_client(c,w,0);
    put_identity(c, w); put_clip(c, w, win, 0, 0, 0, 0, 0);
    put_mask(c, w, win, 0, 0, 0);
    put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0);
}

static struct ch_win *slot(struct ch *ch, u32 wid, int alloc) {
    struct ch_win *free_ = 0;
    for (int i = 0; i < CH_NW; i++) {
        struct ch_win *w = &ch->win[i];
        if (w->used && w->wid == wid) return w;
        if (!w->used && !free_) free_ = w;
    }
    if (!alloc || !free_) return 0;
    volatile char *p = (volatile char *)free_;
    for (unsigned i = 0; i < sizeof *free_; i++) p[i] = 0;
    free_->wid = wid; free_->used = 1;
    free_->m[0] = free_->m[1] = 1.0;           // assume no transform (identity)
    free_->alpha.v[0] = free_->alpha.g[0] = free_->alpha.b[0] = 1.0;
    free_->cur_alpha = 1.0;
    return free_;
}

// Move window to desktop sid. Follow server handler __XMoveWindowsToManagedSpace [V listing
// 18719d3c8]: PKGSpaceForID(sid)->+0x18 (managed space) -> window list -> PKGWindowsMoveToManagedSpace -> free {item, next} nodes.
static void space_move(struct ctx *c, unsigned wid, u64 sid) {
    struct ch *ch = c->ch;
    if (!c->space_for_id || !c->wlist || !c->wmove || !c->xfree) { record_error(ch,OP_SPACE,wid,ERR_SPACE_ABI); return; }
    void *win = c->by_id(wid);
    void *conn = win ? *(void **)((char *)win + 0x30) : 0;
    void *sp = conn ? c->space_for_id(sid) : 0;
    void *managed = sp ? *(void **)((char *)sp + 0x18) : 0;
    if (!managed) { record_error(ch,OP_SPACE,wid,ERR_SPACE_TARGET); return; }
    unsigned ids[1] = {wid};
    void *list = c->wlist(conn, ids, 1);
    c->wmove(conn, list, managed);
    while (list) { void *nx = *(void **)((char *)list + 8); c->xfree(list); list = nx; }
}

static int p8_make(struct ctx *c, char *src, int pending, double now);
static int snapshot_ready(struct ctx *c) {
    return c->clone && c->srr && c->set_level && c->order && c->get_id && c->rel_win;
}
static int snapshot_acquire(struct ctx *c, char *win, struct ch_win *w, double now) {
    if(!snapshot_ready(c) || !win || !w || !*(void **)(win+0x30) || *(int *)(win+0x20)!=0 ||
       !((*(u64 *)(win+0x928)>>44)&1) || SNAP_SEQUENCE(c)==0xffffffffu)return 0;
    int existing=cover_index(c,w->wid,1);
    if(existing>=0 && P8_SOURCE(c)[existing]==(u64)win)return 1;
    u32 was=c->in_cb;c->in_cb=1;
    int index=p8_make(c,win,3,now);
    c->in_cb=was;
    return index>=0;
}

static void apply_cmd(struct ctx *c, struct ch_cmd *k, double now) {
    struct ch *ch = c->ch;
    if(k->op==OP_SNAP && !k->wid && k->flags==1) {
        for(int i=0;i<P8_N;i++)if(P8_TAB(c)[i].live&&P8_TAB(c)[i].pending==3)cover_retire(c,i,SNAP_CANCELLED,now);
        return;
    }
    if(k->op==OP_FORGET || k->op==OP_SPACE)cover_cancel_source(c,k->wid,now);
    if(k->op==OP_SHADOW) {
        if(!effects_ready(c)||!c->effects_api->configure_shadow||!c->effects_api->shadow_supported||
           !c->effects_api->shadow_supported(c->effects_runtime))return;
        HYShadowConfig config;double duration;
        if(hy_shadow_config_command(ch,k,&config,&duration))
            c->effects_api->configure_shadow(c->effects_runtime,&config,&ch->curve[k->cpos],duration,k->flags);
        return;
    }
    if(k->op==OP_EFFECTS) {
        // Missing backend cannot allocate a WID0 slot or reinterpret this as
        // geometry. Only an independently staged/loaded native API is callable.
        const struct hy_effects_api *api=c->effects_api;
        if(!api||api->magic!=HY_EFFECTS_MAGIC||api->size!=sizeof(*api)||api->version!=1||
           !c->effects_runtime||!api->configure)return;
        struct hy_effects_config config;
        if(hy_effects_config_command(ch,k,&config))api->configure(c->effects_runtime,&config);
        return;
    }
    if(k->op==OP_EDGE) {
        // Two-phase handshake: only the daemon may promote an exact prepare
        // after reading its client ACK. No frame command can mint this grant.
        if(!c->edges || !c->edge_api || k->flags>2 || k->x<0 ||
           !(k->x<=9007199254740991.0) || (double)(u64)k->x!=k->x) return;
        // Prime only an existing managed slot. Allocating a geometry-less slot
        // here would let the regular frame loop transform the app before ACK.
        struct ch_win *w=slot(ch,k->wid,0);
        if(!w) return;
        struct edge_lease *lease=live_edge_lease(c,w);
        unsigned index=(unsigned)(w-ch->win);
        u64 pending=c->pending_edge_generation[index];
        if(!k->flags) {
            double current=pending?(double)pending:lease->generation;
            if(k->x && (lease->wid!=w->wid || current!=k->x)) return;
            // Restore server paint while the exact source birth is still
            // available. Clearing it first makes edge_remove skip restoration.
            live_edge_drop(c,w); live_edge_client(c,w,0);
            if(w->geo==3) w->geo=1;
            return;
        }
        if(w->geo==2) return; // The native configure stream owns this slot independently.
        void *win=c->by_id(k->wid);
        if(ch->h.pad_t!=CH_EDGE_PERMISSION || !k->x || !native_allowed(c,w,win)) return;
        if(k->flags==1) {
            if(lease->wid==w->wid && (k->x<=lease->generation || (pending && k->x<=(double)pending))) return;
            int renewing=lease->wid==w->wid && lease->on==3 && ch->h.now<lease->expires &&
                c->edges[w-ch->win].source_window==win;
            if(!renewing) {
                live_edge_drop(c,w); live_edge_client(c,w,0);
                if(w->geo==3) w->geo=1; // Re-prime through the ordinary idle path until the new ACK arrives.
            }
            lease->wid=w->wid;
            if(!renewing) {
                lease->on=1;lease->generation=0;lease->expires=ch->h.now+2.0;
            }
            // Preparing cannot change the active authorization consumed by
            // frame_win/FX/source ownership. Only the exact ACK commit does.
            c->pending_edge_generation[index]=(u64)k->x;
            c->edges[w-ch->win].source_window=win;
            struct { u32 magic,wid,enabled,reserved; double generation; } m=
                {0x50525948u,w->wid,1,1,k->x};
            c->post(c->owner(win),0x7f19,&m,sizeof m);
        } else if(lease->wid==w->wid && lease->on &&
                  (pending ? (double)pending==k->x : lease->on==3 && lease->generation==k->x) &&
                  ch->h.now<lease->expires && c->edges[w-ch->win].source_window==win &&
                  k->y>ch->h.now && k->y<=ch->h.now+2.05) {
            // The main dispatcher is serialized, but a readonly HOST may
            // sample during these multiword stores. Existing on1 carries no
            // active authority; publish on3 only after the complete commit.
            __atomic_store_n(&lease->on,1,__ATOMIC_RELEASE);
            // Release alone orders prior writes; the HOST invalidation marker
            // must also precede all following generation/deadline mutations.
            __atomic_thread_fence(__ATOMIC_RELEASE);
            lease->generation=k->x;lease->expires=k->y;
            c->pending_edge_generation[index]=0;
            __atomic_store_n(&lease->on,3,__ATOMIC_RELEASE);
        }
        return;
    }
    if (k->op == OP_SPACE) {
        struct ch_win *w = slot(ch, k->wid, 0);
        if(w) { live_edge_drop(c,w); live_edge_client(c,w,0); }
        if (w && w->geo == 2) {
            void *win = c->by_id(k->wid);
            native_cancel(c, w, win); // Space owns geometry now; server visibility can lag this command
            if (win) put_plain(c, w, win);
        }
        space_move(c, k->wid, (u64)k->x);
        return;
    }
    if (k->op == OP_CFG) {                           // window owner: same as WS sending 0x542 (@186d441ac)
        void *win = c->by_id(k->wid);
        struct ch_win *nw = slot(ch, k->wid, 0);
        if (nw && nw->geo == 2) {
            native_cancel(c, nw, win);
            if (win) put_plain(c, nw, win);
            if (k->w == 0 && k->h == 0) return; // cancellation above was the one required datagram
        }
        void *own = win && c->owner ? c->owner(win) : 0;
        if(nw && (saved_window(c,nw)->cfg_sent==4 || saved_window(c,nw)->cfg_sent==6) &&
           k->w>=1 && k->h>=1 && dabs(k->x-nw->pos.g[0])<.001 &&
           dabs(k->y-nw->pos.g[1])<.001 && dabs(k->w-nw->size.g[0])<.001 &&
           dabs(k->h-nw->size.g[1])<.001)return; // Same epoch never posts its final configure twice.
        if(nw && saved_window(c,nw)->cfg_sent==3 && k->w>=1 && k->h>=1) {
            struct saved_window *s=saved_window(c,nw);
            double target[4]={nw->pos.g[0],nw->pos.g[1],nw->size.g[0],nw->size.g[1]};
            double requested[4]={k->x,k->y,k->w,k->h};
            int exact=1;for(int i=0;i<4;i++)exact &= dabs(target[i]-requested[i])<.001;
            if(exact){s->cfg_bridge=!!(k->flags&F_STREAM);s->cfg_sent=4;return;}
        }
        // Cancellation is idempotent after disposal: there is no remaining
        // application queue to invalidate. A positive/mixed target still needs
        // its real owner, and an existing owner still requires the sender ABI.
        if(!own && k->w==0 && k->h==0)return;
        if (!own || !c->post) { record_error(ch,k->op,k->wid,ERR_CFG_OWNER); return; }
        int bridge = (k->flags & F_STREAM) || (nw && k->w == 0 && k->h == 0 && saved_window(c, nw)->cfg_bridge);
        struct ch_cfgmsg m;
        m.magic = bridge ? CH_STREAM_MAGIC : CH_CFG_MAGIC; m.wid = k->wid; m.x = k->x; m.y = k->y; m.w = k->w; m.h = k->h; m.t0 = ch->h.now;
        // Queue corner ownership before the single native configure. The addon
        // also rechecks the client root after AppKit applies that configure.
        if(nw && live_edge_enabled(c,nw)) live_edge_client(c,nw,k->w>=1 && k->h>=1);
        c->post(own, bridge ? CH_STREAM_NOTIFY : CH_CFG_NOTIFY, &m, sizeof m);
        if(nw && saved_window(c,nw)->cfg_sent==5) {
            saved_window(c,nw)->cfg_sent=6;
            int index=cover_index(c,nw->wid,1);
            post_evt(ch,EV_SNAPSHOT,nw->wid,now,index>=0?P8_TAB(c)[index].wid:0,SNAP_CONFIGURED,index>=0?3:0,saved_window(c,nw)->cfg_stamp);
        }
        return;
    }
    if (k->op == OP_SNAP) {                          // snapshot backdrop during motion (shrinking only)
        char *win = c->by_id(k->wid);
        struct ch_win *sw = slot(c->ch, k->wid, 0);
        int have = 0;
        for (int i = 0; i < P8_N; i++) have |= P8_TAB(c)[i].live && P8_TAB(c)[i].pending == 2 && P8_TAB(c)[i].src == k->wid;
        if (win && sw && !have && c->ch->h.reserved[0] & 1 && ((*(u64 *)(win + 0x928) >> 44) & 1)) {
            u32 was = c->in_cb; c->in_cb = 1;        // our order must not wake close callback
            p8_make(c, win, 2, now);
            c->in_cb = was;
        }
        return;
    }
    if (k->op == OP_RAISE) {                         // server ordering without permission checks or activation [V 18705d11c]
        void *win = c->by_id(k->wid);
        void *cn = win ? *(void **)((char *)win + 0x30) : 0;
        if (cn && c->order && (!k->flags || c->by_id(k->flags))) {
            c->order(cn, k->wid, 1, k->flags);       // 1 = kCGSOrderAbove
            if (c->sched_win) c->sched_win(0, win);
        }
        return;
    }
    if (k->op == OP_FILL) {
        struct ch_win *fw = slot(c->ch, k->wid, 0);
        if (fw) { fw->fill = k->flags; fw->fkey[4] = -1; }
        return;
    }
    struct ch_win *w = slot(ch, k->wid, k->op != OP_FORGET);
    void *win;
    if (k->op == OP_FORGET) {
        prehide_forget(c, w, c->by_id(k->wid));
        if (!w) return;
        if (actual(c, w, &win)) {
            put_plain(c, w, win);
            if (w->cur_alpha != 1.0) c->set_alpha(0, win, 1.0f, 0.0f);
        }
        slot_free(c, w, win);
        return;
    }
    if (!w) { record_error(ch,k->op,k->wid,ERR_SLOT); return; }
    if (k->op == OP_UNDER) {
        if (w->under && w->under != k->flags) put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0);
        w->under = k->flags; w->ualpha = -1; w->um[0] = w->um[1] = -1; w->ub[2] = -1;
        return;
    }
    if (!actual(c, w, &win)) { post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return; }
    // Geometry/alpha commands claim an optimistic hide; it no longer belongs to the lease.
    if (w->wait == 2 && (k->op == OP_GEOM || k->op == OP_WARP || k->op == OP_ALPHA)) w->wait = 0;
    if (k->op == OP_GEOM || k->op == OP_WARP) {
        int native = k->op == OP_GEOM && (k->flags & F_NATIVE) && !(k->flags & F_STRETCH);
        int terminal = k->op == OP_GEOM && (k->flags & F_MOVE_END) &&
            !(k->flags & (F_NATIVE|F_STRETCH|F_EDGE|F_SNAPSHOT));
        // A new command replaces the pending terminal origin, including a warp/cancel.
        if(w->geo==4)w->geo=1;
        int snapshot_requested=k->op==OP_GEOM && (k->flags & F_SNAPSHOT) && !native && !(k->flags & F_EDGE);
        if(!snapshot_requested)cover_cancel_source(c,w->wid,now);
        // Capture before legacy F_MOVE parks the native origin or OP_CFG reaches AppKit.
        int snapshot_ok=snapshot_requested && snapshot_acquire(c,win,w,now);
        if(snapshot_requested) {
            struct saved_window *s=saved_window(c,w);
            if(SNAP_SEQUENCE(c)!=0xffffffffu)SNAP_SEQUENCE(c)++;
            s->cfg_stamp=SNAP_SEQUENCE(c);s->cfg_sent=snapshot_ok?5:3;
            if(!snapshot_ok) {
                u64 object=(u64)win,owner=c->owner?(u64)c->owner(win):0;
                __builtin_memcpy(&s->cfg_rect[0],&object,8);__builtin_memcpy(&s->cfg_rect[1],&owner,8);
            }
            int index=cover_index(c,w->wid,1);
            if(index>=0)P8_EPOCH(c)[index]=SNAP_SEQUENCE(c);
            post_evt(ch,EV_SNAPSHOT,w->wid,now,index>=0?P8_TAB(c)[index].wid:0,snapshot_ok?SNAP_ACQUIRED:SNAP_DEFERRED,index>=0?3:0,s->cfg_stamp);
        } else if(!native && saved_window(c,w)->cfg_sent>=3) saved_window(c,w)->cfg_sent=0;
        if (native && !native_allowed(c, w, win)) { native_cancel(c, w, win); return; }
        if (native && w->geo == 2 && saved_window(c, w)->cfg_bridge != !!(k->flags & F_STREAM))
            native_cancel(c, w, win); // revoke the previous receiver before a transport handover
        if (!native && w->geo == 2) { native_cancel(c, w, win); put_plain(c, w, win); }
        int changed = w->geo != 2 || w->pos.g[0] != k->x || w->pos.g[1] != k->y ||
                      w->size.g[0] != k->w || w->size.g[1] != k->h;
        if (native) {
            if (changed) saved_window(c, w)->cfg_sent = 0;
            saved_window(c, w)->cfg_bridge = !!(k->flags & F_STREAM);
            w->stretch = 0;
            if (w->wait == 1) w->wait = 0;
            put_plain(c, w, win); // discard only our previous visual transform/crop, never another app's state
        }
        // An idle window without transform syncs to its actual frame (it may have moved);
        // if holding its visible frame (settling), variables define the visible position.
        double a_pos[2] = {w->ax, w->ay}, a_size[2] = {w->aw, w->ah};
        int moving = (w->pos.active | w->size.active) && !w->held;
        if (!w->settling && (!native || w->geo != 2)) {
            if (!w->pos.active) warp(&w->pos, 2, a_pos);
            if (!w->size.active) warp(&w->size, 2, a_size);
        }
        double gp[2] = {k->x, k->y}, gs[2] = {k->w, k->h};
        if (!w->held) {
            // Account for skipped VBLs before changing goals. Held variables have never advanced.
            if (w->pos.active && now > w->pos.last) step(c, &w->pos, 2, now);
            if (w->size.active && now > w->size.last) step(c, &w->size, 2, now);
        }
        if (k->op == OP_WARP) { warp(&w->pos, 2, gp); warp(&w->size, 2, gs); }
        else {
            if ((k->flags & F_FROM) && (!native || w->geo != 2)) {
                double fp[2] = {k->fx, k->fy}, fs[2] = {k->fw, k->fh};
                warp(&w->pos, 2, fp); warp(&w->size, 2, fs);
            }
            retarget(c, &w->pos, 2, gp, k->cpos, k->dpos, now);
            retarget(c, &w->size, 2, gs, k->csize, k->dsize, now);
        }
        if ((k->flags & F_MOVE) && !native && !terminal) { // legacy mode parks actual origin at goal
            double dx = k->x - w->ax, dy = k->y - w->ay;
            if (dabs(dx) >= 1.0 || dabs(dy) >= 1.0) {
                unsigned wid = w->wid;
                c->move(0, &wid, 1, 0, (float)dx, (float)dy);
                actual(c, w, &win);
            }
        }
        w->radius = c->corner ? c->corner(win) : 0;
        w->a0[0] = w->aw; w->a0[1] = w->ah;           // application frame at start: before configure
        // Live 1:1 content already covers a shrinking target: no new
        // application buffer is needed before that motion can start.
        int missing_buffer = (k->flags & F_STRETCH) ?
            (dabs(w->aw-k->w)>2 || dabs(w->ah-k->h)>2) :
            (w->aw+2<k->w || w->ah+2<k->h);
        if (!native && k->op == OP_GEOM && !moving && ch->h.hold_max >= 0 && missing_buffer) {
            // Like Wayland: motion from rest starts after the application supplies a frame at the new size,
            // so new content is visible from animation frame one, without stretching old content. Do not hold
            // an already moving window: retarget without stopping (S6: otherwise key autorepeat causes steps).
            w->held = 1;
            w->needs = missing_buffer;
            ch->h.holding = 1;
            ch->h.hold_t = now;
        }
        if (k->flags & F_MOVE) {
            w->geo = native ? 2 : 1; w->moved = 0;
            u64 cn = *(int *)((char *)win + 0x20) == 0 ?
                (u64)*(void **)((char *)win + 0x30) : 0; // only normal windows admit prehide
            int have = 0;
            for (int i = 0; i < CH_NCONN; i++) have |= ch->conn[i] == cn;
            if (!have && cn) ch->conn[ch->conn_next++ % CH_NCONN] = cn;
        }
        if (native) { w->geo = 2; w->needs = 0; if (!(k->flags & F_HOLD)) w->held = 0; }
        if(!native && !(k->flags & F_STRETCH))
            w->geo=(k->flags & F_EDGE) && live_edge_granted(c,w) ? 3 : 1;
        if(terminal){w->geo=4;w->moved=0;}
        // warp or unchanged target (animation did not start): reconcile frame immediately, buffer in box
        // (clip/edge), avoiding false EV_MOVED for a window at minimum size.
        w->settling = k->op == OP_WARP || !(w->pos.active | w->size.active);
        // Retargeting during popin (another window split the tile) must not switch stretched -> 1:1
        // mid-motion, which would cause a scale jump [daily_bugs F3].
        if (k->flags & F_STRETCH) w->stretch = 1;
        else if (!(w->stretch && w->size.active)) w->stretch = 0;
        if (!native && k->op == OP_GEOM && (k->flags & F_WAIT)) { w->wait = 1; w->wait_t = now; }
        // Neighbor of an opening window waits at start until new window supplies a tile-sized frame (<=150 ms),
        // then starts in the same frame as its popin: one wave (like Hyprland: configure before showing).
        if (k->op == OP_GEOM && (k->flags & F_HOLD) && !moving) {
            // A new opening batch must not stop an already visible moving neighbor.
            // Its current spring retargets continuously; only resting neighbors join the hold.
            w->held = 1; w->needs = native ? 0 : dabs(w->aw - k->w) > 2 || dabs(w->ah - k->h) > 2; ch->h.holding = 1;
            ch->h.hold_t = now;
        }
        if(snapshot_requested && !snapshot_ok){w->held=w->needs=0;}
        w->done_t = now;
    } else if (k->op == OP_ALPHA) {
        double ga[1] = {k->a};
        if (k->calpha == CH_INSTANT) { warp(&w->alpha, 1, ga); return; }
        if (k->flags & F_FROM) { double fa[1] = {k->fa}; warp(&w->alpha, 1, fa); }
        if (!w->held && !w->wait && w->alpha.active && now > w->alpha.last) step(c, &w->alpha, 1, now);
        retarget(c, &w->alpha, 1, ga, k->calpha, k->dalpha, now);
    }
}

// One window frame. 1 = window still needs ticks.
static int frame_win(struct ctx *c, struct ch_win *w, double now) {
    struct ch *ch = c->ch;
    struct edge_lease *lease=live_edge_lease(c,w);
    if(lease && lease->on && lease->wid==w->wid) {
        int preparing=live_edge_primed(c,w);
        if(!preparing && !live_edge_enabled(c,w)) { live_edge_drop(c,w); live_edge_client(c,w,0); }
        else if(ch->h.pad_t!=CH_EDGE_PERMISSION && ch->h.now-lease->generation>1) live_edge_client(c,w,1);
    }
    if(w->geo==3 && !live_edge_enabled(c,w)) w->geo=1;
    if (w->wait == 2) {
        // An application connection is not a window role. Fail open if the daemon never
        // claims this window (dialog, sheet, inspector, menu utility, or missed event).
        void *win = c->by_id(w->wid);
        if (!win) { slot_free(c, w, 0); return 0; }
        if (now - w->wait_t < 0.15) return 1;
        if (w->cur_alpha == 0.0 && w->alpha.g[0] == 0.0) c->set_alpha(0, win, 1.0f, 0.0f);
        slot_free(c, w, win);
        return 0;
    }
    if (w->wait == 1 && !w->held) {
        // Opening like Hyprland: show window after application draws a tile-sized frame
        // (there the client knows size before first frame). Until then invisible, frame and alpha at start.
        void *win;
        if (!actual(c, w, &win)) { post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return 0; }
        int ok = dabs(w->aw - w->size.g[0]) <= ch->h.settle_px && dabs(w->ah - w->size.g[1]) <= ch->h.settle_px;
        if (!ok && now - w->wait_t < (ch->h.hold_max > 0.15 ? ch->h.hold_max : 0.15)) {
            if (w->cur_alpha != 0.0) { c->set_alpha(0, win, 0.0f, 0.0f); w->cur_alpha = 0.0; }
            return 1;
        }
        w->wait = 0;
        double t0 = now - (ch->h.period > 0.002 ? ch->h.period : 1.0 / 60);
        w->pos.t0 = w->size.t0 = w->alpha.t0 = t0;
        w->pos.last = w->size.last = w->alpha.last = t0;
    }
    int was = w->pos.active | w->size.active | w->alpha.active;
    int an;
    if (w->held) {                                  // batch awaiting application frames: frame stays at start,
        an = 1;                                     // geometry and fade begin in the same frame
    } else {
        an = step(c, &w->pos, 2, now);
        an |= step(c, &w->size, 2, now);
        an |= step(c, &w->alpha, 1, now);
    }
    void *win;
    if (!actual(c, w, &win)) { put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0); post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return 0; }

    double a = w->alpha.v[0];
    if (!finite(a)) a = 1.0;
    int virtual_source=cover_index(c,w->wid,1);
    if(virtual_source>=0 && P8_SOURCE(c)[virtual_source]==(u64)win && c->by_id(P8_TAB(c)[virtual_source].wid))
        c->set_alpha(0,win,0,0); // App-owned changes cannot reveal the redraw through the cover.
    if (a != w->cur_alpha) {
        if(cover_index(c,w->wid,1)<0)c->set_alpha(0, win, (float)(a < 0 ? 0 : a > 1 ? 1 : a), 0.0f);
        w->cur_alpha = a;
    }

    if (w->geo == 2) {
        if (!native_allowed(c, w, win) || w->alpha.g[0] <= 0) {
            native_cancel(c, w, win);
            put_plain(c, w, win);
            return w->alpha.active;
        }
        struct saved_window *s = saved_window(c, w);
        int moving = w->pos.active | w->size.active;
        if (!w->held && s->cfg_sent != 2) {
            double r[4] = {w->pos.v[0], w->pos.v[1], w->size.v[0], w->size.v[1]};
            int valid = finite(r[0]) && finite(r[1]) && finite(r[2]) && finite(r[3]) && r[2] >= 1 && r[3] >= 1;
            int changed = !s->cfg_sent;
            for (int i = 0; i < 4; i++) changed |= dabs(r[i] - s->cfg_rect[i]) > 0.001;
            if (valid && (changed || !moving) && native_post_frame(c, w, win, r)) {
                for (int i = 0; i < 4; i++) s->cfg_rect[i] = r[i];
                s->cfg_stamp = ch->h.now;
                s->cfg_sent = moving ? 1 : 2; // exactly one final even if app ignores it or clamps its minimum
            }
        }
        put_plain(c, w, win); // actual A is presentation; no independent B translation, stretch, fill or crop
        if (was && !an) {
            w->done_t = now;
            post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah);
        }
        int fits = dabs(w->ax - w->pos.g[0]) <= 1 && dabs(w->ay - w->pos.g[1]) <= 1 &&
                   dabs(w->aw - w->size.g[0]) <= ch->h.settle_px && dabs(w->ah - w->size.g[1]) <= ch->h.settle_px;
        double limit = ch->h.settle > 0 ? ch->h.settle : 0.25;
        if (limit > 1) limit = 1;
        int pending = s->cfg_sent == 2 && !fits && ch->h.now - s->cfg_stamp < limit;
        if (w->settling && fits && !moving && !w->held)
            post_evt(ch, EV_SETTLED, w->wid, now, w->ax, w->ay, w->aw, w->ah);
        w->settling = moving || w->held || pending;
        return an || pending;
    }

    // Buffer stability: A unchanged for N consecutive ticks means application finished redrawing.
    if (dabs(w->ax - w->pa[0]) < 0.5 && dabs(w->ay - w->pa[1]) < 0.5 && dabs(w->aw - w->pa[2]) < 0.5 && dabs(w->ah - w->pa[3]) < 0.5)
        w->stable++;
    else { w->stable = 0; w->pa[0] = w->ax; w->pa[1] = w->ay; w->pa[2] = w->aw; w->pa[3] = w->ah; }

    if(saved_window(c,w)->cfg_sent==4 && !(w->pos.active|w->size.active) && !w->held) {
        struct saved_window *s=saved_window(c,w);void *owner=c->owner?c->owner(win):0;
        u64 object,original_owner;__builtin_memcpy(&object,&s->cfg_rect[0],8);__builtin_memcpy(&original_owner,&s->cfg_rect[1],8);
        if((u64)win!=object || (u64)owner!=original_owner) {
            post_evt(ch,EV_SNAPSHOT,w->wid,now,0,SNAP_CANCELLED,0,s->cfg_stamp);s->cfg_sent=0;
        }
        else if(owner && c->post) {
            struct ch_cfgmsg message={.magic=s->cfg_bridge?CH_STREAM_MAGIC:CH_CFG_MAGIC,.wid=w->wid,
                .x=w->pos.g[0],.y=w->pos.g[1],.w=w->size.g[0],.h=w->size.g[1],.t0=now};
            c->post(owner,s->cfg_bridge?CH_STREAM_NOTIFY:CH_CFG_NOTIFY,&message,sizeof message);
            post_evt(ch,EV_SNAPSHOT,w->wid,now,0,SNAP_CONFIGURED,0,s->cfg_stamp);s->cfg_sent=0;
        }
    }
    if(cover_index(c,w->wid,1)>=0) {
        if(was && !an){w->done_t=now;post_evt(ch,EV_DONE,w->wid,now,w->ax,w->ay,w->aw,w->ah);}
        w->settling=1;
        return 1;
    }
    double bx = w->pos.v[0], by = w->pos.v[1], bw = w->size.v[0], bh = w->size.v[1];
    if(w->geo==4 && !w->held && !(w->pos.active|w->size.active) &&
       finite(bx) && finite(by) && bw>=1 && bh>=1) {
        // The AppKit size was configured once before motion. Transfer only origin,
        // then sample A before rendering this very WS frame: an old translation
        // must never survive beside the newly moved native window for one frame.
        double dx=bx-w->ax,dy=by-w->ay;
        w->geo=1;w->settling=1; // exactly one attempt; retarget/forget cannot replay it
        if(c->move && (dabs(dx)>=0.01 || dabs(dy)>=0.01)) {
            unsigned wid=w->wid;
            c->move(0,&wid,1,0,(float)dx,(float)dy);
            if(!actual(c,w,&win)) {
                post_evt(ch,EV_GONE,w->wid,now,0,0,0,0);slot_free(c,w,0);return 0;
            }
        }
        // If native movement is rejected/clamped, the normal live transform below
        // continues to own B; identity is installed only when sampled A matches.
    }
    if (!an) {
        // Popin ended but buffer is not tile-sized: keep stretching while application draws (buffer changes),
        // but for no more than ~150 ms with stable buffer; otherwise stretched -> 1:1 in one frame [F3].
        if (w->stretch && (dabs(w->aw - bw) > 1 || dabs(w->ah - bh) > 1) &&
            w->stable * ch->h.period < 0.15) {
            if (was) { w->done_t = now; post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah); }
            w->settling = 1;                          // then normal buffer-in-box reconciliation, without false EV_MOVED
            an = 1;
            goto show;
        }
        w->stretch = 0;
        if (was) { w->done_t = now; w->settling = 1; post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah); }
        if (!w->settling) {
            // idle: window left target (application/system moved it); notify daemon once (S4)
            if (w->geo && !w->moved && (dabs(w->ax - w->pos.g[0]) > 1.5 || dabs(w->ay - w->pos.g[1]) > 1.5 ||
                                        dabs(w->aw - w->size.g[0]) > ch->h.settle_px || dabs(w->ah - w->size.g[1]) > ch->h.settle_px)) {
                w->moved = 1;
                post_evt(ch, EV_MOVED, w->wid, now, w->ax, w->ay, w->aw, w->ah);
            }
            return 0;
        }
        // End without waiting (like Hyprland: actual buffer in tile box after animation):
        // frame arrived and matches buffer; display window as is, removing clip and backdrop.
        int fits = dabs(w->aw - bw) <= 1.0 && dabs(w->ah - bh) <= 1.0 && dabs(w->ax - bx) <= 1.0 && dabs(w->ay - by) <= 1.0;
        if (fits) {
            put_plain(c, w, win);
            w->settling = 0;
            post_evt(ch, EV_SETTLED, w->wid, now, w->ax, w->ay, w->aw, w->ah);
            return 0;
        }
        // Mismatch: application did not exactly fit tile (minimum size, character grid); like Hyprland,
        // buffer stays in tile box: larger is clipped to B; smaller has band filled with window edge color.
        // Neighbors do not move. Keep clip until buffer matches B (checked by idle tick).
        an = w->stable < 2;
    }
show:
    if (!(bw >= 1) || !(bh >= 1) || !finite(bx) || !finite(by)) { put_plain(c, w, win); return an; }
    // Oversized axes stay1:1 and crop. An already accepted undersized live
    // buffer projects to current B only during size motion; no per-frame resize
    // request or persistent opening/stretch ownership is introduced.
    int st = w->stretch;
    double sx = st ? w->aw / bw : 1.0, sy = st ? w->ah / bh : 1.0;
    unsigned projected=0;
    if(!st)projected=live_resize_projection(c,w,bw,bh,&sx,&sy);
    if (sx < 0.02 || sx > 50 || sy < 0.02 || sy > 50) { put_plain(c, w, win); return an; }
    if (dabs(bw - w->aw) < 0.01 && dabs(bh - w->ah) < 0.01 && dabs(bx - w->ax) < 0.01 && dabs(by - w->ay) < 0.01) {
        put_plain(c, w, win);
    } else {
        double source_w=bw*sx,source_h=bh*sy;
        double cw = source_w < w->aw ? source_w : w->aw, ch_ = source_h < w->ah ? source_h : w->ah;
        put_xform(c, w, sx, sy, (w->ax - bx) * sx, (w->ay - by) * sy);
        int crop = !st && (dabs(cw - w->aw) > 0.5 || dabs(ch_ - w->ah) > 0.5);
        if (use_mask(c, w)) { put_clip(c, w, win, 0, 0, 0, 0, 0); put_mask(c, w, win, crop, cw, ch_); }
        else { put_mask(c, w, win, 0, 0, 0); put_clip(c, w, win, crop, bx, by, cw/sx, ch_/sy); }
        put_under(c, w, !st, bx, by, bw, bh, w->cur_alpha, cw/sx, ch_/sy);
        if(!st && !projected && live_edge_enabled(c,w)) {
            struct edge_state *edge=&c->edges[w-ch->win];
            struct edge_lease original=*live_edge_lease(c,w);
            u32 original_permission=ch->h.pad_t;
            void *anchor=edge->source_window;
            void *owner=anchor && c->owner ? c->owner(anchor) : 0;
            int result=edge_update(c->edge_api,edge,w->wid,w->aw,w->ah,
                                  (struct edge_rect){bx,by,bw,bh},w->cur_alpha,c->key,1,ch->deco.radius);
            if(result==EDGE_NO_PATCH && original_permission!=ch->h.pad_t) result=EDGE_INVALID;
            if(result==EDGE_NO_PATCH && original_permission==CH_EDGE_PERMISSION) {
                struct edge_lease *current=live_edge_lease(c,w);
                int same=current->wid==original.wid && current->on==original.on &&
                    current->generation==original.generation && current->expires==original.expires;
                if(same && original.wid==w->wid && original.on==3 &&
                   ch->h.now<original.expires && anchor && c->by_id(w->wid)==anchor &&
                   (!c->owner || c->owner(anchor)==owner) && native_allowed(c,w,anchor))
                    edge->source_window=anchor;
                else result=EDGE_INVALID;
            }
            if(result<=EDGE_INVALID) {
                // A failed helper revokes this window, not unrelated grants.
                if(ch->h.pad_t!=CH_EDGE_PERMISSION) ch->h.pad_t=0;
                live_edge_client(c,w,0);
                if(w->geo==3) w->geo=1;
            }
        } else live_edge_drop(c,w);
    }
    return an;          // idle (including stable buffer not exactly fitting tile): no per-frame ticks
}

// Frame grid: obtain period T and vblank time from WS vblank cache (possibly stale, but phase remains correct);
// te is the nearest vblank at or after now+margin. All frame values
// are computed for te (presentation time), rather than timer firing time: a timer delay
// of a few milliseconds does not shift sampling; time step is exactly T.
static double frame_grid(struct ctx *c, double now, double *T_out) {
    // WindowServer's getter chooses the dominant display, including the main display
    // when there is just one. Display ids are not guaranteed to start at 1.
    if (c->display_id) {
        void *win = c->ch->deco.focus ? c->by_id(c->ch->deco.focus) : 0;
        if (!win) for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &c->ch->win[i];
            if (w->used && w->geo) { win = c->by_id(w->wid); if (win) break; }
        }
        u32 id = c->display_id(win);
        if (id) c->display = id;
    }
    double p = 0, n = 0;
    if (c->vbl) c->vbl(c->display, &p, &n);
    double T = n - p;
    if (!(T > 0.002 && T < 0.05) || !__builtin_isfinite(p) || !__builtin_isfinite(n)) {
        // Missing samples leave the outputs untouched. Keep the last known phase and
        // period; rebasing to now on every tick turns timer jitter into visual jitter.
        T = c->ch->h.period;
        if (!(T > 0.002 && T < 0.05)) T = 1.0 / 60; // only before the first valid display sample
        n = c->ch->h.te > 0 ? c->ch->h.te : now;
    }
    double lim = now + c->ch->h.margin;
    double quotient = (lim - n) / T;
    // The VBL cache can be old. A geometry-sized bound on timestamps or the frame
    // quotient breaks after long uptime and may produce a huge incremental loop.
    if (!__builtin_isfinite(quotient) || quotient <= -1e15 || quotient >= 1e15) { n = lim; quotient = 0; }
    double k = (double)(long)quotient;
    double te = n;
    te += k * T;
    while (te <= lim) te += T;
    while (te - T > lim) te -= T;
    *T_out = T;
    return te;
}

// P8: close snapshot (close_clone.md)
// Daemon settings: reserved[0] bit0 = callback, bit1 = clone (otherwise log only), bits 8-15 = size curve,
// 16-23 = alpha curve; reserved[1]/[2] = durations (double), reserved[3] = popin k (double).
#define P8_ON(c) ((unsigned char *)(c) + 0xc00)      // previous on-screen bit of tracked windows, by slot
static double hd(struct ch *ch, int i) { double v; __builtin_memcpy(&v, &ch->h.reserved[i], 8); return v; }

static void p8_free_win(struct ctx *c, char *cl) {
    *(u64 *)(cl + 0x928) &= ~(1ull << 54);           // otherwise release_window only clears owner [V]
    c->rel_win(*(void **)(cl + 0x30), cl);           // owner NULL; our callback rejects it by owner
}

// Clone src at visible frame, source level, above; engine slot (stretch) without animation. Returns index or -1.
static int p8_make(struct ctx *c, char *src, int pending, double now) {   // pending: 0 closing, 1 awaiting 0x3e9, 2 backdrop
    struct ch *ch = c->ch;
    if (!c->clone || !c->srr || !c->set_level || !c->order || !c->get_id) return -1;
    int k = -1;
    for (int i = 0; i < P8_N; i++) if (!P8_TAB(c)[i].live) { k = i; break; }
    void *shape = *(void **)(src + c->shape_off);
    if (k < 0 || !shape) return -1;
    rect a = c->bbox(shape);
    rect r0 = {0, 0, a.w, a.h};
    rect fr = c->srr(src, r0);
    void *disp = c->win_disp ? c->win_disp(src) : 0;
    if (!disp && c->main_disp) disp = c->main_disp();
    if (!disp || !finite(fr.w) || !(fr.w >= 1) || !(fr.h >= 1)) return -1;
    // Reentrancy guard covers BOTH clone and order: order itself sends 0x3ea to our callback. Previously clearing
    // the flag before order caused recursive cloning and WS stack overflow [V crash 12:33:20].
    u32 was = c->in_cb;
    c->in_cb = 1;
    struct ch_win *source=slot(ch,*(unsigned *)src,0);
    double logical_alpha=source?source->cur_alpha:1;
    // CaptureSurface bakes native alpha into its pixels. Normalize only within
    // this serialized acquisition, then cover/reveal use the logical alpha once.
    if(pending==3)c->set_alpha(0,src,1,0);
    char *cl = c->clone(src, fr, disp, 1);
    if (!cl) { if(pending==3)c->set_alpha(0,src,(float)logical_alpha,0);c->in_cb = was; return -1; }
    c->set_level(cl, 0, *(int *)(src + 0x20), *(short *)(src + 0x28));
    unsigned cwid = c->get_id(cl);
    if(pending==3)c->set_alpha(0,cl,(float)logical_alpha,0);
    if (pending == 2) c->order(0, cwid, -1, *(unsigned *)src);   // backdrop below window
    else if (pending == 1) c->order(0, cwid, 0, 0); // orderOut can be native tab selection; retain pixels invisibly
    else c->order(0, cwid, 1, *(unsigned *)src); // confirmed close — visible above source
    c->in_cb = was;
    struct ch_win *w = slot(ch, cwid, 1);
    if (!w) { p8_free_win(c, cl);if(pending==3)c->set_alpha(0,src,(float)logical_alpha,0); return -1; }
    double cur[2] = {fr.x, fr.y}, sz[2] = {fr.w, fr.h};
    warp(&w->pos, 2, cur); warp(&w->size, 2, sz);
    w->ax = fr.x; w->ay = fr.y; w->aw = fr.w; w->ah = fr.h;
    w->stretch = 1;
    struct p8c *e = &P8_TAB(c)[k];
    e->wid = cwid; e->src = *(unsigned *)src; e->t0 = now; e->live = 1; e->pending = pending;
    P8_SOURCE(c)[k]=(u64)src;
    if(pending==3) {
        w->stretch=0;w->geo=1;
        c->set_alpha(0,src,0,0); // Actual presentation hides; logical source alpha remains unchanged.
    }
    return k;
}

static void cover_retire(struct ctx *c,int index,int result,double now) {
    struct p8c *e=&P8_TAB(c)[index];
    if(!e->live || e->pending!=3)return;
    void *source=c->by_id(e->src);struct ch_win *sw=slot(c->ch,e->src,0);
    unsigned clone_id=e->wid,source_id=e->src,epoch=P8_EPOCH(c)[index];
    e->live=0; // The normal source presentation path may now perform the exact handoff.
    if(source && sw && (u64)source==P8_SOURCE(c)[index]) {
        if(result==SNAP_REVEALED) {
            sw->settling=1;frame_win(c,sw,now);
        } else {
            void *present;
            if(actual(c,sw,&present)) {
                double p[2]={sw->ax,sw->ay},s[2]={sw->aw,sw->ah};
                warp(&sw->pos,2,p);warp(&sw->size,2,s);sw->held=sw->settling=0;
                put_plain(c,sw,present);
            }
        }
        c->set_alpha(0,source,(float)sw->cur_alpha,0);
        if(saved_window(c,sw)->cfg_sent>=3)saved_window(c,sw)->cfg_sent=0;
    }
    void *clone=c->by_id(clone_id);struct ch_win *cw=slot(c->ch,clone_id,0);
    if(clone)c->set_alpha(0,clone,0,0);
    post_evt(c->ch,EV_SNAPSHOT,source_id,now,clone_id,result,3,epoch);
    P8_SOURCE(c)[index]=0;P8_EPOCH(c)[index]=0;
    if(cw){if(clone)put_plain(c,cw,clone);slot_free(c,cw,clone);}
    if(clone && !*(void **)((char *)clone+0x30))p8_free_win(c,clone);
}

// Start clone exit: popin k% + fadeOut using configured curves; neighbors receive EV_GONE in same daemon cycle.
static void p8_go(struct ctx *c, int k, double now) {
    struct ch *ch = c->ch;
    struct p8c *e = &P8_TAB(c)[k];
    struct ch_win *w = slot(ch, e->wid, 0);
    if(e->pending==1) {
        char *clone=c->by_id(e->wid);
        if(clone && !*(void **)(clone+0x30)) {
            u32 was=c->in_cb;c->in_cb=1;
            c->order(0,e->wid,1,0);c->in_cb=was;
        }
    }
    e->pending = 0; e->t0 = now;
    if (w) {
        double kk = hd(ch, 3);
        if (!__builtin_isfinite(kk)) kk = 0.92;
        if (kk < 0) kk = 0; else if (kk > 1) kk = 1;
        double fx = w->pos.v[0], fy = w->pos.v[1], fw = w->size.v[0], fh = w->size.v[1];
        double tw = fw * kk, th = fh * kk;
        if (tw < 5) tw = fw < 5 ? fw : 5;
        if (th < 5) th = fh < 5 ? fh : 5;
        double tp[2] = {fx + (fw - tw) / 2, fy + (fh - th) / 2}, ts[2] = {tw, th};
        u32 cs = (ch->h.reserved[0] >> 8) & 0xff, ca = (ch->h.reserved[0] >> 16) & 0xff;
        retarget(c, &w->pos, 2, tp, cs, hd(ch, 1), now);
        retarget(c, &w->size, 2, ts, cs, hd(ch, 1), now);
        double z[1] = {0.0};
        retarget(c, &w->alpha, 1, z, ca, hd(ch, 2), now);
    }
    c->nclone++;
    post_evt(ch, EV_CLONE, e->wid, now, e->src, 0, 0, 0);
    post_evt(ch, EV_GONE, e->src, now, 0, 0, 0, 0);
    if (!c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, now);
}

// 0x3ea (ordering finished): if a tracked tiled window left screen (bit 44: 1->0), snapshot its content
// now before the frame (AppKit first removes a closing window, then releases ~70 ms later [V 12:30]).
static void p8_order_done(struct ctx *c) {
    struct ch *ch = c->ch;
    // tabs: another window of same application appeared (0->1) in this operation; tab switch, not close
    u64 came[8]; int nc = 0;
    for (int i = 0; i < CH_NW && nc < 8; i++) {
        struct ch_win *w = &ch->win[i];
        if (!w->used || P8_ON(c)[i]) continue;
        char *win = c->by_id(w->wid);
        if (win && ((*(u64 *)(win + 0x928) >> 44) & 1)) came[nc++] = (u64)*(void **)(win + 0x30);
    }
    for (int i = 0; i < CH_NW; i++) {
        struct ch_win *w = &ch->win[i];
        if (!w->used || !w->geo) { P8_ON(c)[i] = 0; continue; }
        char *win = c->by_id(w->wid);
        int on = win && ((*(u64 *)(win + 0x928) >> 44) & 1);
        int tab = 0;
        if (win) for (int j = 0; j < nc; j++) tab |= came[j] == (u64)*(void **)(win + 0x30);
        int was = P8_ON(c)[i];
        P8_ON(c)[i] = (unsigned char)on;              // before cloning: nested call cannot see same 1->0 transition
        if(was && !on) { live_edge_drop(c,w); live_edge_client(c,w,0); }
        if (was && !on && !tab && win && *(void **)(win + 0x30) && *(int *)(win + 0x20) == 0 &&
            w->cur_alpha > 0.05 && w->alpha.g[0] > 0.05 && (ch->h.reserved[0] & 2))
            p8_make(c, win, 1, ch->h.now);
    }
    for (int i = 0; i < CH_NW; i++) {                 // remember on-screen state of all slots after operation
        struct ch_win *w = &ch->win[i];
        char *win = w->used ? c->by_id(w->wid) : 0;
        P8_ON(c)[i] = (unsigned char)(win && ((*(u64 *)(win + 0x928) >> 44) & 1));
    }
}

// 0x3e9 (release_window) / 0x3ea (finish_order_windows) callback: synchronous on WS main thread; IA/0 signature (blraaz).
void anim_will_release(u32 type, void *data, unsigned long len, struct ctx *c) {
    if (c->dead || c->in_cb) return;
    struct ch *ch = c->ch;
    if (ch->h.magic != CH_MAGIC || ch->h.stop || !(ch->h.reserved[0] & 1)) return;
    if (type == 0x3ea) { c->in_cb = 1; p8_order_done(c); c->in_cb = 0; return; }
    if (type != 0x3e9 || !data || len != 8) return;
    char *src = data;
    if (!*(void **)(src + 0x30)) return;                       // server window / our clone
    unsigned swid = *(unsigned *)src;
    int on = (int)((*(u64 *)(src + 0x928) >> 44) & 1), lvl = *(int *)(src + 0x20);
    struct ch_win *sw = slot(ch, swid, 0);
    if(sw) { live_edge_drop(c,sw); live_edge_client(c,sw,0); }
    post_evt(ch, EV_REL, swid, ch->h.now, on, 1, lvl, (sw ? 1 : 0) + (sw && sw->geo ? 2 : 0));
    if (!(ch->h.reserved[0] & 2) || lvl != 0) return;
    for (int i = 0; i < P8_N; i++) {                           // captured on order-out: this is a close, start exit
        struct p8c *e = &P8_TAB(c)[i];
        if (e->live && e->pending && e->src == swid) { p8_go(c, i, ch->h.now); return; }
    }
    if (!on || !sw || !sw->geo) { if (!on) c->nskip++; return; }
    if (sw->alpha.g[0] < 0.05 || sw->cur_alpha < 0.05) return; // daemon close_anim already faded it out
    int k = p8_make(c, src, 0, ch->h.now);                     // still on screen (path A)
    if (k >= 0) p8_go(c, k, ch->h.now);
}

// Tick: register callback and free clones whose animation ended (or all clones on stop).
static void p8_tick(struct ctx *c, int stopping, double now) {
    struct ch *ch = c->ch;
    int want = !stopping && (ch->h.reserved[0] & 1) && c->add_cb && c->rm_cb && c->cb;
    if (want && !c->cb_on) {
        c->rm_cb(c->cb, 0x3e9, c); c->add_cb(c->cb, 0x3e9, c);
        c->rm_cb(c->cb, 0x3ea, c); c->add_cb(c->cb, 0x3ea, c);
        c->cb_on = 1;
    }
    if (!want && c->cb_on) { c->rm_cb(c->cb, 0x3e9, c); c->rm_cb(c->cb, 0x3ea, c); c->cb_on = 0; }
    for (int i = 0; i < P8_N; i++) {
        struct p8c *e = &P8_TAB(c)[i];
        if (!e->live) continue;
        struct ch_win *w = slot(ch, e->wid, 0);
        int done;
        if(e->pending==3) {
            struct ch_win *sw=slot(ch,e->src,0);void *source=c->by_id(e->src);
            int invalid=stopping || !sw || !source || !c->by_id(e->wid) || (u64)source!=P8_SOURCE(c)[i] ||
                !((*(u64 *)((char *)source+0x928)>>44)&1) ||
                (sw->alpha.g[0]<=0 && !sw->alpha.active && sw->cur_alpha<=.01) || now-e->t0>30;
            if(invalid){cover_retire(c,i,SNAP_CANCELLED,now);continue;}
            int ready=!(sw->pos.active|sw->size.active|sw->alpha.active) && !sw->held && sw->stable>=2 &&
                dabs(sw->ax-sw->pos.g[0])<=1 && dabs(sw->ay-sw->pos.g[1])<=1 &&
                dabs(sw->aw-sw->size.g[0])<=ch->h.settle_px && dabs(sw->ah-sw->size.g[1])<=ch->h.settle_px &&
                saved_window(c,sw)->cfg_sent==6;
            if(ready)cover_retire(c,i,SNAP_REVEALED,now);
            continue;
        } else if (e->pending == 2) {                       // backdrop: while window moves (and until it fits the box)
            struct ch_win *sw = slot(ch, e->src, 0);
            double cap=30.0;
            if(sw && finite(sw->pos.dur) && sw->pos.dur+1>cap) cap=sw->pos.dur+1;
            if(sw && finite(sw->size.dur) && sw->size.dur+1>cap) cap=sw->size.dur+1;
            void *source=c->by_id(e->src);
            done = stopping || !sw || !source || (P8_SOURCE(c)[i] && P8_SOURCE(c)[i]!=(u64)source) || now - e->t0 > cap ||
                   (!(sw->pos.active | sw->size.active) && (!sw->settling || sw->stable >= 3));
        } else if (e->pending) {                     // not closing (Cmd+H, minimize, tab switch): remove
            void *sw = c->by_id(e->src);             // no 0x3e9 within 120 ms, or window back on screen
            done = stopping || now - e->t0 > 0.12 || (sw && ((*(u64 *)((char *)sw + 0x928) >> 44) & 1));
        } else {
            double cap = 30.0, geometry_duration = hd(ch, 1), fade_duration = hd(ch, 2);
            // Springs finish by their actual state. A bounded failsafe handles pathological
            // custom springs; valid configured beziers can run up to 40s after time_scale.
            if (__builtin_isfinite(geometry_duration) && geometry_duration + 1 > cap) cap = geometry_duration + 1;
            if (__builtin_isfinite(fade_duration) && fade_duration + 1 > cap) cap = fade_duration + 1;
            done = stopping || !w || !(w->pos.active | w->size.active | w->alpha.active) || now - e->t0 > cap;
        }
        if (!done) continue;
        char *cl = c->by_id(e->wid);
        if (w) {
            if (cl) put_plain(c, w, cl);
            slot_free(c, w, cl);
        }
        if (cl && !*(void **)(cl + 0x30)) p8_free_win(c, cl);
        e->live = 0;
        P8_SOURCE(c)[i]=0;
    }
}

// Snapshot backdrop (OP_SNAP) below window: like Hyprland, extend edge pixels into band when box exceeds buffer.
// One axis: stretch last snapshot row/column across band width, clipping to band. Both axes: stretch whole snapshot
// to B, clip to B (window above covers its own area). Clone slot does not animate itself (trans/clip/alpha handled here).
static void snap_frame(struct ctx *c, struct ch_win *cw, struct ch_win *sw) {
    void *cl;
    if (!actual(c, cw, &cl)) return;
    cw->pos.active = cw->size.active = cw->alpha.active = 0;
    cw->settling = 0; cw->stretch = 0;
    double bx = sw->pos.v[0], by = sw->pos.v[1], bw = sw->size.v[0], bh = sw->size.v[1];
    double aw = sw->aw < bw ? sw->aw : bw, ah = sw->ah < bh ? sw->ah : bh;
    double gw = bw - aw, gh = bh - ah, ux = cw->ax, uy = cw->ay, uw = cw->aw, uh = cw->ah;
    double tx0, ty0, tw, th, kx, ky, kw, kh;
    int show = 1;
    // stretch row/column 8 pt from edge: edge itself has Tahoe glass and window outline (sky-colored band)
    double ry = uh > 16 ? uh - 8 : uh - 1, rx = uw > 16 ? uw - 8 : uw - 1;
    if (gh > 0.5 && gw <= 0.5) { tx0 = bx; tw = bw; th = uh * gh; ty0 = by + ah - ry * gh; kx = bx; ky = by + ah; kw = bw; kh = gh; }
    else if (gw > 0.5 && gh <= 0.5) { ty0 = by; th = bh; tw = uw * gw; tx0 = bx + aw - rx * gw; kx = bx + aw; ky = by; kw = gw; kh = bh; }
    else if (gw > 0.5 && gh > 0.5) { tx0 = bx; ty0 = by; tw = bw; th = bh; kx = bx; ky = by; kw = bw; kh = bh; }
    else { show = 0; tx0 = ux; ty0 = uy; tw = uw; th = uh; kx = ky = kw = kh = 0; }
    double a = show ? sw->cur_alpha : 0.0, av[1] = {a};
    warp(&cw->alpha, 1, av);                      // otherwise clone frame_win would restore slot variable alpha
    if (a != cw->cur_alpha) { c->set_alpha(0, cl, (float)(a < 0 ? 0 : a > 1 ? 1 : a), 0.0f); cw->cur_alpha = a; }
    if (!show || !(tw >= 0.01) || !(th >= 0.01) || !finite(tx0) || !finite(ty0)) return;
    double sx = uw / tw, sy = uh / th;
    put_xform(c, cw, sx, sy, (ux - tx0) * sx, (uy - ty0) * sy);
    put_clip(c, cw, cl, 1, kx, ky, kw, kh);
}

static void cover_frame(struct ctx *c,struct ch_win *cw,struct ch_win *sw) {
    void *clone;if(!actual(c,cw,&clone))return;
    double p[2]={sw->pos.v[0],sw->pos.v[1]},s[2]={sw->size.v[0],sw->size.v[1]},a[1]={sw->cur_alpha};
    warp(&cw->pos,2,p);warp(&cw->size,2,s);warp(&cw->alpha,1,a);
    cw->settling=0;cw->stretch=0;cw->geo=1;
    put_xform(c,cw,1,1,cw->ax-p[0],cw->ay-p[1]);
    put_clip(c,cw,clone,1,p[0],p[1],s[0],s[1]);
    if(cw->cur_alpha!=a[0]){c->set_alpha(0,clone,(float)a[0],0);cw->cur_alpha=a[0];}
}

void anim_tick(struct ctx *c, double now) {
    struct ch *ch = c->ch;
    struct ch_hdr *h = &ch->h;
    if(h->magic==CH_MAGIC && h->size==(u32)sizeof(struct ch)) {
        h->version|=CH_CAP_TERMINAL_MOVE;
        if((h->stop||c->dead) && effects_ready(c)) {
            c->effects_api->destroy(c->effects_runtime);c->effects_runtime=0;
        }
        if(effects_ready(c))h->version|=CH_CAP_EFFECTS;
        else h->version&=~CH_CAP_EFFECTS;
        if(effects_ready(c)&&c->effects_api->shadow_supported&&c->effects_api->shadow_supported(c->effects_runtime))h->version|=CH_CAP_SHADOW;
        else h->version&=~CH_CAP_SHADOW;
        if(snapshot_ready(c))h->version|=CH_CAP_SNAPSHOT|CH_CAP_SNAPSHOT_COVER;
        else h->version&=~(CH_CAP_SNAPSHOT|CH_CAP_SNAPSHOT_COVER);
        if(SNAP_SEQUENCE(c)==0xffffffffu)h->version&=~CH_CAP_SNAPSHOT_COVER;
    }
    if((h->stop || c->dead) && c->edges && h->magic==CH_MAGIC && h->size==(u32)sizeof(struct ch)) {
        // Teardown revokes preparation even while motion/hold flags remain set.
        h->now=now;
        for(int i=0;i<CH_NW;i++) if(ch->win[i].used) live_edge_client(c,&ch->win[i],0);
    }
    if((h->stop || c->dead) && c->edge_api && c->edges)
        for(int i=0;i<CH_NW;i++) edge_remove(c->edge_api,&c->edges[i]);
    // wrong channel (different structure version): stop without reading further
    if ((h->stop || c->dead) && h->magic == CH_MAGIC && h->size == (u32)sizeof(struct ch))
        p8_tick(c, 1, now); // free clones even when the close callback was disabled mid-animation
    if (h->stop && !c->dead && !c->cleaned && h->magic == CH_MAGIC) {
        // stop (reinstall/daemon stop): remove our transforms, masks, borders, shadows, and radii from windows
        c->cleaned = 1;
        h->now = now;
        for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (!w->used) continue;
            void *win = c->by_id(w->wid);
            if (!win) { slot_free(c, w, 0); continue; }
            native_cancel(c, w, win);
            put_plain(c, w, win);
            if (w->cur_alpha != 1.0) c->set_alpha(0, win, 1.0f, 0.0f);
            void *cwc = *(void **)((char *)win + 0x18);
            layers_drop(c, w, cwc ? *(void **)((char *)cwc + 0x38) : 0, cwc ? *(void **)((char *)cwc + 0x98) : 0);
            radius_restore(c, w, win);
            if (c->sched_win) c->sched_win(0, win);
        }
    }
    if (c->dead || h->magic != CH_MAGIC || h->size != (u32)sizeof(struct ch) || h->stop) { c->running = 0; return; }
    u64 t_in = c->mabs ? c->mabs() : 0;
    double T, te = frame_grid(c, now, &T);
    h->last_dt = now - h->now;
    h->ticks++;
    h->now = now;
    if (h->te_prev > 0 && dabs(T - h->period) < 0.01 * T && te <= h->te_prev + 1e-6) {
        // An order callback can request another tick before the next VBL. Sampling the
        // same frame twice advances stability/holds and retargets from a past t0.
        // Keep pending commands for the next frame instead of overwriting that frame.
        c->resched(c->queue, c->self, c, c->session, 1, 1, h->te_prev + T * h->phase);
        return;
    }
    h->period = T;
    h->te = te;

    u32 head = __atomic_load_n(&h->cmd_head, __ATOMIC_ACQUIRE), tail = h->cmd_tail;
    if (head - tail > CH_NCMD) { tail = head - CH_NCMD; record_error(ch,0,0,ERR_CMD_RING); }
    // Batch t0 = previous presentation time (te - T): first presented animation frame is exactly
    // one period after start, avoiding a 1-2 frame jump (Hyprland starts in event frame).
    double t0 = te - T;
    if (t0 > now) t0 = now;
    if(effects_ready(c))for(int i=0;i<CH_NW;i++)if(ch->win[i].used) {
        // FORGET/CFG callbacks may restore P4 masks during command ingestion.
        // Uncover their legal parent masks before those existing consumers run.
        c->effects_api->suspend(c->effects_runtime,i,0);
        c->effects_api->suspend(c->effects_runtime,i,1);
    }
    for (; tail != head; tail++) apply_cmd(c, &ch->cmd[tail % CH_NCMD], t0);
    __atomic_store_n(&h->cmd_tail, tail, __ATOMIC_RELEASE);
    if(h->reserved[0] & (1ull<<24)) {
        // Animation master-off resolves current and freshly queued goals in
        // this transaction. Keep engine ownership/scheduling and normal frame
        // cleanup; stop would restore the user's old native geometry instead.
        h->holding=0; h->hold_t=0;
        for(int i=0;i<CH_NW;i++) {
            struct ch_win *w=&ch->win[i];
            if(!w->used) continue;
            int changed=w->pos.active || w->size.active || w->alpha.active || w->held || w->wait==1;
            if(w->geo) { warp(&w->pos,2,w->pos.g); warp(&w->size,2,w->size.g); }
            warp(&w->alpha,1,w->alpha.g);
            warp(&w->act,1,w->act.g); warp(&w->sact,1,w->sact.g);
            w->held=w->needs=0;
            if(w->wait==1) w->wait=0; // wait2 is unclaimed first-map admission, not an animation.
            if(changed && w->geo) w->settling=1;
        }
    }

    // New windows: server ids only increase; check ids following the largest seen.
    // Window exists visibly before application shows it, allowing daemon to hide it in time.
    if (h->wid_max && (now - c->scan_t >= 0.016 - 1e-6 || now < c->scan_t)) {
        c->scan_t = now;
        u32 m = h->wid_max, miss = 0;
        for (u32 id = h->wid_max + 1; id <= h->wid_max + 64 && miss < 24; id++) {
            void *nw = c->by_id(id);
            if (!nw) { miss++; continue; }
            miss = 0; m = id;
            if (!*(void **)((char *)nw + 0x30)) continue;   // server window (our close clone etc.), not new
            // Level-0 window (normal: *(int*)(win+0x20), as read by __XGetWindowLevel) from a tiled
            // application stays invisible until first show; otherwise application could display it in its own
            // position before daemon decides placement (16+ ms).
            double pre = 0;
            u64 cn = (u64)*(void **)((char *)nw + 0x30);
            if (ch->prehide && *(int *)((char *)nw + 0x20) == 0 && cn) {
                int t = 0;
                for (int i = 0; i < CH_NCONN; i++) t |= ch->conn[i] == cn;
                struct ch_win *w = t ? slot(ch, id, 1) : 0;
                if (w) {
                    double z[1] = {0.0};
                    warp(&w->alpha, 1, z);
                    w->cur_alpha = 0.0;
                    c->set_alpha(0, nw, 0.0f, 0.0f);
                    w->wait = 2; w->wait_t = now;  // bounded, unclaimed optimistic hide
                    pre = 1;
                }
            }
            post_evt(ch, EV_NEW, id, now, pre, 0, 0, 0);
        }
        h->wid_max = m;
    }

    // Batch start: all windows wait until every resized window supplies a frame at new size
    // (or hold_max), then all start in one frame with t0 = previous presentation time.
    if (h->holding) {
        if (!h->hold_t) h->hold_t = now;
        int wait = 0;
        for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (!w->used || !w->held || !w->needs) continue;
            void *win = c->by_id(w->wid);
            if (!win) { w->needs = 0; continue; }
            actual(c, w, &win);
            if (dabs(w->aw - w->a0[0]) < 0.5 && dabs(w->ah - w->a0[1]) < 0.5) wait = 1;
        }
        int opening = 0;                             // opening window in batch (F_WAIT): wait for its frame, no longer than 150 ms
        for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (!w->used || w->wait != 1) continue;
            opening = 1;
            void *win;
            if (!actual(c, w, &win)) continue;
            if (!(dabs(w->aw - w->size.g[0]) <= h->settle_px && dabs(w->ah - w->size.g[1]) <= h->settle_px)) wait = 1;
        }
        double lim = opening ? (h->hold_max > 0.15 ? h->hold_max : 0.15) : h->hold_max > 0 ? h->hold_max : T;
        if (!wait || now - h->hold_t > lim) {
            double t0 = te - T;
            if (t0 > now) t0 = now;
            for (int i = 0; i < CH_NW; i++) {
                struct ch_win *w = &ch->win[i];
                if (!w->used || !w->held) continue;
                w->held = 0;
                if (w->wait == 1) w->wait = 0;     // the batch readiness check owns the release
                w->pos.t0 = w->size.t0 = w->alpha.t0 = t0;
                w->pos.last = w->size.last = w->alpha.last = t0;
                w->a0[0] = w->aw; w->a0[1] = w->ah;
            }
            h->holding = 0; h->hold_t = 0;
        }
    }

    u32 n = 0;
    unsigned char border_presented[CH_NW] = {0};
    int decoration_ready = deco_ready(c);
    for (int i = 0; i < CH_NW; i++) {
        struct ch_win *w = &ch->win[i];
        if (!w->used) continue;
        if(effects_ready(c)) {
            // Let the existing P4 and helper paths observe their own legal masks
            // before geometry ingestion; retain GPU caches/fade epoch privately.
            c->effects_api->suspend(c->effects_runtime,i,0);
            c->effects_api->suspend(c->effects_runtime,i,1);
            if(effects_owns_corner(c,w)&&c->corner&&c->dbg_radius) {
                void *prepared=c->by_id(w->wid);
                if(prepared && c->corner(prepared)>0.01) {
                    // Already ACKed client preparation owns upstream clipping.
                    // Set native radius before edge_update creates its surface;
                    // custom source/helper masks and matching rings own contour.
                    c->dbg_radius(prepared,0);w->radius=0;w->rset|=1;
                }
            }
        }
        if(cover_index(c,w->wid,0)>=0)continue;
        // The geometry transform and the ring belong to one presentation.
        // Hold this window's explicit WS context scope across both updates;
        // inner mask/ring commits cannot publish a half-updated presentation.
        // Snapshot helpers retain their source-before-cover ordering below.
        void *presentation_context = 0;
        if (decoration_ready && (w->geo == 1 || w->geo == 4) &&
            (w->pos.active || w->size.active || w->settling || w->held) && cover_index(c,w->wid,1)<0) {
            void *presented = c->by_id(w->wid);
            void *cwc = presented ? *(void **)((char *)presented + 0x18) : 0;
            presentation_context = cwc ? *(void **)((char *)cwc + 0x38) : 0;
        }
        unsigned long long presentation_tx[4] = {0};
        if (presentation_context) {
            c->tx_ctor(presentation_tx,1);
            c->tx_add(presentation_tx,presentation_context);
        }
        int a = frame_win(c, w, te);
        n += a;
        if (presentation_context) {
            if (w->used) n += border_win(c,w,te);
            border_presented[i] = 1;
            layers_commit(c,presentation_tx);
        }
        if (a && w->used) {                          // trajectory log (P0): visible frame and alpha at te
            struct ch_traj *r = &ch->traj[h->traj_head % CH_NTRAJ];
            r->te = te; r->wid = w->wid; r->bx = w->pos.v[0]; r->by = w->pos.v[1];
            r->bw = w->size.v[0]; r->bh = w->size.v[1]; r->alpha = w->cur_alpha;
            __atomic_store_n(&h->traj_head, h->traj_head + 1, __ATOMIC_RELEASE);
        }
    }
    // Source geometry has now advanced to te. Underlay and border must consume
    // that same sample; running this before frame_win leaked old pixels beyond B.
    for (int i = 0; i < P8_N; i++) {
        struct p8c *e = &P8_TAB(c)[i];
        if (!e->live || (e->pending!=2 && e->pending!=3)) continue;
        struct ch_win *sw = slot(ch, e->src, 0), *cw = slot(ch, e->wid, 0);
        if (sw && cw){if(e->pending==3)cover_frame(c,cw,sw);else snap_frame(c, cw, sw);}
    }
    {                                                // borders: also while idle (focus); CA only on change
        int ok = decoration_ready;
        for (int i = 0; ok && i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (w->used) {
                if (!border_presented[i]) n += border_win(c, w, te);
                if(live_edge_enabled(c,w))
                    edge_decorate(c->edge_api,&c->edges[i],(void*)w->bl_act,(void*)w->bl_sh,
                                  w->size.v[0],w->size.v[1],ch->deco.sys_off==1?0:ch->deco.width);
                n += effects_render_win(c,w,te);
            }
        }
    }
    if(effects_ready(c))for(int i=0;i<CH_NW;i++)if(!ch->win[i].used) {
        c->effects_api->drop(c->effects_runtime,i,0);c->effects_api->drop(c->effects_runtime,i,1);
    }
    p8_tick(c, 0, te);
    for (int i = 0; i < P8_N; i++) n += P8_TAB(c)[i].live;
    h->nactive = n;
    if (n) {                                         // frame grid regularity: te step must equal T
        if (h->te_prev > 0 && dabs(te - h->te_prev - T) > 0.25 * T) h->te_skips++;
        h->te_prev = te;
        if (now - (te - T) > 0.6 * T) h->ticks_late++;   // tick late within its frame (only during animation)
    } else h->te_prev = 0;
    if (c->mabs) {
        double us = (double)(c->mabs() - t_in) * c->mabs_us;
        h->tick_us_last = us;
        if (us > h->tick_us_max) h->tick_us_max = us;
    }
    c->running = n != 0;
    double at;
    if (n) at = te + T * h->phase;      // next frame: phase fraction of period after vblank te
    else at = now + (h->idle_poll > 0.002 ? h->idle_poll : 0.008);
    c->resched(c->queue, c->self, c, c->session, 1, 1, at);
}

// metalCallbacks: (x0=MetalContext*, x1=&shared_ptr<Display>, x2=0, x3=ctx)
void anim_frame(void *mctx, void *disp, void *z, struct ctx *c) {
    if (c->dead) return;
    c->ch->h.frames++;
    if (c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, 0.0);
}

// Typed readonly contract for a reviewed installer/HOST, separate from FX APIs.
unsigned anim_ctx_pending_offset(void) { return __builtin_offsetof(struct ctx,pending_edge_generation); }
unsigned anim_ctx_size(void) { return sizeof(struct ctx); }
u64 anim_edge_pending_generation(struct ctx *c,unsigned index) {
    return c && index<CH_NW ? c->pending_edge_generation[index] : 0;
}
