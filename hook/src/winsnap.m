// Snapshot windows for the daemon in one call within its own process (no fork): all layer-0 windows
// (including hidden windows and other desktops), each with its Space and on-screen status;
// read the active Space before and after the list: if it changes during the snapshot, stable=0.
// CGWindowList frames are VISIBLE frames (with server transform); engine provides actual frames (chan A).
// Build: clang -O2 -fobjc-arc -dynamiclib -framework AppKit -framework ApplicationServices
//         src/winsnap.m -o build/libwinsnap.dylib
#import <AppKit/AppKit.h>
#include "snapshot_policy.h"
#include "focus_monitor.h"

static BOOL menuTracking;
static void menuNotice(CFNotificationCenterRef center, void *observer, CFStringRef name,
                       const void *object, CFDictionaryRef info) {
    menuTracking = CFEqual(name, CFSTR("com.apple.HIToolbox.beginMenuTrackingNotification"));
}

// Pump distributed AppKit tracking notices on the daemon's main thread without capturing pixels.
int ws_menu_tracking(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterRef c = CFNotificationCenterGetDistributedCenter();
        CFNotificationCenterAddObserver(c, &menuTracking, menuNotice,
            CFSTR("com.apple.HIToolbox.beginMenuTrackingNotification"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(c, &menuTracking, menuNotice,
            CFSTR("com.apple.HIToolbox.endMenuTrackingNotification"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0, true);
    return menuTracking;
}

// Accessory panels can own input without changing the frontmost application.
// Query window metadata only; the ordinary Dock and its tooltips are not panels.
int ws_input_overlay(void) {
    @autoreleasepool {
        CFArrayRef windows = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        if (!windows) return 1;  // Do not steal focus while native ownership is unknown.
        BOOL active = NO;
        for (NSDictionary *window in (__bridge NSArray *)windows) {
            if ([window[(id)kCGWindowLayer] intValue] > 0 &&
                [window[(id)kCGWindowIsOnscreen] boolValue] &&
                [window[(id)kCGWindowAlpha] doubleValue] > .001) {
                NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:
                    [window[(id)kCGWindowOwnerPID] intValue]];
                BOOL spotlight=[app.bundleIdentifier isEqualToString:@"com.apple.Spotlight"];
                CGRect bounds=CGRectZero;
                NSDictionary *raw=window[(id)kCGWindowBounds];
                if (raw) CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)raw,&bounds);
                BOOL dockPanel=[app.bundleIdentifier isEqualToString:@"com.apple.dock"] &&
                    [app.executableURL.path isEqualToString:@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"] &&
                    bounds.size.width>200 && bounds.size.height>200;
                if(spotlight || dockPanel) {active=YES;break;}
            }
        }
        CFRelease(windows);
        return active;
    }
}

typedef int CGSConnectionID;
extern CGSConnectionID SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(CGSConnectionID cid);
extern CFArrayRef SLSCopySpacesForWindows(CGSConnectionID cid, int mask, CFArrayRef wids);
extern CFArrayRef SLSCopyManagedDisplaySpaces(CGSConnectionID cid);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(CGSConnectionID cid, uint32_t owner, CFArrayRef spaces,
                                                   uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);

// wid -> Space for every window: one query per desktop (previously one per window, ~35 RPCs
// to WindowServer per snapshot, 60 snapshots/sec).
static NSMutableDictionary *current_display_spaces(CFArrayRef displays) {
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    if (!displays) return current;
    for (NSDictionary *d in (__bridge NSArray *)displays) {
        NSNumber *sid = d[@"Current Space"][@"id64"] ?: d[@"Current Space"][@"ManagedSpaceID"];
        if (d[@"Display Identifier"] && sid) current[d[@"Display Identifier"]] = sid;
    }
    return current;
}

static NSMutableDictionary *space_map(CGSConnectionID cid, NSMutableDictionary *types, NSMutableSet *fullscreen,
                                     NSMutableDictionary *displayCurrent) {
    NSMutableDictionary *m = [NSMutableDictionary dictionary];
    CFArrayRef ds = SLSCopyManagedDisplaySpaces(cid);
    if (!ds) return m;
    [displayCurrent addEntriesFromDictionary:current_display_spaces(ds)];
    for (NSDictionary *d in (__bridge NSArray *)ds) {
        for (NSDictionary *sp in d[@"Spaces"]) {
            NSNumber *sid = sp[@"id64"] ?: sp[@"ManagedSpaceID"];
            if (!sid) continue;
            NSNumber *type = sp[@"type"] ?: @0;
            types[sid] = type;
            uint64_t set = 0, clear = 0;
            CFArrayRef ws = SLSCopyWindowsWithOptionsAndTags(cid, 0, (__bridge CFArrayRef) @[ sid ], 0x7, &set, &clear);
            if (!ws) continue;
            for (NSNumber *w in (__bridge NSArray *)ws) {
                if (!m[w]) m[w] = sid;
                if (type.intValue == 4) [fullscreen addObject:w];
            }
            CFRelease(ws);
        }
    }
    CFRelease(ds);
    return m;
}

static NSString *esc(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:@[ s ?: @"" ] options:0 error:nil];
    NSString *j = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return [j substringWithRange:NSMakeRange(1, j.length - 2)];       // already quoted
}

