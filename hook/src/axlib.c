// Быстрый «configure» приложению: позиция+размер окна одним синхронным вызовом (≈1–10 мс),
// и признаки окна для тайлинга (обычное окно, размер можно менять). Элементы кэшируются по wid.
// Видимую анимацию делает движок в WindowServer; сюда — только конечная/промежуточная рамка.
// Сборка: clang -O2 -dynamiclib -framework ApplicationServices src/axlib.c -o build/libax.dylib
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

#define NC 256
static struct { CGWindowID wid; pid_t pid; AXUIElementRef el; } cache[NC];

int ax_focus(int pid, unsigned wid, int raise);

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;   // кэш общий для потоков configure
static int evict;                                        // следующий слот на вытеснение (кэш полон)

static AXUIElementRef lookup_locked(pid_t pid, CGWindowID wid, int refresh) {
    for (int i = 0; i < NC; i++)
        if (cache[i].el && cache[i].wid == wid && cache[i].pid == pid) {
            if (!refresh) return (AXUIElementRef)CFRetain(cache[i].el);
            CFRelease(cache[i].el); cache[i].el = NULL;
        }
    AXUIElementRef app = AXUIElementCreateApplication(pid), found = NULL;
    AXUIElementSetMessagingTimeout(app, 0.25f);
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef el = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(el, &id) != kAXErrorSuccess || !id) continue;
            int slot = -1;
            for (int j = 0; j < NC; j++) if (cache[j].el && cache[j].wid == id) { slot = j; break; }
            if (slot < 0) for (int j = 0; j < NC; j++) if (!cache[j].el) { slot = j; break; }
            if (slot < 0) { slot = evict; evict = (evict + 1) % NC; }   // кэш полон: вытеснить по кругу
            if (cache[slot].el) CFRelease(cache[slot].el);
            cache[slot].wid = id; cache[slot].pid = pid; cache[slot].el = (AXUIElementRef)CFRetain(el);
            AXUIElementSetMessagingTimeout(el, 0.25f);
            if (id == wid && !found) found = (AXUIElementRef)CFRetain(el);   // +1: слот могут вытеснить
        }
        CFRelease(wins);
    }
    CFRelease(app);
    return found;
}

// Элемент возвращается с +1 (CFRetain) — поток может пользоваться им без блокировки.
static AXUIElementRef lookup(pid_t pid, CGWindowID wid, int refresh) {
    pthread_mutex_lock(&mu);
    AXUIElementRef el = lookup_locked(pid, wid, refresh);   // уже +1
    pthread_mutex_unlock(&mu);
    return el;
}

int ax_trusted(void) { return AXIsProcessTrusted(); }

// 1 — обычное окно (AXStandardWindow) с изменяемым размером; 0 — нет; -1 — окна нет у приложения.
int ax_tileable(int pid, unsigned wid) {
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) el = lookup(pid, wid, 1);
    if (!el) return -1;
    CFStringRef sr = NULL;
    int ok = AXUIElementCopyAttributeValue(el, kAXSubroleAttribute, (CFTypeRef *)&sr) == kAXErrorSuccess && sr &&
             CFEqual(sr, kAXStandardWindowSubrole);
    if (sr) CFRelease(sr);
    Boolean settable = false;
    if (ok && AXUIElementIsAttributeSettable(el, kAXSizeAttribute, &settable) != kAXErrorSuccess) settable = false;
    CFRelease(el);
    return ok && settable;
}

// Рамка окна в глобальных pt (начало сверху слева). 0 — успех, иначе код AXError.
int ax_frame(int pid, unsigned wid, double x, double y, double w, double h) {
    for (int attempt = 0; attempt < 2; attempt++) {
        AXUIElementRef el = lookup(pid, wid, attempt);
        if (!el) continue;
        CGPoint p = {x, y};
        CGSize s = {w, h};
        AXValueRef pv = AXValueCreate(kAXValueCGPointType, &p), sv = AXValueCreate(kAXValueCGSizeType, &s);
        // позиция -> размер -> позиция: AppKit подрезает рамку о край экрана, поэтому окно, растущее
        // вверх, сначала поднимаем, а сжимающееся вниз, которое при подъёме упёрлось, — ставим ещё раз.
        AXUIElementSetAttributeValue(el, kAXPositionAttribute, pv);
        AXError e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, sv);
        if (e == kAXErrorSuccess) AXUIElementSetAttributeValue(el, kAXPositionAttribute, pv);
        CFRelease(pv); CFRelease(sv); CFRelease(el);
        if (e == kAXErrorSuccess) return 0;
        if (e != kAXErrorInvalidUIElement && e != kAXErrorCannotComplete) return e;
    }
    return -1;
}

