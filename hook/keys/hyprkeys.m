// Global tiling shortcuts use the standard system mechanism (RegisterEventHotKey).
// A key press sends a command to the HyprWM daemon socket. Bindings come from /tmp/hyprkeys.json.
// Public API; no Accessibility permission required and no other processes modified.
// Build: clang -fobjc-arc -framework Carbon -framework AppKit -o hyprkeys hyprkeys.m
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#import <sys/stat.h>
#include <math.h>

static NSArray *gBinds;      // [{keycode, mods, cmd:[args...], desc}]
static NSString *controlPath(void) {
    return NSProcessInfo.processInfo.environment[@"HYPRWM_CTL"] ?: @"/tmp/hyprwm.ctl";
}
#define CTL (controlPath().fileSystemRepresentation)

static dispatch_queue_t gQ;           // One serial queue preserves command order.
static dispatch_source_t gRepeat;     // Auto-repeat while a repeating binding is held.
static UInt32 gBindingGeneration, gNextBindingGeneration;
static BOOL hotkeyModifiersDisabled(unsigned mods);
static BOOL hotkeyBindingDisabled(unsigned key,unsigned mods);
static void publishKeyboardStatus(void);
static BOOL gReloadRejected;
#define REPEAT_DELAY 0.280            // input.lua: repeat_delay 280
#define REPEAT_RATE 40.0              //            repeat_rate 40

static BOOL repeatInteger(id value, NSInteger fallback, NSInteger maximum, NSInteger *out) {
    if (!value) { *out = fallback; return YES; }
    if (![value isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double number = [value doubleValue];
    if (!isfinite(number) || number < 0 || number > maximum || floor(number) != number) return NO;
    *out = (NSInteger)number;
    return YES;
}

static NSData *commandData(NSArray *arguments) {
    if (![arguments isKindOfClass:[NSArray class]] || !arguments.count) return nil;
    for (id argument in arguments)
        if (![argument isKindOfClass:[NSString class]]) return nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:arguments options:0 error:nil];
    if (!json) return nil;
    NSMutableData *data = [json mutableCopy];
    [data appendBytes:"\n" length:1];
    return data;
}

static void sendLine(NSDictionary *b) {
    NSData *data = commandData(b[@"cmd"]);
    if (!data) { NSLog(@"[hyprkeys] invalid command argv: %@", b[@"desc"]); return; }
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    dispatch_async(gQ, ^{
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        struct sockaddr_un a = {.sun_family = AF_UNIX};
        if(strlcpy(a.sun_path, CTL, sizeof a.sun_path)>=sizeof a.sun_path){close(fd);NSLog(@"[hyprkeys] control socket path is too long");return;}
        char reply[512] = "Cannot connect to the HyprWM daemon.";
        if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
            size_t sent = 0;
            while (sent < data.length) {
                ssize_t n = write(fd, (const char *)data.bytes + sent, data.length - sent);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                sent += (size_t)n;
            }
            if (sent == data.length) {
                ssize_t n = read(fd, reply, sizeof reply - 1);
                reply[n > 0 ? n : 0] = 0;
            }
        }
        close(fd);
        NSLog(@"[hyprkeys] %@ -> %@: %s", b[@"desc"], line, reply);
    });
}

static OSStatus onHotKey(EventHandlerCallRef call, EventRef ev, void *ctx) {
    EventHotKeyID hk;
    if (GetEventParameter(ev, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hk), NULL, &hk) != noErr) return noErr;
    if (!gBindingGeneration || hk.signature != gBindingGeneration || hk.id >= gBinds.count) return noErr;
    NSDictionary *b = gBinds[hk.id];
    if (b[@"enabled"] && ![b[@"enabled"] boolValue]) return noErr;
    if (GetEventKind(ev) == kEventHotKeyReleased) {
        if (gRepeat) { dispatch_source_cancel(gRepeat); gRepeat = nil; }
        return noErr;
    }
    sendLine(b);
    if ([b[@"repeat"] boolValue]) {
        if (gRepeat) dispatch_source_cancel(gRepeat);
        gRepeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gRepeat, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(REPEAT_DELAY * NSEC_PER_SEC)),
                                  (uint64_t)(NSEC_PER_SEC / REPEAT_RATE), NSEC_PER_MSEC);
        dispatch_source_set_event_handler(gRepeat, ^{ sendLine(b); });
        dispatch_resume(gRepeat);
    }
    return noErr;
}

