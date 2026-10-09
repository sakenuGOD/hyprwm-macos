// Движок анимаций v4 внутри WindowServer: центральный покадровый такт, как в Hyprland.
//
// Каждый тик (раз за кадр, на главном потоке WS):
//   1. забирает из общей памяти все опубликованные команды и применяет их с одним t0;
//   2. продвигает переменные всех окон (позиция, размер, альфа) по кривым Hyprland —
//      пружина аналитикой hyprutils advanceSpring, безье с запеканием 255 точек и getYForPoint;
//   3. читает у сервера фактическую рамку окна A и ставит трансформ, который показывает
//      окно в видимой рамке B(t): A растягивается в B (пивот — левый верхний угол окна).
//      Приложению конечный размер сообщается один раз (демон), до перерисовки видно растяжение.
// Когда анимации окна кончились и приложение приняло размер (или вышло время ожидания) —
// identity, слот трансформа удаляется сервером, окно рисуется как есть.
//
// Тик: anim_frame висит в metalCallbacks (зовётся из composite() раз за кадр) и ставит
// anim_tick в очередь главного потока «сейчас»; в простое тик сам перепланирует себя
// через idle_poll, чтобы забирать команды.
// Сборка: build_anim4.sh (плоский образ __TEXT, без релокаций и без обращений к __DATA).
#include "chan.h"

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
    set_xform_fn set_xform;  // 0x00  все указатели функций подписаны IA/0
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
    u32          shape_off, dead;     // 0x70  смещение формы окна в CGXWindow (0x170); dead: снят установщиком
    vbl_fn       vbl;                 // 0x78  WSDisplayScheduleGetPrevNextVBL (кэш развёртки дисплея)
    u32          display, pad2;       // 0x80  CGDirectDisplayID главного дисплея
    clip_fn      clip;                // 0x88  CGXWindow::set_window_list_global_clip_shape(conn, region, wids, n)
    rgn_fn       rgn;                 // 0x90  CGRegionCreateWithRect
    rel_fn       release;             // 0x98  CFRelease
    double     (*corner)(void *win);  // 0xa0  CGXWindow::resolved_corner_radius() const
    void      *(*rdiff)(void *a, void *b);   // 0xa8  CGRegionCreateDifferenceWithRegion (a − b)
    u64        (*mabs)(void);         // 0xb0  mach_absolute_time (замер стоимости тика)
    double       mabs_us;             // 0xb8  мкс на один mach-тик (timebase)
    // П4: ObjC/CA внутри WS. Всё — в ОДНОЙ транзакции WS на вызов (ctor → addContextToCommit → свойства → dtor):
    // WS коммитит только явно перечисленные контексты (setCommittingContexts: в ~WSCAContextScopeTransaction)
    void        *msg;                 // 0xc0  objc_msgSend (вызов через приведённые типы)
    void      *(*sel)(const char *);  // 0xc8  sel_registerName
    void      *(*cls)(const char *);  // 0xd0  objc_getClass
    void      *(*srgb)(double, double, double, double);   // 0xd8  CGColorCreateSRGB
    void       (*tx_ctor)(void *tx, unsigned params);     // 0xe0  WSCAContextScopeTransaction(WSCAScopeParameters)
    void       (*tx_add)(void *tx, void *cactx);          // 0xe8  addContextToCommit(CAContext*)
    void       (*tx_dtor)(void *tx);                      // 0xf0  ~WSCAContextScopeTransaction (commit)
    void        *black;               // 0xf8  CGColor (кэш)
    void        *s_layer, *s_retain, *s_release, *s_frame, *s_radius, *s_bg, *s_mask;   // 0x100.. селекторы (кэш)
    void        *c_layer;             // 0x138 класс CALayer
    void        *s_bounds;            // 0x140
    // перенос окна на стол — как серверный __XMoveWindowsToManagedSpace, но от соединения-владельца окна
    void      *(*space_for_id)(u64 sid);                                  // 0x148 PKGSpaceForID
    void      *(*wlist)(void *conn, const unsigned *wids, unsigned n);    // 0x150 window_ordering_group_list_create_from_window_id_array
    void       (*wmove)(void *conn, void *list, void *managed);           // 0x158 PKGWindowsMoveToManagedSpace
    void       (*xfree)(void *p);                                         // 0x160 free
    // П6: рамка фокуса (селекторы и классы — кэш, заполняет deco_ready)
    void        *s_bwidth, *s_bcolor, *s_colors, *s_start, *s_end, *s_opacity;   // 0x168..0x190
    void        *s_addsub, *s_remove, *s_convert, *s_arr, *s_getmask, *s_curve;  // 0x198..0x1c0
    void        *c_grad, *c_array, *str_cont;                                    // 0x1c8 0x1d0 0x1d8
    void        *s_shpath, *s_shcolor, *s_shrad, *s_shoff, *s_shop, *s_insert, *s_bwidth2;   // 0x1e0..0x210
    void      *(*path_rr)(struct rect4_ r, double cw, double ch, const void *t);           // 0x218 CGPathCreateWithRoundedRect
    void       (*path_rel)(void *p);                                                    // 0x220 CGPathRelease
    void       (*dbg_radius)(void *win, double r);                                     // 0x228 CGXWindow::set_debug_corner_radius
    void       (*dbg_clear)(void *win);                                                // 0x230 CGXWindow::clear_debug_corner_radius
    // заливка пустой полосы B−A (дотяжка края): CAShapeLayer с путём even-odd
    void      *(*path_mut)(void);                                                       // 0x238 CGPathCreateMutable
    void       (*path_addrr)(void *p, const void *t, struct rect4_ r, double cw, double ch);   // 0x240 CGPathAddRoundedRect
    void       (*path_addrect)(void *p, const void *t, struct rect4_ r);               // 0x248 CGPathAddRect
    void        *s_path, *s_fillcolor, *s_fillrule, *s_hidden, *c_shape, *str_eo;      // 0x250..0x278
    // после своей CA-транзакции — заявка на перерисовку дисплеев окна: WS композитит «отсоединённо» и сам
    // чужой коммит слоёв может не показать до постороннего события (клик) — кроссфейд шёл рывками/застревал
    void       (*sched_win)(void *conn, void *win);                                     // 0x280 CGXScheduleUpdateDisplaysIntersectingWindow
    // кроссфейд через CABasicAnimation (кадры интерполирует CA в момент рендера — без покадровых коммитов)
    void        *c_basic, *s_akp, *s_from, *s_to, *s_adur, *s_tf, *s_addanim, *s_pres;  // 0x288..0x2c0
    void        *s_opget, *s_shopget, *c_num, *s_numf, *c_tfn, *s_tfcp, *str_op, *str_shop; // 0x2c8..0x300
    u64          cleaned;                                                               // 0x308 слои сняты при stop
    void        *s_subl, *s_count, *s_objat, *s_iskind, *s_shpathget;                   // 0x310..0x330
    void       (*order)(void *conn, unsigned wid, int op, unsigned rel);                // 0x338 CGXOrderWindow
    // П8: снимок закрытия (notes/research/close_clone.md)
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
    void        *s_curveget, *cur_curve;                                               // 0x3a0 0x3a8 форма угла окна
    void       (*tags)(void *conn, void **wins, u64 mask, int clear);                  // 0x3b0 set_window_list_tags (1 окно; clear=1 — снять)
    void        *str_circ;                                                              // 0x3b8 "circular"
    // configure через приложение (native_hooks §1): уведомление WS владельцу окна, модуль hyprforce применяет
    void       (*post)(void *conn, unsigned type, const void *data, unsigned len);      // 0x3c0 WSPostNotificationToConnection
    void      *(*owner)(void *win);                                                     // 0x3c8 CGXWindowGetOwner
    void        *s_arm;                                                                 // 0x3d0 setAutoresizingMask:
    // невидимая системная тень override-ом (beyond_bounds.md §1.7): WS сам держит её невидимой при любой
    // смене активности, клип рисования окна остаётся раздутым под наши кольцо/тень
    void       (*wm_shadow)(void *win, const void *act, const void *inact);             // 0x3d8 WSWindowSetWindowManagerShadowProperties
    void       (*sh_inval)(void *conn, void *win);                                      // 0x3e0 WSWindowInvalidateShadowFrame
    void       (*sh_sched)(void *win, void *conn);                                      // 0x3e8 CGXWindow::invalidate_shadow_and_schedule_update
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
_Static_assert(sizeof(struct ctx) <= 0x800, "ctx заходит на P8_TAB");
_Static_assert(__builtin_offsetof(struct ctx, s_shpathget) == 0x330, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, order) == 0x338, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, cb) == 0x380, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, nskip) == 0x39c, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, cur_curve) == 0x3a8, "ctx");
_Static_assert(__builtin_offsetof(struct ctx, tags) == 0x3b0, "ctx");

static inline double dabs(double x) { return x < 0 ? -x : x; }
static inline int finite(double x) { return x == x && dabs(x) < 1e7; }

// ── кривые ─────────────────────────────────────────────────────────────────
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

