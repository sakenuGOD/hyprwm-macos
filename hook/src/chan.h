// Общая память демон <-> движок в WindowServer (/tmp/hyprwm/chan, mmap MAP_SHARED с обеих сторон).
// Демон пишет команды в кольцо cmd и публикует cmd_head одним атомарным store (release):
// всё, что опубликовано одной публикацией, движок применяет в ОДНОМ тике с одним t0 —
// как в Hyprland, где все переменные одного события стартуют в одном тике.
// Движок пишет состояние окон (wins), события (evt) и пульс (ticks/now).
#pragma once

typedef unsigned int u32;
typedef unsigned long long u64;

#define CH_MAGIC  0x3531574d52505948ULL   // "HYPRWM15"
#define CH_NW     64
#define CH_NCURVE 16
#define CH_NCMD   256
#define CH_NEVT   128
#define CH_BAKED  255
#define CH_NTRAJ  256
#define CH_NCONN  32

enum { CV_NONE = 0, CV_BEZIER = 1, CV_SPRING = 2 };
enum { OP_GEOM = 1, OP_ALPHA = 2, OP_FORGET = 3, OP_WARP = 4, OP_UNDER = 5, OP_SPACE = 6, OP_FILL = 7, OP_RAISE = 8, OP_SNAP = 9, OP_CFG = 10 };
   // CFG: конечная рамка окна (k.x..h) — приложению уведомлением WS в тик старта пачки (модуль hyprforce, native_hooks §1)
#define CH_CFG_NOTIFY 0x7f17     // тип уведомления WS → приложение
#define CH_CFG_MAGIC  0x47464348u // "HCFG"
struct ch_cfgmsg { u32 magic, wid; double x, y, w, h; double t0; };   // полезная нагрузка (0x30)
   // SNAP: подкладка-снимок окна под ним на время хода (сжатие: где бокс больше нового буфера — прежнее содержимое)
   // RAISE: окно над окном k.flags (wid; 0 — над всеми своего уровня), без активации — активное поверх соседей (Hyprland)
   // FILL: k.flags = цвет края окна RGBA8 (0 — нет): пустая полоса B−A закрашивается им (дотяжка края)   // UNDER: k.flags = wid подложки
   // SPACE: перенести окно на рабочий стол (k.x = id стола) изнутри WS — клиентский SLSMoveWindowsToManagedSpace чужие окна не двигает
enum { F_FROM = 1, F_MOVE = 2, F_STRETCH = 4, F_WAIT = 8, F_HOLD = 16 };   // HOLD: сосед открытия — стоит, пока новое окно не готово (одна волна)   // WAIT: открытие — невидимо до кадра размера плитки (≤ wait_max)
   // STRETCH: содержимое тянется на B (открытие, как m_animatingIn)           // флаги OP_GEOM / OP_ALPHA
enum { EV_GONE = 1, EV_SETTLED = 2, EV_DONE = 3, EV_NEW = 4, EV_MOVED = 5, EV_REL = 6, EV_CLONE = 7 };
   // REL: окно освобождается (0x3e9): x = на экране (бит 44), y = есть владелец, w = уровень, h = наш слот (1) / geo (2)
   // CLONE: снимок закрытия выставлен (wid = клон, x = исходное окно)   // MOVED: покоящееся окно ушло с цели (x,y,w,h = A)
   // NEW: на сервере появилось окно (номера растут)   // DONE: видимые анимации окна кончились (B = цель)

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