// Native reload keeps the last accepted complete binding set on parse or registration failure.
static NSMutableArray<NSValue *> *gHotKeyRefs;
static NSData *gAcceptedData;
static NSData *gAttemptedData;
static NSString *bindingPath(void) {
    return NSProcessInfo.processInfo.environment[@"HYPRWM_KEYS_BINDINGS"] ?: @"/tmp/hyprkeys.json";
}
static NSData *readBindingData(void) {
    NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:bindingPath()];
    if(!file)return nil;
    NSData *data=[file readDataUpToLength:262145 error:nil];
    [file closeFile];
    return data.length<=262144 ? data:nil;
}
static BOOL validateBindingRows(id rows) {
    if (![rows isKindOfClass:[NSArray class]] || [rows count] > 4096) return NO;
    NSMutableSet *seen=[NSMutableSet set];
    for(id row in rows) {
        if (![row isKindOfClass:[NSDictionary class]] || !commandData(row[@"cmd"])) return NO;
        if(row[@"enabled"] && (CFGetTypeID((__bridge CFTypeRef)row[@"enabled"]) != CFBooleanGetTypeID())) return NO;
        if([row[@"event"] isEqual:@"wheel"])continue;
        NSInteger key,mods;
        if(!repeatInteger(row[@"keycode"],-1,127,&key) || key<0 || !repeatInteger(row[@"mods"],-1,65535,&mods) || mods<0 || (mods&~0x1b00))return NO;
        if(row[@"enabled"] && ![row[@"enabled"] boolValue])continue;
        NSString *signature=[NSString stringWithFormat:@"%ld:%ld",(long)key,(long)mods];
        if([seen containsObject:signature])return NO;
        [seen addObject:signature];
    }
    return YES;
}
static void unregisterBindings(void) {
    gBindingGeneration=0;
    for(NSValue *value in gHotKeyRefs)UnregisterEventHotKey((EventHotKeyRef)value.pointerValue);
    [gHotKeyRefs removeAllObjects];
}
static BOOL registerBindings(NSArray *rows,BOOL strict) {
    if(gNextBindingGeneration==UINT32_MAX){NSLog(@"[hyprkeys] registration generation exhausted; restart the watcher");return NO;}
    UInt32 generation=++gNextBindingGeneration;
    if(!gHotKeyRefs)gHotKeyRefs=[NSMutableArray array];
    for(NSUInteger i=0;i<rows.count;i++) {
        NSDictionary *b=rows[i];if([b[@"event"] isEqual:@"wheel"] || (b[@"enabled"] && ![b[@"enabled"] boolValue]))continue;
        if(hotkeyBindingDisabled([b[@"keycode"] unsignedIntValue],[b[@"mods"] unsignedIntValue]))continue;
        EventHotKeyID hid={.signature=generation,.id=(UInt32)i};EventHotKeyRef ref=NULL;
        OSStatus status=RegisterEventHotKey([b[@"keycode"] unsignedIntValue],[b[@"mods"] unsignedIntValue],hid,GetApplicationEventTarget(),0,&ref);
        if(status==noErr)[gHotKeyRefs addObject:[NSValue valueWithPointer:ref]];
        else {NSLog(@"[hyprkeys] shortcut unavailable: %@ (%d)",b[@"desc"],(int)status);if(strict){unregisterBindings();return NO;}}
    }
    gBindingGeneration=generation;
    return YES;
}
static BOOL acceptBindings(NSData *data,BOOL strict) {
    if(!data || data.length>262144)return NO;
    id candidate=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(!validateBindingRows(candidate))return NO;
    NSArray *previous=gBinds;
    if(gRepeat){dispatch_source_cancel(gRepeat);gRepeat=nil;}
    unregisterBindings();
    if(!registerBindings(candidate,strict)){registerBindings(previous,NO);return NO;}
    gBinds=candidate;gAcceptedData=data;return YES;
}
static BOOL reloadBindingData(NSData *data) {
    if([data isEqual:gAcceptedData]) {
        BOOL recovered=gReloadRejected;
        gReloadRejected=NO;gAttemptedData=nil;
        return recovered;
    }
    if([data isEqual:gAttemptedData])return NO;
    gAttemptedData=data;gReloadRejected=!acceptBindings(data,YES);
    if(!gReloadRejected)NSLog(@"[hyprkeys] configuration reloaded: %lu bindings",(unsigned long)gBinds.count);
    return YES;
}
static void installBindingReload(void) {
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,200*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{
        NSData *data=readBindingData();
        if(!data || data.length>262144)return;
        dispatch_async(dispatch_get_main_queue(),^{if(reloadBindingData(data))publishKeyboardStatus();});
    });
    dispatch_resume(timer);
    // The application owns this source for its lifetime; no per-event allocations/timers.
    static dispatch_source_t retainedTimer;retainedTimer=timer;
}