// operator= из hyprutils CGenericAnimatedVariable: старт от текущего значения; у пружины
// при перезапуске посреди хода скорость сохраняется (Vector2D: масштаб 1, float: OLD/NEW).
static void retarget(struct ch *ch, struct ch_var *v, int n, const double *g, u32 cv, double dur, double now) {
    int same = 1;
    for (int i = 0; i < n; i++) same &= v->g[i] == g[i];
    if (same) return;
    int was = v->active, sp = is_spring(ch, cv);
    double scale = 1.0;
    if (was && sp && n == 1) {
        double od = v->g[0] - v->b[0], nd = g[0] - v->v[0];
        scale = dabs(nd) > 1e-6 ? od / nd : 0.0;
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

// Продвинуть переменную; 1 — ещё анимируется.
static int step(struct ctx *c, struct ch_var *v, int n, double now) {
    if (!v->active) return 0;
    struct ch *ch = c->ch;
    double y; int fin;
    if (is_spring(ch, v->curve)) {
        double dt = now - v->last;
        v->last = now;
        spring_adv(c, &ch->curve[v->curve], &v->sv, &v->svel, dt);
        fin = dabs(1.0 - v->sv) <= 0.001 && dabs(v->svel) <= 0.001;
        if (fin) { v->sv = 1.0; v->svel = 0.0; }
        y = v->sv;
    } else {
        // время в double (Hyprland считает в целых мс: на 180 Гц не видно, на 60 Гц даёт неровность до ±4% — P25)
        double pct = v->dur > 0 ? (now - v->t0) / v->dur : 1.0;
        fin = pct >= 1.0 || v->curve >= CH_NCURVE || ch->curve[v->curve].type != CV_BEZIER;
        y = fin ? 1.0 : bezier_y(&ch->curve[v->curve], pct);
    }
    for (int i = 0; i < n; i++) v->v[i] = fin ? v->g[i] : v->b[i] + (v->g[i] - v->b[i]) * y;
    if (fin) v->active = 0;
    return !fin;
}

// ── окна ───────────────────────────────────────────────────────────────────
static void post_evt(struct ch *ch, u32 type, u32 wid, double now, double x, double y, double w, double h) {
    u32 hd = ch->h.evt_head;
    struct ch_evt *e = &ch->evt[hd % CH_NEVT];
    e->type = type; e->wid = wid; e->t = now; e->x = x; e->y = y; e->w = w; e->h = h;
    __atomic_store_n(&ch->h.evt_head, hd + 1, __ATOMIC_RELEASE);
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

// Серверная обрезка окна по видимой рамке B (глобальные pt): содержимое 1:1 от левого верхнего
// угла, лишнее справа/снизу отрезано — как uv-обрезка Hyprland при resize. on=0 — снять.
// conn = владелец окна: тогда сервер не заводит «чужой» override.
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

// ── П4: маска видимой рамки B на слое Hosting CA-дерева окна (compositor.md §1б, §3) ─────────────────────
// Маска едет вместе с окном (трансформ/Space-переход), скругляется и сглаживается CA; экранный клип этого не умел.
struct rect4 { double x, y, w, h; };
typedef void *(*msg0_t)(void *, void *);
typedef void (*msgp_t)(void *, void *, void *);
typedef void (*msgd_t)(void *, void *, double);
typedef void (*msgr_t)(void *, void *, struct rect4);
typedef struct rect4 (*msgb_t)(void *, void *);     // CGRect-возврат: HFA в d0–d3 (arm64, без stret)

static int mask_ready(struct ctx *c) {
    if (!c->msg || !c->sel || !c->cls || !c->tx_ctor || !c->tx_add || !c->tx_dtor || !c->srgb) return 0;
    if (!c->c_layer) {
        c->s_layer = c->sel("layer"); c->s_retain = c->sel("retain"); c->s_release = c->sel("release");
        c->s_frame = c->sel("setFrame:"); c->s_radius = c->sel("setCornerRadius:");
        c->s_bg = c->sel("setBackgroundColor:"); c->s_mask = c->sel("setMask:");
        c->s_bounds = c->sel("bounds");
        c->s_arm = c->sel("setAutoresizingMask:");
        c->black = c->srgb(0, 0, 0, 1);
        c->c_layer = c->cls("CALayer");
    }
    return c->c_layer && c->black;
}

// Слой держится у ВЕРХНЕГО края родителя (ось Y слоёв окна — вверх): WS меняет bounds Hosting/Server root в
// ingestion на кадр позже нашего тика, и маска/кольца, отсчитанные от нижнего края, на этот кадр съезжали на
// величину изменения высоты. kCALayerMinYMargin (8) — CA сам двигает их в той же транзакции (resizeSublayers…
// и маску @0x18a5fde54, native_hooks §3.3; sync_protocol.md).
typedef void (*msgu_t)(void *, void *, unsigned);
static void keep_top(struct ctx *c, void *L) {
    if (L && c->s_arm) ((msgu_t)c->msg)(L, c->s_arm, 8);
}

// on: показать окно только в (0,0,cw,chh) от левого верхнего угла буфера; off: снять маску.
static void put_mask(struct ctx *c, struct ch_win *w, void *win, int on, double cw, double chh) {
    struct ch *ch = c->ch;
    if (!on && !w->mask) return;
    if (!mask_ready(c)) return;
    void *cwc = *(void **)((char *)win + 0x18);
    void *H = cwc ? *(void **)((char *)cwc + 0x98) : 0;          // "Hosting"
    void *cactx = cwc ? *(void **)((char *)cwc + 0x38) : 0;      // CAContext окна
    if (!H || !cactx) { ch->h.mask_errs++; return; }
    // Высота — у самого слоя, не у формы окна: слой меняет размер на кадр-два позже формы (приложение уже
    // прислало новый размер). По высоте формы маска уходила за слой — окно пропадало на кадр [V rec2 f_010].
    struct rect4 hb = on ? ((msgb_t)c->msg)(H, c->s_bounds) : (struct rect4){0, 0, 0, 0};
    if (on && !(hb.h >= 1 && finite(hb.h) && finite(hb.y))) { ch->h.mask_errs++; return; }
    if (on && w->mask && dabs(cw - w->mrect[0]) < 0.25 && dabs(chh - w->mrect[1]) < 0.25 &&
        dabs(hb.y - w->mhost[0]) < 0.25 && dabs(hb.h - w->mhost[1]) < 0.25) return;
    unsigned long long tx[4] = {0, 0, 0, 0};                     // {CFArray*, disableActions, began} — 16 байт
    c->tx_ctor(tx, 1);                                           // бит0: disableActions
    c->tx_add(tx, cactx);
    if (on) {
        void *M = (void *)w->mask;
        if (!M) {
            M = ((msg0_t)c->msg)(c->c_layer, c->s_layer);
            if (M) {
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
            double hh = chh < hb.h ? chh : hb.h;                  // буфер видим от верхнего края слоя
            double y = ch->h.mask_flip ? hb.y + hb.h - hh : hb.y;  // ось Y слоя вверх [V rec2 f_011]
            struct rect4 f = {hb.x, y, cw, hh};
            ((msgr_t)c->msg)(M, c->s_frame, f);
            ((msgd_t)c->msg)(M, c->s_radius, w->radius > 0 ? w->radius : 18.0);
            ((msgp_t)c->msg)(H, c->s_mask, M);
            w->mrect[0] = cw; w->mrect[1] = chh; w->mhost[0] = hb.y; w->mhost[1] = hb.h;
        }
    } else {
        ((msgp_t)c->msg)(H, c->s_mask, 0);
        ((msg0_t)c->msg)((void *)w->mask, c->s_release);
        w->mask = 0; w->mrect[0] = w->mrect[1] = 0;
    }
    c->tx_dtor(tx);                                              // commit этого контекста
    if (c->sched_win) c->sched_win(0, win);
}

static int use_mask(struct ctx *c, struct ch_win *w) {
    return c->ch->h.use_mask && (!c->ch->h.mask_only || c->ch->h.mask_only == w->wid);
}

// ── П6: рамка фокуса — слои в Server root CA-дерева окна (compositor.md §3 п.3) ─────────────────────────
// Неактивное кольцо: CALayer с borderWidth/borderColor/cornerRadius. Активное: CAGradientLayer (цвета градиента
// Hyprland, запечённые в OkLab демоном), маска — такое же кольцо; кроссфейд = opacity активного слоя.
// Кольцо — снаружи видимой рамки B (Hyprland: рамка снаружи контента), внешний радиус = radius + width.
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
        c->s_pres = c->sel("presentationLayer"); c->s_opget = c->sel("opacity"); c->s_shopget = c->sel("shadowOpacity");
        c->c_num = c->cls("NSNumber"); c->s_numf = c->sel("numberWithFloat:");
        c->c_tfn = c->cls("CAMediaTimingFunction"); c->s_tfcp = c->sel("functionWithControlPoints::::");
        void *ns3 = c->cls("NSString");
        void *(*mk)(void *, void *, const char *) = (void *(*)(void *, void *, const char *))c->msg;
        void *sutf = c->sel("stringWithUTF8String:");
        c->str_op = ns3 ? mk(ns3, sutf, "opacity") : 0;
        c->str_shop = ns3 ? mk(ns3, sutf, "shadowOpacity") : 0;
        if (c->str_op) ((msg0_t)c->msg)(c->str_op, c->s_retain);
        if (c->str_shop) ((msg0_t)c->msg)(c->str_shop, c->s_retain);
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
    ((msgd_t)c->msg)(L, c->s_bwidth, wd);
    ((msgp_t)c->msg)(L, c->s_bcolor, color);
    ((msgd_t)c->msg)(L, c->s_radius, r);
    void *cv = c->cur_curve ? c->cur_curve : c->str_cont;     // форма угла — как у самого окна (Hosting)
    if (cv) ((msgp_t)c->msg)(L, c->s_curve, cv);
    return L;
}

typedef double (*msgdr_t)(void *, void *);
// Только чтение: borderWidth/cornerRadius слоёв окна в reserved заголовка (кто рисует обводку Tahoe)
static void probe_layers(struct ctx *c, void *cwc) {
    struct ch *ch = c->ch;
    void *bwsel = c->sel("borderWidth"), *crsel = c->sel("cornerRadius");
    int offs[3] = {0x88, 0x98, 0x90};
    for (int i = 0; i < 3; i++) {
        void *L = *(void **)((char *)cwc + offs[i]);
        double v = L ? ((msgdr_t)c->msg)(L, bwsel) : -1, r = L ? ((msgdr_t)c->msg)(L, crsel) : -1;
        ch->h.reserved[i] = (u64)(v * 1000) << 32 | (u64)(r * 1000);
    }
    ch->h.reserved[3]++;
}

static void border_make(struct ctx *c, struct ch_win *w, void *root) {
    struct ch_deco *d = &c->ch->deco;
    double r = d->radius + d->width;
    void *ci = c->srgb(d->inact[0], d->inact[1], d->inact[2], d->inact[3]);
    double band = (d->sys_off == 1 ? 0.0 : d->width) + d->inset10 / 10.0;   // как в border_win: наружу + внутрь
    if (band < 0.5) band = d->width;
    void *I = ci ? ring(c, band, r, ci) : 0;
    if (ci) c->release(ci);
    void *G = ((msg0_t)c->msg)(c->c_grad, c->s_layer);
    if (!I || !G) return;
    void *cols[8]; unsigned n = d->ngrad > 8 ? 8 : d->ngrad;
    if (n < 2) n = 2;
    for (unsigned i = 0; i < n; i++) cols[i] = c->srgb(d->grad[i][0], d->grad[i][1], d->grad[i][2], d->grad[i][3]);
    void *arr = ((msgarr_t)c->msg)(c->c_array, c->s_arr, cols, n);
    ((msgp_t)c->msg)(G, c->s_colors, arr);
    for (unsigned i = 0; i < n; i++) if (cols[i]) c->release(cols[i]);
    struct pt2 a = {d->start[0], d->start[1]}, b = {d->end[0], d->end[1]};
    ((msgpt_t)c->msg)(G, c->s_start, a);
    ((msgpt_t)c->msg)(G, c->s_end, b);
    void *M = ring(c, band, r, c->black);
    if (M) ((msgp_t)c->msg)(G, c->s_mask, M);
    ((msgf_t)c->msg)(G, c->s_opacity, 0.0f);
    keep_top(c, I); keep_top(c, G);
    ((msg0_t)c->msg)(I, c->s_retain); ((msg0_t)c->msg)(G, c->s_retain);
    ((msgp_t)c->msg)(root, c->s_addsub, I);
    ((msgp_t)c->msg)(root, c->s_addsub, G);
    w->bl_in = (u64)I; w->bl_act = (u64)G; w->bop = 0; w->bframe[2] = -1;
}

// Снять рамку и маску окна (слот освобождается). cactx может быть 0 (окна уже нет): тогда транзакция без
// контекста — только чтобы release/removeFromSuperlayer шли внутри сбалансированной транзакции WS.
static void layers_drop(struct ctx *c, struct ch_win *w, void *cactx) {
    if (!w->bl_in && !w->bl_act && !w->bl_sh && !w->bl_fill && !w->mask) return;
    if (!mask_ready(c)) return;
    unsigned long long tx[4] = {0, 0, 0, 0};
    c->tx_ctor(tx, 1);
    if (cactx) c->tx_add(tx, cactx);
    void *L[4] = {(void *)w->bl_in, (void *)w->bl_act, (void *)w->bl_sh, (void *)w->bl_fill};
    for (int i = 0; i < 4; i++) if (L[i]) { ((msg0_t)c->msg)(L[i], c->s_remove); ((msg0_t)c->msg)(L[i], c->s_release); }
    if (w->mask) ((msg0_t)c->msg)((void *)w->mask, c->s_release);   // маску держит и Hosting, если он жив
    w->bl_in = w->bl_act = w->bl_sh = w->bl_fill = w->mask = 0;
    w->fkey[4] = -1;
    c->tx_dtor(tx);
}

// WSShadowProperties (0x40): sigma, density, rimDens, rimRad, innerDens, innerRad, offY (float), flags, …, маска
// override @+0x38 [V сеттер копирует ldp q0..q3; beyond_bounds §1.7.1]. on: sigma 23 (frame_bounds +65 pt),
// density 0.001 (порог «тень включена» — клип не схлопывается; 0.26/255 — невидимо), контур Tahoe 0, маска 0xfff —
// AppKit не перебьёт. off: нулевая структура с маской 0 — снова значения AppKit (тень Tahoe возвращается).
struct ws_shadow { float f[14]; u32 mask, pad; };
static void shadow_override(struct ctx *c, void *win, int on) {
    struct ws_shadow s;
    for (int i = 0; i < 14; i++) s.f[i] = 0;
    s.mask = 0; s.pad = 0;
    if (on) { s.f[0] = 23.0f; s.f[1] = 0.001f; s.mask = 0xfff; }
    void *conn = c->owner ? c->owner(win) : 0;
    if (c->sh_inval) c->sh_inval(conn, win);
    c->wm_shadow(win, &s, &s);
    if (c->sh_sched) c->sh_sched(win, conn);
}

static void radius_restore(struct ctx *c, struct ch_win *w, void *win) {
    if ((w->rset & 4) && win && c->wm_shadow) shadow_override(c, win, 0);   // системная тень — значения AppKit
    if ((w->rset & 1) && win && c->dbg_clear) c->dbg_clear(win);    // радиус приложения снова в силе
    if ((w->rset & 2) && win && c->tags) { void *a[1] = {win}; c->tags(0, a, 8, 1); }   // тень/контур Tahoe — назад
    w->rset = 0;
}

static void slot_free(struct ctx *c, struct ch_win *w, void *win) {
    radius_restore(c, w, win);
    void *cwc = win ? *(void **)((char *)win + 0x18) : 0;
    layers_drop(c, w, cwc ? *(void **)((char *)cwc + 0x38) : 0);
    w->used = 0;
}

typedef void (*msgi_t)(void *, void *, void *, unsigned);
#define SH_E 64.0              // ширина кольца-маски тени: тень видна до SH_E pt наружу (range 34 + offset 10 + запас)

// Тень: слой под системным Shadow (индекс 0 в Server root); рисуется только shadowPath; маска — кольцо,
// внутренний край которого = бокс с рамкой, поэтому внутри окна тени нет (как Hyprland).
static void shadow_make(struct ctx *c, struct ch_win *w, void *root, void *shadow_sys) {
    struct ch_deco *d = &c->ch->deco;
    void *S = ((msg0_t)c->msg)(c->c_layer, c->s_layer);
    if (!S) return;
    void *black = c->black;
    ((msgp_t)c->msg)(S, c->s_shcolor, black);
    ((msgd_t)c->msg)(S, c->s_shrad, d->srad);
    struct pt2 off = {0, -d->soff};                     // ось Y слоя вверх: вниз = −
    ((msgpt_t)c->msg)(S, c->s_shoff, off);
    ((msgf_t)c->msg)(S, c->s_shop, 0.0f);
    void *M = ring(c, SH_E, d->radius + d->width + SH_E, black);
    if (M) ((msgp_t)c->msg)(S, c->s_mask, M);
    keep_top(c, S);
    ((msg0_t)c->msg)(S, c->s_retain);
    ((msgi_t)c->msg)(root, c->s_insert, S, 0);
    w->bl_sh = (u64)S; w->sop = -1;
    if (d->sys_off && shadow_sys) {                  // системная тень и контур окна Tahoe (borderWidth 1 у Shadow [V])
        ((msgf_t)c->msg)(shadow_sys, c->s_shop, 0.0f);
        ((msgd_t)c->msg)(shadow_sys, c->s_bwidth, 0.0);
    }
}

typedef float (*msgfr_t)(void *, void *);
// Свойство-float слоя → to: CABasicAnimation от текущего видимого значения (presentationLayer — ретаргет посреди
// хода без скачка) по cubic-bezier из конфига; модельное значение = to. Внутри открытой транзакции WS.
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
    }
    ((msgf_t)c->msg)(L, setsel, (float)to);
}

// Уборка следов прошлых установок движка (их слоты потеряны при переустановке, слои остались в дереве окна:
// «лишнее кольцо старой геометрии», «два активных кольца», чужая маска на Hosting). В Server root от WS — только
// Shadow; наши признаки: CAGradientLayer/CAShapeLayer, CALayer с borderWidth ≥ 1 или shadowPath. Внутри транзакции.
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
        int ours = (c->c_grad && ((int (*)(void *, void *, void *))c->msg)(L, c->s_iskind, c->c_grad)) ||
                   (c->c_shape && ((int (*)(void *, void *, void *))c->msg)(L, c->s_iskind, c->c_shape)) ||
                   ((msgdr_t)c->msg)(L, c->sel("borderWidth")) >= 1.0 ||
                   ((msg0_t)c->msg)(L, c->s_shpathget) != 0;
        if (ours) kill[k++] = L;
    }
    for (int i = 0; i < k; i++) ((msg0_t)c->msg)(kill[i], c->s_remove);
    void *m = ((msg0_t)c->msg)(H, c->s_getmask);
    if (m && m != (void *)w->mask) ((msgp_t)c->msg)(H, c->s_mask, 0);
    c->ch->h.reserved[4] += (u64)k + (m && m != (void *)w->mask);   // счётчик убранных следов (для лога)
}

