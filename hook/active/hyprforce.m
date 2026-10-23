// «Все окна выглядят активными» (П3, MASTER §9.4): в Hyprland неактивные окна рисуются так же, как
// активное, — серого вида у неактивных нет. В AppKit активный вид окна = hasKeyAppearance ||
// hasMainAppearance (`_hasActiveAppearance`), а `hasMainAppearance` истинно при бите forceMainAppearance;
// цветные светофоры и акцентные кнопки — `_hasActiveControls` по биту forceActiveControls
// (notes/research/exotic.md §5.2, wayland_gap.md §2.1). Клавиатурный фокус не меняется: key-окно одно.
//
// Грузится в процесс приложения (dlopen через lldb или DYLD_INSERT_LIBRARIES): конструктор ставит оба бита
// всем обычным окнам и следит за новыми. Повторная загрузка безопасна (флаг в процессе).
// Отключить в работающем процессе: `defaults`-ключа нет — перезапустить приложение (биты живут в окнах).
// Сборка: hook/active/build.sh
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static BOOL eligible(NSWindow *w) {
    if (![w isKindOfClass:NSWindow.class]) return NO;
    if ([w isKindOfClass:NSPanel.class]) return NO;               // панели/палитры/всплывашки — как есть
    if (!(w.styleMask & NSWindowStyleMaskTitled)) return NO;       // меню, тултипы, служебные
    if (w.level != NSNormalWindowLevel) return NO;
    return YES;
}

static char kDone;

