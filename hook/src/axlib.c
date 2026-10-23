// Fast application configure: window position+size in one synchronous call (~1-10 ms),
// plus tiling attributes (standard window, resizable). Elements are cached by wid.
// The WindowServer engine handles visible animation; this receives only final/intermediate frames.
// Build: clang -O2 -dynamiclib -framework ApplicationServices src/axlib.c -o build/libax.dylib
#include <ApplicationServices/ApplicationServices.h>
#include <pthread.h>
#include "axpolicy.h"
#include "launcher_intent.h"
#include "pointer_hit.h"
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <math.h>

extern AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *);

#define NC 256
static struct { CGWindowID wid; pid_t pid; AXUIElementRef el; } cache[NC];

int ax_focus(int pid, unsigned wid, int raise);

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;   // cache shared by configure threads
static int evict;                                        // next eviction slot (cache full)
static uint64_t cache_epoch; // prevents an in-flight application snapshot reintroducing forgotten proxies

// Only pointer ownership changes occur under mu. AX calls can block and must remain outside it.
static AXUIElementRef lookup(pid_t pid, CGWindowID wid, int refresh) {
    AXUIElementRef retired[NC] = {0};
    int nretired = 0;
    pthread_mutex_lock(&mu);
    for (int i = 0; i < NC; i++)
        if (cache[i].el && cache[i].wid == wid && cache[i].pid == pid) {
            if (!refresh) {
                AXUIElementRef found = (AXUIElementRef)CFRetain(cache[i].el);
                pthread_mutex_unlock(&mu);
                return found;
            }
            retired[nretired++] = cache[i].el;
            cache[i].el = NULL;
        }
    if (refresh) ++cache_epoch;
    uint64_t epoch = cache_epoch;
    pthread_mutex_unlock(&mu);
    for (int i = 0; i < nretired; i++) CFRelease(retired[i]);
    nretired = 0;

    AXUIElementRef app = AXUIElementCreateApplication(pid), found = NULL;
    if (!app) return NULL;
    AXUIElementSetMessagingTimeout(app, 0.25f);
    CFArrayRef wins = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        AXUIElementRef fetched[NC];
        CGWindowID ids[NC];
        int nfetched = 0;
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef el = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(el, &id) != kAXErrorSuccess || !id) continue;
            AXUIElementSetMessagingTimeout(el, 0.25f);
            if (id == wid && !found) found = (AXUIElementRef)CFRetain(el);
            if (nfetched < NC) { fetched[nfetched] = el; ids[nfetched++] = id; }
        }
        pthread_mutex_lock(&mu);
        for (int i = 0; i < nfetched && epoch == cache_epoch; i++) {
            int slot = -1;
            for (int j = 0; j < NC; j++)
                if (cache[j].el && cache[j].wid == ids[i] && cache[j].pid == pid) { slot = j; break; }
            if (slot < 0) for (int j = 0; j < NC; j++) if (!cache[j].el) { slot = j; break; }
            if (slot < 0) { slot = evict; evict = (evict + 1) % NC; }   // cache full: round-robin eviction
            if (cache[slot].el) retired[nretired++] = cache[slot].el;
            cache[slot].wid = ids[i]; cache[slot].pid = pid;
            cache[slot].el = (AXUIElementRef)CFRetain(fetched[i]);
        }
        pthread_mutex_unlock(&mu);
        for (int i = 0; i < nretired; i++) CFRelease(retired[i]);
        CFRelease(wins);
    }
    // Terminal can expose no AXWindows while its selected window belongs to
    // another Space. Its exact AXFocusedWindow remains available and carries
    // the normal role/resize metadata needed to admit that selected source.
    if (!found) {
        AXUIElementRef focused = NULL;
        if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&focused) == kAXErrorSuccess && focused) {
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(focused, &id) == kAXErrorSuccess && id == wid) found = focused;
            else CFRelease(focused);
        }
    }
    CFRelease(app);
    return found;
}

int ax_trusted(void) { return AXIsProcessTrusted(); }

static int attr_is(AXUIElementRef el, CFStringRef key, CFTypeRef expected) {
    CFTypeRef value = NULL;
    int result = AXUIElementCopyAttributeValue(el, key, &value) == kAXErrorSuccess && value && CFEqual(value, expected);
    if (value) CFRelease(value);
    return result;
}

static CFTypeRef copy_attr(AXUIElementRef el, CFStringRef key) {
    CFTypeRef value = NULL;
    AXUIElementCopyAttributeValue(el, key, &value);
    return value;
}

static int value_is(CFTypeRef value, CFTypeRef expected) { return value && CFEqual(value, expected); }