// Write JSON to buf; return length or -required_size if buf is too small.
int ws_snapshot(char *buf, int cap) {
    @autoreleasepool {
        CGSConnectionID cid = SLSMainConnectionID();
        uint64_t sp0 = SLSGetActiveSpace(cid);
        NSScreen *s = NSScreen.screens.firstObject;
        CGFloat H = NSMaxY(s.frame);
        NSRect v = s.visibleFrame;
        NSMutableDictionary *space_types = [NSMutableDictionary dictionary];
        NSMutableSet *fullscreen = [NSMutableSet set];
        NSMutableDictionary *displayCurrent = [NSMutableDictionary dictionary];
        NSDictionary *spm = getenv("WINSNAP_OLD") ? nil : space_map(cid, space_types, fullscreen, displayCurrent);
        NSArray<NSScreen *> *screens = NSScreen.screens;
        NSMutableArray *monitors = [NSMutableArray array];
        FocusMonitorRect monitorRects[screens.count ?: 1];
        for (NSScreen *display in screens) {
            CGDirectDisplayID did = [display.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
            CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(did);
            NSString *key = uuid ? CFBridgingRelease(CFUUIDCreateString(NULL, uuid)) : @"";
            if (uuid) CFRelease(uuid);
            NSRect f = display.frame, visible = display.visibleFrame;
            NSDictionary *frame = @{@"x": @(f.origin.x), @"y": @(H - NSMaxY(f)),
                                    @"w": @(f.size.width), @"h": @(f.size.height)};
            NSDictionary *work = @{@"x": @(visible.origin.x), @"y": @(H - NSMaxY(visible)),
                                   @"w": @(visible.size.width), @"h": @(visible.size.height)};
            NSNumber *current = displayCurrent[key] ?: displayCurrent[@"Main"];
            if (!current && display == s) current = @(sp0);
            monitorRects[monitors.count] = (FocusMonitorRect){f.origin.x, H - NSMaxY(f), f.size.width, f.size.height};
            [monitors addObject:@{@"id": @(did), @"screen": frame, @"visible": work, @"space": current ?: @0}];
        }
        NSMutableArray *workspaceNative = [NSMutableArray array];
        CFArrayRef workspaceDisplays = SLSCopyManagedDisplaySpaces(cid);
        if (workspaceDisplays) {
            for (NSDictionary *display in (__bridge NSArray *)workspaceDisplays) {
                NSString *identifier = display[@"Display Identifier"];
                NSDictionary *current = display[@"Current Space"];
                NSNumber *sid = current[@"id64"] ?: current[@"ManagedSpaceID"];
                for (NSDictionary *space in display[@"Spaces"]) {
                    NSNumber *candidate = space[@"id64"] ?: space[@"ManagedSpaceID"];
                    if (identifier && sid && [candidate isEqual:sid])
                        [workspaceNative addObject:@{@"display":identifier,@"sid":sid,
                            @"uuid":space[@"uuid"] ?: space[@"UUID"] ?: @"",@"type":space[@"type"] ?: @(-1)}];
                }
            }
            CFRelease(workspaceDisplays);
        }
        NSMutableString *o = [NSMutableString string];
        [o appendFormat:@"{\"screen\":{\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},",
                        s.frame.origin.x, H - NSMaxY(s.frame), s.frame.size.width, s.frame.size.height];
        [o appendFormat:@"\"visible\":{\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},",
                        v.origin.x, H - NSMaxY(v), v.size.width, v.size.height];
        NSData *monitorJSON = [NSJSONSerialization dataWithJSONObject:monitors options:0 error:nil];
        [o appendFormat:@"\"monitors\":%@,", [[NSString alloc] initWithData:monitorJSON encoding:NSUTF8StringEncoding]];
        NSData *workspaceJSON = [NSJSONSerialization dataWithJSONObject:workspaceNative options:0 error:nil];
        [o appendFormat:@"\"workspace_native\":%@,", [[NSString alloc] initWithData:workspaceJSON encoding:NSUTF8StringEncoding]];
        [o appendFormat:@"\"front_pid\":%d,\"windows\":[",
                        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier];
        // First on-screen windows in TRUE z-order (OnScreenOnly goes front to back; OptionAll
        // does not guarantee order, which previously produced an incorrect front window), then the rest.
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
            int layer = [d[(id)kCGWindowLayer] intValue];
            BOOL ordered = [d[(id)kCGWindowIsOnscreen] boolValue];
            CGRect r = CGRectZero;
            CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &r);
            if (!snapshot_include(layer, ordered, r.size.width, r.size.height)) continue;
            NSNumber *wid = d[(id)kCGWindowNumber];
            uint64_t sp = 0;
            if (spm) sp = [spm[wid] unsignedLongLongValue];
            else {
                CFArrayRef sps = SLSCopySpacesForWindows(cid, 7, (__bridge CFArrayRef) @[ wid ]);
                if (sps && CFArrayGetCount(sps) > 0)
                    sp = [(__bridge NSNumber *)CFArrayGetValueAtIndex(sps, 0) unsignedLongLongValue];
                if (sps) CFRelease(sps);
            }
            if (!sp && ordered && layer != 0) sp = sp0;
            size_t monitorIndex = focus_monitor_for((FocusMonitorRect){r.origin.x, r.origin.y, r.size.width, r.size.height},
                                                    monitorRects, monitors.count);
            unsigned int monitorID = monitors.count ? [monitors[monitorIndex][@"id"] unsignedIntValue] : 0;
            [o appendFormat:@"%@{\"wid\":%d,\"pid\":%d,\"owner\":%@,\"name\":%@,\"x\":%.1f,\"y\":%.1f,"
                             "\"w\":%.1f,\"h\":%.1f,\"on\":%d,\"space\":%llu,\"layer\":%d,\"alpha\":%.3f,\"native_fullscreen\":%d,\"monitor\":%u}",
                            first ? @"" : @",", wid.intValue, [d[(id)kCGWindowOwnerPID] intValue],
                            esc(d[(id)kCGWindowOwnerName]), esc(d[(id)kCGWindowName]),
                            r.origin.x, r.origin.y, r.size.width, r.size.height,
                            ordered, sp, layer, [d[(id)kCGWindowAlpha] doubleValue], [fullscreen containsObject:wid], monitorID];
            first = NO;
        }
        CFRelease(a);
        uint64_t sp1 = SLSGetActiveSpace(cid);
        BOOL displaysStable = YES;
        if (screens.count > 1) {
            CFArrayRef after = SLSCopyManagedDisplaySpaces(cid);
            displaysStable = after && [displayCurrent isEqualToDictionary:current_display_spaces(after)];
            if (after) CFRelease(after);
        }
        NSArray<NSScreen *> *afterScreens = NSScreen.screens;
        displaysStable = displaysStable && afterScreens.count == monitors.count;
        CGFloat afterH = NSMaxY(afterScreens.firstObject.frame);
        for (NSUInteger i = 0; displaysStable && i < afterScreens.count; ++i) {
            NSScreen *display = afterScreens[i];
            NSDictionary *before = monitors[i], *frame = before[@"screen"], *work = before[@"visible"];
            NSRect f = display.frame, a = display.visibleFrame;
            displaysStable = [display.deviceDescription[@"NSScreenNumber"] isEqual:before[@"id"]] &&
                f.origin.x == [frame[@"x"] doubleValue] && afterH - NSMaxY(f) == [frame[@"y"] doubleValue] &&
                f.size.width == [frame[@"w"] doubleValue] && f.size.height == [frame[@"h"] doubleValue] &&
                a.origin.x == [work[@"x"] doubleValue] && afterH - NSMaxY(a) == [work[@"y"] doubleValue] &&
                a.size.width == [work[@"w"] doubleValue] && a.size.height == [work[@"h"] doubleValue];
        }
        [o appendFormat:@"],\"space\":%llu,\"space_type\":%d,\"stable\":%d}", sp1,
            [space_types[@(sp1)] intValue], sp0 == sp1 && displaysStable];
        const char *u = o.UTF8String;
        int n = (int)strlen(u);
        if (n + 1 > cap) return -(n + 1);
        memcpy(buf, u, n + 1);
        return n;
    }
}

// Window operations by CGS wid through Accessibility (parent process needs permission).
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

// 0 = success; -1 = no window; -2 = no button / AX error
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

// Focus a specific window (rather than the entire application).
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
