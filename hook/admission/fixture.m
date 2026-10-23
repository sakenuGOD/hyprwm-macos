// ROOT ONLY: running this binary creates disposable native windows.
#import "admission.h"
#import "client.h"
#include <stdio.h>
#include <unistd.h>

static NSMutableDictionary<NSString *, NSWindow *> *windows;
static NSUInteger serial;
static NSString *path;
static double fixtureBudget;
static void output(NSDictionary *event) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static NSArray *frame(NSWindow *w) {
    NSRect f = w.frame;
    return @[@(f.origin.x), @(NSMaxY(NSScreen.screens.firstObject.frame) - NSMaxY(f)), @(f.size.width), @(f.size.height)];
}
@interface FixtureView : NSView
@property BOOL first;
@end
@implementation FixtureView
- (void)drawRect:(NSRect)rect {
    (void)rect;
    [[NSColor colorWithCalibratedRed:.12 green:.22 blue:.32 alpha:1] set];
    NSRectFill(self.bounds);
    [self.window.title drawAtPoint:NSMakePoint(20, 25) withAttributes:@{NSForegroundColorAttributeName:NSColor.whiteColor}];
    if (!self.first) {
        self.first = YES;
        output(@{@"event": @"first_draw", @"time": @(HAClock()), @"wid": @(self.window.windowNumber), @"frame": frame(self.window)});
    }
}
@end
static NSWindow *create(NSString *kind) {
    NSString *ident = [NSString stringWithFormat:@"%lu", (unsigned long)++serial];
    Class cls = [kind isEqual:@"panel"] ? NSPanel.class : NSWindow.class;
    NSWindow *w = [[cls alloc] initWithContentRect:NSMakeRect(300, 240, 440, 300)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed = NO;
    w.tabbingMode = NSWindowTabbingModeDisallowed;
    w.title = [NSString stringWithFormat:@"Admission fixture %@ %@", ident, kind];
    w.contentView = [[FixtureView alloc] initWithFrame:NSMakeRect(0, 0, 440, 300)];
    windows[ident] = w;
    // Do not ask for windowNumber before ordering: exercise deferred WID creation.
    output(@{@"event": @"created", @"id": ident, @"kind": kind, @"time": @(HAClock()), @"frame": frame(w)});
    return w;
}
static void command(NSString *line) {
    NSArray *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *action = parts.firstObject;
    NSWindow *w = parts.count > 1 ? windows[parts[1]] : nil;
    if ([action isEqual:@"quit"]) {
        hypradmission_uninstall();
        for (NSWindow *owned in windows.allValues) [owned close];
        [NSApp terminate:nil]; return;
    }
    if ([action isEqual:@"new"] || [action isEqual:@"panel"]) [create(action) makeKeyAndOrderFront:nil];
    else if ([action isEqual:@"burst"]) {
        NSInteger n = parts.count > 1 ? [parts[1] integerValue] : 4;
        for (NSInteger i = 0; i < MIN(MAX(n, 1), 16); i++) [create(@"normal") makeKeyAndOrderFront:nil];
    } else if ([action isEqual:@"sheet"] && w) [w beginSheet:create(@"sheet") completionHandler:nil];
    else if ([action isEqual:@"child"] && w) [w addChildWindow:create(@"child") ordered:NSWindowAbove];
    else if ([action isEqual:@"end-sheet"] && w.attachedSheet) {
        NSWindow *sheet = w.attachedSheet;
        [w endSheet:sheet]; [sheet orderOut:nil];
    } else if ([action isEqual:@"close"] && w) [w close];
    else if ([action isEqual:@"reopen"] && w) [w makeKeyAndOrderFront:nil];
    else if ([action isEqual:@"uninstall"]) hypradmission_uninstall();
    else if ([action isEqual:@"install"]) output(@{@"event": @"install", @"result": @(hypradmission_install(path, fixtureBudget, output))});
    else if ([action isEqual:@"reinstall"]) {
        hypradmission_uninstall();
        output(@{@"event": @"installed", @"result": @(hypradmission_install(path, fixtureBudget, output))});
    }
    else if ([action isEqual:@"dump"]) {
        NSMutableArray *list = [NSMutableArray new];
        for (NSString *ident in windows) {
            NSWindow *owned = windows[ident];
            [list addObject:@{@"id": ident, @"wid": @(owned.windowNumber), @"visible": @(owned.visible), @"frame": frame(owned)}];
        }
        output(@{@"event": @"dump", @"windows": list});
    }
    output(@{@"event": @"command_done", @"command": line, @"time": @(HAClock())});
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 4) { fprintf(stderr, "usage: fixture SOCKET BUDGET_MS SERVER_EXECUTABLE\n"); return 2; }
        setvbuf(stdout, NULL, _IOLBF, 0);
        path = [NSString stringWithUTF8String:argv[1]];
        fixtureBudget = argc > 2 ? atof(argv[2]) : 12;
        HASetServerExecutable(@(argv[3]));
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSWindow setAllowsAutomaticWindowTabbing:NO];
        windows = [NSMutableDictionary new];
        int status = hypradmission_install(path, fixtureBudget, output);
        output(@{@"event": @"ready", @"pid": @(getpid()), @"installed": @(status), @"budget_ms": @(fixtureBudget)});
        if (status != 0) return 3;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *line = NULL; size_t length = 0;
            while (getline(&line, &length, stdin) >= 0) {
                NSString *text = [NSString stringWithUTF8String:line];
                dispatch_async(dispatch_get_main_queue(), ^{ command(text); });
            }
            free(line);
            dispatch_async(dispatch_get_main_queue(), ^{ command(@"quit"); });
        });
        [NSApp run];
    }
}
