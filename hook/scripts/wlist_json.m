// Окна текущего рабочего стола + геометрия экрана, в JSON — вход для движка раскладки.
// clang -fobjc-arc -framework AppKit -framework ApplicationServices -o wlist_json wlist_json.m
#import <AppKit/AppKit.h>

int main(void) {
    @autoreleasepool {
        NSScreen *s = NSScreen.screens.firstObject;
        CGFloat H = NSMaxY(s.frame);                       // перевод в координаты CG (0 сверху)
        NSRect v = s.visibleFrame;
        printf("{\n \"screen\": {\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},\n",
               s.frame.origin.x, H - NSMaxY(s.frame), s.frame.size.width, s.frame.size.height);
        printf(" \"visible\": {\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f},\n",
               v.origin.x, H - NSMaxY(v), v.size.width, v.size.height);
        printf(" \"front_pid\": %d,\n", NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
        printf(" \"windows\": [\n");

        CFArrayRef a = CGWindowListCopyWindowInfo(
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID);
        BOOL first = YES;
        for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
            NSDictionary *d = (__bridge NSDictionary *)CFArrayGetValueAtIndex(a, i);
            int layer = [d[(id)kCGWindowLayer] intValue];
            CGRect r = CGRectZero;
            CGRectMakeWithDictionaryRepresentation(
                (__bridge CFDictionaryRef)d[(id)kCGWindowBounds], &r);
            if (layer != 0 || r.size.width < 120 || r.size.height < 120) continue;
            NSString *owner = d[(id)kCGWindowOwnerName] ?: @"?";
            NSString *name = d[(id)kCGWindowName] ?: @"";
            NSString *esc = [[name stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
            printf("%s  {\"wid\":%d,\"pid\":%d,\"owner\":\"%s\",\"name\":\"%s\","
                   "\"x\":%.0f,\"y\":%.0f,\"w\":%.0f,\"h\":%.0f}",
                   first ? "" : ",\n", [d[(id)kCGWindowNumber] intValue],
                   [d[(id)kCGWindowOwnerPID] intValue],
                   [owner UTF8String], [esc UTF8String],
                   r.origin.x, r.origin.y, r.size.width, r.size.height);
            first = NO;
        }
        printf("\n ]\n}\n");
        CFRelease(a);
    }
    return 0;
}
