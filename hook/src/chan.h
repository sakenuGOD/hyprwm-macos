// Общая память демон <-> движок в WindowServer (/tmp/hyprwm/chan, mmap MAP_SHARED с обеих сторон).
// Демон пишет команды в кольцо cmd и публикует cmd_head одним атомарным store (release):
// всё, что опубликовано одной публикацией, движок применяет в ОДНОМ тике с одним t0 —
// как в Hyprland, где все переменные одного события стартуют в одном тике.
// Движок пишет состояние окон (wins), события (evt) и пульс (ticks/now).
#pragma once

typedef unsigned int u32;
typedef unsigned long long u64;

#define CH_MAGIC  0x3530574d52505948ULL   // "HYPRWM05"
#define CH_NW     64
#define CH_NCURVE 16
#define CH_NCMD   256
#define CH_NEVT   128
#define CH_BAKED  255

enum { CV_NONE = 0, CV_BEZIER = 1, CV_SPRING = 2 };
enum { OP_GEOM = 1, OP_ALPHA = 2, OP_FORGET = 3, OP_WARP = 4, OP_UNDER = 5 };   // UNDER: k.flags = wid подложки
enum { F_FROM = 1, F_MOVE = 2, F_STRETCH = 4 };   // STRETCH: содержимое тянется на B (открытие, как m_animatingIn)           // флаги OP_GEOM / OP_ALPHA
enum { EV_GONE = 1, EV_SETTLED = 2, EV_DONE = 3, EV_NEW = 4 };   // NEW: на сервере появилось окно (номера растут)   // DONE: видимые анимации окна кончились (B = цель)

struct ch_curve {                // 0x1010
    u32 type, pad;
    double mass, k, d;           // spring
    double bx[CH_BAKED], by[CH_BAKED];   // bezier: запечённые точки t=(i+1)/255, как hyprutils
};

struct ch_cmd {                  // 0x88
    u32 op, wid, flags, cpos, csize, calpha, pad0, pad1;
    double x, y, w, h;           // цель (глобальные pt, начало сверху слева)
    double fx, fy, fw, fh;       // откуда (F_FROM)
    double dpos, dsize, dalpha;  // длительность bezier, с (speed*100 мс)
    double a, fa;                // альфа: цель / откуда (F_FROM)
};

struct ch_var {                  // 0x70
    double b[2], g[2], v[2];     // begun / goal / value
    double sv, svel;             // нормированное значение пружины и скорость
    double t0, last, dur;        // начало, последний шаг пружины, длительность bezier
    u32 curve, active;
};

struct ch_win {                  // 0x1d8
    u32 wid, used, settling, clipped;   // clipped: стоит серверная обрезка по видимой рамке
    struct ch_var pos, size, alpha;
    double ax, ay, aw, ah;       // фактическая рамка окна на сервере (последний тик)
    double m[4];                 // применённый трансформ: sx, sy, tx, ty
    double done_t;               // когда закончились анимации (ожидание размера от приложения)
    double cur_alpha;            // применённая альфа
    double clip[4];              // последняя поставленная обрезка (глобальные pt)
    u32 stretch, under;          // stretch: тянуть содержимое на B (открытие); under: wid подложки (0 — нет)
    double um[4];                // применённый трансформ подложки
    double ualpha;               // применённая альфа подложки
    double radius;               // радиус скругления окна у сервера (resolved_corner_radius)
    double pa[4];                // A прошлого тика
    u32 stable, pad3;            // сколько тиков подряд A не менялась
    double a0[2];                // размер буфера в момент старта анимации (старый кадр приложения)
    u32 held, needs;             // held: ждёт старта пачки; needs: ждём от приложения кадр нового размера
};

struct ch_evt { u32 type, wid; double t, x, y, w, h; };   // 0x30

struct ch_hdr {                  // 0x100
    u64 magic;
    u32 version, size;
    u32 cmd_head;                // пишет демон (release)
    u32 cmd_tail;                // пишет движок
    u32 evt_head;                // пишет движок (release)
    u32 evt_tail;                // пишет демон
    u32 ticks, frames;           // пульс движка
    double now;                  // время последнего тика (SLSCurrentRealTime)
    u32 nactive, errors;
    double idle_poll;            // период опроса команд в простое, с
    double settle;               // сколько ждать, пока приложение примет конечный размер, с
    double settle_px;            // допуск размера, pt (сетка символов терминалов)
    u32 stop, applied;           // stop: движок перестаёт перепланировать себя; applied: число set_xform
    double last_dt;
    double phase;                // фаза тика в кадре: доля периода после развёртки
    double period;               // период развёртки, с (из кэша WS)
    double margin;               // te — первая развёртка позже now+margin
    double te;                   // момент показа, на который посчитан последний кадр
    u32 wid_max, holding;        // wid_max: наибольший виденный номер окна; holding: пачка ждёт кадров приложений
    double hold_t;               // когда пачка начала ждать
    double hold_max;             // сколько ждать кадр приложения, с (потом старт всё равно)
    u64 reserved[12];
};

struct ch {
    struct ch_hdr h;
    struct ch_curve curve[CH_NCURVE];
    struct ch_cmd cmd[CH_NCMD];
    struct ch_evt evt[CH_NEVT];
    struct ch_win win[CH_NW];
};