// Рамка одного окна на кадр te. 1 — кроссфейд ещё идёт.
static int border_win(struct ctx *c, struct ch_win *w, double te) {
    struct ch *ch = c->ch;
    struct ch_deco *d = &ch->deco;
    if (!w->geo) return 0;
    void *win = c->by_id(w->wid);
    if (!win) return 0;
    void *cwc = *(void **)((char *)win + 0x18);
    void *root = cwc ? *(void **)((char *)cwc + 0x80) : 0;
    void *H = cwc ? *(void **)((char *)cwc + 0x98) : 0;
    void *cactx = cwc ? *(void **)((char *)cwc + 0x38) : 0;
    if (!root || !H || !cactx) return 0;
    if (!d->on || w->wid == d->nofull || (d->only && w->wid != d->only)) {
        if (w->bl_in || w->bl_sh) layers_drop(c, w, cactx);
        radius_restore(c, w, win);
        return 0;
    }
    // радиус угла как в Hyprland (decoration.rounding) — отладочный радиус WS главнее радиуса приложения [V листинг
    // resolved_corner_radius 187063110: бит 6 win+0x928 → win+0x858]; Telegram/Tahoe иначе 26, Ghostty 16
    if (d->radius > 0 && c->dbg_radius && c->corner && dabs(c->corner(win) - d->radius) > 0.01) {
        c->dbg_radius(win, d->radius);
        w->rset |= 1;
    }
    // системная тень и контур Tahoe — тегом DisableShadow (бит 3 `win+0x80`): WS сам держит их выключенными при
    // любой смене активности (гашение свойств слоя Shadow он перезаписывал → контур появлялся/исчезал рывком)
    if (d->sys_off != 1 && c->tags && (w->rset & 2)) {   // режим не «тег» — вернуть окну тень (и расширенный клип)
        void *a[1] = {win};
        c->tags(0, a, 8, 1);
        w->rset &= ~2u;
    }
    if (d->sys_off == 1 && c->tags && !(w->rset & 2) && !((*(u64 *)((char *)win + 0x80) >> 3) & 1)) {
        void *a[1] = {win};
        c->tags(0, a, 8, 0);
        w->rset |= 2;
    }
    // режим 3: override тени — один раз на окно; повторно, только если кто-то перезаписал итог (density active
    // win+0x35c ≠ 0.001, практически не бывает при маске 0xfff)
    int ovr = d->sys_off == 3 && c->wm_shadow;
    if (ovr && (!(w->rset & 4) || dabs(*(float *)((char *)win + 0x35c) - 0.001f) > 0.0005)) {
        shadow_override(c, win, 1);
        w->rset |= 4;
    }
    if (!ovr && (w->rset & 4) && c->wm_shadow) {
        shadow_override(c, win, 0);
        w->rset &= ~4u;
    }
    double rin = c->corner ? c->corner(win) : d->radius;
    int rchg = dabs(rin - w->radius) > 0.01;
    if (rchg) w->radius = rin;
    // Кроссфейд рамки/тени ведёт сам CA (fade_to): нам — только смена цели и заявки на перерисовку, пока он идёт
    double gt = w->wid == d->focus ? 1.0 : 0.0;
    int tchg = !w->bl_in || w->act.g[0] != gt;
    double op = gt;
    double sop = d->sh_on ? d->sop_in + (d->sop_act - d->sop_in) * gt : 0.0;
    double fend = w->act.t0 + (d->dur > d->sdur ? d->dur : d->sdur) + 0.034;
    int an = te < fend;                              // CA-анимация идёт: каждый кадр — заявка на перерисовку
    // бокс рамки в координатах окна: видимая рамка B от левого верхнего угла буфера (popin тянет A на B — тогда A)
    double bw = w->stretch ? w->aw : w->size.v[0], bh = w->stretch ? w->ah : w->size.v[1];
    if (!(bw >= 1) || !(bh >= 1) || !finite(bw) || !finite(bh)) return an;
    struct rect4 hb = ((msgb_t)c->msg)(H, c->s_bounds);
    if (!(hb.h >= 1) || !finite(hb.h) || !finite(hb.y)) return an;
    // кольцо: наружу на ow (= ширина рамки, как Hyprland; 0 — если клип окна узкий, режим «тег»), внутрь на ins
    // (закрыть обводку, которую рисует само приложение); ширина полосы кольца = ow + ins
    double wd = d->width, ins = d->inset10 / 10.0;
    double ow = d->sys_off == 1 ? 0.0 : wd;
    if (d->sys_off == 1 && ins > wd) ins = wd;
    struct rect4 f = {hb.x - ow, ch->h.mask_flip ? hb.y + hb.h - bh - ow : hb.y - ow, bw + 2 * ow, bh + 2 * ow};
    int moved = !w->bl_in || rchg || dabs(f.x - w->bframe[0]) > 0.01 || dabs(f.y - w->bframe[1]) > 0.01 ||
                dabs(f.w - w->bframe[2]) > 0.01 || dabs(f.h - w->bframe[3]) > 0.01;
    // пустая полоса: видимая рамка B больше слоя с буфером (приложение ещё не перерисовалось в новый размер)
    int strip = w->fill && c->c_shape && c->path_mut && !w->stretch && (bw > hb.w + 0.5 || bh > hb.h + 0.5);
    double fk[5] = {strip ? bw : 0, strip ? bh : 0, strip ? hb.w : 0, strip ? hb.h : 0, (double)w->fill};
    int fchg = 0;
    for (int i = 0; i < 5; i++) fchg |= dabs(fk[i] - w->fkey[i]) > 0.01;
    if (!strip && !w->bl_fill) fchg = 0;
    // режим 2: окно остаётся «теневым» (клип отрисовки расширен на радиус тени — beyond_bounds.md §1), а саму тень
    // и контур Tahoe гасим на слое Shadow, как только WS их вернёт (переприменяет при смене активности)
    void *shs = *(void **)((char *)cwc + 0x88);
    int fixsh = (d->sys_off == 2 || (d->sys_off == 3 && !c->wm_shadow)) && shs && c->s_shopget &&
                (((msgfr_t)c->msg)(shs, c->s_shopget) > 0.001f || ((msgdr_t)c->msg)(shs, c->sel("borderWidth")) > 0.001);
    if (!moved && !fchg && !tchg && !fixsh && dabs(sop - w->sop) < 0.002) {
        if (an && c->sched_win) c->sched_win(0, win);
        return an;
    }
    unsigned long long tx[4] = {0, 0, 0, 0};
    c->tx_ctor(tx, 1);
    c->tx_add(tx, cactx);
    if (!w->bl_in) {
        // круговые углы и у окна (Hosting), и у колец: у continuous внешняя и внутренняя кривые кольца не
        // концентричны — на углах кольцо «жирнее» прямых участков [жалоба 13:15]
        // форма угла кольца — как у самого окна (Hosting): WS держит свою форму угла окна, а содержимое лежит
        // поверх кольца — видна полоса между краем окна и внешним краем кольца; при разной форме угол «жирнее» [V 13:55]
        c->cur_curve = c->s_curveget ? ((msg0_t)c->msg)(H, c->s_curveget) : 0;
        sweep_old(c, w, root, *(void **)((char *)cwc + 0x88), H);
        border_make(c, w, root);
    }
    if (fixsh) {
        ((msgf_t)c->msg)(shs, c->s_shop, 0.0f);
        ((msgd_t)c->msg)(shs, c->s_bwidth, 0.0);
    }
    if (d->sh_on && !w->bl_sh && c->path_rr && c->path_rel)
        shadow_make(c, w, root, *(void **)((char *)cwc + 0x88));
    if (w->bl_in && w->bl_act) {
        if (moved) {
            struct rect4 fr = ((msgcv_t)c->msg)(H, c->s_convert, f, root);
            ((msgr_t)c->msg)((void *)w->bl_in, c->s_frame, fr);
            ((msgr_t)c->msg)((void *)w->bl_act, c->s_frame, fr);
            void *M = ((msg0_t)c->msg)((void *)w->bl_act, c->s_getmask);
            struct rect4 mf = {0, 0, fr.w, fr.h};
            if (M) ((msgr_t)c->msg)(M, c->s_frame, mf);
            double ro = w->radius + ow;                              // внешний = радиус окна + выступ рамки (spec §5.1)
            ((msgd_t)c->msg)((void *)w->bl_in, c->s_radius, ro);
            if (M) ((msgd_t)c->msg)(M, c->s_radius, ro);
            w->bframe[0] = f.x; w->bframe[1] = f.y; w->bframe[2] = f.w; w->bframe[3] = f.h;
        }
        if (tchg) {
            // встречный кроссфейд: неактивное кольцо гаснет, пока проявляется активное — без грязной смеси
            // «градиент поверх тусклого» в середине (Hyprland смешивает цвета, а не слои)
            fade_to(c, (void *)w->bl_act, c->str_op, c->s_opget, c->s_opacity, op, d->dur, d->bez);
            fade_to(c, (void *)w->bl_in, c->str_op, c->s_opget, c->s_opacity, 1.0 - op, d->dur, d->bez);
        }
        w->bop = op;
    }
    if (fchg) {
        if (strip && !w->bl_fill) {
            void *F = ((msg0_t)c->msg)(c->c_shape, c->s_layer);
            if (F) {
                ((msg0_t)c->msg)(F, c->s_retain);
                keep_top(c, F);
                if (c->str_eo) ((msgp_t)c->msg)(F, c->s_fillrule, c->str_eo);
                ((msgi_t)c->msg)(root, c->s_insert, F, w->bl_sh ? 1 : 0);     // над своей тенью, под окном
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
                double ar = w->radius;                                // буфер скруглён WS (Hosting) — вырезать
                if (ar > hb.w / 2) ar = hb.w / 2;                     // так же, иначе на стыке «зарубки»
                if (ar > hb.h / 2) ar = hb.h / 2;
                c->path_addrr(path, 0, ra, ar, ar);                   // even-odd: буфер вырезан
                ((msgp_t)c->msg)(F, c->s_path, path);
                c->path_rel(path);
            }
            ((void (*)(void *, void *, int))c->msg)(F, c->s_hidden, 0);
        } else if (F) ((void (*)(void *, void *, int))c->msg)(F, c->s_hidden, 1);
        for (int i = 0; i < 5; i++) w->fkey[i] = fk[i];
    }
    if (w->bl_sh) {
        void *S = (void *)w->bl_sh;
        if (moved || w->sop < 0) {
            struct rect4 fr = ((msgcv_t)c->msg)(H, c->s_convert, f, root);
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
    c->tx_dtor(tx);
    if (tchg) { w->act.g[0] = gt; w->act.t0 = te; an = 1; }
    if (c->sched_win) c->sched_win(0, win);
    return an;
}

// Подложка: окно-фон под окном приложения (deco/hyprdeco). Видна только пока окно анимируется:
// ставится ровно на видимую рамку B (сплошной цвет — масштаб без потерь), альфа = альфа окна.
static void put_under(struct ctx *c, struct ch_win *w, int on, double bx, double by, double bw, double bh, double a,
                      double cw, double chh) {
    if (!w->under) return;
    void *uw = c->by_id(w->under);
    if (!uw) { w->under = 0; return; }
    if (!on) w->ub[2] = -1;                              // следующий показ — пересчитать обрезку
    // видна только пустая полоса: рамка B минус видимая часть буфера (bx,by,cw,chh) — под
    // полупрозрачным окном подложки нет, она не затемняет его
    if (on && cw >= bw - 0.5 && chh >= bh - 0.5) on = 0;
    double na = on ? a : 0.0;
    // регионы — только когда полоса изменилась (P13: раньше 3 CGRegion + серверная обрезка каждый кадр)
    if (on && dabs(bx - w->ub[0]) < 0.25 && dabs(by - w->ub[1]) < 0.25 && dabs(bw - w->ub[2]) < 0.25 &&
        dabs(bh - w->ub[3]) < 0.25 && dabs(cw - w->ub[4]) < 0.25 && dabs(chh - w->ub[5]) < 0.25) {
        /* обрезка подложки та же */
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
    free_->m[0] = free_->m[1] = 1.0;           // считаем, что трансформа нет (identity)
    free_->alpha.v[0] = free_->alpha.g[0] = free_->alpha.b[0] = 1.0;
    free_->cur_alpha = 1.0;
    return free_;
}

// Окно — на рабочий стол sid. Последовательность серверного обработчика __XMoveWindowsToManagedSpace [V листинг
// 18719d3c8]: PKGSpaceForID(sid)->+0x18 (managed space) → список окон → PKGWindowsMoveToManagedSpace → free узлов {item, next}.
static void space_move(struct ctx *c, unsigned wid, u64 sid) {
    struct ch *ch = c->ch;
    if (!c->space_for_id || !c->wlist || !c->wmove || !c->xfree) { ch->h.errors++; return; }
    void *win = c->by_id(wid);
    void *conn = win ? *(void **)((char *)win + 0x30) : 0;
    void *sp = conn ? c->space_for_id(sid) : 0;
    void *managed = sp ? *(void **)((char *)sp + 0x18) : 0;
    if (!managed) { ch->h.errors++; return; }
    unsigned ids[1] = {wid};
    void *list = c->wlist(conn, ids, 1);
    c->wmove(conn, list, managed);
    while (list) { void *nx = *(void **)((char *)list + 8); c->xfree(list); list = nx; }
}

struct p8c { u32 wid, src; double t0; u32 live, pending; };   // pending: 1 — снят при order-out, ждёт 0x3e9; 2 — подкладка
#define P8_TAB(c) ((struct p8c *)((char *)(c) + 0x800))
#define P8_N 32
static int p8_make(struct ctx *c, char *src, int pending, double now);

static void apply_cmd(struct ctx *c, struct ch_cmd *k, double now) {
    struct ch *ch = c->ch;
    if (k->op == OP_SPACE) { space_move(c, k->wid, (u64)k->x); return; }
    if (k->op == OP_CFG) {                           // владелец окна = как WS сам шлёт 0x542 (@186d441ac)
        void *win = c->by_id(k->wid);
        void *own = win && c->owner ? c->owner(win) : 0;
        if (!own || !c->post) { ch->h.errors++; return; }
        struct ch_cfgmsg m;
        m.magic = CH_CFG_MAGIC; m.wid = k->wid; m.x = k->x; m.y = k->y; m.w = k->w; m.h = k->h; m.t0 = now;
        c->post(own, CH_CFG_NOTIFY, &m, sizeof m);
        return;
    }
    if (k->op == OP_SNAP) {                          // подкладка-снимок на время хода (только для сжатия)
        char *win = c->by_id(k->wid);
        struct ch_win *sw = slot(c->ch, k->wid, 0);
        int have = 0;
        for (int i = 0; i < P8_N; i++) have |= P8_TAB(c)[i].live && P8_TAB(c)[i].pending == 2 && P8_TAB(c)[i].src == k->wid;
        if (win && sw && !have && c->ch->h.reserved[0] & 1 && ((*(u64 *)(win + 0x928) >> 44) & 1)) {
            u32 was = c->in_cb; c->in_cb = 1;        // свой order не должен будить колбэк закрытия
            p8_make(c, win, 2, now);
            c->in_cb = was;
        }
        return;
    }
    if (k->op == OP_RAISE) {                         // серверный порядок без проверки прав и без активации [V 18705d11c]
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
    if (!w) { ch->h.errors++; return; }
    void *win;
    if (k->op == OP_FORGET) {
        if (actual(c, w, &win)) {
            put_plain(c, w, win);
            if (w->cur_alpha != 1.0) c->set_alpha(0, win, 1.0f, 0.0f);
        } else win = 0;
        slot_free(c, w, win);
        return;
    }
    if (k->op == OP_UNDER) {
        if (w->under && w->under != k->flags) put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0);
        w->under = k->flags; w->ualpha = -1; w->um[0] = w->um[1] = -1; w->ub[2] = -1;
        return;
    }
    if (!actual(c, w, &win)) { post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return; }
    if (k->op == OP_GEOM || k->op == OP_WARP) {
        // покоящееся окно без трансформа синхронизируется с фактической рамкой (его могли
        // подвинуть); если окно держит видимую рамку (settling), видимое положение — переменные
        double a_pos[2] = {w->ax, w->ay}, a_size[2] = {w->aw, w->ah};
        int moving = (w->pos.active | w->size.active) && !w->held;
        if (!w->settling) {
            if (!w->pos.active) warp(&w->pos, 2, a_pos);
            if (!w->size.active) warp(&w->size, 2, a_size);
        }
        double gp[2] = {k->x, k->y}, gs[2] = {k->w, k->h};
        if (k->op == OP_WARP) { warp(&w->pos, 2, gp); warp(&w->size, 2, gs); }
        else {
            if (k->flags & F_FROM) {
                double fp[2] = {k->fx, k->fy}, fs[2] = {k->fw, k->fh};
                warp(&w->pos, 2, fp); warp(&w->size, 2, fs);
            }
            retarget(ch, &w->pos, 2, gp, k->cpos, k->dpos, now);
            retarget(ch, &w->size, 2, gs, k->csize, k->dsize, now);
        }
        if (k->flags & F_MOVE) {                    // реальное окно — сразу в цель (хит-тест, приложению)
            double dx = k->x - w->ax, dy = k->y - w->ay;
            if (dabs(dx) >= 1.0 || dabs(dy) >= 1.0) {
                unsigned wid = w->wid;
                c->move(0, &wid, 1, 0, (float)dx, (float)dy);
                actual(c, w, &win);
            }
        }
        w->radius = c->corner ? c->corner(win) : 0;
        w->a0[0] = w->aw; w->a0[1] = w->ah;           // кадр приложения на старте: до configure
        if (k->op == OP_GEOM && !moving && ch->h.hold_max >= 0) {   // hold_max < 0: не ждать вовсе (Hyprland)
            // Как Wayland: движение из покоя стартует, когда приложение уже прислало кадр нового размера —
            // тогда с первого кадра анимации видно новое содержимое, старое не растягивается. Уже едущее
            // окно не держим: ретаргет без остановки (S6 — иначе «ступеньки» на автоповторе биндов).
            w->held = 1;
            w->needs = dabs(w->aw - k->w) > 2 || dabs(w->ah - k->h) > 2;
            ch->h.holding = 1;
        }
        if (k->flags & F_MOVE) {
            w->geo = 1; w->moved = 0;
            u64 cn = (u64)*(void **)((char *)win + 0x30);   // приложение тайлится — запомнить соединение
            int have = 0;
            for (int i = 0; i < CH_NCONN; i++) have |= ch->conn[i] == cn;
            if (!have && cn) ch->conn[ch->conn_next++ % CH_NCONN] = cn;
        }
        // warp или цель не сдвинулась (анимация не стартовала): сразу сверка рамки — буфер в боксе
        // (обрезка/край), без ложного EV_MOVED у окна, стоящего на своём минимуме
        w->settling = k->op == OP_WARP || !(w->pos.active | w->size.active);
        // ретаргет посреди popin (следующее окно поделило плитку) не переключает показ «растянуто → 1:1»
        // посреди хода — иначе прыжок масштаба [daily_bugs F3]
        if (k->flags & F_STRETCH) w->stretch = 1;
        else if (!(w->stretch && w->size.active)) w->stretch = 0;
        if (k->op == OP_GEOM && (k->flags & F_WAIT)) { w->wait = 1; w->wait_t = now; }
        // сосед открывающегося окна: стоит на старте, пока новое окно не пришлёт кадр размера плитки (≤150 мс),
        // и стартует с его popin в одном кадре — одна волна (как Hyprland: configure до показа)
        if (k->op == OP_GEOM && (k->flags & F_HOLD)) {   // ждёт и новое окно, и свой кадр нового размера
            w->held = 1; w->needs = dabs(w->aw - k->w) > 2 || dabs(w->ah - k->h) > 2; ch->h.holding = 1;
        }
        w->done_t = now;
    } else if (k->op == OP_ALPHA) {
        double ga[1] = {k->a};
        if (k->flags & F_FROM) { double fa[1] = {k->fa}; warp(&w->alpha, 1, fa); }
        retarget(ch, &w->alpha, 1, ga, k->calpha, k->dalpha, now);
    }
}

// Один кадр окна. 1 — окну ещё нужны тики.
static int frame_win(struct ctx *c, struct ch_win *w, double now) {
    struct ch *ch = c->ch;
    if (w->wait) {
        // Открытие как в Hyprland: окно показывается, когда приложение уже нарисовало кадр размера плитки
        // (там размер известен клиенту до первого кадра). До того — невидимо, рамка и альфа стоят на старте.
        void *win;
        if (!actual(c, w, &win)) { post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return 0; }
        int ok = dabs(w->aw - w->size.g[0]) <= ch->h.settle_px && dabs(w->ah - w->size.g[1]) <= ch->h.settle_px;
        if (!ok && now - w->wait_t < (ch->h.hold_max > 0.15 ? ch->h.hold_max : 0.15)) {
            if (w->cur_alpha != 0.0) { c->set_alpha(0, win, 0.0f, 0.0f); w->cur_alpha = 0.0; }
            return 1;
        }
        w->wait = 0;
        double t0 = now - (ch->h.period > 0.004 ? ch->h.period : 1.0 / 60);
        w->pos.t0 = w->size.t0 = w->alpha.t0 = t0;
        w->pos.last = w->size.last = w->alpha.last = t0;
    }
    int was = w->pos.active | w->size.active | w->alpha.active;
    int an;
    if (w->held) {                                  // пачка ждёт кадров приложений: рамка стоит на старте,
        an = 1;                                     // альфа идёт (её держать незачем)
        step(c, &w->alpha, 1, now);
    } else {
        an = step(c, &w->pos, 2, now);
        an |= step(c, &w->size, 2, now);
        an |= step(c, &w->alpha, 1, now);
    }
    void *win;
    if (!actual(c, w, &win)) { put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0); post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); slot_free(c, w, 0); return 0; }

    double a = w->alpha.v[0];
    if (!finite(a)) a = 1.0;
    if (a != w->cur_alpha) {
        c->set_alpha(0, win, (float)(a < 0 ? 0 : a > 1 ? 1 : a), 0.0f);
        w->cur_alpha = a;
    }

    // стабильность буфера: A не менялась N тиков подряд — приложение закончило перерисовку
    if (dabs(w->ax - w->pa[0]) < 0.5 && dabs(w->ay - w->pa[1]) < 0.5 && dabs(w->aw - w->pa[2]) < 0.5 && dabs(w->ah - w->pa[3]) < 0.5)
        w->stable++;
    else { w->stable = 0; w->pa[0] = w->ax; w->pa[1] = w->ay; w->pa[2] = w->aw; w->pa[3] = w->ah; }

    double bx = w->pos.v[0], by = w->pos.v[1], bw = w->size.v[0], bh = w->size.v[1];
    if (!an) {
        // конец popin, а буфер ещё не размера плитки: держать растяжение, пока приложение рисует (буфер меняется),
        // но не дольше ~150 мс стабильного буфера — иначе «растянуто → 1:1» за кадр [F3]
        if (w->stretch && (dabs(w->aw - bw) > 1 || dabs(w->ah - bh) > 1) && w->stable < 9) {
            if (was) { w->done_t = now; post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah); }
            w->settling = 1;                          // дальше — обычная сверка «буфер в боксе», без ложного EV_MOVED
            an = 1;
            goto show;
        }
        w->stretch = 0;
        if (was) { w->done_t = now; w->settling = 1; post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah); }
        if (!w->settling) {
            // покой: окно ушло с цели (приложение/система сами двинули) — сообщить демону один раз (S4)
            if (w->geo && !w->moved && (dabs(w->ax - w->pos.g[0]) > 1.5 || dabs(w->ay - w->pos.g[1]) > 1.5 ||
                                        dabs(w->aw - w->size.g[0]) > ch->h.settle_px || dabs(w->ah - w->size.g[1]) > ch->h.settle_px)) {
                w->moved = 1;
                post_evt(ch, EV_MOVED, w->wid, now, w->ax, w->ay, w->aw, w->ah);
            }
            return 0;
        }
        // Конец без ожидания (как Hyprland: после анимации — реальный буфер в боксе плитки):
        // рамка дошла и совпадает с буфером — окно как есть, обрезка и подложка сняты.
        int fits = dabs(w->aw - bw) <= 1.0 && dabs(w->ah - bh) <= 1.0 && dabs(w->ax - bx) <= 1.0 && dabs(w->ay - by) <= 1.0;
        if (fits) {
            put_plain(c, w, win);
            w->settling = 0;
            post_evt(ch, EV_SETTLED, w->wid, now, w->ax, w->ay, w->aw, w->ah);
            return 0;
        }
        // не совпадает: приложение не встало ровно в плитку (минимум, сетка символов) — как Hyprland,
        // буфер остаётся в боксе плитки: больше — обрезан по B, меньше — край закрыт цветом края окна.
        // Соседи не двигаются. Обрезка держится, пока буфер не совпадёт с B (простой тик проверяет).
        an = w->stable < 2;
    }