// Один раз на окно: сеттеры зовут _setFrameNeedsDisplay:, а NSWindowDidUpdate приходит на каждый проход
// run loop — без метки окно перерисовывалось бы бесконечно. Биты force не сбрасываются resignKey/Main.
static void force(NSWindow *w) {
    if (objc_getAssociatedObject(w, &kDone) || !eligible(w)) return;
    objc_setAssociatedObject(w, &kDone, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SEL a = NSSelectorFromString(@"_setForceMainAppearance:"), b = NSSelectorFromString(@"_setForceActiveControls:");
    if ([w respondsToSelector:a]) ((void (*)(id, SEL, BOOL))objc_msgSend)(w, a, YES);
    if ([w respondsToSelector:b]) ((void (*)(id, SEL, BOOL))objc_msgSend)(w, b, YES);
    // native_hooks §3.4: свой «зум + прозрачность» AppKit при появлении/уходе окна наслаивается на popin и клон
    // закрытия движка — у тайловых окон анимации ведёт только движок (как в Hyprland)
    w.animationBehavior = NSWindowAnimationBehaviorNone;
}

static void force_all(void) {
    for (NSWindow *w in NSApp.windows) force(w);
}

// ── Configure родным путём macOS 26 (notes/research/native_hooks.md §1–§2) ──────────────────────────────
// Тайлинг macOS меняет рамку чужого окна через `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:
// springSettings:completion:]`: AppKit сам применяет минимум/шаг размера и ставит рамку и содержимое одним
// CA-коммитом [V PROGRESS 15:10]. Рамка цели — в координатах CG (левый верхний угол), метод сам переводит её
// [V @0x1857477a0]. Канал — ступенька: Darwin notify (песочница пропускает) → заменит уведомление WS из движка.
// Рамка = 4 × int16 в полупунктах: x | y<<16 | w<<32 | h<<48.
//   "hyprwm.cap.<pid>"  = CFG_CAP — модуль умеет configure (демон шлёт сюда вместо AX)
//   "hyprwm.r.<wid>"    = цель окна (демон держит регистрацию, обнуляет, когда окно встало)
//   "hyprwm.cfg.<pid>"  post — применить цели всех окон приложения
//   "hyprwm.next.<pid>" = рамка первого кадра следующего тайлового окна (до показа)
//   стенд: "hyprwm.cfgw.<pid>" = wid | mode<<32 (0 — сразу, 1 — пружина drift, 2 — setFrame:), рамка в "cfg"
#import <notify.h>
#ifndef NPFX
#define NPFX "hyprwm"   // стенд собирает копию с другим префиксом, чтобы не будить уже загруженные копии
#endif
#define CFG_CAP 5   // 1 — notify-канал; 2 — плюс уведомление WS из движка (OP_CFG); 3 — минимумы окон
#import <QuartzCore/QuartzCore.h>

static NSRect unpack(uint64_t s) {
    return NSMakeRect((int16_t)s / 2.0, (int16_t)(s >> 16) / 2.0, (int16_t)(s >> 32) / 2.0, (int16_t)(s >> 48) / 2.0);
}

// Состояние имени notifyd хранит, пока на имя есть регистрация, — свои держим всё время жизни процесса
enum { T_W, T_R, T_NEXT, T_CAP, T_WS, T_N };
static int tok[T_N];

static uint64_t nstate(int i) {
    uint64_t s = 0;
    notify_get_state(tok[i], &s);
    return s;
}

static uint64_t wstate(NSInteger wid) {      // цель окна — регистрацию держит демон
    char name[64];
    snprintf(name, sizeof name, NPFX ".r.%ld", (long)wid);
    int t;
    uint64_t s = 0;
    if (notify_register_check(name, &t) == NOTIFY_STATUS_OK) {
        notify_get_state(t, &s);
        notify_cancel(t);
    }
    return s;
}

static id wm_geometry(NSRect cg) {
    Class G = NSClassFromString(@"_WMResizeTargetGeometry");
    SEL s = NSSelectorFromString(@"targetGeometryWithFrame:contentsGravity:");
    return G ? ((id (*)(id, SEL, CGRect, long))objc_msgSend)(G, s, cg, 2) : nil;   // 2 — как шлёт система
}

static id wm_spring(double m, double k, double d) {
    Class S = NSClassFromString(@"_WMSpringAnimationSettings");
    SEL s = NSSelectorFromString(@"initWithMass:stiffness:damping:epsilon:");
    return S ? ((id (*)(id, SEL, double, double, double, double))objc_msgSend)([S alloc], s, m, k, d, 0.001) : nil;
}

static void cocoa_frame(NSWindow *w, NSRect cg, BOOL display) {
    NSRect r = cg;   // CG → Cocoa: начало снизу слева от главного экрана
    r.origin.y = NSMaxY(NSScreen.screens.firstObject.frame) - NSMaxY(cg);
    [w setFrame:r display:display];
}

// Родной путь; без него (другая версия AppKit) — setFrame:
static void wm_resize(NSWindow *w, NSRect cg, id spring) {
    SEL s = NSSelectorFromString(@"_resizeFromWindowManagerWithTargetGeometry:springSettings:completion:");
    id g = wm_geometry(cg);
    if (!g || ![w respondsToSelector:s]) {
        cocoa_frame(w, cg, YES);
        return;
    }
    ((void (*)(id, SEL, id, id, id))objc_msgSend)(w, s, g, spring, ^(BOOL ok) {});
}

static void cfg_command(void) {
    uint64_t ws = nstate(T_W);
    if (ws) {                                                    // стенд cfgtest.py
        NSInteger wid = (NSInteger)(ws & 0xffffffff);
        int mode = (int)(ws >> 32);
        NSRect cg = unpack(nstate(T_R));
        for (NSWindow *w in NSApp.windows)
            if (w.windowNumber == wid && cg.size.width >= 1 && cg.size.height >= 1) {
                if (mode == 2) cocoa_frame(w, cg, YES);
                else wm_resize(w, cg, mode == 1 ? wm_spring(1, 210, 24) : nil);
            }
        return;
    }
    for (NSWindow *w in NSApp.windows) {                         // демон: цели окон приложения
        if (w.windowNumber <= 0) continue;
        uint64_t s = wstate(w.windowNumber);
        if (!s) continue;
        NSRect cg = unpack(s);
        if (cg.size.width < 1 || cg.size.height < 1) continue;
        wm_resize(w, cg, nil);   // уже в цели — AppKit сам ничего не делает (сравнение рамок @0x1857477bc)
    }
}

// Минимум окна — у самого AppKit (native_hooks §4): max(minSize, contentMinSize в рамке) — вместо выучки по ответу AX (ложные
// минимумы: Терминал 455 против 448, Ghostty «на весь экран»). "hyprwm.min.<wid>" = w | h<<16 (полупункты),
// регистрацию держит модуль, пока окно живо.
static NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *min_tok;   // wid -> [token, value]

static void publish_min(NSWindow *w) {
    if (w.windowNumber <= 0 || !eligible(w)) return;
    // Только открытые API. 2026-10-09 16:11 вызов закрытого `_validSize:force:` с угаданной сигнатурой
    // уронил Ghostty (EXC_BAD_ACCESS 0x1 в `_validSize:forFullScreen:force:`+0x178) — закрытые методы с
    // аргументами вызывать только после проверки сигнатуры по листингу и на тестовом процессе.
    NSSize m = w.minSize;
    NSSize cm = [w frameRectForContentRect:NSMakeRect(0, 0, w.contentMinSize.width, w.contentMinSize.height)].size;
    m.width = MAX(m.width, cm.width);
    m.height = MAX(m.height, cm.height);
    uint64_t v = (uint64_t)(lround(m.width * 2) & 0xffff) | (uint64_t)(lround(m.height * 2) & 0xffff) << 16;
    NSNumber *k = @(w.windowNumber);
    if (!min_tok) min_tok = [NSMutableDictionary new];
    NSArray *e = min_tok[k];
    int t;
    if (e) {
        if ([e[1] unsignedLongLongValue] == v) return;
        t = [e[0] intValue];
    } else {
        char name[64];
        snprintf(name, sizeof name, NPFX ".min.%ld", (long)w.windowNumber);
        if (notify_register_check(name, &t) != NOTIFY_STATUS_OK) return;
    }
    notify_set_state(t, v);
    min_tok[k] = @[ @(t), @(v) ];
}

static void drop_min(NSWindow *w) {
    NSArray *e = min_tok[@(w.windowNumber)];
    if (!e) return;
    notify_cancel([e[0] intValue]);
    [min_tok removeObjectForKey:@(w.windowNumber)];
}

static char kShown;
extern NSString *const NSWindowWillOrderOnScreenNotification;

// AppKit шлёт это до вывода окна на сервер и потом сам рисует содержимое (`displayIfNeeded` @0x184aed020):
// рамка, поставленная здесь, — уже рамка первого кадра [V PROGRESS 15:10].
static void will_order(NSWindow *w) {
    if (objc_getAssociatedObject(w, &kShown) || !eligible(w)) return;
    // Stop AppKit's own appearance animation before the first server order.
    // DidBecomeKey/DidUpdate can arrive after an unwanted default-pose frame.
    force(w);
    objc_setAssociatedObject(w, &kShown, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    uint64_t s = nstate(T_NEXT);
    if (!s) { publish_min(w); return; }
    NSRect cg = unpack(s);
    if (cg.size.width >= 1 && cg.size.height >= 1) cocoa_frame(w, cg, NO);
    publish_min(w);   // минимум нового окна — до того, как демон его раскладывает
}

// Канал WS → приложение (native_hooks §1.2): движок в тик старта пачки шлёт владельцу окна уведомление
// CH_CFG_NOTIFY (WSPostNotificationToConnection), клиент SkyLight зовёт наш колбэк по типу.
#define CFG_NOTIFY 0x7f17
#define CFG_MAGIC 0x47464348u
struct cfgmsg { uint32_t magic, wid; double x, y, w, h; double t0; };
#import <dlfcn.h>

static void ws_cfg(uint32_t type, void *data, size_t len, void *ctx, int cid) {
    const struct cfgmsg *m = data;
    if (len < sizeof *m || m->magic != CFG_MAGIC) {      // на всякий случай — с заголовком датаграммы {type, seq, 0}
        if (len >= sizeof *m + 12 && ((const struct cfgmsg *)((const char *)data + 12))->magic == CFG_MAGIC)
            m = (const struct cfgmsg *)((const char *)data + 12);
        else
            return;
    }
    struct cfgmsg c = *m;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSWindow *w in NSApp.windows)
            if (w.windowNumber == (NSInteger)c.wid) {
                wm_resize(w, NSMakeRect(c.x, c.y, c.w, c.h), nil);
                notify_set_state(tok[T_WS], (uint64_t)c.wid);   // стенд: последнее окно, пришедшее этим путём
            }
    });
}

