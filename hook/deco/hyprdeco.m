// hyprdeco — окна-подложки под окнами приложений (как фон/края буфера в Hyprland).
// Подложка: окно без рамки, сплошной цвет фона приложения, скругление как у окна, системная тень,
// мышь проходит насквозь. Движок в WindowServer каждый кадр ставит ей трансформ на видимую рамку B
// и альфу; здесь — только создание, цвет, реальная рамка и порядок «прямо под окном».
// Команды построчно в stdin, ответы в stdout:
//   new <key> <r> <g> <b> <radius> [a]  -> "wid <key> <wid>"   (r<0 — системный фон окна темы)
//   frame <key> <x> <y> <w> <h>         реальная рамка (глобальные pt, начало сверху слева)
//   color <key> <r> <g> <b>
//   below <key> <wid>                   поставить прямо под окном wid
//   del <key>
//   sample <key> <wid>                  цвет подложки = средний цвет правого столбца и нижней строки
//                                       буфера окна (как CLAMP_TO_EDGE в Hyprland), снимок ScreenCaptureKit
// Сборка: clang -O2 -fobjc-arc -framework AppKit -framework QuartzCore deco/hyprdeco.m -o build/hyprdeco
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>

static NSMutableDictionary<NSString *, NSWindow *> *wins;

static NSRect flip(double x, double y, double w, double h) {
    double H = NSScreen.screens.firstObject.frame.size.height;
    return NSMakeRect(x, H - y - h, w, h);
}

static void set_color(NSWindow *w, CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    w.contentView.layer.backgroundColor = [NSColor colorWithSRGBRed:r green:g blue:b alpha:a].CGColor;
}

// Снимок окна wid (маленький, 96×96) -> средний цвет края, ставится подложке key.
static void sample(NSString *key, CGWindowID wid) {
    [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent *c, NSError *e) {
        SCWindow *win = nil;
        for (SCWindow *x in c.windows) if (x.windowID == wid) { win = x; break; }
        if (!win) return;
        SCContentFilter *f = [[SCContentFilter alloc] initWithDesktopIndependentWindow:win];
        SCStreamConfiguration *cfg = [SCStreamConfiguration new];
        cfg.width = 96; cfg.height = 96; cfg.showsCursor = NO; cfg.ignoreShadowsSingleWindow = YES;
        [SCScreenshotManager captureImageWithFilter:f configuration:cfg completionHandler:^(CGImageRef img, NSError *e2) {
            if (!img) return;
            size_t W = 96, H = 96;
            uint8_t *px = calloc(W * H, 4);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef cx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
            CGContextDrawImage(cx, CGRectMake(0, 0, W, H), img);
            double s[4] = {0, 0, 0, 0}; long n = 0;
            for (size_t y = 12; y + 12 < H; y++) {            // правый столбец (в 2 px от края)
                for (size_t k = 3; k <= 6; k++) {
                    uint8_t *p = px + (y * W + W - k) * 4;
                    if (p[3] > 150) { s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; s[3] += p[3]; n++; break; }
                }
            }
            for (size_t x = 12; x + 12 < W; x++) {            // нижняя строка (в контексте CG — строка 2)
                for (size_t k = 3; k <= 6; k++) {
                    uint8_t *p = px + ((H - k) * W + x) * 4;
                    if (p[3] > 150) { s[0] += p[0]; s[1] += p[1]; s[2] += p[2]; s[3] += p[3]; n++; break; }
                }
            }
            CGContextRelease(cx); CGColorSpaceRelease(cs); free(px);
            if (n < 10) return;                               // край прозрачный — оставить прежний цвет
            double a = s[3] / n / 255.0;
            double r = s[0] / n / 255.0 / a, g = s[1] / n / 255.0 / a, b = s[2] / n / 255.0 / a;   // из premultiplied
            dispatch_async(dispatch_get_main_queue(), ^{
                NSWindow *w = wins[key];
                if (!w) return;
                set_color(w, r, g, b, a);
                printf("color %s %.3f %.3f %.3f %.3f\n", key.UTF8String, r, g, b, a);
                fflush(stdout);
            });
        }];
    }];
}