show:
    if (!(bw >= 1) || !(bh >= 1) || !finite(bx) || !finite(by)) { put_plain(c, w, win); return an; }
    // Содержимое в видимой рамке B — как Hyprland при resize: буфер 1:1 от левого верхнего угла,
    // лишнее обрезано сервером по B. Никакого растяжения (кроме открытия — stretch): буфер
    // не меньше рамки обеспечивает демон (растущей оси размер сразу, сжимающейся — в конце).
    // Растяжение — только у popin открытия (как m_animatingIn в Hyprland). При resize пачка стартует,
    // когда приложение уже прислало кадр нового размера (held), поэтому старый кадр не тянется.
    int old = 0;
    int st = w->stretch || old;
    double sx = st ? w->aw / bw : 1.0, sy = st ? w->ah / bh : 1.0;
    if (sx < 0.02 || sx > 50 || sy < 0.02 || sy > 50) { put_plain(c, w, win); return an; }
    if (dabs(bw - w->aw) < 0.01 && dabs(bh - w->ah) < 0.01 && dabs(bx - w->ax) < 0.01 && dabs(by - w->ay) < 0.01) {
        put_plain(c, w, win);
    } else {
        // Без масштаба: показывается только настоящий буфер 1:1. Где буфер больше рамки — обрезка по B;
        // где меньше (приложение не успело перерисоваться) — край окна ждёт буфер, а не растягивает его.
        // Как Hyprland: буфер 1:1 от левого верхнего угла рамки, видна часть B∩A; пустое место
        // (буфер ещё меньше рамки) закрывает подложка цвета фона окна — без растяжения и без ожидания.
        double cw = bw < w->aw ? bw : w->aw, ch_ = bh < w->ah ? bh : w->ah;
        put_xform(c, w, sx, sy, (w->ax - bx) * sx, (w->ay - by) * sy);
        int crop = !st && (dabs(cw - w->aw) > 0.5 || dabs(ch_ - w->ah) > 0.5);
        if (use_mask(c, w)) { put_clip(c, w, win, 0, 0, 0, 0, 0); put_mask(c, w, win, crop, cw, ch_); }
        else { put_mask(c, w, win, 0, 0, 0); put_clip(c, w, win, crop, bx, by, cw, ch_); }
        put_under(c, w, !st, bx, by, bw, bh, w->cur_alpha, cw, ch_);
    }
    return an;          // покой (в т.ч. «окно не ровно в плитке» со стабильным буфером) — без покадровых тиков
}