static int ws_cfg_init(void) {
    int (*main_cid)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    int (*reg)(int, void *, uint32_t, void *) = dlsym(RTLD_DEFAULT, "SLSRegisterConnectionNotifyProc");
    return main_cid && reg && reg(main_cid(), (void *)ws_cfg, CFG_NOTIFY, NULL) == 0;
}

static void cfg_init(void) {
    for (NSWindow *w in NSApp.windows)   // уже показанные окна не трогать
        if (w.isVisible) objc_setAssociatedObject(w, &kShown, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillOrderOnScreenNotification object:nil
                                                     queue:nil usingBlock:^(NSNotification *n) { will_order(n.object); }];
    for (NSWindow *w in NSApp.windows) publish_min(w);
    for (NSString *n in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResizeNotification ])
        [NSNotificationCenter.defaultCenter addObserverForName:n object:nil queue:nil
                                                    usingBlock:^(NSNotification *x) { publish_min(x.object); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *x) { drop_min(x.object); }];
    const char *fmt[T_N] = {NPFX ".cfgw.%d", NPFX ".cfg.%d", NPFX ".next.%d", NPFX ".cap.%d", NPFX ".ws.%d"};
    char name[64];
    for (int i = 0; i < T_N; i++) {
        snprintf(name, sizeof name, fmt[i], getpid());
        notify_register_check(name, &tok[i]);
    }
    snprintf(name, sizeof name, NPFX ".cfg.%d", getpid());
    int t;
    if (notify_register_dispatch(name, &t, dispatch_get_main_queue(), ^(int k) { cfg_command(); }) == NOTIFY_STATUS_OK)
        notify_set_state(tok[T_CAP], ws_cfg_init() ? CFG_CAP : 1);
}

__attribute__((constructor)) static void hyprforce_init(void) {
    static int once;
    if (once++) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!NSApp) return;
        force_all();
        cfg_init();
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        // новое окно, смена key/main, деактивация приложения: AppKit пересчитывает вид — бит force остаётся,
        // но окна, созданные после загрузки, нужно пометить; проще повторять на каждом таком событии
        for (NSString *n in @[ NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification,
                               NSWindowDidBecomeMainNotification, NSWindowDidResignMainNotification,
                               NSWindowDidUpdateNotification ]) {
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) {
                NSWindow *w = note.object;
                if (w) force(w);
            }];
        }
        for (NSString *n in @[ NSApplicationDidResignActiveNotification, NSApplicationDidBecomeActiveNotification ])
            [nc addObserverForName:n object:nil queue:nil usingBlock:^(NSNotification *note) { force_all(); }];
        NSLog(@"hyprforce: активный вид включён (%lu окон)", (unsigned long)NSApp.windows.count);
    });
}
