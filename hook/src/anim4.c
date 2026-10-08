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
};

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
        double ms = (double)(long)((now - v->t0) * 1000.0);          // ms целые, как duration_cast
        double pct = v->dur > 0 ? ms / (v->dur * 1000.0) : 1.0;
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

// Подложка: окно-фон под окном приложения (deco/hyprdeco). Видна только пока окно анимируется:
// ставится ровно на видимую рамку B (сплошной цвет — масштаб без потерь), альфа = альфа окна.
static void put_under(struct ctx *c, struct ch_win *w, int on, double bx, double by, double bw, double bh, double a,
                      double cw, double chh) {
    if (!w->under) return;
    void *uw = c->by_id(w->under);
    if (!uw) { w->under = 0; return; }
    // видна только пустая полоса: рамка B минус видимая часть буфера (bx,by,cw,chh) — под
    // полупрозрачным окном подложки нет, она не затемняет его
    if (on && cw >= bw - 0.5 && chh >= bh - 0.5) on = 0;
    double na = on ? a : 0.0;
    if (on) {
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

static void apply_cmd(struct ctx *c, struct ch_cmd *k, double now) {
    struct ch *ch = c->ch;
    struct ch_win *w = slot(ch, k->wid, k->op != OP_FORGET);
    if (!w) { ch->h.errors++; return; }
    void *win;
    if (k->op == OP_FORGET) {
        if (actual(c, w, &win)) {
            put_plain(c, w, win);
            if (w->cur_alpha != 1.0) c->set_alpha(0, win, 1.0f, 0.0f);
        }
        w->used = 0;
        return;
    }
    if (k->op == OP_UNDER) {
        if (w->under && w->under != k->flags) put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0);
        w->under = k->flags; w->ualpha = -1; w->um[0] = w->um[1] = -1;
        return;
    }
    if (!actual(c, w, &win)) { post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); w->used = 0; return; }
    if (k->op == OP_GEOM || k->op == OP_WARP) {
        // покоящееся окно без трансформа синхронизируется с фактической рамкой (его могли
        // подвинуть); если окно держит видимую рамку (settling), видимое положение — переменные
        double a_pos[2] = {w->ax, w->ay}, a_size[2] = {w->aw, w->ah};
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
        if (k->op == OP_GEOM) {
            // Как Wayland: движение стартует, когда приложение уже прислало кадр нового размера —
            // тогда с первого кадра анимации видно новое содержимое, старое не растягивается.
            w->held = 1;
            w->needs = dabs(w->aw - k->w) > 2 || dabs(w->ah - k->h) > 2;
            ch->h.holding = 1;
        }
        w->settling = k->op == OP_WARP;           // warp: сразу показать цель, дождаться размера
        w->stretch = (k->flags & F_STRETCH) != 0;
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
    int was = w->pos.active | w->size.active | w->alpha.active;
    int an;
    if (w->held) {                                  // пачка ждёт кадров приложений: рамка стоит на старте
        an = 1;
    } else {
        an = step(c, &w->pos, 2, now);
        an |= step(c, &w->size, 2, now);
        an |= step(c, &w->alpha, 1, now);
    }
    void *win;
    if (!actual(c, w, &win)) { put_under(c, w, 0, 0, 0, 0, 0, 0, 0, 0); post_evt(ch, EV_GONE, w->wid, now, 0, 0, 0, 0); w->used = 0; return 0; }

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
        w->stretch = 0;
        if (was) { w->done_t = now; w->settling = 1; post_evt(ch, EV_DONE, w->wid, now, w->ax, w->ay, w->aw, w->ah); }
        if (!w->settling) return 0;
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
        put_clip(c, w, win, crop, bx, by, cw, ch_);
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

void anim_tick(struct ctx *c, double now) {
    struct ch *ch = c->ch;
    struct ch_hdr *h = &ch->h;
    // канал не тот (другая версия структуры) — остановиться, ничего не читая дальше
    if (c->dead || h->magic != CH_MAGIC || h->size != (u32)sizeof(struct ch) || h->stop) { c->running = 0; return; }
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
            post_evt(ch, EV_NEW, id, now, 0, 0, 0, 0);
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
        double lim = h->hold_max > 0 ? h->hold_max : 0.017;   // не дольше кадра: Hyprland стартует сразу
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

    u32 n = 0;
    for (int i = 0; i < CH_NW; i++)
        if (ch->win[i].used) n += frame_win(c, &ch->win[i], te);
    h->nactive = n;
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