// Batch read-only focus evidence in one AX request. Unsupported values are represented by
// AX error values inside the result, rather than causing extra individual IPC requests.
static int copy_attrs_policy(AXUIElementRef el, const CFStringRef *keys, int count, CFTypeRef *out, int legacy) {
    for (int i = 0; i < count; i++) out[i] = NULL;
    CFArrayRef attrs = CFArrayCreate(NULL, (const void **)keys, count, &kCFTypeArrayCallBacks);
    if (!attrs) return 0;
    CFArrayRef values = NULL;
    AXError error = AXUIElementCopyMultipleAttributeValues(el, attrs, 0, &values);
    CFRelease(attrs);
    int coherent = 0;
    if (error == kAXErrorSuccess && values && CFGetTypeID(values) == CFArrayGetTypeID() &&
        CFArrayGetCount(values) == count) {
        coherent = 1;
        for (int i = 0; i < count; i++) {
            CFTypeRef value = CFArrayGetValueAtIndex(values, i);
            if (value == kCFNull || (CFGetTypeID(value) == AXValueGetTypeID() &&
                AXValueGetType(value) == kAXValueAXErrorType)) continue;
            out[i] = CFRetain(value);
        }
    } else if (legacy && (error == kAXErrorNotImplemented || error == kAXErrorAttributeUnsupported)) {
        // Legacy AX providers can lack the batch API. Failed/hung requests are never multiplied.
        for (int i = 0; i < count; i++) out[i] = copy_attr(el, keys[i]);
    }
    if (values) CFRelease(values);
    return coherent;
}
static int copy_attrs(AXUIElementRef el, const CFStringRef *keys, int count, CFTypeRef *out) {
    return copy_attrs_policy(el,keys,count,out,1);
}

static unsigned focus_window_context(AXUIElementRef el) {
    // Optional vendor evidence: AXSheets has no public SDK constant. The standard evidence
    // remains AXSheet role and AXParent relationships; malformed/unsupported arrays are ignored.
    const CFStringRef keys[] = {kAXRoleAttribute, kAXSubroleAttribute, kAXModalAttribute,
                               kAXParentAttribute, CFSTR("AXSheets"), CFSTR("AXFullScreen")};
    CFTypeRef values[6];
    AXUIElementSetMessagingTimeout(el, 0.05f);
    copy_attrs(el, keys, 6, values);
    unsigned context = 0;
    if (!values[0]) context |= AXWM_FOCUS_UNKNOWN;
    else if (!value_is(values[0], kAXWindowRole) ||
             (values[1] && !value_is(values[1], kAXStandardWindowSubrole)))
        context |= AXWM_FOCUS_TRANSIENT;
    if (value_is(values[2], kCFBooleanTrue)) context |= AXWM_FOCUS_MODAL;
    if (values[3]) {
        AXUIElementRef parent = (AXUIElementRef)values[3];
        AXUIElementSetMessagingTimeout(parent, 0.03f);
        CFTypeRef role = copy_attr(parent, kAXRoleAttribute);
        if (value_is(role, kAXWindowRole) || value_is(role, kAXSheetRole)) context |= AXWM_FOCUS_TRANSIENT;
        if (role) CFRelease(role);
    }
    if (values[4] && CFGetTypeID(values[4]) == CFArrayGetTypeID() && CFArrayGetCount(values[4]) > 0)
        context |= AXWM_FOCUS_MODAL;
    if (context & AXWM_FOCUS_MODAL) context |= AXWM_FOCUS_TRANSIENT;
    if (value_is(values[5], kCFBooleanTrue)) context |= AXWM_FOCUS_FULLSCREEN;
    for (int i = 0; i < 6; i++) if (values[i]) CFRelease(values[i]);
    return context;
}