// Только размер — для live-resize каждый кадр (позицию окна уже поставил движок).
int ax_size(int pid, unsigned wid, double w, double h) {
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) return -1;
    CGSize s = {w, h};
    AXValueRef sv = AXValueCreate(kAXValueCGSizeType, &s);
    AXError e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, sv);
    CFRelease(sv); CFRelease(el);
    return e;
}

void ax_forget(unsigned wid) {
    pthread_mutex_lock(&mu);
    for (int i = 0; i < NC; i++)
        if (cache[i].el && cache[i].wid == wid) { CFRelease(cache[i].el); cache[i].el = NULL; }
    pthread_mutex_unlock(&mu);
}

// ── фокус конкретного окна из фонового процесса (как yabai: focus_window) ─────────────────────
// activateWithOptions с macOS 14 из фона игнорируется; SkyLight делает процесс передним с нужным
// окном, а два синтетических event-record делают окно key. raise=1 — ещё поднять окно (AXRaise).
#include <string.h>
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn);

int ax_focus(int pid, unsigned wid, int raise) {
    ProcessSerialNumber psn = {0, 0};
    if (GetProcessForPID(pid, &psn) != 0) return -1;
    CGError e = _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200);   // kCPSUserGenerated
    uint8_t b[0xf8];
    for (int k = 1; k <= 2; k++) {
        memset(b, 0, sizeof b);
        b[0x04] = 0xf8; b[0x08] = (uint8_t)k; b[0x3a] = 0x10;
        memcpy(b + 0x3c, &wid, sizeof wid);
        memset(b + 0x20, 0xff, 0x10);
        SLPSPostEventRecordTo(&psn, b);
    }
    if (raise) {
        AXUIElementRef el = lookup(pid, wid, 0);
        if (el) { AXUIElementPerformAction(el, kAXRaiseAction); CFRelease(el); }
    }
    return e;
}

// ── цвет края окна для подложки (аналог CLAMP_TO_EDGE в Hyprland) ──────────────────────────────
// Снимок только этого окна (без тени): средний цвет столбца у правого края и строки у нижнего,
// с отступом от скруглённых углов. rgb — 0..1 sRGB. 0 — успех.
#include <dlfcn.h>
typedef CGImageRef (*wlimg_fn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

int ax_edge_color(unsigned wid, double x, double y, double w, double h, double *rgb) {
    static wlimg_fn f;
    if (!f) f = (wlimg_fn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    if (!f || w < 40 || h < 40) return -1;
    CGRect r = CGRectMake(x, y, w, h);
    CGImageRef img = f(r, kCGWindowListOptionIncludingWindow, wid,
                       kCGWindowImageBoundsIgnoreFraming | kCGWindowImageNominalResolution);
    if (!img) return -2;
    size_t W = CGImageGetWidth(img), H = CGImageGetHeight(img);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    uint8_t *px = calloc(W * H, 4);
    CGContextRef cx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(cx, CGRectMake(0, 0, W, H), img);
    double s[3] = {0, 0, 0}; long n = 0;
    size_t m = 30;                                         // мимо скруглений
    for (size_t yy = m; yy + m < H; yy += 4) {             // правый столбец (2 px от края)
        uint8_t *p = px + (yy * W + (W - 3)) * 4;
        if (p[3] < 200) continue;
        s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n++;
    }
    for (size_t xx = m; xx + m < W; xx += 4) {             // нижняя строка (в CG-контексте — верх массива)
        uint8_t *p = px + (2 * W + xx) * 4;
        if (p[3] < 200) continue;
        s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n++;
    }
    CGContextRelease(cx); CGColorSpaceRelease(cs); CGImageRelease(img); free(px);
    if (!n) return -3;
    for (int i = 0; i < 3; i++) rgb[i] = s[i] / n / 255.0;
    return 0;
}

// Фактическая рамка окна глазами приложения (AX): что оно реально приняло после configure.
int ax_get_frame(int pid, unsigned wid, double *out) {
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) return -1;
    CFTypeRef p = NULL, s = NULL;
    int ok = AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &p) == kAXErrorSuccess &&
             AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &s) == kAXErrorSuccess;
    CGPoint pt = {0, 0}; CGSize sz = {0, 0};
    if (ok) { AXValueGetValue(p, kAXValueCGPointType, &pt); AXValueGetValue(s, kAXValueCGSizeType, &sz); }
    if (p) CFRelease(p);
    if (s) CFRelease(s);
    CFRelease(el);
    if (!ok) return -2;
    out[0] = pt.x; out[1] = pt.y; out[2] = sz.width; out[3] = sz.height;
    return 0;
}