struct ch_win {                  // 0x1e8
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
    u32 stable, rset;            // stable: сколько тиков подряд A не менялась; rset: движок поставил окну радиус Hyprland
    double a0[2];                // размер буфера в момент старта анимации (старый кадр приложения)
    u32 held, needs;             // held: ждёт старта пачки; needs: ждём от приложения кадр нового размера
    u32 geo, moved;              // geo: у окна есть цель-рамка (было OP_GEOM/WARP с F_MOVE); moved: EV_MOVED уже послан
    double ub[6];                // последняя обрезка подложки: B (x,y,w,h) и видимая часть буфера (w,h)
    u32 wait, fill;              // wait: открытие ждёт кадр приложения нужного размера (F_WAIT); fill: цвет края RGBA8
    double wait_t;               // с какого момента ждёт
    u64 mask;                    // CALayer маски на слое Hosting окна (0 — нет); живёт в WS
    double mrect[2];             // поставленный размер видимой части (cw, ch)
    double mhost[2];             // bounds слоя Hosting при постановке маски (y0, h): слой меняет размер позже формы окна
    struct ch_var act;           // П6: прогресс активной рамки 0..1 (кривая border, кроссфейд 600 мс)
    u64 bl_in, bl_act;           // слои рамки в Server root окна: неактивное кольцо, градиент (маска — кольцо)
    double bframe[4];            // поставленная рамка (координаты Hosting)
    double bop;                  // поставленная непрозрачность активного слоя
    struct ch_var sact;          // прогресс активной тени 0..1 (fadeShadow, 800 мс)
    u64 bl_sh;                   // слой тени (под системным Shadow), маска — кольцо (тень вне окна)
    double sop;                  // поставленная shadowOpacity
    u64 bl_fill;                 // CAShapeLayer заливки пустой полосы B−A (цвет края, под содержимым)
    double fkey[5];              // поставленные bw, bh, aw, ah, цвет — путь пересчитывается только при изменении
};

// П6: рамка фокуса (general.col.*, border_size, rounding). Пишет демон, читает движок.
struct ch_deco {
    u32 on, focus;               // focus: wid активного окна (0 — нет)
    u32 curve, ngrad;            // кривая border; число цветов градиента (≤8, запечено в OkLab демоном)
    double dur, width, radius;   // длительность кроссфейда, с; ширина рамки, pt; радиус окна, pt (внешний = radius+width)
    double grad[8][4];           // RGBA (sRGB, не premult)
    double inact[4];             // неактивная рамка
    double start[2], end[2];     // startPoint/endPoint CAGradientLayer (единичные координаты слоя, ось Y вверх)
    u32 nofull, only;            // nofull: окно без рамки (fullscreen); only: рамка только у этого окна (проверка)
    u32 sh_on, scurve;           // своя тень (decoration.shadow); кривая fadeShadow
    double sdur, srad, soff;     // длительность кроссфейда; shadowRadius (σ); смещение вниз, pt
    double sop_act, sop_in;      // shadowOpacity активного/неактивного (α цвета × плотность гаусса)
    u32 sys_off, inset10;        // sys_off: гасить системную тень/контур окна; inset10: кольцо заходит внутрь окна на N/10 pt
                                 // (закрывает светлый внутренний контур, который рисует само приложение на Tahoe)
    double bez[4], sbez[4];      // кривые кроссфейда рамки/тени (cubic-bezier x1,y1,x2,y2) — CABasicAnimation в CA
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
    double tick_us_last, tick_us_max;   // стоимость тика (mach-тики → мкс по timebase, считает движок)
    u32 ticks_late, te_skips;    // тик позже 0.6·T после развёртки; шаг te ≠ T при анимации
    u32 traj_head, pad_t;        // кольцо траектории: следующая запись
    double te_prev;              // te прошлого тика с анимацией
    u32 use_mask, mask_only;     // П4: обрезка B маской в CA-дереве окна вместо экранного клипа; mask_only — только это окно
    u32 mask_flip, mask_errs;    // mask_flip: ось Y слоя вверх (y = h − ch); mask_errs: сколько раз дерево не нашлось
    u64 reserved[5];
};

struct ch_traj { double te; u32 wid, pad; double bx, by, bw, bh, alpha; };   // 0x38

struct ch {
    struct ch_hdr h;
    struct ch_curve curve[CH_NCURVE];
    struct ch_cmd cmd[CH_NCMD];
    struct ch_evt evt[CH_NEVT];
    struct ch_win win[CH_NW];
    struct ch_traj traj[CH_NTRAJ];
    // соединения (CGXConnection*) приложений, чьи окна движок вёл в плитку: новое окно уровня 0 такого
    // приложения прячется в тот же тик, когда появилось (демон решит: popin или показать) — пишет движок
    u64 conn[CH_NCONN];
    u32 conn_next, prehide;      // prehide: включено демоном
    struct ch_deco deco;
};