static unsigned element_flags(AXUIElementRef el, int include_resize) {
    unsigned flags = 0;
    if (!include_resize) AXUIElementSetMessagingTimeout(el, 0.05f);
    CFTypeRef role = copy_attr(el, kAXRoleAttribute), subrole = copy_attr(el, kAXSubroleAttribute);
    if (value_is(role, kAXWindowRole)) flags |= AXWM_WINDOW;
    if (value_is(role, kAXSheetRole)) flags |= AXWM_SHEET | AXWM_TRANSIENT;
    if (value_is(role, CFSTR("AXDialog"))) flags |= AXWM_DIALOG | AXWM_TRANSIENT;
    if (value_is(subrole, kAXStandardWindowSubrole)) flags |= AXWM_STANDARD;
    else if (subrole && (flags & AXWM_WINDOW)) flags |= AXWM_TRANSIENT;
    if (value_is(subrole, kAXDialogSubrole) || value_is(subrole, kAXSystemDialogSubrole))
        flags |= AXWM_DIALOG | AXWM_TRANSIENT;
    if (role) CFRelease(role);
    if (subrole) CFRelease(subrole);
    if (attr_is(el, kAXModalAttribute, kCFBooleanTrue)) flags |= AXWM_MODAL | AXWM_TRANSIENT;

    // AX sheets may be reported with a standard subrole, but have a window parent (SDK contract).
    AXUIElementRef parent = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXParentAttribute, (CFTypeRef *)&parent) == kAXErrorSuccess && parent) {
        AXUIElementSetMessagingTimeout(parent, include_resize ? 0.25f : 0.05f);
        CFTypeRef parent_role = copy_attr(parent, kAXRoleAttribute);
        if (value_is(parent_role, kAXWindowRole) || value_is(parent_role, kAXSheetRole))
            flags |= AXWM_TRANSIENT;
        if (parent_role) CFRelease(parent_role);
        CFRelease(parent);
    }
    // Some AX providers attach a dialog through AXWindow rather than AXParent.
    // A top-level window refers to itself; only a distinct owning window is transient evidence.
    CFTypeRef owning = copy_attr(el, kAXWindowAttribute);
    if (owning && CFGetTypeID(owning) == AXUIElementGetTypeID() && !CFEqual(owning, el)) {
        CGWindowID own_id = 0, self_id = 0;
        _AXUIElementGetWindow((AXUIElementRef)owning, &own_id);
        _AXUIElementGetWindow(el, &self_id);
        if (own_id && own_id != self_id) flags |= AXWM_TRANSIENT;
    }
    if (owning) CFRelease(owning);
    Boolean settable = false;
    if (include_resize && AXUIElementIsAttributeSettable(el, kAXSizeAttribute, &settable) == kAXErrorSuccess && settable)
        flags |= AXWM_RESIZABLE;
    unsigned required = AXWM_WINDOW | AXWM_STANDARD | AXWM_RESIZABLE;
    if ((flags & required) == required && !(flags & AXWM_TRANSIENT)) flags |= AXWM_TILEABLE;
    return flags;
}

int ax_window_flags(int pid, unsigned wid) {
    for (int attempt = 0; attempt < 2; attempt++) {
        AXUIElementRef el = lookup(pid, wid, attempt);
        if (!el) continue;
        CFTypeRef role = NULL;
        AXError error = AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
        if (role) CFRelease(role);
        if (error == kAXErrorInvalidUIElement || error == kAXErrorCannotComplete) {
            CFRelease(el);
            continue; // cached AX proxy expired; re-resolve instead of permanently classifying as other
        }
        unsigned flags = element_flags(el, 1);
        CFRelease(el);
        return (int)flags;
    }
    return -1;
}

// 1 — confirmed ordinary resizable top-level window; 0 — protected; -1 — not yet exposed by AX.
int ax_tileable(int pid, unsigned wid) {
    int flags = ax_window_flags(pid, wid);
    return flags < 0 ? flags : !!(flags & AXWM_TILEABLE);
}

// Read-only evidence for automatic focus. A modal viewer/menu must retain keyboard focus even
// when the cursor crosses its underlying tiled window. This never activates or raises any window.
int ax_focus_context(int pid, unsigned *focused_wid, unsigned *context) {
    if (!focused_wid || !context || pid <= 0) return -1;
    *focused_wid = 0; *context = 0;
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return -1;
    AXUIElementSetMessagingTimeout(app, 0.1f);
    AXUIElementRef focused = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, (CFTypeRef *)&focused);
    if (error == kAXErrorSuccess && focused) {
        CGWindowID wid = 0;
        if (_AXUIElementGetWindow(focused, &wid) == kAXErrorSuccess) *focused_wid = wid;
        if (!*focused_wid) *context |= AXWM_FOCUS_UNKNOWN;
        *context |= focus_window_context(focused);
        CFRelease(focused);
    } else if (error == kAXErrorNoValue || (error == kAXErrorSuccess && !focused)) {
        *context |= AXWM_FOCUS_NO_KEY;
    } else {
        *context |= AXWM_FOCUS_UNKNOWN;
    }

    AXUIElementRef ui = NULL;
    AXError ui_error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute, (CFTypeRef *)&ui);
    if (ui_error == kAXErrorSuccess && ui) {
        // Bound tree walks; some apps expose cycles or deep document hierarchies.
        for (int depth = 0; ui && depth < 8; depth++) {
            AXUIElementSetMessagingTimeout(ui, 0.03f); // app timeout does not propagate to returned elements
            const CFStringRef keys[] = {kAXRoleAttribute, kAXParentAttribute};
            CFTypeRef values[2];
            copy_attrs(ui, keys, 2, values);
            CFTypeRef role = values[0];
            if (value_is(role, kAXMenuRole) || value_is(role, kAXMenuItemRole) || value_is(role, kAXMenuBarItemRole))
                *context |= AXWM_FOCUS_MENU;
            if (value_is(role, kAXSheetRole)) *context |= AXWM_FOCUS_TRANSIENT;
            int terminal = *context & (AXWM_FOCUS_MENU | AXWM_FOCUS_TRANSIENT | AXWM_FOCUS_MODAL);
            if (value_is(role, kAXWindowRole)) {
                // No reason to inspect the parent app's whole AX hierarchy. Reuse metadata when
                // this ancestor is the focused window; another owning window needs its own check.
                CGWindowID id = 0;
                _AXUIElementGetWindow(ui, &id);
                if (!id || id != *focused_wid) *context |= focus_window_context(ui);
                terminal = 1;
            }
            if (value_is(role, kAXApplicationRole)) terminal = 1;
            if (role) CFRelease(role);
            AXUIElementRef parent = (AXUIElementRef)values[1];
            if (terminal) { if (parent) CFRelease(parent); break; }
            int cycle = parent && CFEqual(ui, parent);
            CFRelease(ui);
            ui = parent;
            if (cycle) break;
        }
        if (ui) CFRelease(ui);
    } else if ((*context & AXWM_FOCUS_NO_KEY) && ui_error != kAXErrorNoValue && ui_error != kAXErrorSuccess) {
        // A failed focused-UI query cannot rule out a menu/sheet ancestor.
        *context = (*context & ~AXWM_FOCUS_NO_KEY) | AXWM_FOCUS_UNKNOWN;
    }
    CFRelease(app);
    return error == kAXErrorSuccess || *context != AXWM_FOCUS_UNKNOWN ? 0 : -1;
}