// Сетка кадров: из кэша развёртки WS (он может быть старым — фаза при этом верна) берём
// период T и момент развёртки; te — ближайшая развёртка не раньше now+margin. Все значения
// кадра считаются на te (момент показа), а не на время срабатывания таймера: опоздание
// таймера на несколько мс не сдвигает выборку, шаг по времени ровно T.
static double frame_grid(struct ctx *c, double now, double *T_out) {
    double p = 0, n = 0;
    if (c->vbl) c->vbl(c->display, &p, &n);
    double T = n - p;
    if (!(T > 0.004 && T < 0.05)) { T = 1.0 / 60; n = now; }
    double lim = now + c->ch->h.margin;
    double k = (double)(long)((lim - n) / T);
    double te = n;
    if (k > -1e7 && k < 1e7) te += k * T;
    while (te <= lim) te += T;
    while (te - T > lim) te -= T;
    *T_out = T;
    return te;
}

// ── П8: снимок закрытия (close_clone.md) ───────────────────────────────────────────────────────────────
// Настройки от демона: reserved[0] бит0 — колбэк, бит1 — клон (иначе только журнал), биты 8–15 кривая размера,
// 16–23 кривая альфы; reserved[1]/[2] — длительности (double), reserved[3] — k popin (double).
#define P8_ON(c) ((unsigned char *)(c) + 0xc00)      // бит «на экране» ведомых окон на прошлой проверке (по слоту)
static double hd(struct ch *ch, int i) { double v; __builtin_memcpy(&v, &ch->h.reserved[i], 8); return v; }

