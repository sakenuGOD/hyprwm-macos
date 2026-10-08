// Покадровый тик анимации окон внутри WindowServer (таймер _gMainThreadQueue).
// Колбэк: run_timer_pass -> blraaz fn(x0=ctx, d0=now). Таймер одноразовый.
// Синхронизация с кадром: anim_frame висит в metalCallbacks (зовётся из composite() раз за кадр,
// на главном потоке внутри update_display_callback) и лишь ставит anim_tick в очередь "сейчас" —
// тик выполняется сразу после кадра N, кадр N+1 берёт новый трансформ: ровно шаг на кадр.
// policy=1 — заменяет уже стоящий таймер (fn,ctx), оставляя более раннее время: без дублей.
// Сам тик ставит лишь страховочный таймер на +fallback (если кадр не придёт).
// Модель: окно уже стоит в конечной позиции (CGXMoveWindowList), визуальный сдвиг x/y
// (old - new) гасится пружиной Hyprland (drift: m1 k210 d24). Трансформ окна мапит экран->окно,
// поэтому translate = -offset. offset=0 -> identity -> слот удаляется сервером.
// Сборка: clang -arch arm64e -O2 -ffreestanding -fno-builtin -fno-stack-protector -c; без релокаций.

typedef void (*set_xform_fn)(void *conn, unsigned *wid, unsigned *key, double *m);
typedef double (*d1_fn)(double);
typedef void (*resched_fn)(void *queue, void *fn, void *ctx, void *session, int policy, int nodelay, double at);

// Пружина Hyprland (hyprutils advanceSpring): нормированное value 0->1, аналитика,
// затухание недодемпфированного осциллятора. value применяем к исходному вектору сдвига.
struct Win {            // 0x40
    unsigned wid, active;
    double x0, y0;      // исходный визуальный сдвиг (экранные pt)
    double v, vel;      // value и его скорость (нормированные, как у Hyprland)
    double pad;
};

struct Ctx {
    set_xform_fn set_xform;   // 0x00  IA/0
    resched_fn   resched;     // 0x08  IA/0
    void        *self;        // 0x10  IA/0 (этот колбэк)
    void        *queue;       // 0x18  &gMainThreadQueue
    void        *session;     // 0x20  (*__sessionControlRef)->+0x20
    double       k, d;        // 0x28, 0x30  stiffness / damping (mass = 1)
    double       last;        // 0x38
    unsigned     key, n;      // 0x40, 0x44
    double       frame;       // 0x48  dt первого шага, сек
    unsigned     ticks, running; // 0x50, 0x54
    d1_fn        f_exp, f_sin, f_cos; // 0x58, 0x60, 0x68  IA/0 (libSystem)
    double       eps;         // 0x70  порог Hyprland (value и velocity), 0.001
    double       one;         // 0x78  = 1.0 (из ctx: иначе компилятор заводит __literal16)
    struct Win   w[16];       // 0x80
};

void anim_tick(struct Ctx *c, double now) {
    double dt = c->last > 0 ? now - c->last : c->frame;
    if (dt < 0 || dt > 0.05) dt = c->frame;
    c->last = now;
    c->ticks++;

    const double w0 = c->k > 0 ? c->k : 1;      // omega0^2 = k/m, m = 1
    const double g = c->d * 0.5;                // gamma = d/(2m)
    const double wd2 = w0 - g * g;              // omega_d^2
    unsigned any = 0;

    for (unsigned i = 0; i < c->n; i++) {
        struct Win *w = &c->w[i];
        if (!w->active) continue;

        if (wd2 > 0) {                          // недодемпфированный случай (drift, bounce)
            double wdv = wd2, r = wdv;          // sqrt без libm: Ньютон
            for (int it = 0; it < 24; it++) r = 0.5 * (r + wdv / r);
            double disp = w->v - 1.0;
            double e = c->f_exp(-g * dt), sn = c->f_sin(r * dt), cs = c->f_cos(r * dt);
            double nd = e * ((disp * cs) + (((w->vel + g * disp) / r) * sn));
            w->vel = e * ((w->vel * cs) - (((g * w->vel) + (w0 * disp)) / r) * sn);
            w->v = 1.0 + nd;
        } else {                                // критический/передемпфированный: шаговый интегратор
            const double h = 1.0 / 480;
            int steps = (int)(dt / h) + 1;
            double hs = dt / steps;
            for (int s2 = 0; s2 < steps; s2++) {
                double disp = w->v - 1.0;
                w->vel += (-c->k * disp - c->d * w->vel) * hs;
                w->v += w->vel * hs;
            }
        }

        double dv = w->v - 1.0, av = dv < 0 ? -dv : dv;
        double sp = w->vel < 0 ? -w->vel : w->vel;
        double x, y;
        if (av <= c->eps && sp <= c->eps) {     // порог Hyprland
            w->v = 1.0; w->vel = 0.0; w->active = 0;
            x = 0; y = 0;
        } else {
            any = 1;
            x = w->x0 * (1.0 - w->v);           // value 0 -> полный сдвиг, 1 -> на месте
            y = w->y0 * (1.0 - w->v);
        }
        // volatile + поэлементно: иначе компилятор кладёт константу в __literal16
        // и адресует её через adrp (релокация) — в инжектируемом блобе её нет.
        volatile double m[16];
        for (int j = 0; j < 16; j++) m[j] = 0.0;
        double one = c->one;
        m[0] = one; m[5] = one; m[10] = one; m[15] = one;
        m[12] = -x; m[13] = -y;
        unsigned wid = w->wid, key = c->key;
        c->set_xform(0, &wid, &key, (double *)m);
    }

    c->running = any;
    if (any) c->resched(c->queue, c->self, c, c->session, 1, 1, now + 0.05);
    else c->last = 0;
}

// metalCallbacks: (x0=MetalContext*, x1=&shared_ptr<Display>, x2=0, x3=ctx)
void anim_frame(void *mctx, void *disp, void *z, struct Ctx *c) {
    if (c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, 0.0);
}