// Enhanced UI can animate AX position writes: the following size write then
// clamps against the old origin. Configure work is serialized per application.
// Suppress that mode only for the setters, preserving false/unsupported values.
static AXUIElementRef suspend_ax_animation(pid_t pid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return NULL;
    AXUIElementSetMessagingTimeout(app, 0.25f);
    CFTypeRef value = NULL;
    AXError e = AXUIElementCopyAttributeValue(app, CFSTR("AXEnhancedUserInterface"), &value);
    int enabled = e == kAXErrorSuccess && value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    if (value) CFRelease(value);
    if (enabled && AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanFalse) == kAXErrorSuccess) return app;
    CFRelease(app);
    return NULL;
}

static void resume_ax_animation(AXUIElementRef app) {
    if (!app) return;
    AXUIElementSetAttributeValue(app, CFSTR("AXEnhancedUserInterface"), kCFBooleanTrue);
    CFRelease(app);
}

// Window frame in global pt (top-left origin). 0 = success; otherwise AXError code.
int ax_frame(int pid, unsigned wid, double x, double y, double w, double h) {
    for (int attempt = 0; attempt < 2; attempt++) {
        AXUIElementRef el = lookup(pid, wid, attempt);
        if (!el) continue;
        CGPoint p = {x, y};
        CGSize s = {w, h};
        AXValueRef pv = AXValueCreate(kAXValueCGPointType, &p), sv = AXValueCreate(kAXValueCGSizeType, &s);
        AXUIElementRef app = suspend_ax_animation(pid);
        // Size -> position -> size: shrink before moving to an edge, then repair
        // any growth clamped at the old origin. The worker reads back the accepted frame.
        AXError e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, sv);
        if (e == kAXErrorSuccess) e = AXUIElementSetAttributeValue(el, kAXPositionAttribute, pv);
        if (e == kAXErrorSuccess) e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, sv);
        resume_ax_animation(app);
        CFRelease(pv); CFRelease(sv); CFRelease(el);
        if (e == kAXErrorSuccess) return 0;
        if (e != kAXErrorInvalidUIElement && e != kAXErrorCannotComplete) return e;
    }
    return -1;
}

// Size only: per-frame live-resize (the engine already set the window position).
int ax_size(int pid, unsigned wid, double w, double h) {
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) return -1;
    CGSize s = {w, h};
    AXValueRef sv = AXValueCreate(kAXValueCGSizeType, &s);
    AXUIElementRef app = suspend_ax_animation(pid);
    AXError e = AXUIElementSetAttributeValue(el, kAXSizeAttribute, sv);
    resume_ax_animation(app);
    CFRelease(sv); CFRelease(el);
    return e;
}

void ax_forget(unsigned wid) {
    AXUIElementRef retired[NC];
    int nretired = 0;
    pthread_mutex_lock(&mu);
    ++cache_epoch;
    for (int i = 0; i < NC; i++)
        if (cache[i].el && cache[i].wid == wid) {
            retired[nretired++] = cache[i].el;
            cache[i].el = NULL;
        }
    pthread_mutex_unlock(&mu);
    for (int i = 0; i < nretired; i++) CFRelease(retired[i]);
}

