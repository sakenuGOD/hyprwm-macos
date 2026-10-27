#import "admission.h"
#import "client.h"
#import "lifecycle.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <notify.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <uuid/uuid.h>

static NSString *socketPath, *launch;
static NSUInteger generation;
static NSMutableDictionary *source;
static NSString *installOwner;
static double budget;
static HAEventCallback callback;
static NSMutableArray *observers;
static NSMapTable<NSWindow *, NSMutableDictionary *> *records;
static BOOL installed, inWill, stopping;
static BOOL closeInstalled;
static NSUInteger closeCursor;
static int (*setAlpha)(int,uint32_t,float);
static int (*mainConnection)(void);
static NSString *const appKitPath=@"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";
static NSString *const appKitUUID=@"3C90C255-D239-3B5C-9213-9C5D383BEF9C";
static NSString *const skyLightPath=@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static NSString *const skyLightUUID=@"CD5F2362-8462-38D4-8C57-0BCD4E04F962";
static NSString *image_uuid(const struct mach_header_64 *header) {
    if (!header || header->magic!=MH_MAGIC_64) return nil;
    const uint8_t *cursor=(const void *)(header+1);
    for (uint32_t n=0;n<header->ncmds;n++) {
        const struct load_command *command=(const void *)cursor;
        if (command->cmdsize<sizeof(*command)) return nil;
        if (command->cmd==LC_UUID && command->cmdsize>=sizeof(struct uuid_command)) {
            char text[37];uuid_unparse_upper(((const struct uuid_command *)command)->uuid,text);return @(text);
        }
        cursor+=command->cmdsize;
    }
    return nil;
}
static BOOL native_symbol(void *code,NSString *path,NSString *uuid) {
    Dl_info info={0};
    return code && dladdr(ptrauth_strip(code,ptrauth_key_function_pointer),&info) && info.dli_fname &&
        [path isEqual:@(info.dli_fname)] && [uuid isEqual:image_uuid(info.dli_fbase)];
}
static BOOL native_getter(Method method) {
    char result[16]={0};if(method)method_getReturnType(method,result,sizeof(result));
    return method && method_getNumberOfArguments(method)==2 && result[0]=='@' &&
        native_symbol((void *)method_getImplementation(method),appKitPath,appKitUUID);
}

// macOS26 local SkyLight listing: SLSSetWindowAlpha(cid,wid,float), internally
// CGSWindowSetAlpha on the app's mapped window. Do not change NSWindow.alphaValue:
// the engine owns presentation, while the app's persistent model stays at 1.
static BOOL native_alpha(NSWindow *w, float alpha) {
    return w && setAlpha && mainConnection && setAlpha(mainConnection(), (uint32_t)w.windowNumber, alpha) == 0;
}
static BOOL owns_source(void) {return installOwner && [source[@"owner"] isEqual:installOwner];}
static BOOL finish_presentation(NSWindow *w, NSMutableDictionary *r) {
    NSNumber *token = r[@"presentationToken"]; if (!token) return YES;
    r[@"releaseDue"]=@YES;
    // A closed NSWindow may later allocate another native WID. An old lease
    // has no authority over that replacement window's alpha.
    if (w && w.windowNumber != [r[@"presentationWID"] integerValue]) w=nil;
    uint64_t claimed = 0;
    if ((w && notify_get_state(token.intValue, &claimed) != NOTIFY_STATUS_OK) ||
        (!claimed && w && !native_alpha(w, [r[@"originalAlpha"] floatValue]))) {
        if (![r[@"restoreRefused"] boolValue]) NSLog(@"hypradmission: native presentation release refused; retaining lease for application-update recovery");
        r[@"restoreRefused"]=@YES;return NO;
    }
    notify_cancel(token.intValue); [r removeObjectForKey:@"presentationToken"];
    [r removeObjectForKey:@"originalAlpha"];
    [r removeObjectForKey:@"presentationWID"];
    [r removeObjectForKey:@"releaseDue"];[r removeObjectForKey:@"restoreRefused"];
    return YES;
}
static BOOL begin_presentation(NSWindow *w, NSMutableDictionary *r) {
    if (r[@"presentationToken"]) return NO;
    NSString *name = r[@"offer"][@"presentation"];
    if (![name isKindOfClass:NSString.class] || ![name hasPrefix:@"hyprwm.admit."]) return NO;
    if (!setAlpha || !mainConnection) return NO;
    int token;
    if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK) return NO;
    // A lease is usable only after native visibility is actually suppressed.
    // Geometry alone must never claim ownership of the first displayed frame.
    if (notify_set_state(token, 0) != NOTIFY_STATUS_OK || !native_alpha(w, 0)) {
        notify_cancel(token);
        return NO;
    }
    NSNumber *presentationToken=@(token);NSDictionary *presentationKey=r[@"key"];
    NSString *owner=installOwner;
    r[@"presentationToken"]=presentationToken;r[@"presentationWID"]=@(w.windowNumber);r[@"originalAlpha"]=@(w.alphaValue);
    __weak NSWindow *weakWindow = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (owns_source() && [installOwner isEqual:owner] && r[@"key"]==presentationKey &&
            r[@"presentationToken"]==presentationToken) finish_presentation(weakWindow, r);
    });
    return YES;
}

