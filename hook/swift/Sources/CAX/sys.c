// Обёртки приватных функций SkyLight и CoreGraphics — 1:1 с ctypes-вызовами hook/hyprwm.py.
#include <ApplicationServices/ApplicationServices.h>
#include <stdint.h>

extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *owner);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
extern CGError _SLPSGetFrontProcess(ProcessSerialNumber *psn);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *r);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *a);
extern CGError SLSMoveWindowsToManagedSpace(int cid, CFArrayRef wids, uint64_t space);
extern uint64_t SLSGetActiveSpace(int cid);
extern OSStatus GetProcessPID(const ProcessSerialNumber *psn, pid_t *pid);

static int cid;
int hs_cid(void) {                     // соединение с WS — лениво, только когда демон реально работает
    if (!cid) cid = SLSMainConnectionID();
    return cid;
}

int hs_win_pid_level(unsigned wid, int *pid, int *level) {
    int o = 0; pid_t p = 0; int lv = 0;
    if (SLSGetWindowOwner(hs_cid(), wid, &o) || SLSConnectionGetPID(o, &p)) return -1;
    SLSGetWindowLevel(hs_cid(), wid, &lv);      // как в Python: ошибка уровня не проверяется
    *pid = p; *level = lv;
    return 0;
}

int hs_front_pid(int *pid) {
    ProcessSerialNumber psn = {0, 0};
    pid_t p = 0;
    if (_SLPSGetFrontProcess(&psn) || GetProcessPID(&psn, &p)) return -1;
    *pid = p;
    return 0;
}

int hs_win_bounds(unsigned wid, double *out) {
    CGRect r = CGRectZero;
    if (SLSGetWindowBounds(hs_cid(), wid, &r)) return -1;
    out[0] = r.origin.x; out[1] = r.origin.y; out[2] = r.size.width; out[3] = r.size.height;
    return 0;
}

int hs_win_alpha(unsigned wid, float *a) {
    *a = -1;
    return SLSGetWindowAlpha(hs_cid(), wid, a) ? -1 : 0;
}

void hs_move_to_space(const int32_t *wids, int n, uint64_t space) {
    CFNumberRef nums[n > 0 ? n : 1];
    for (int i = 0; i < n; i++) nums[i] = CFNumberCreate(NULL, kCFNumberSInt32Type, &wids[i]);
    CFArrayRef a = CFArrayCreate(NULL, (const void **)nums, n, &kCFTypeArrayCallBacks);
    SLSMoveWindowsToManagedSpace(hs_cid(), a, space);
    CFRelease(a);
    for (int i = 0; i < n; i++) CFRelease(nums[i]);
}

uint64_t hs_active_space(void) { return SLSGetActiveSpace(hs_cid()); }

void hs_mouse(double *x, double *y) {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = CGEventGetLocation(e);
    CFRelease(e);
    *x = p.x; *y = p.y;
}

// Как в Python: CGEventSourceButtonState(1, 0). 1 = kCGEventSourceStateHIDSystemState (комментарий в
// hyprwm.py говорит «combinedSessionState», но число там 1 — оставлено 1:1).
int hs_mouse_down(void) { return CGEventSourceButtonState((CGEventSourceStateID)1, kCGMouseButtonLeft); }

void hs_spotlight(void) {               // Cmd+Space
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, 49, down);
        CGEventSetFlags(e, (CGEventFlags)(1 << 20));
        CGEventPost((CGEventTapLocation)0, e);
        CFRelease(e);
    }
}