// Focus a specific window from a background process (like yabai: focus_window).
// Since macOS 14, background activateWithOptions is ignored; SkyLight brings the process forward with
// the desired window, and two synthetic event records make it key. raise=1 also raises it (AXRaise).
#include <string.h>
extern CGError _SLPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern OSStatus GetProcessForPID(pid_t pid, ProcessSerialNumber *psn);

// Raising preserves the application's key/main selection: no activation or focus setter.
int ax_raise(int pid, unsigned wid) {
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) return -1;
    AXUIElementSetMessagingTimeout(el, 0.05f);
    AXError error = AXUIElementPerformAction(el, kAXRaiseAction);
    CFRelease(el);
    return error;
}

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
    // On current macOS, SLPS activation can succeed without changing the key
    // window inside an already active application. AppKit's public AXMain
    // setter selects that exact window without an explicit AXRaise action.
    AXUIElementRef el = lookup(pid, wid, 0);
    if (el) {
        AXUIElementSetMessagingTimeout(el, 0.05f);
        AXUIElementSetAttributeValue(el, kAXMainAttribute, kCFBooleanTrue);
        if (raise) AXUIElementPerformAction(el, kAXRaiseAction);
        CFRelease(el);
    }
    return e;
}

// Window edge color for the backdrop (similar to CLAMP_TO_EDGE in Hyprland).
// Snapshot of this window only (without shadow): average color of the rightmost column and bottom row,
// inset from rounded corners. rgb = 0..1 sRGB. 0 = success.
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
    size_t m = 30;                                         // avoid rounded corners
    for (size_t yy = m; yy + m < H; yy += 4) {             // right column (2 px from edge)
        uint8_t *p = px + (yy * W + (W - 3)) * 4;
        if (p[3] < 200) continue;
        s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n++;
    }
    for (size_t xx = m; xx + m < W; xx += 4) {             // bottom row (top of array in CG context)
        uint8_t *p = px + (2 * W + xx) * 4;
        if (p[3] < 200) continue;
        s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; n++;
    }
    CGContextRelease(cx); CGColorSpaceRelease(cs); CGImageRelease(img); free(px);
    if (!n) return -3;
    for (int i = 0; i < 3; i++) rgb[i] = s[i] / n / 255.0;
    return 0;
}

// Actual application-side window frame (AX): what it accepted after configure.
static int frame_values(CFTypeRef p, CFTypeRef s, double *out) {
    CGPoint pt; CGSize sz;
    if (!out || !p || !s || CFGetTypeID(p) != AXValueGetTypeID() || CFGetTypeID(s) != AXValueGetTypeID() ||
        AXValueGetType((AXValueRef)p) != kAXValueCGPointType || AXValueGetType((AXValueRef)s) != kAXValueCGSizeType ||
        !AXValueGetValue((AXValueRef)p,kAXValueCGPointType,&pt) || !AXValueGetValue((AXValueRef)s,kAXValueCGSizeType,&sz) ||
        !isfinite(pt.x) || !isfinite(pt.y) || !isfinite(sz.width) || !isfinite(sz.height) || sz.width <= 0 || sz.height <= 0) return -2;
    out[0]=pt.x;out[1]=pt.y;out[2]=sz.width;out[3]=sz.height;
    return 0;
}
int ax_get_frame(int pid, unsigned wid, double *out) {
    if (!out) return -2;
    AXUIElementRef el = lookup(pid, wid, 0);
    if (!el) return -1;
    const CFStringRef keys[]={kAXPositionAttribute,kAXSizeAttribute};CFTypeRef values[2];
    int coherent=copy_attrs_policy(el,keys,2,values,0);
    int result=coherent ? frame_values(values[0],values[1],out) : -2;
    if (values[0]) CFRelease(values[0]);
    if (values[1]) CFRelease(values[1]);
    CFRelease(el);
    return result;
}

// Release a window from macOS native tiling (halves/quarters without gaps).
// While system-tiled, WindowManager ignores external sizes and restores the tile.
// Release through the application's Window -> Move & Resize -> Return to Previous Size menu item
// (acts on the application's key window, so first make this window key). 0 = item pressed.
static int title_match(CFStringRef t) {
    if (!t) return 0;
    // Preserve Russian menu-title matches as their original UTF-8 bytes.
    const char *keys[] = {"Previous Size", "\xd0\xbf\xd1\x80\xd0\xb5\xd0\xb4\xd1\x8b\xd0\xb4\xd1\x83\xd1\x89\xd0\xb5\xd0\xbc\xd1\x83\x20\xd1\x80\xd0\xb0\xd0\xb7\xd0\xbc\xd0\xb5\xd1\x80\xd1\x83", "\xd0\xbf\xd1\x80\xd0\xb5\xd0\xb4\xd1\x8b\xd0\xb4\xd1\x83\xd1\x89\xd0\xb8\xd0\xb9\x20\xd1\x80\xd0\xb0\xd0\xb7\xd0\xbc\xd0\xb5\xd1\x80", NULL};
    char buf[256];
    if (!CFStringGetCString(t, buf, sizeof buf, kCFStringEncodingUTF8)) return 0;
    for (int i = 0; keys[i]; i++) if (strstr(buf, keys[i])) return 1;
    return 0;
}