static NSArray *cg_frame(NSWindow *w) {
    NSRect f = w.frame;
    double top = NSMaxY(NSScreen.screens.firstObject.frame);
    return @[@(f.origin.x), @(top - NSMaxY(f)), @(f.size.width), @(f.size.height)];
}
static NSRect ns_frame(NSArray *r) {
    double top = NSMaxY(NSScreen.screens.firstObject.frame);
    return NSMakeRect([r[0] doubleValue], top - [r[1] doubleValue] - [r[3] doubleValue],
                      [r[2] doubleValue], [r[3] doubleValue]);
}
static void event(NSString *name, NSWindow *w, NSDictionary *extra) {
    if (!callback) return;
    NSMutableDictionary *e = [@{@"event": name, @"time": @(HAClock()), @"pid": @(getpid()),
                                @"wid": @(w.windowNumber), @"frame": cg_frame(w)} mutableCopy];
    [e addEntriesFromDictionary:extra ?: @{}];
    callback(e);
}
static NSMutableDictionary *record(NSWindow *w) {
    NSMutableDictionary *r = [records objectForKey:w];
    if (!r) {
        uint64_t next=[source[@"next"] unsignedLongLongValue];
        if (next >= INT64_MAX) return nil;
        source[@"next"]=@(next+1);
        r = [@{@"object": @(next+1), @"attempt": @0} mutableCopy];
        if (objc_getAssociatedObject(w,(const void *)sel_registerName("hyprwmFirstMapPreexistingVersion1"))) r[@"preexisting"]=@YES;
        [records setObject:r forKey:w];
    }
    return r;
}
static NSDictionary *message(NSString *operation, NSMutableDictionary *r, double deadline) {
    NSDictionary *offer = r[@"offer"];
    return @{@"schema": @1, @"transport": @"fixture-uds-v1", @"op": operation, @"key": r[@"key"],
             @"service": offer[@"service"], @"lease": offer[@"lease"], @"revision": offer[@"revision"],
             @"deadline": @(deadline)};
}
static void cancel(NSWindow *w, NSMutableDictionary *r, NSString *reason) {
    finish_presentation(w, r);
    if (r[@"offer"]) {
        double deadline = HAClock() + budget;
        HAExchange(socketPath, message(@"cancel", r, deadline), deadline);
        [r removeObjectForKey:@"offer"];
    }
    event(@"native", w, @{@"reason": reason});
}
static BOOL group_facts(NSWindow *w, BOOL *known) {
    // Passive verified getter; public -tabGroup lazily creates group state.
    SEL sel = NSSelectorFromString(@"_windowStackController");
    Method method = class_getInstanceMethod(w.class, sel);
    char result[16] = {0};
    if (method) method_getReturnType(method, result, sizeof(result));
    if (!native_getter(method)) {
        *known = NO; return NO;
    }
    *known = YES;
    id group = ((id (*)(id, SEL))objc_msgSend)(w, sel);
    if (!group) return NO;
    Method members = class_getInstanceMethod([group class], @selector(windows));
    memset(result, 0, sizeof result);
    if (members) method_getReturnType(members, result, sizeof result);
    if (!native_getter(members)) {
        *known = NO; return NO;
    }
    id windows = ((id (*)(id, SEL))objc_msgSend)(group, @selector(windows));
    if (![windows isKindOfClass:NSArray.class]) { *known = NO; return NO; }
    return [windows count] != 1 || [windows firstObject] != w;
}
static BOOL accepted_close_marker(NSWindow *w,uint32_t wid,char out[256]) {
    // HLC's accepted-close callback performs this local lookup only. Socket
    // work and validation of a new binding happen on normal application updates.
    if(!installed || stopping || !closeInstalled || !owns_source() || !w.visible || w.windowNumber!=wid)return NO;
    NSMutableDictionary *r=[records objectForKey:w];NSData *bytes=r[@"closeMarker"];
    if(![bytes isKindOfClass:NSData.class] || bytes.length!=88 || [r[@"closeWID"] unsignedIntValue]!=wid)return NO;
    memcpy(out,bytes.bytes,88);return YES;
}
static BOOL close_marker_bytes(NSString *text,char out[88]) {
    if(![text isKindOfClass:NSString.class] || text.length!=87 ||
       !CFStringGetCString((__bridge CFStringRef)text,out,88,kCFStringEncodingASCII) ||
       out[87] || memcmp(out,"HLC1:",5) || out[37]!=':' || out[70]!=':')return NO;
    for(unsigned i=5;i<87;i++)if(i!=37 && i!=70 && !((out[i]>='0' && out[i]<='9') || (out[i]>='a' && out[i]<='f')))return NO;
    return YES;
}
static void refresh_close_binding(void) {
    if(!installed || stopping || !closeInstalled || !owns_source() || inWill)return;
    NSArray<NSWindow *> *windows=NSApp.windows;NSUInteger count=windows.count;
    if(!count || count>4096)return;
    // One bounded exchange per real DidUpdate. No timer and no IPC from close.
    for(NSUInteger step=0;step<MIN(count,256);step++) {
        NSWindow *w=windows[(closeCursor++)%count];NSMutableDictionary *r=record(w);
        if(!r)continue;
        NSInteger number=w.windowNumber;
        if(!w.visible || w.miniaturized || [w isKindOfClass:NSPanel.class] || w.level!=NSNormalWindowLevel ||
           !(w.styleMask&NSWindowStyleMaskTitled) || !(w.styleMask&NSWindowStyleMaskResizable) ||
           w.parentWindow || w.isSheet || w.sheetParent || NSApp.modalWindow==w || number<=0 || (uint64_t)number>UINT32_MAX) {
            [r removeObjectForKey:@"closeMarker"];[r removeObjectForKey:@"closeWID"];continue;
        }
        double now=HAClock();if(now-[r[@"closeFetched"] doubleValue]<0.1)continue;
        r[@"closeFetched"]=@(now);
        BOOL known=NO,grouped=group_facts(w,&known);
        if(!known || grouped){[r removeObjectForKey:@"closeMarker"];continue;}
        if([r[@"closeKey"][@"wid"] integerValue]!=number) {
            // Preexisting windows have no first-map offer/key. A separate
            // lookup key shares their existing object identity and source.
            r[@"closeKey"]=@{@"pid":@(getpid()),@"launch":launch,@"generation":@(generation),
                @"object":r[@"object"],@"wid":@(number),@"attempt":@1};
            [r removeObjectForKey:@"closeMarker"];
        }
        double deadline=now+MIN(budget,0.006);
        NSDictionary *request=@{@"schema":@1,@"transport":@"fixture-uds-v1",@"op":@"close-bind",
            @"key":r[@"closeKey"],@"deadline":@(deadline)};
        NSDictionary *reply=HAExchange(socketPath,request,deadline);char bytes[88]={0};
        if([reply[@"schema"] isEqual:@1] && [reply[@"transport"] isEqual:@"fixture-uds-v1"] &&
           [reply[@"status"] isEqual:@"close-bound"] && [reply[@"key"] isEqual:r[@"closeKey"]] &&
           close_marker_bytes(reply[@"marker"],bytes)) {
            r[@"closeMarker"]=[NSData dataWithBytes:bytes length:sizeof(bytes)];r[@"closeWID"]=@(number);
        }else{[r removeObjectForKey:@"closeMarker"];[r removeObjectForKey:@"closeWID"];}
        return;
    }
}
static void will_order(NSWindow *w) {
    if (!installed || stopping || !owns_source() || inWill || ![w isKindOfClass:NSWindow.class] || w.visible) return;
    NSMutableDictionary *r = record(w);
    if (!r || r[@"presentationToken"] || [r[@"preexisting"] boolValue] || [r[@"done"] boolValue] || w.windowNumber <= 0) return;
    r[@"done"] = @YES;
    r[@"attempt"] = @([r[@"attempt"] unsignedLongLongValue] + 1);
    r[@"key"] = @{@"pid": @(getpid()), @"launch": launch, @"generation": @(generation),
                  @"object": r[@"object"], @"wid": @(w.windowNumber), @"attempt": r[@"attempt"]};
    BOOL known = NO, grouped = group_facts(w, &known);
    NSString *title = w.title ?: @"";
    if (title.length > 512) title = [title substringToIndex:512];
    // C comparison/logical expressions are int, so @(expression) emits JSON
    // 0/1. The wire schema intentionally distinguishes booleans from numbers.
    NSDictionary *facts = @{@"normal": @((BOOL)((w.styleMask & NSWindowStyleMaskTitled) != 0)),
       @"resizable": @((BOOL)((w.styleMask & NSWindowStyleMaskResizable) != 0)), @"panel": @([w isKindOfClass:NSPanel.class]),
       @"sheet": @((BOOL)(w.isSheet || w.sheetParent != nil)), @"parent": @((BOOL)(w.parentWindow != nil)),
       @"modal": @((BOOL)(NSApp.modalWindow == w)), @"level": @(w.level), @"grouped": @(grouped), @"group_known": @(known),
       @"title": title};
    NSSize minimum = w.minSize;
    NSRect content = [w frameRectForContentRect:NSMakeRect(0, 0, w.contentMinSize.width, w.contentMinSize.height)];
    minimum.width = MAX(minimum.width, content.size.width);
    minimum.height = MAX(minimum.height, content.size.height);
    double deadline = HAClock() + budget;
    NSDictionary *request = @{@"schema": @1, @"transport": @"fixture-uds-v1", @"op": @"prepare", @"key": r[@"key"],
                             @"deadline": @(deadline), @"facts": facts,
                             @"minimum": @[@(minimum.width), @(minimum.height)]};
    inWill = YES;
    event(@"will", w, @{@"key": r[@"key"], @"facts": facts, @"deadline": @(deadline)});
    NSDictionary *offer = HAExchange(socketPath, request, deadline);
    if (!HAOfferUsable(offer, request, HAClock())) {
        event(@"native", w, @{@"reason": offer[@"status"] ?: @"timeout-or-transport", @"key": r[@"key"]});
        inWill = NO; return;
    }
    r[@"offer"] = offer;
    NSRect old = w.frame;
    // Last deadline check is immediately before the only geometry mutation.
    if (HAClock() >= deadline) { cancel(w, r, @"expired-before-set"); inWill = NO; return; }
    [w setFrame:ns_frame(offer[@"rect"]) display:NO];
    NSArray *actual = cg_frame(w), *target = offer[@"rect"];
    double error = 0;
    for (NSUInteger i = 0; i < 4; i++) error = MAX(error, fabs([actual[i] doubleValue] - [target[i] doubleValue]));
    if (error > 1) {
        [w setFrame:old display:NO];
        cancel(w, r, @"constraint-mismatch");
    } else {
        if (!begin_presentation(w, r)) {
            [w setFrame:old display:NO];
            cancel(w, r, @"presentation-hide-failed");
        } else {
            NSMutableDictionary *details=[@{@"key":r[@"key"],@"target":target,@"lease":offer[@"lease"]} mutableCopy];
#ifdef HYPRADMISSION_OWNED_DIAGNOSTICS
            for(NSString *name in @[@"epoch",@"revision",@"service"])if(offer[name])details[name]=offer[name];
#endif
            event(@"applied", w, details);
        }
    }
    inWill = NO;
}
static void did_order(NSWindow *w) {
    if (!installed || stopping || !owns_source()) return;
    NSMutableDictionary *r = [records objectForKey:w];
    if (!r) return;
    event(@"did_order", w, r[@"key"] ? @{@"key": r[@"key"]} : nil);
    if (!r[@"offer"] || r[@"mapped"]) return;
    double deadline = HAClock() + budget;
    NSMutableDictionary *request = [message(@"mapped", r, deadline) mutableCopy];
    request[@"actual"] = cg_frame(w);
    NSDictionary *reply = HAExchange(socketPath, request, deadline);
    BOOL accepted = [reply[@"status"] isEqual:@"mapped"] && [reply[@"key"] isEqual:r[@"key"]] &&
        [reply[@"service"] isEqual:r[@"offer"][@"service"]];
    r[@"mapped"] = @(accepted);
    if (!accepted) finish_presentation(w, r);
    event(@"confirmed", w, @{@"accepted": @(accepted), @"status": reply[@"status"] ?: @"timeout-or-transport"});
}
int hypradmission_install(NSString *path, double budgetMS, HAEventCallback logger) {
    if (!NSThread.isMainThread || !path.length || !HAHasServerExecutable() || !(budgetMS >= 1 && budgetMS <= 100)) return -1;
    if (installed) return -2;
    NSString * __unsafe_unretained *will = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "NSWindowWillOrderOnScreenNotification");
    NSString * __unsafe_unretained *did = (NSString * __unsafe_unretained *)dlsym(RTLD_DEFAULT, "NSWindowDidOrderOnScreenNotification");
    setAlpha=dlsym(RTLD_DEFAULT,"SLSSetWindowAlpha");mainConnection=dlsym(RTLD_DEFAULT,"SLSMainConnectionID");
    if (!will || !did || !*will || !*did || !native_symbol((void *)will,appKitPath,appKitUUID) ||
        !native_symbol((void *)did,appKitPath,appKitUUID) ||
        !native_symbol((void *)setAlpha,skyLightPath,skyLightUUID) ||
        !native_symbol((void *)mainConnection,skyLightPath,skyLightUUID) ||
        !native_getter(class_getInstanceMethod(NSWindow.class,NSSelectorFromString(@"_windowStackController")))) return -3;
    struct proc_bsdinfo info={0};
    if (proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&info,sizeof(info)) != sizeof(info)) return -4;
    NSArray *birth=@[@(getpid()),@(info.pbi_uid),@(info.pbi_start_tvsec),@(info.pbi_start_tvusec)];
    const void *key=(const void *)sel_registerName("hyprwmFirstMapSourceVersion1");
    id anchor=NSThread.mainThread;
    id previous=objc_getAssociatedObject(anchor,key);
    if (previous && (![previous isKindOfClass:NSMutableDictionary.class] ||
        ![previous[@"schema"] isEqual:@1] || ![previous[@"birth"] isEqual:birth] ||
        ![previous[@"launch"] isKindOfClass:NSString.class] || ![previous[@"launch"] length] ||
        ![previous[@"generation"] isEqual:@1] || ![previous[@"next"] isKindOfClass:NSNumber.class] ||
        [previous[@"next"] unsignedLongLongValue] >= INT64_MAX ||
        (previous[@"owner"] && ![previous[@"owner"] isKindOfClass:NSString.class]))) return -5;
    source=previous ?: [@{@"schema":@1,@"birth":birth,@"launch":NSUUID.UUID.UUIDString,@"generation":@1,@"next":@0} mutableCopy];
    if (source[@"owner"]) return -6;
    installOwner=NSUUID.UUID.UUIDString;source[@"owner"]=installOwner;
    if (!previous) objc_setAssociatedObject(anchor,key,source,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    socketPath = [path copy]; budget = budgetMS / 1000; callback = logger;
    launch=source[@"launch"];generation=[source[@"generation"] unsignedIntegerValue];
    records = [NSMapTable weakToStrongObjectsMapTable];
    observers = [NSMutableArray new]; stopping=NO;installed = YES;
    HLCConfig closeConfig={.schema=1,.marker=accepted_close_marker};
    closeInstalled=HLCInstall(&closeConfig)>=0;closeCursor=0;
    if(!closeInstalled) {
        // A v3 readiness receipt includes the accepted-close witness. A foreign
        // swizzle remains untouched and the shared source is returned cleanly.
        installed=NO;records=nil;observers=nil;socketPath=nil;callback=NULL;
        if(owns_source())[source removeObjectForKey:@"owner"];
        installOwner=nil;return -7;
    }
    for (NSWindow *w in NSApp.windows) {
        objc_setAssociatedObject(w,(const void *)sel_registerName("hyprwmFirstMapPreexistingVersion1"),@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(w)[@"preexisting"]=@YES;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [observers addObject:[center addObserverForName:*will object:nil queue:nil usingBlock:^(NSNotification *n) { will_order(n.object); }]];
    [observers addObject:[center addObserverForName:*did object:nil queue:nil usingBlock:^(NSNotification *n) { did_order(n.object); }]];
    // A failed native release remains owned and retries on real application
    // updates. Never erase its token or grant a successor while it is hidden.
    [observers addObject:[center addObserverForName:NSApplicationDidUpdateNotification object:NSApp queue:nil usingBlock:^(NSNotification *n) {
        (void)n;if (!owns_source()) return;
        for (NSWindow *w in records) {NSMutableDictionary *r=[records objectForKey:w];if ([r[@"releaseDue"] boolValue]) finish_presentation(w,r);}
        refresh_close_binding();
    }]];
    [observers addObject:[center addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        NSWindow *w = n.object; NSMutableDictionary *r = [records objectForKey:w];
        finish_presentation(w, r);
        if (r[@"offer"]) {
            double deadline = HAClock() + budget;
            HAExchange(socketPath, message([r[@"mapped"] boolValue] ? @"closed" : @"cancel", r, deadline), deadline);
        }
        [r removeObjectForKey:@"offer"]; [r removeObjectForKey:@"mapped"]; [r removeObjectForKey:@"done"];
    }]];
    return 0;
}
int hypradmission_uninstall(void) {
    if (!NSThread.isMainThread) return -1;
    if (!installed) return 0;
    if (!owns_source()) return -2;
    stopping=YES;
    if(closeInstalled) {
        for(NSWindow *w in records){NSMutableDictionary *r=[records objectForKey:w];[r removeObjectForKey:@"closeMarker"];}
        if(HLCUninstall()!=0)return -3;
        closeInstalled=NO;
    }
    for (NSWindow *w in records) {
        NSMutableDictionary *r = [records objectForKey:w];
        if (!finish_presentation(w, r)) return -3;
        if (r[@"offer"]) {
            double deadline = HAClock() + budget;
            HAExchange(socketPath, message([r[@"mapped"] boolValue] ? @"closed" : @"cancel", r, deadline), deadline);
        }
    }
    installed = NO;
    for (id observer in observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    observers = nil; records = nil; socketPath = nil; callback = NULL;
    if (owns_source()) [source removeObjectForKey:@"owner"];
    installOwner=nil;
    return 0;
}
BOOL hypradmission_is_installed(void) {return installed && owns_source();}
BOOL hypradmission_is_accepting(void) {return installed && owns_source() && !stopping;}

#ifdef HYPRADMISSION_OWNED_DIAGNOSTICS
int hypradmission_owned_set_logger(HAEventCallback logger) {
    if (!NSThread.isMainThread || !installed) return -1;
    callback = logger;
    return 0;
}
NSDictionary *hypradmission_owned_state(void) {
    return @{@"installed":@(installed),@"generation":@(generation),
        @"source_launch":launch?:@"",@"source_counter":source[@"next"]?:@0,
        @"budget_ms":@(budget*1000),@"observer_count":@(observers.count),
        @"owned_diagnostics":@YES};
}
#endif

// Explicit additive install after CAP6. No duplicate configure observers and
// no constructor; root can stage this on an owned process before rolling out.
void hypradmission_request(const char *path) {
    NSString *copy = path ? [NSString stringWithUTF8String:path] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        int result;
        if (copy) result = installed ? 0 : hypradmission_install(copy, 12, nil);
        else result = hypradmission_uninstall();
        static int token = -1;
        if (token < 0) {
            char name[96]; snprintf(name, sizeof name, "hyprwm.admission.%d", getpid());
            notify_register_check(name, &token);
        }
        if (token >= 0) notify_set_state(token, installed && owns_source() ? 1 : 0);
        NSLog(@"hypradmission: install=%d result=%d", installed, result);
    });
}