static void p8_free_win(struct ctx *c, char *cl) {
    *(u64 *)(cl + 0x928) &= ~(1ull << 54);           // иначе release_window только обнулит владельца [V]
    c->rel_win(*(void **)(cl + 0x30), cl);           // владелец NULL; наш колбэк отсечёт по владельцу
}

// Клон окна src: на место видимой рамки, уровень источника, поверх; слот движка (stretch) без анимации. → индекс или -1
static int p8_make(struct ctx *c, char *src, int pending, double now) {   // pending: 0 уход, 1 ждёт 0x3e9, 2 подкладка
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
    // защита от повторного входа охватывает И клон, И order: order сам шлёт 0x3ea → наш колбэк. Раньше флаг
    // сбрасывался до order → рекурсия клонов → переполнение стека WS [V крэш 12:33:20]
    u32 was = c->in_cb;
    c->in_cb = 1;
    char *cl = c->clone(src, fr, disp, 1);
    if (!cl) { c->in_cb = was; return -1; }
    c->set_level(cl, 0, *(int *)(src + 0x20), *(short *)(src + 0x28));
    unsigned cwid = c->get_id(cl);
    if (pending == 2) c->order(0, cwid, -1, *(unsigned *)src);   // подкладка — под окном
    else c->order(0, cwid, 1, pending ? 0 : *(unsigned *)src);  // ушедшее с экрана — поверх своего уровня
    c->in_cb = was;
    struct ch_win *w = slot(ch, cwid, 1);
    if (!w) { p8_free_win(c, cl); return -1; }
    double cur[2] = {fr.x, fr.y}, sz[2] = {fr.w, fr.h};
    warp(&w->pos, 2, cur); warp(&w->size, 2, sz);
    w->ax = fr.x; w->ay = fr.y; w->aw = fr.w; w->ah = fr.h;
    w->stretch = 1;
    struct p8c *e = &P8_TAB(c)[k];
    e->wid = cwid; e->src = *(unsigned *)src; e->t0 = now; e->live = 1; e->pending = pending;
    return k;
}

