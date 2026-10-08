// Снимок окон для демона одним вызовом в его же процессе (без форка): все окна слоя 0
// (вкл. скрытые и на других рабочих столах), у каждого — его Space, видно ли на экране;
// активный Space читается до и после списка: если он сменился посреди снимка — stable=0.
// Рамки из CGWindowList — ВИДИМЫЕ (с серверным трансформом); реальные даёт движок (chan A).
// Сборка: clang -O2 -fobjc-arc -dynamiclib -framework AppKit -framework ApplicationServices
//         src/winsnap.m -o build/libwinsnap.dylib
#import <AppKit/AppKit.h>

typedef int CGSConnectionID;
extern CGSConnectionID SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef wids);

static NSString *esc(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[ s ?: @"" ] options:0 error:nil];
    NSString *j = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [j substringWithRange:NSMakeRange(1, j.length - 2)];       // уже в кавычках
}

// JSON в buf; возвращает длину или -нужный_размер, если buf мал.
int ws_snapshot(char *buf, int cap) {
    @autoreleasepool {
        CGSConnectionID cid = SLSMainConnectionID();
        uint64_t sp0 = SLSGetActiveSpace(cid);
        NSScreen *s = NSScreen.screens.firstObject;
        CGFloat H = NSMaxY(s.frame);
        NSRect v = s.visibleFrame;
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"{\"screen\":{\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},",
                        s.frame.origin.x, H - NSMaxY(s.frame), s.frame.size.width, s.frame.size.height];
        [o appendFormat:@"\"visible\":{\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},",
                        v.origin.x, H - NSMaxY(v), v.size.width, v.size.height];
        [o appendFormat:@"\"front_pid\":%d,\"windows\":[",
                        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier];
        // Сначала окна на экране в НАСТОЯЩЕМ z-порядке (OnScreenOnly идёт спереди назад; OptionAll
        // порядок не гарантирует — из-за этого «переднее окно» было неверным), потом остальные.
        CFArrayRef on = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                   kCGNullWindowID);
        CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements,
                                                    kCGNullWindowID);
        NSMutableArray *m = [NSMutableArray arrayWithArray:(__bridge NSArray *)on];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *d in m) [seen addObject:d[(id)kCGWindowNumber]];
        for (NSDictionary *d in (__bridge NSArray *)all)
            if (![seen containsObject:d[(id)kCGWindowNumber]]) [m addObject:d];
        CFRelease(on); CFRelease(all);
        CFArrayRef a = (__bridge_retained CFArrayRef)m;
        BOOL first = YES;
        for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
            NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(a, i);
            if ([d[(id)kCGWindowLayer] intValue] != 0) continue;
            CGRect r = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &r);
            if (r.size.width < 60 || r.size.height < 60) continue;
            NSNumber *wid = d[(id)kCGWindowNumber];
            CFArrayRef sps = SLSCopySpacesForWindows(cid, 7, (__bridge CFArrayRef) @[ wid ]);
            uint64_t sp = 0;
            if (sps && CFArrayGetCount(sps) > 0)
                sp = [(__bridge NSNumber *)CFArrayGetValueAtIndex(sps, 0) unsignedLongLongValue];
            if (sps) CFRelease(sps);
            [o appendFormat:@"%@{\"wid\":%d,\"pid\":%d,\"owner\":%@,\"name\":%@,\"x\":%.1f,\"y\":%.1f,"
                             "\"w\":%.1f,\"h\":%.1f,\"on\":%d,\"space\":%llu}",
                            first ? @"" : @",", wid.intValue, [d[(id)kCGWindowOwnerPID] intValue],
                            esc(d[(id)kCGWindowOwnerName]), esc(d[(id)kCGWindowName]),
                            r.origin.x, r.origin.y, r.size.width, r.size.height,
                            [d[(id)kCGWindowIsOnscreen] boolValue], sp];
            first = NO;
        }
        CFRelease(a);
        uint64_t sp1 = SLSGetActiveSpace(cid);
        [o appendFormat:@"],\"space\":%llu,\"stable\":%d}", sp1, sp0 == sp1];
        const char *u = o.UTF8String;
        int n = (int)strlen(u);
        if (n + 1 > cap) return -(n + 1);
        memcpy(buf, u, n + 1);
        return n;
    }
}

// ── операции над окном по CGS wid через Accessibility (нужен доступ у процесса-родителя) ──
extern AXError _AXUIElementGetWindow(AXUIElementRef el, CGWindowID *wid);

static AXUIElementRef ax_window(pid_t pid, CGWindowID wid) {
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    CFArrayRef wins = NULL;
    AXUIElementRef found = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, (CFTypeRef *)&wins) == kAXErrorSuccess && wins) {
        for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
            AXUIElementRef w = (AXUIElementRef)CFArrayGetValueAtIndex(wins, i);
            CGWindowID id = 0;
            if (_AXUIElementGetWindow(w, &id) == kAXErrorSuccess && id == wid) { found = (AXUIElementRef)CFRetain(w); break; }
        }
        CFRelease(wins);
    }
    CFRelease(app);
    return found;
}

// 0 — успех; -1 нет окна; -2 нет кнопки/ошибка AX
int ws_close(int pid, unsigned wid) {
    AXUIElementRef w = ax_window(pid, wid);
    if (!w) return -1;
    AXUIElementRef btn = NULL;
    int r = -2;
    if (AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute, (CFTypeRef *)&btn) == kAXErrorSuccess && btn) {
        r = AXUIElementPerformAction(btn, kAXPressAction) == kAXErrorSuccess ? 0 : -2;
        CFRelease(btn);
    }
    CFRelease(w);
    return r;
}

// Фокус на конкретное окно (а не на приложение целиком).
int ws_focus(int pid, unsigned wid) {
    AXUIElementRef w = ax_window(pid, wid);
    if (!w) return -1;
    AXUIElementSetAttributeValue(w, kAXMainAttribute, kCFBooleanTrue);
    AXUIElementPerformAction(w, kAXRaiseAction);
    CFRelease(w);
    @autoreleasepool {
        [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] activateWithOptions:0];
    }
    return 0;
}

int ws_quit(int pid) {
    @autoreleasepool {
        return [[NSRunningApplication runningApplicationWithProcessIdentifier:pid] terminate] ? 0 : -1;
    }
}