static void handle(NSString *line) {
    NSArray<NSString *> *a = [line componentsSeparatedByString:@" "];
    if (a.count < 2) return;
    NSString *cmd = a[0], *key = a[1];
    NSWindow *w = wins[key];
    if ([cmd isEqual:@"new"] && a.count >= 6) {
        if (!w) {
            w = [[NSWindow alloc] initWithContentRect:NSMakeRect(-10000, -10000, 100, 100)
                                            styleMask:NSWindowStyleMaskBorderless
                                              backing:NSBackingStoreBuffered defer:NO];
            w.releasedWhenClosed = NO;
            w.opaque = NO;
            w.backgroundColor = NSColor.clearColor;
            w.hasShadow = NO;          // видна только полоса B−A, тень всё равно была бы обрезана
            w.ignoresMouseEvents = YES;
            w.animationBehavior = NSWindowAnimationBehaviorNone;
            w.collectionBehavior = NSWindowCollectionBehaviorManaged | NSWindowCollectionBehaviorIgnoresCycle;
            NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 100, 100)];
            v.wantsLayer = YES;
            v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            w.contentView = v;
            w.alphaValue = 0.0;
            wins[key] = w;
        }
        w.contentView.layer.cornerRadius = a[5].doubleValue;
        w.contentView.layer.cornerCurve = kCACornerCurveContinuous;
        double al = a.count >= 7 ? a[6].doubleValue : 1.0;
        NSColor *c = a[2].doubleValue < 0 ? NSColor.windowBackgroundColor
                                          : [NSColor colorWithSRGBRed:a[2].doubleValue green:a[3].doubleValue
                                                                 blue:a[4].doubleValue alpha:1];
        __block CGColorRef cg = NULL;
        [NSApp.effectiveAppearance performAsCurrentDrawingAppearance:^{
            cg = CGColorRetain([c colorWithAlphaComponent:al].CGColor);
        }];
        w.contentView.layer.backgroundColor = cg;
        CGColorRelease(cg);
        [w orderBack:nil];
        [w invalidateShadow];
        printf("wid %s %ld\n", key.UTF8String, (long)w.windowNumber);
    } else if (!w) {
        return;
    } else if ([cmd isEqual:@"frame"] && a.count >= 6) {
        [w setFrame:flip(a[2].doubleValue, a[3].doubleValue, a[4].doubleValue, a[5].doubleValue) display:YES];
        [w invalidateShadow];
    } else if ([cmd isEqual:@"color"] && a.count >= 5) {
        w.contentView.layer.backgroundColor = [NSColor colorWithSRGBRed:a[2].doubleValue green:a[3].doubleValue
                                                                    blue:a[4].doubleValue alpha:1].CGColor;
    } else if ([cmd isEqual:@"below"] && a.count >= 3) {
        [w orderWindow:NSWindowBelow relativeTo:a[2].integerValue];
    } else if ([cmd isEqual:@"sample"] && a.count >= 3) {
        sample(key, (CGWindowID)a[2].integerValue);
    } else if ([cmd isEqual:@"del"]) {
        [w orderOut:nil];
        [wins removeObjectForKey:key];
    }
    fflush(stdout);
}

int main(void) {
    @autoreleasepool {
        wins = [NSMutableDictionary dictionary];
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        setvbuf(stdout, NULL, _IOLBF, 0);
        [NSThread detachNewThreadWithBlock:^{
            char buf[512];
            while (fgets(buf, sizeof buf, stdin)) {
                NSString *s = [[NSString stringWithUTF8String:buf]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                dispatch_sync(dispatch_get_main_queue(), ^{ handle(s); });
            }
            exit(0);
        }];
        [NSApp run];
    }
}