static const char *want_title;   // exact menu item title for ax_menu_press (NULL = "Previous Size")

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

// Press an application menu item by exact title (e.g. "New Window"). 0 = pressed.
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

// Only tell the process its window became key, without changing the front process (keyboard stays
// with the active process). Test: whether the application draws the window as active.
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

// Tell the application it is active (kCGSEventResume 0x13), without taking the keyboard from the front
// process: AppKit _handleActivatedEvent -> _activateWindows -> key appearance (notes/wayland_gap.md section 2.3 A).
// Record layout matches server PostCGSEventToProcess [hypothesis]; fields are confirmed live.
int ax_resume(int pid, unsigned flags, unsigned long long d30) {
    ProcessSerialNumber psn = {0, 0};
    if (GetProcessForPID(pid, &psn) != 0) return -1;
    uint8_t b[0xf8];
    memset(b, 0, sizeof b);
    uint32_t len = 0xf8, type = 0x13, fl = flags;
    memcpy(b + 0x04, &len, 4); memcpy(b + 0x08, &type, 4);       // as in PostCGSEventToProcess
    memcpy(b + 0x30, &d30, 8);
    memcpy(b + 0x38, &fl, 4);
    uint16_t f16 = (uint16_t)flags; memcpy(b + 0x8a, &f16, 2);
    memcpy(b + 0x8c, &psn.highLongOfPSN, 4); memcpy(b + 0x90, &psn.lowLongOfPSN, 4);
    return SLPSPostEventRecordTo(&psn, b);
}

/* Capture launcher origin before macOS's application activation switches Space.
 * This passive callback performs no AX/WindowServer calls and never changes an event.
 * A busy cache is skipped rather than blocking the input thread. */
