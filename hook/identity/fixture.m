// ROOT-OWNED LIVE PROBE: creates only its own disposable AppKit windows.
// Agent builds this file but must not run it. Commands: dump, select a|b, select-key a|b,
// close a|b, reopen a|b, join b, detach b, uninstall, install, quit. Optional --floating.
#import "identity.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include "../tests/owned_fixture_protocol.h"
#include "../tests/owned_tab_pixels.h"

static NSMutableDictionary<NSString *, NSWindow *> *windows;
static int transportConnection, transportResult;
static OwnedTabPixels *pixels;
static void pixel_reply(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
static void dump(void) {
    char *json = hypridentity_copy_json();
    if (json && transportConnection) {
        NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
        NSMutableDictionary *value = [[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] mutableCopy];
        value[@"transport_connection"] = @(transportConnection);
        value[@"transport_result"] = @(transportResult);
        NSData *out = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
        puts([[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding].UTF8String);
    } else puts(json ?: "{\"installed\":false}");
    free(json);
}
static void command(NSString *line) {
    NSArray *parts = [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *action = parts.firstObject;
    NSWindow *window = parts.count > 1 ? windows[parts[1]] : nil;
    if ([action isEqual:@"pixels-start"]) {
        if(pixels) { pixel_reply(@{@"pixel_error":@"capture already started"}); return; }
        pixels=[OwnedTabPixels new];
        NSWindow *selected=windows[@"a"].tabGroup.selectedWindow;
        [pixels start:selected done:^(NSDictionary *value){ pixel_reply(value); }];
        return;
    }
    if ([action isEqual:@"pixels-stop"]) {
        if(!pixels) { pixel_reply(@{@"pixel_error":@"capture was not started"}); return; }
        [pixels stop:^(NSDictionary *value){ pixel_reply(value); pixels=nil; }];
        return;
    }
    if ([action isEqual:@"quit"]) {
        hypridentity_uninstall();
        for (NSWindow *owned in windows.allValues) [owned close];
        [NSApp terminate:nil];
        return;
    }
    if ([action isEqual:@"select"] && window) window.tabGroup.selectedWindow = window;
    else if ([action isEqual:@"dispose"]) {
        for(NSWindow *owned in windows.allValues) [owned orderOut:nil];
    }
    else if ([action isEqual:@"select-key"] && window) {
        window.tabGroup.selectedWindow = window;
        [window makeKeyAndOrderFront:nil];
        [NSApp activate];
    }
    else if ([action isEqual:@"close"] && window) [window close];
    else if ([action isEqual:@"reopen"] && window) [window makeKeyAndOrderFront:nil];
    else if ([action isEqual:@"join"] && window && window != windows[@"a"]) {
        [windows[@"a"] addTabbedWindow:window ordered:NSWindowAbove];
        window.tabGroup.selectedWindow = window;
    }
    else if ([action isEqual:@"detach"] && window) [window moveTabToNewWindow:nil];
    else if ([action isEqual:@"uninstall"]) hypridentity_uninstall();
    else if ([action isEqual:@"install"]) hypridentity_install();
    else if ([action isEqual:@"transport-start"]) {
        int (*mainConnection)(void) = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        transportConnection = mainConnection ? mainConnection() : 0;
        transportResult = transportConnection ? hypridentity_transport_start(transportConnection) : -1001;
    }
    else if ([action isEqual:@"transport-stop"]) transportResult = hypridentity_transport_stop();
    dump();
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (!hypr_fixture_protocol(argc,argv)) return 3;
        setvbuf(stdout, NULL, _IOLBF, 0);
        [NSApplication sharedApplication];
        if (!hypr_fixture_core(argc,argv)) return 4;
        BOOL floating = argc > 1 && strcmp(argv[1], "--floating") == 0;
        [NSApp setActivationPolicy:floating ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular];
        [NSWindow setAllowsAutomaticWindowTabbing:NO];
        windows = [NSMutableDictionary new];
        // Install BEFORE the group is created, so all prior transitions can be observed.
        if (hypridentity_install() != 0) return 2;
        for (NSString *key in @[@"a", @"b"]) {
            NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 150, 540, 400)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed = NO;
            window.title = [@"Identity fixture " stringByAppendingString:key];
            window.tabbingIdentifier = @"hyprwm-identity-probe";
            // Saturated body colors make a gray/blank/stale transition observable.
            window.contentView.wantsLayer = YES;
            window.contentView.layer.backgroundColor = ([key isEqual:@"a"] ?
                [NSColor colorWithRed:0.10 green:0.20 blue:0.85 alpha:1] :
                [NSColor colorWithRed:0.15 green:0.80 blue:0.20 alpha:1]).CGColor;
            if (floating) window.level = NSFloatingWindowLevel;
            windows[key] = window;
        }
        [windows[@"a"] makeKeyAndOrderFront:nil];
        [windows[@"a"] addTabbedWindow:windows[@"b"] ordered:NSWindowAbove];
        [windows[@"b"] makeKeyAndOrderFront:nil];
        [NSApp activate];
        dump();
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char *line = NULL;
            size_t capacity = 0;
            while (getline(&line, &capacity, stdin) >= 0) {
                NSString *text = [NSString stringWithUTF8String:line];
                dispatch_async(dispatch_get_main_queue(), ^{ command(text); });
            }
            free(line);
            dispatch_async(dispatch_get_main_queue(), ^{ command(@"quit"); });
        });
        [NSApp run];
    }
}