// Запуск ухода клона: popin k% + fadeOut по кривым конфига; соседям — EV_GONE в этом же цикле демона.
static void p8_go(struct ctx *c, int k, double now) {
    struct ch *ch = c->ch;
    struct p8c *e = &P8_TAB(c)[k];
    struct ch_win *w = slot(ch, e->wid, 0);
    e->pending = 0; e->t0 = now;
    if (w) {
        double kk = hd(ch, 3) > 0.3 ? hd(ch, 3) : 0.92;
        double fx = w->pos.v[0], fy = w->pos.v[1], fw = w->size.v[0], fh = w->size.v[1];
        double tp[2] = {fx + fw * (1 - kk) / 2, fy + fh * (1 - kk) / 2}, ts[2] = {fw * kk, fh * kk};
        u32 cs = (ch->h.reserved[0] >> 8) & 0xff, ca = (ch->h.reserved[0] >> 16) & 0xff;
        retarget(ch, &w->pos, 2, tp, cs, hd(ch, 1), now);
        retarget(ch, &w->size, 2, ts, cs, hd(ch, 1), now);
        double z[1] = {0.0};
        retarget(ch, &w->alpha, 1, z, ca, hd(ch, 2), now);
    }
    c->nclone++;
    post_evt(ch, EV_CLONE, e->wid, now, e->src, 0, 0, 0);
    post_evt(ch, EV_GONE, e->src, now, 0, 0, 0, 0);
    if (!c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, now);
}

// 0x3ea (конец операции упорядочивания): какое ведомое тайловое окно ушло с экрана (бит 44: 1→0) — снять его
// содержимое сейчас, до кадра (AppKit при закрытии сначала убирает окно, release — через ~70 мс [V 12:30]).
static void p8_order_done(struct ctx *c) {
    struct ch *ch = c->ch;
    // вкладки: в той же операции окно того же приложения вышло на экран (0→1) — это смена вкладки, не закрытие
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
        P8_ON(c)[i] = (unsigned char)on;              // до клона: вложенный вызов не увидит тот же переход 1→0
        if (was && !on && !tab && win && *(void **)(win + 0x30) && *(int *)(win + 0x20) == 0 &&
            w->cur_alpha > 0.05 && w->alpha.g[0] > 0.05 && (ch->h.reserved[0] & 2))
            p8_make(c, win, 1, ch->h.now);
    }
    for (int i = 0; i < CH_NW; i++) {                 // запомнить «на экране» всех слотов после операции
        struct ch_win *w = &ch->win[i];
        char *win = w->used ? c->by_id(w->wid) : 0;
        P8_ON(c)[i] = (unsigned char)(win && ((*(u64 *)(win + 0x928) >> 44) & 1));
    }
}

// Колбэк 0x3e9 (release_window) и 0x3ea (finish_order_windows): синхронно, главный поток WS. Подпись IA/0 (blraaz).
void anim_will_release(u32 type, void *data, unsigned long len, struct ctx *c) {
    if (c->dead || c->in_cb) return;
    struct ch *ch = c->ch;
    if (ch->h.magic != CH_MAGIC || ch->h.stop || !(ch->h.reserved[0] & 1)) return;
    if (type == 0x3ea) { c->in_cb = 1; p8_order_done(c); c->in_cb = 0; return; }
    if (type != 0x3e9 || !data || len != 8) return;
    char *src = data;
    if (!*(void **)(src + 0x30)) return;                       // серверное окно / наш клон
    unsigned swid = *(unsigned *)src;
    int on = (int)((*(u64 *)(src + 0x928) >> 44) & 1), lvl = *(int *)(src + 0x20);
    struct ch_win *sw = slot(ch, swid, 0);
    post_evt(ch, EV_REL, swid, ch->h.now, on, 1, lvl, (sw ? 1 : 0) + (sw && sw->geo ? 2 : 0));
    if (!(ch->h.reserved[0] & 2) || lvl != 0) return;
    for (int i = 0; i < P8_N; i++) {                           // снят при order-out — это закрытие: в путь
        struct p8c *e = &P8_TAB(c)[i];
        if (e->live && e->pending && e->src == swid) { p8_go(c, i, ch->h.now); return; }
    }
    if (!on || !sw || !sw->geo) { if (!on) c->nskip++; return; }
    if (sw->alpha.g[0] < 0.05 || sw->cur_alpha < 0.05) return; // close_anim демона уже погасил
    int k = p8_make(c, src, 0, ch->h.now);                     // ещё на экране (путь А)
    if (k >= 0) p8_go(c, k, ch->h.now);
}

// Тик: регистрация колбэка и освобождение клонов, чья анимация кончилась (или всех — при остановке).
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
        if (e->pending == 2) {                       // подкладка: пока окно едет (и пока не встало в бокс)
            struct ch_win *sw = slot(ch, e->src, 0);
            done = stopping || !sw || now - e->t0 > 2.0 ||
                   (!(sw->pos.active | sw->size.active) && (!sw->settling || sw->stable >= 3));
        } else if (e->pending) {                     // не закрытие (Cmd+H, свёртывание, вкладка) — снять:
            void *sw = c->by_id(e->src);             // 0x3e9 не пришёл за 120 мс, или окно снова на экране
            done = stopping || now - e->t0 > 0.12 || (sw && ((*(u64 *)((char *)sw + 0x928) >> 44) & 1));
        } else done = stopping || !w || !(w->pos.active | w->size.active | w->alpha.active) || now - e->t0 > 2.0;
        if (!done) continue;
        char *cl = c->by_id(e->wid);
        if (w) w->used = 0;
        if (cl && !*(void **)(cl + 0x30)) p8_free_win(c, cl);
        e->live = 0;
    }
}