// ── вывести окно из встроенного тайлинга macOS (половины/четверти без зазоров) ─────────────────
// Пока окно «разложено системой», WindowManager игнорирует чужие размеры и возвращает его в плитку.
// Снимается пунктом меню приложения «Окно → Переместить и изменить размер → Вернуть к предыдущему
// размеру» (действует на key-окно приложения — окно сначала делается key). 0 — пункт нажат.
static int title_match(CFStringRef t) {
    if (!t) return 0;
    const char *keys[] = {"Previous Size", "предыдущему размеру", "предыдущий размер", NULL};
    char buf[256];
    if (!CFStringGetCString(t, buf, sizeof buf, kCFStringEncodingUTF8)) return 0;
    for (int i = 0; keys[i]; i++) if (strstr(buf, keys[i])) return 1;
    return 0;
}

static const char *want_title;   // точное название пункта меню для ax_menu_press (NULL — «Previous Size»)

static int find_press(AXUIElementRef el, int depth) {
    if (depth > 7) return -1;
    CFArrayRef kids = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXChildrenAttribute, (CFTypeRef *)&kids) != kAXErrorSuccess || !kids) return -1;
    int r = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(kids) && r == -1; i++) {
        AXUIElementRef k = (AXUIElementRef)CFArrayGetValueAtIndex(kids, i);
        CFStringRef t = NULL;
        AXUIElementCopyAttributeValue(k, kAXTitleAttribute, (CFTypeRef *)&t);
        int hit = 0;
        if (want_title) {
            char tb[256];
            hit = t && CFStringGetCString(t, tb, sizeof tb, kCFStringEncodingUTF8) && !strcmp(tb, want_title);
        } else hit = title_match(t);
        if (hit) {
            CFTypeRef en = NULL;
            AXUIElementCopyAttributeValue(k, kAXEnabledAttribute, &en);
            int enabled = en && CFBooleanGetValue(en);
            if (en) CFRelease(en);
            r = enabled ? (AXUIElementPerformAction(k, kAXPressAction) == kAXErrorSuccess ? 0 : -3) : -2;
        } else {
            r = find_press(k, depth + 1);
        }
        if (t) CFRelease(t);
    }
    CFRelease(kids);
    return r;
}

int ax_untile(int pid, unsigned wid) {
    ax_focus(pid, wid, 0);
    usleep(30000);
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.5f);
    AXUIElementRef bar = NULL;
    int r = -1;
    if (AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef *)&bar) == kAXErrorSuccess && bar) {
        r = find_press(bar, 0);
        CFRelease(bar);
    }
    CFRelease(app);
    return r;
}

// Нажать пункт меню приложения по точному названию (например «New Window»). 0 — нажат.
int ax_menu_press(int pid, const char *title) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    AXUIElementSetMessagingTimeout(app, 0.5f);
    AXUIElementRef bar = NULL;
    int r = -1;
    want_title = title;
    if (AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute, (CFTypeRef *)&bar) == kAXErrorSuccess && bar) {
        r = find_press(bar, 0);
        CFRelease(bar);
    }
    want_title = NULL;
    CFRelease(app);
    return r;
}

// Только «окно стало key» для процесса — без смены переднего процесса (клавиатура остаётся у
// активного). Проверка: будет ли приложение рисовать окно в активном виде.
int ax_key_appearance(int pid, unsigned wid) {
    ProcessSerialNumber psn = {0, 0};
    if (GetProcessForPID(pid, &psn) != 0) return -1;
    uint8_t b[0xf8];
    for (int k = 1; k <= 2; k++) {
        memset(b, 0, sizeof b);
        b[0x04] = 0xf8; b[0x08] = (uint8_t)k; b[0x3a] = 0x10;
        memcpy(b + 0x3c, &wid, sizeof wid);
        memset(b + 0x20, 0xff, 0x10);
        SLPSPostEventRecordTo(&psn, b);
    }
    return 0;
}

// Сказать приложению «ты активно» (kCGSEventResume 0x13), не забирая клавиатуру у переднего
// процесса: AppKit _handleActivatedEvent -> _activateWindows -> key-вид окна (notes/wayland_gap.md §2.3 A).
// Раскладка записи как у серверного PostCGSEventToProcess — [гипотеза], поля подтверждаются вживую.
int ax_resume(int pid, unsigned flags, unsigned long long d30) {
    ProcessSerialNumber psn = {0, 0};
    if (GetProcessForPID(pid, &psn) != 0) return -1;
    uint8_t b[0xf8];
    memset(b, 0, sizeof b);
    uint32_t len = 0xf8, type = 0x13, fl = flags;
    memcpy(b + 0x04, &len, 4); memcpy(b + 0x08, &type, 4);       // как PostCGSEventToProcess
    memcpy(b + 0x30, &d30, 8);
    memcpy(b + 0x38, &fl, 4);
    uint16_t f16 = (uint16_t)flags; memcpy(b + 0x8a, &f16, 2);
    memcpy(b + 0x8c, &psn.highLongOfPSN, 4); memcpy(b + 0x90, &psn.lowLongOfPSN, 4);
    return SLPSPostEventRecordTo(&psn, b);
}