static pthread_mutex_t launcher_mu = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef launcher_tap;
static CFRunLoopSourceRef launcher_source;
static CFRunLoopRef launcher_runloop;
static uint64_t launcher_space, launcher_seq;
static int32_t launcher_front;
static uint32_t launcher_dock[16], launcher_count;
static double launcher_rects[16][4];
static pthread_cond_t launcher_cond = PTHREAD_COND_INITIALIZER;
static pthread_t launcher_thread;
static int launcher_ready, launcher_started;
static ax_launcher_intent launcher_value;
static CFMachPortRef pointer_tap;
static CFRunLoopSourceRef pointer_source;
static _Atomic int pointer_ready;
static _Atomic uint64_t pointer_words[8];
_Static_assert(sizeof(ax_pointer_hit)==64,"pointer input metadata ABI");
static uint64_t launcher_now(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
uint64_t ax_launcher_now_ns(void) { return launcher_now(); }
static void pointer_publish(ax_pointer_hit value) {
    uint64_t words[8];memcpy(words,&value,sizeof words);
    uint64_t sequence=atomic_load_explicit(&pointer_words[0],memory_order_seq_cst);
    atomic_store_explicit(&pointer_words[0],sequence+1,memory_order_seq_cst);
    for(unsigned i=1;i<8;i++)atomic_store_explicit(&pointer_words[i],words[i],memory_order_seq_cst);
    atomic_store_explicit(&pointer_words[0],sequence+2,memory_order_seq_cst);
}
static CGEventRef pointer_callback(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context) {
    (void)proxy;(void)context;
    if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput) {
        pointer_publish((ax_pointer_hit){0});
        if(pointer_tap)CGEventTapEnable(pointer_tap,true);
        return event;
    }
    if(!event || !(type==kCGEventMouseMoved || type==kCGEventLeftMouseDown || type==kCGEventLeftMouseUp ||
        type==kCGEventLeftMouseDragged || type==kCGEventRightMouseDown || type==kCGEventRightMouseUp ||
        type==kCGEventRightMouseDragged || type==kCGEventOtherMouseDown || type==kCGEventOtherMouseUp ||
        type==kCGEventOtherMouseDragged))return event;
    CGPoint point=CGEventGetLocation(event);
    int64_t wid=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);
    int64_t under=CGEventGetIntegerValueField(event,kCGMouseEventWindowUnderMousePointer);
    int64_t target=CGEventGetIntegerValueField(event,kCGEventTargetUnixProcessID);
    int64_t source=CGEventGetIntegerValueField(event,kCGEventSourceUnixProcessID);
    ax_pointer_hit hit={.monotonic_ns=launcher_now(),.x=point.x,.y=point.y,.event_type=(uint32_t)type,
        .event_timestamp_ns=CGEventGetTimestamp(event)};
    if(isfinite(point.x)&&isfinite(point.y)&&fabs(point.x)<=100000&&fabs(point.y)<=100000)hit.valid=1;
    if(wid>0 && wid<=UINT32_MAX){hit.wid=(uint32_t)wid;hit.valid|=2;}
    if(under>0 && under<=UINT32_MAX)hit.under_wid=(uint32_t)under;
    if(target>0 && target<=INT32_MAX)hit.target_pid=(int32_t)target;
    if(source>0 && source<=INT32_MAX)hit.source_pid=(int32_t)source;
    pointer_publish(hit);
    return event; /* Listen only; no caller event is modified or replaced. */
}
int ax_pointer_hit_available(void){return atomic_load_explicit(&pointer_ready,memory_order_seq_cst);}
int ax_pointer_hit_read(ax_pointer_hit *out){
    if(!out)return -1;
    for(unsigned attempt=0;attempt<3;attempt++){
        uint64_t words[8];words[0]=atomic_load_explicit(&pointer_words[0],memory_order_seq_cst);
        if(!words[0] || (words[0]&1))continue;
        for(unsigned i=1;i<8;i++)words[i]=atomic_load_explicit(&pointer_words[i],memory_order_seq_cst);
        atomic_thread_fence(memory_order_seq_cst);
        if(words[0]!=atomic_load_explicit(&pointer_words[0],memory_order_seq_cst))continue;
        memcpy(out,words,sizeof words);return 1;
    }
    return 0;
}
static CGEventRef launcher_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    (void)proxy; (void)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (launcher_tap) CGEventTapEnable(launcher_tap, true);
        return event;
    }
    int kind = -1;
    CGEventFlags flags = CGEventGetFlags(event);
    if (type == kCGEventKeyDown) {
        int key = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (key == 53 || ((flags & kCGEventFlagMaskControl) && (key == 123 || key == 124))) kind = 0;
        else if ((flags & kCGEventFlagMaskCommand) && !(flags & (kCGEventFlagMaskControl | kCGEventFlagMaskAlternate))) {
            if (key == 49) kind = 1;
            else if (key == 48) kind = 2;
        } else if (key == 48 && (flags & kCGEventFlagMaskAlternate) &&
                   !(flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskControl))) {
            /* Third-party AltTab uses Option-Tab; Shift reverses the same cycle. */
            kind = 2;
        }
    }
    if (pthread_mutex_trylock(&launcher_mu) != 0) return event;
    if (type == kCGEventLeftMouseDown) {
        uint32_t wid = (uint32_t)CGEventGetIntegerValueField(event, kCGMouseEventWindowUnderMousePointer);
        for (uint32_t i = 0; wid && i < launcher_count; ++i) if (launcher_dock[i] == wid) { kind = 3; break; }
        if (!wid) {
            CGPoint point = CGEventGetLocation(event);
            for (uint32_t i = 0; i < launcher_count; ++i) {
                const double *r = launcher_rects[i];
                if (r[2] > 0 && r[3] > 0 && point.x >= r[0] && point.x <= r[0]+r[2] &&
                    point.y >= r[1] && point.y <= r[1]+r[3]) { kind = 3; break; }
            }
        }
    }
    if (kind >= 0) {
        uint64_t now = launcher_now();
        uint64_t origin = launcher_space;
        int32_t front = launcher_front;
        /* Command-Tab cycling preserves the first origin even after an autoswitch. */
        if (kind == 2 && launcher_value.kind == 2 && now >= launcher_value.monotonic_ns &&
            now - launcher_value.monotonic_ns <= 3000000000ULL) {
            origin = launcher_value.origin_space; front = launcher_value.front_pid;
        }
        launcher_value = (ax_launcher_intent){++launcher_seq, kind ? origin : 0, now, front, kind};
    }
    pthread_mutex_unlock(&launcher_mu);
    return event;
}
static void *launcher_worker(void *unused) {
    (void)unused;
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventLeftMouseDown);
    launcher_tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                                   mask, launcher_callback, NULL);
    if (launcher_tap) launcher_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, launcher_tap, 0);
    if (launcher_source) {
        launcher_runloop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
        CFRunLoopAddSource(launcher_runloop, launcher_source, kCFRunLoopCommonModes);
        CGEventTapEnable(launcher_tap, true);
        CGEventMask mouse_mask=CGEventMaskBit(kCGEventMouseMoved)|CGEventMaskBit(kCGEventLeftMouseDown)|
            CGEventMaskBit(kCGEventLeftMouseUp)|CGEventMaskBit(kCGEventLeftMouseDragged)|
            CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|CGEventMaskBit(kCGEventRightMouseDragged)|
            CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|CGEventMaskBit(kCGEventOtherMouseDragged);
        /* Annotation happens after the early launcher origin listener. Field92
         * here identifies an input-capable window, not a fullscreen shell bbox. */
        pointer_tap=CGEventTapCreate(kCGAnnotatedSessionEventTap,kCGTailAppendEventTap,kCGEventTapOptionListenOnly,
                                    mouse_mask,pointer_callback,NULL);
        if(pointer_tap)pointer_source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,pointer_tap,0);
        if(pointer_source){CFRunLoopAddSource(launcher_runloop,pointer_source,kCFRunLoopCommonModes);CGEventTapEnable(pointer_tap,true);}
        atomic_store_explicit(&pointer_ready,pointer_source?1:-1,memory_order_release);
    } else atomic_store_explicit(&pointer_ready,-1,memory_order_release);
    pthread_mutex_lock(&launcher_mu);
    launcher_ready = launcher_source ? 1 : -1;
    pthread_cond_broadcast(&launcher_cond);
    pthread_mutex_unlock(&launcher_mu);
    if (launcher_source) CFRunLoopRun();
    atomic_store_explicit(&pointer_ready,0,memory_order_release);
    if(pointer_tap){CGEventTapEnable(pointer_tap,false);CFRelease(pointer_tap);pointer_tap=NULL;}
    if(pointer_source){CFRunLoopRemoveSource(launcher_runloop,pointer_source,kCFRunLoopCommonModes);CFRelease(pointer_source);pointer_source=NULL;}
    if (launcher_tap) { CGEventTapEnable(launcher_tap, false); CFRelease(launcher_tap); }
    if (launcher_source) { CFRunLoopRemoveSource(launcher_runloop, launcher_source, kCFRunLoopCommonModes); CFRelease(launcher_source); }
    if (launcher_runloop) CFRelease(launcher_runloop);
    pthread_mutex_lock(&launcher_mu);
    launcher_source = NULL; launcher_tap = NULL; launcher_runloop = NULL;
    if (launcher_ready > 0) launcher_ready = 0;
    pthread_mutex_unlock(&launcher_mu);
    return NULL;
}
int ax_launcher_start(void) {
    pthread_mutex_lock(&launcher_mu);
    if (!launcher_started) {
        launcher_started = 1;
        if (pthread_create(&launcher_thread, NULL, launcher_worker, NULL)) { launcher_started = 0; launcher_ready = -2; }
    }
    /* Start is asynchronous: callers poll available without blocking their main loop. */
    int value = launcher_ready;
    pthread_mutex_unlock(&launcher_mu);
    return value < 0 ? value : 0;
}
int ax_launcher_available(void) {
    pthread_mutex_lock(&launcher_mu); int value = launcher_ready; pthread_mutex_unlock(&launcher_mu); return value;
}
void ax_launcher_stop(void) {
    pthread_mutex_lock(&launcher_mu);
    int started = launcher_started;
    CFRunLoopRef loop = launcher_runloop ? (CFRunLoopRef)CFRetain(launcher_runloop) : NULL;
    pthread_mutex_unlock(&launcher_mu);
    if (loop) { CFRunLoopStop(loop); CFRelease(loop); }
    /* A failed or still-starting tap has no loop. Joining while startup pending is avoided. */
    if (!started || !loop) return;
    pthread_join(launcher_thread, NULL);
    pthread_mutex_lock(&launcher_mu); launcher_started = 0; pthread_mutex_unlock(&launcher_mu);
}
void ax_launcher_cache(uint64_t space, int32_t front_pid, const uint32_t *wids, uint32_t count) {
    ax_launcher_cache_dock(space, front_pid, wids, NULL, count);
}
void ax_launcher_cache_dock(uint64_t space, int32_t front_pid, const uint32_t *wids, const double *rects, uint32_t count) {
    pthread_mutex_lock(&launcher_mu);
    launcher_space = space; launcher_front = front_pid;
    launcher_count = wids ? (count > 16 ? 16 : count) : 0;
    for (uint32_t i = 0; i < launcher_count; ++i) {
        launcher_dock[i] = wids[i];
        for (int j = 0; j < 4; ++j) launcher_rects[i][j] = rects ? rects[4*i+j] : 0;
    }
    pthread_mutex_unlock(&launcher_mu);
}
int ax_launcher_read(uint64_t after_sequence, ax_launcher_intent *out) {
    if (!out) return -1;
    pthread_mutex_lock(&launcher_mu);
    *out = launcher_value;
    pthread_mutex_unlock(&launcher_mu);
    return out->sequence > after_sequence ? 1 : 0;
}
void ax_launcher_clear(uint64_t sequence) {
    pthread_mutex_lock(&launcher_mu);
    if (launcher_value.sequence == sequence) launcher_value.kind = 0;
    pthread_mutex_unlock(&launcher_mu);
}