#include "hotkey_rules.h"

// Registration evidence is refreshed by this run loop, not inferred from a PID.
// Carbon hotkeys do not require Accessibility or Input Monitoring permission.
static void publishKeyboardStatus(void) {
    NSString *directory=NSProcessInfo.processInfo.environment[@"HYPRWM_KEYBOARD_STATE"] ?:
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/HyprWM/keyboard"];
    NSFileManager *manager=NSFileManager.defaultManager;
    if(![manager fileExistsAtPath:directory])
        [manager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    struct stat info;
    if(lstat(directory.fileSystemRepresentation,&info) || !S_ISDIR(info.st_mode) || info.st_uid!=getuid() || (info.st_mode&0077))return;
    NSUInteger expected=0,suspended=0;
    for(NSDictionary *row in gBinds) {
        if([row[@"event"] isEqual:@"wheel"] || (row[@"enabled"] && ![row[@"enabled"] boolValue]))continue;
        if(hotkeyBindingDisabled([row[@"keycode"] unsignedIntValue],[row[@"mods"] unsignedIntValue]))suspended++;
        else expected++;
    }
    NSDictionary *status=@{@"schema":@1,@"backend":@"carbon",@"permission":@"not_required",
        @"pid":@(getpid()),@"updated":@([NSDate.date timeIntervalSince1970]),@"registered":@(gHotKeyRefs.count),
        @"expected":@(expected),@"suspended":@(suspended),@"bindings":@(gBinds.count),
        @"reload_rejected":@(gReloadRejected),@"bindings_path":bindingPath(),
        @"executable":[NSProcessInfo.processInfo.arguments[0] stringByStandardizingPath]};
    NSData *data=[NSJSONSerialization dataWithJSONObject:status options:0 error:nil];
    NSString *path=[directory stringByAppendingPathComponent:@"status.json"];
    // Atomic replacement cannot follow a pre-existing status-file symlink.
    if(data && [data writeToFile:path options:NSDataWritingAtomic error:nil])
        [manager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
}
static void installKeyboardStatus(void) {
    publishKeyboardStatus();
    static dispatch_source_t timer;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),2*NSEC_PER_SEC,200*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{publishKeyboardStatus();});dispatch_resume(timer);
}

int main(void) {
    @autoreleasepool {
        NSData *d = readBindingData();
        if (!d) { NSLog(@"[hyprkeys] Missing %@; generate the hotkey configuration first.",bindingPath()); return 1; }

        gQ = dispatch_queue_create("hyprkeys.send", DISPATCH_QUEUE_SERIAL);
        EventTypeSpec spec[2] = { { kEventClassKeyboard, kEventHotKeyPressed },
                                  { kEventClassKeyboard, kEventHotKeyReleased } };
        InstallApplicationEventHandler(&onHotKey, 2, spec, NULL, NULL);

        [NSApplication sharedApplication];
        NSApp.activationPolicy=NSApplicationActivationPolicyAccessory;
        if(!installHotkeyApplicationRules()){NSLog(@"[hyprkeys] invalid application hotkey rules");return 1;}
        if(!acceptBindings(d,NO)){NSLog(@"[hyprkeys] invalid binding document");return 1;}
        NSLog(@"[hyprkeys] ready: %lu bindings -> %s",(unsigned long)gBinds.count,CTL);
        NSLog(@"[hyprkeys] application rules: suspended modifiers %@; %lu keyboard shortcuts registered",
              gDisabledHotkeyModifiers ?: [NSSet set],(unsigned long)gHotKeyRefs.count);
        installBindingReload();
        installKeyboardStatus();
        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;   // No Dock icon.
        [NSApp run];
    }
    return 0;
}