// Подкладка-снимок (OP_SNAP) под окном: как Hyprland при боксе больше буфера — крайние пиксели тянутся на полосу.
// Одна ось: последняя строка/столбец снимка растянута на ширину полосы, обрезка — полоса. Обе оси: снимок целиком
// на B, обрезка по B (окно поверх закрывает свою часть). Слот клона сам не анимируется (trans/clip/альфа — здесь).
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
    // тянется строка/столбец в 8 pt от края: у самого края — стекло и контур окна Tahoe («небесная» полоса)
    double ry = uh > 16 ? uh - 8 : uh - 1, rx = uw > 16 ? uw - 8 : uw - 1;
    if (gh > 0.5 && gw <= 0.5) { tx0 = bx; tw = bw; th = uh * gh; ty0 = by + ah - ry * gh; kx = bx; ky = by + ah; kw = bw; kh = gh; }
    else if (gw > 0.5 && gh <= 0.5) { ty0 = by; th = bh; tw = uw * gw; tx0 = bx + aw - rx * gw; kx = bx + aw; ky = by; kw = gw; kh = bh; }
    else if (gw > 0.5 && gh > 0.5) { tx0 = bx; ty0 = by; tw = bw; th = bh; kx = bx; ky = by; kw = bw; kh = bh; }
    else { show = 0; tx0 = ux; ty0 = uy; tw = uw; th = uh; kx = ky = kw = kh = 0; }
    double a = show ? sw->cur_alpha : 0.0, av[1] = {a};
    warp(&cw->alpha, 1, av);                      // frame_win клона иначе вернул бы альфу переменной слота
    if (a != cw->cur_alpha) { c->set_alpha(0, cl, (float)(a < 0 ? 0 : a > 1 ? 1 : a), 0.0f); cw->cur_alpha = a; }
    if (!show || !(tw >= 0.01) || !(th >= 0.01) || !finite(tx0) || !finite(ty0)) return;
    double sx = uw / tw, sy = uh / th;
    put_xform(c, cw, sx, sy, (ux - tx0) * sx, (uy - ty0) * sy);
    put_clip(c, cw, cl, 1, kx, ky, kw, kh);
}

void anim_tick(struct ctx *c, double now) {
    struct ch *ch = c->ch;
    struct ch_hdr *h = &ch->h;
    // канал не тот (другая версия структуры) — остановиться, ничего не читая дальше
    if ((h->stop || c->dead) && c->cb_on) p8_tick(c, 1, now);   // снять колбэк, освободить клоны
    if (h->stop && !c->dead && !c->cleaned && h->magic == CH_MAGIC) {
        // остановка (переустановка/стоп демона): снять с окон всё своё — трансформ, маску, рамку, тень, радиус
        c->cleaned = 1;
        for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (!w->used) continue;
            void *win = c->by_id(w->wid);
            if (!win) continue;
            put_plain(c, w, win);
            void *cwc = *(void **)((char *)win + 0x18);
            layers_drop(c, w, cwc ? *(void **)((char *)cwc + 0x38) : 0);
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
    h->period = T;
    h->te = te;

    u32 head = __atomic_load_n(&h->cmd_head, __ATOMIC_ACQUIRE), tail = h->cmd_tail;
    if (head - tail > CH_NCMD) { tail = head - CH_NCMD; h->errors++; }
    // t0 пачки = момент показа прошлого кадра (te − T): первый показанный кадр анимации — ровно
    // через один период после старта, без скачка на 1–2 кадра (Hyprland стартует в кадре события)
    double t0 = te - T;
    if (t0 > now) t0 = now;
    for (; tail != head; tail++) apply_cmd(c, &ch->cmd[tail % CH_NCMD], t0);
    __atomic_store_n(&h->cmd_tail, tail, __ATOMIC_RELEASE);

    // Новые окна: номера окон на сервере только растут — проверить следующие за наибольшим виденным.
    // Окно видно с момента создания, раньше, чем приложение его покажет: демон успевает его спрятать.
    if (h->wid_max) {
        u32 m = h->wid_max, miss = 0;
        for (u32 id = h->wid_max + 1; id <= h->wid_max + 64 && miss < 24; id++) {
            void *nw = c->by_id(id);
            if (!nw) { miss++; continue; }
            miss = 0; m = id;
            if (!*(void **)((char *)nw + 0x30)) continue;   // серверное окно (наш клон закрытия и т.п.) — не новое
            // окно уровня 0 (обычное: *(int*)(win+0x20) — так читает __XGetWindowLevel) от тайлового
            // приложения — невидимо до первого показа: иначе приложение успевает показать его на «своём»
            // месте раньше, чем демон (16+ мс) решит, куда его ставить
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
                    pre = 1;
                }
            }
            post_evt(ch, EV_NEW, id, now, pre, 0, 0, 0);
        }
        h->wid_max = m;
    }

    // Старт пачки: все окна ждут, пока каждое, которому сменили размер, пришлёт кадр нового размера
    // (или hold_max); потом все стартуют в одном кадре с t0 = прошлый показанный кадр.
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
        int opening = 0;                             // в пачке открытие (F_WAIT): ждём его кадр — не дольше 150 мс
        for (int i = 0; i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (!w->used || !w->wait) continue;
            opening = 1;
            void *win;
            if (!actual(c, w, &win)) continue;
            if (!(dabs(w->aw - w->size.g[0]) <= h->settle_px && dabs(w->ah - w->size.g[1]) <= h->settle_px)) wait = 1;
        }
        double lim = opening ? (h->hold_max > 0.15 ? h->hold_max : 0.15) : h->hold_max > 0 ? h->hold_max : 0.017;   // не дольше кадра: Hyprland стартует сразу
        if (!wait || now - h->hold_t > lim) {
            double t0 = te - T;
            if (t0 > now) t0 = now;
            for (int i = 0; i < CH_NW; i++) {
                struct ch_win *w = &ch->win[i];
                if (!w->used || !w->held) continue;
                w->held = 0;
                w->pos.t0 = w->size.t0 = w->alpha.t0 = t0;
                w->pos.last = w->size.last = w->alpha.last = t0;
                w->a0[0] = w->aw; w->a0[1] = w->ah;
            }
            h->holding = 0; h->hold_t = 0;
        }
    }

    for (int i = 0; i < P8_N; i++) {                 // подкладки: дотяжка края окна в полосу «бокс B минус буфер»
        struct p8c *e = &P8_TAB(c)[i];
        if (!e->live || e->pending != 2) continue;
        struct ch_win *sw = slot(ch, e->src, 0), *cw = slot(ch, e->wid, 0);
        if (sw && cw) snap_frame(c, cw, sw);
    }
    u32 n = 0;
    for (int i = 0; i < CH_NW; i++) {
        struct ch_win *w = &ch->win[i];
        if (!w->used) continue;
        int a = frame_win(c, w, te);
        n += a;
        if (a && w->used) {                          // журнал траектории (П0): видимая рамка и альфа на te
            struct ch_traj *r = &ch->traj[h->traj_head % CH_NTRAJ];
            r->te = te; r->wid = w->wid; r->bx = w->pos.v[0]; r->by = w->pos.v[1];
            r->bw = w->size.v[0]; r->bh = w->size.v[1]; r->alpha = w->cur_alpha;
            __atomic_store_n(&h->traj_head, h->traj_head + 1, __ATOMIC_RELEASE);
        }
    }
    {                                                // рамки: и в покое (фокус), CA — только при изменении
        int ok = deco_ready(c);
        for (int i = 0; ok && i < CH_NW; i++) {
            struct ch_win *w = &ch->win[i];
            if (w->used) n += border_win(c, w, te);
        }
    }
    p8_tick(c, 0, te);
    for (int i = 0; i < P8_N; i++) n += P8_TAB(c)[i].live;
    h->nactive = n;
    if (n) {                                         // ровность сетки кадров: шаг te должен быть ровно T
        if (h->te_prev > 0 && dabs(te - h->te_prev - T) > 0.25 * T) h->te_skips++;
        h->te_prev = te;
        if (now - (te - T) > 0.6 * T) h->ticks_late++;   // тик опоздал в своём кадре (только при анимации)
    } else h->te_prev = 0;
    if (c->mabs) {
        double us = (double)(c->mabs() - t_in) * c->mabs_us;
        h->tick_us_last = us;
        if (us > h->tick_us_max) h->tick_us_max = us;
    }
    c->running = n != 0;
    double at;
    if (n) at = te + T * h->phase;      // следующий кадр: через phase периода после развёртки te
    else at = now + (h->idle_poll > 0.002 ? h->idle_poll : 0.008);
    c->resched(c->queue, c->self, c, c->session, 1, 1, at);
}

// metalCallbacks: (x0=MetalContext*, x1=&shared_ptr<Display>, x2=0, x3=ctx)
void anim_frame(void *mctx, void *disp, void *z, struct ctx *c) {
    if (c->dead) return;
    c->ch->h.frames++;
    if (c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, 0.0);
}
