#import "ConfigureStream.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <math.h>
#include <notify.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/stat.h>
#include <unistd.h>
#include <uuid/uuid.h>
#include "../src/managed_process_identity.c"
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Keep the deployed CAP5 callback, its tokens, and first-map ownership intact.
// This is the existing ch_cfgmsg wire ABI, not a new native producer ABI.
enum { CSNotify = 0x7f18, CSMagic = 0x47464353, CSMaxWindows = 32 };
typedef struct { uint32_t magic, wid; double x, y, w, h, t0; } CSMessage;
_Static_assert(sizeof(CSMessage) == 48, "SCFG wire size");
static CFStringRef const CSProperty = CFSTR("hyprwm.configure-stream.v1");
static NSString *const CSSky = @"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static pthread_mutex_t stateLock = PTHREAD_MUTEX_INITIALIZER;
static void *codeAddress(void *pointer) {
#if __has_feature(ptrauth_calls)
    return ptrauth_strip(pointer, ptrauth_key_function_pointer);
#else
    return pointer;
#endif
}

static double clockNow(void) {
    mach_timebase_info_data_t base; mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom * 1e-9;
}
static NSNumber *jsonBool(BOOL value) {
    // Box protocol booleans explicitly: a boxed C comparison may be NSNumber 1.
    return (__bridge NSNumber *)(value ? kCFBooleanTrue : kCFBooleanFalse);
}
static BOOL integer(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return NO;
    double n = [value doubleValue];
    return isfinite(n) && n >= (double)minimum && n <= (double)maximum && floor(n) == n;
}
static BOOL numeric(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static NSDictionary *processIdentity(pid_t pid) {
    uint64_t before[4] = {0}, after[4] = {0}; char path[PROC_PIDPATHINFO_MAXSIZE] = {0}, again[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (pid <= 1 || managed_process_identity(pid, before) || proc_pidpath(pid, path, sizeof(path)) <= 0 ||
        managed_process_identity(pid, after) || memcmp(before, after, sizeof(before)) ||
        proc_pidpath(pid, again, sizeof(again)) <= 0 || strcmp(path, again)) return nil;
    return @{@"birth":@[@(before[0]), @(before[1]), @(before[2]), @(before[3])], @"executable":@(path)};
}
static NSString *imageUUID(const struct mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 2048 || header->sizeofcmds > 1048576) return nil;
    const uint8_t *cursor = (const void *)(header + 1), *end = cursor + header->sizeofcmds;
    NSString *result = nil;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if ((size_t)(end - cursor) < sizeof(struct load_command)) return nil;
        const struct load_command *command = (const void *)cursor;
        if (command->cmdsize < sizeof(*command) || command->cmdsize > (size_t)(end - cursor)) return nil;
        if (command->cmd == LC_UUID) {
            if (result || command->cmdsize != sizeof(struct uuid_command)) return nil;
            char text[37]; uuid_unparse_upper(((const struct uuid_command *)command)->uuid, text); result = @(text);
        }
        cursor += command->cmdsize;
    }
    return cursor == end ? result : nil;
}
static NSDictionary *selfIdentity(void) {
    NSDictionary *native = processIdentity(getpid()); NSString *uuid = imageUUID((const void *)_dyld_get_image_header(0));
    if (!native || !uuid) return nil;
    NSMutableDictionary *result = [native mutableCopy]; result[@"main_uuid"] = uuid; return result;
}
static NSString *moduleUUID(void) {
    Dl_info info = {0};
    return dladdr(codeAddress((void *)hypr_configure_stream_v1_json), &info) ? imageUUID(info.dli_fbase) : nil;
}
static BOOL actorValid(id actor, BOOL sameUser) {
    if (![actor isKindOfClass:NSDictionary.class]) return NO;
    NSArray *birth = actor[@"birth"];
    NSString *path = actor[@"executable"];
    if (![birth isKindOfClass:NSArray.class] || birth.count != 4 ||
        !integer(birth[0], 2, INT32_MAX) || !integer(birth[1], 0, UINT32_MAX) ||
        !integer(birth[2], 1, (1ULL << 53) - 1) || !integer(birth[3], 0, 999999) ||
        (sameUser && [birth[1] unsignedIntValue] != getuid()) ||
        ![path isKindOfClass:NSString.class] || !path.isAbsolutePath || path.length >= PROC_PIDPATHINFO_MAXSIZE) return NO;
    NSDictionary *current = processIdentity([birth[0] intValue]);
    return [current[@"birth"] isEqual:birth] && [current[@"executable"] isEqual:path];
}

// Fixed protected location, opened one component at a time. No user-writable
// grant table, symlink traversal, environment override or caller-supplied path.
static NSDictionary *readGrant(NSDictionary *target, NSString **rawSHA256) {
    if (rawSHA256) *rawSHA256 = nil;
    NSArray *birth = target[@"birth"];
    if (birth.count != 4) return nil;
    int directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0) return nil;
    for (NSString *part in @[@"Library", @"Application Support", @"HyprWM", @"Configure Stream Grants", [birth[1] description]]) {
        int next = openat(directory, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(directory); directory = next;
        struct stat info = {0};
        if (directory < 0 || fstat(directory, &info) || info.st_uid != 0 || (info.st_mode & 022)) { if (directory >= 0) close(directory); return nil; }
    }
    NSString *name = [[birth valueForKey:@"description"] componentsJoinedByString:@"-"];
    name = [name stringByAppendingString:@".json"];
    int fd = openat(directory, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    struct stat before = {0}, after = {0}, named = {0}; NSMutableData *data = nil;
    if (fd >= 0 && !fstat(fd, &before) && S_ISREG(before.st_mode) && before.st_uid == 0 && !(before.st_mode & 022) &&
        before.st_nlink == 1 && before.st_size > 0 && before.st_size <= 16384) {
        data = [NSMutableData dataWithLength:(NSUInteger)before.st_size];
        ssize_t count = read(fd, data.mutableBytes, data.length);
        if (count != before.st_size || fstat(fd, &after) || fstatat(directory, name.fileSystemRepresentation, &named, AT_SYMLINK_NOFOLLOW) ||
            before.st_dev != after.st_dev || before.st_ino != after.st_ino || before.st_size != after.st_size ||
            before.st_mode != after.st_mode || before.st_uid != after.st_uid || before.st_nlink != after.st_nlink ||
            !S_ISREG(after.st_mode) || after.st_uid != 0 || (after.st_mode & 022) || after.st_nlink != 1 ||
            before.st_mtimespec.tv_sec != after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec != after.st_mtimespec.tv_nsec ||
            after.st_dev != named.st_dev || after.st_ino != named.st_ino || after.st_size != named.st_size ||
            after.st_mode != named.st_mode || after.st_uid != named.st_uid || after.st_nlink != named.st_nlink ||
            after.st_mtimespec.tv_sec != named.st_mtimespec.tv_sec || after.st_mtimespec.tv_nsec != named.st_mtimespec.tv_nsec) data = nil;
    }
    if (fd >= 0) close(fd); close(directory);
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![value isKindOfClass:NSDictionary.class]) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1] = {0};
    static const char digits[] = "0123456789abcdef";
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    for (NSUInteger i = 0; i < sizeof(digest); i++) { hex[i * 2] = digits[digest[i] >> 4]; hex[i * 2 + 1] = digits[digest[i] & 15]; }
    if (rawSHA256) *rawSHA256 = @(hex);
    return value;
}

@interface CSWindow : NSObject
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic) uint32_t wid;
@property(nonatomic) uintptr_t object;
@property(nonatomic) uint64_t minimum, sequence, applied;
@property(nonatomic) uint64_t probeSequence;
@property(nonatomic) double stamp, ackTime, ackStamp, probeStamp, probeAckTime;
@property(nonatomic) BOOL pending, ready, inFlight, awaitingReadback;
@property(nonatomic) CSMessage newest;
@property(nonatomic) CSMessage dispatched;
@property(nonatomic) uint64_t dispatchedSequence;
@property(nonatomic) double dispatchedAt;
@property(nonatomic) NSArray *accepted;
@property(nonatomic) NSArray *probeFrame;
@end
@implementation CSWindow
@end

@interface CSOwner : NSObject
@property(nonatomic) NSDictionary *grant;
@property(nonatomic) NSString *grantSHA256;
@property(nonatomic) NSMutableDictionary<NSNumber *, CSWindow *> *windows;
@property(nonatomic) uint64_t epoch, generation;
@property(nonatomic) double floor, expires;
@property(nonatomic) BOOL enabled, scheduled;
@property(nonatomic) NSUInteger inFlight;
@property(nonatomic) NSUInteger callbacks;
@property(nonatomic) NSString *reason;
@end
@implementation CSOwner
@end

static CSOwner *owner;
static uint64_t nextGeneration, lastEpoch;
static BOOL installed;
static int connection;
static void *skyHandle; // Deliberately retained; callbacks outlive OFF.
static dispatch_source_t timer;
static id closeObserver;
static int (*connectionPID)(int, pid_t *);
static int (*windowOwner)(int, uint32_t, int *);
static int (*orderedIn)(int, uint32_t, uint8_t *);
static int (*windowBounds)(int, uint32_t, CGRect *);
static CFArrayRef (*copySpaces)(int, int, CFArrayRef);
static CFArrayRef (*copyDisplays)(int);
static uint64_t (*activeSpace)(int);
static int (*setProperty)(int, int, CFStringRef, CFTypeRef);
static int (*copyProperty)(int, int, CFStringRef, CFTypeRef *);
static int (*registerNotify)(int, void *, uint32_t, void *);

static BOOL nativeSymbol(const char *name, void **output, NSString *expectedUUID) {
    void *symbol = dlsym(skyHandle, name); Dl_info info = {0};
    if (!symbol || !dladdr(codeAddress(symbol), &info) || !info.dli_fname || ![CSSky isEqual:@(info.dli_fname)] ||
        ![imageUUID(info.dli_fbase) isEqual:expectedUUID]) return NO;
    *output = symbol; return YES;
}
static BOOL windowServerExecutable(NSString *path) {
    if (![path isKindOfClass:NSString.class]) return NO;
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) &&
        !strcmp(resolved, "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer");
}
static BOOL resolveNative(NSString *uuid) {
    if (![uuid isKindOfClass:NSString.class] || ![[[NSUUID alloc] initWithUUIDString:uuid].UUIDString isEqual:uuid]) return NO;
    if (!skyHandle) skyHandle = dlopen(CSSky.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!skyHandle) return NO;
    int (*mainConnection)(void) = NULL;
    if (!nativeSymbol("SLSMainConnectionID", (void **)&mainConnection, uuid) ||
        !nativeSymbol("SLSConnectionGetPID", (void **)&connectionPID, uuid) ||
        !nativeSymbol("SLSGetWindowOwner", (void **)&windowOwner, uuid) ||
        !nativeSymbol("SLSWindowIsOrderedIn", (void **)&orderedIn, uuid) ||
        !nativeSymbol("SLSGetWindowBounds", (void **)&windowBounds, uuid) ||
        !nativeSymbol("SLSCopySpacesForWindows", (void **)&copySpaces, uuid) ||
        !nativeSymbol("SLSCopyManagedDisplaySpaces", (void **)&copyDisplays, uuid) ||
        !nativeSymbol("SLSGetActiveSpace", (void **)&activeSpace, uuid) ||
        !nativeSymbol("SLSSetConnectionProperty", (void **)&setProperty, uuid) ||
        !nativeSymbol("SLSCopyConnectionProperty", (void **)&copyProperty, uuid) ||
        !nativeSymbol("SLSRegisterConnectionNotifyProc", (void **)&registerNotify, uuid)) return NO;
    int cid = mainConnection(); pid_t pid = 0;
    if (cid <= 0 || connectionPID(cid, &pid) || pid != getpid() || (installed && connection != cid)) return NO;
    connection = cid; return YES;
}
static BOOL ordinarySpace(uint64_t sid) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if (!session || ![session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue] ||
        [session[@"CGSSessionScreenIsLocked"] boolValue] ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight)) return NO;
    if (!sid || activeSpace(connection) != sid) return NO;
    NSArray *displays = CFBridgingRelease(copyDisplays(connection)); NSUInteger matches = 0;
    if (![displays isKindOfClass:NSArray.class] || displays.count != 1) return NO;
    for (id display in displays) {
        if (![display isKindOfClass:NSDictionary.class]) return NO;
        NSArray *spaces = display[@"Spaces"]; if (![spaces isKindOfClass:NSArray.class] || spaces.count > 64) return NO;
        for (id row in spaces) {
            if (![row isKindOfClass:NSDictionary.class]) return NO;
            id number = row[@"id64"] ?: row[@"ManagedSpaceID"];
            if (integer(number, 1, (1ULL << 53) - 1) && [number unsignedLongLongValue] == sid) {
                if (!integer(row[@"type"], 0, 0)) return NO;
                matches++;
            }
        }
    }
    return matches == 1 && activeSpace(connection) == sid;
}
static BOOL leaseValid(CSOwner *state) {
    return state && state.enabled && clockNow() < state.expires &&
        [selfIdentity() isEqual:state.grant[@"target"]] && actorValid(state.grant[@"manager"], YES) &&
        actorValid(state.grant[@"window_server"], NO);
}
static uint64_t knownMinimum(NSWindow *window) {
    NSSize minimum = window.minSize;
    NSSize content = [window frameRectForContentRect:NSMakeRect(0, 0, window.contentMinSize.width, window.contentMinSize.height)].size;
    minimum.width = MAX(minimum.width, content.width); minimum.height = MAX(minimum.height, content.height);
    if (!isfinite(minimum.width) || !isfinite(minimum.height) || minimum.width <= 0 || minimum.height <= 0 ||
        minimum.width > 32767.5 || minimum.height > 32767.5) return 0;
    uint64_t expected = (uint64_t)lround(minimum.width * 2) | ((uint64_t)lround(minimum.height * 2) << 16);
    char name[80]; snprintf(name, sizeof(name), "hyprwm.min.%ld", (long)window.windowNumber);
    int token; uint64_t value = 0;
    if (notify_register_check(name, &token) != NOTIFY_STATUS_OK) return 0;
    uint32_t result = notify_get_state(token, &value); notify_cancel(token);
    return result == NOTIFY_STATUS_OK && value == expected && (value & 0xffff) > 0 && (value >> 16) > 0 ? value : 0;
}
static BOOL windowValid(CSOwner *state, CSWindow *row) {
    NSWindow *window = row.window;
    if (!window || (uintptr_t)(__bridge void *)window != row.object || window.windowNumber != row.wid ||
        ![window isKindOfClass:NSWindow.class] || [window isKindOfClass:NSPanel.class] ||
        !(window.styleMask & NSWindowStyleMaskTitled) || !(window.styleMask & NSWindowStyleMaskResizable) ||
        (window.styleMask & NSWindowStyleMaskFullScreen) || window.level != NSNormalWindowLevel ||
        !window.isVisible || window.isMiniaturized || !window.isOnActiveSpace || NSApp.isHidden ||
        (window.collectionBehavior & NSWindowCollectionBehaviorCanJoinAllSpaces)) return NO;
    NSUInteger objects = 0; for (NSWindow *item in NSApp.windows) if (item.windowNumber == row.wid) { if (item != window) return NO; objects++; }
    int cid = 0; pid_t pid = 0; uint8_t ordered = 0;
    if (objects != 1 || windowOwner(connection, row.wid, &cid) || cid != connection ||
        connectionPID(cid, &pid) || pid != getpid() || orderedIn(connection, row.wid, &ordered) || !ordered) return NO;
    uint64_t sid = [state.grant[@"ordinary_space"] unsignedLongLongValue];
    NSArray *spaces = CFBridgingRelease(copySpaces(connection, 7, (__bridge CFArrayRef)@[@(row.wid)]));
    return [spaces isKindOfClass:NSArray.class] && spaces.count == 1 && [spaces[0] isEqual:@(sid)] &&
        activeSpace(connection) == sid && row.minimum && knownMinimum(window) == row.minimum;
}
static NSArray *actualFrame(NSWindow *window) {
    int before = 0, after = 0; pid_t pid = 0; CGRect frame = CGRectZero;
    if (!window || windowOwner(connection, (uint32_t)window.windowNumber, &before) || before != connection ||
        connectionPID(before, &pid) || pid != getpid() || windowBounds(connection, (uint32_t)window.windowNumber, &frame) ||
        windowOwner(connection, (uint32_t)window.windowNumber, &after) || after != before ||
        connectionPID(after, &pid) || pid != getpid()) return nil;
    if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) || !isfinite(frame.size.width) || !isfinite(frame.size.height)) return nil;
    return @[@(frame.origin.x), @(frame.origin.y), @(frame.size.width), @(frame.size.height)];
}
static BOOL frameMatches(NSArray *frame, CSMessage message, double tolerance) {
    return frame.count == 4 && fabs([frame[0] doubleValue] - message.x) <= tolerance && fabs([frame[1] doubleValue] - message.y) <= tolerance &&
        fabs([frame[2] doubleValue] - message.w) <= tolerance && fabs([frame[3] doubleValue] - message.h) <= tolerance;
}
static BOOL cocoaFrame(CSMessage message, NSRect *result) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count != 1) return NO;
    NSRect screen = screens[0].frame;
    if (!isfinite(NSMaxY(screen))) return NO;
    *result = NSMakeRect(message.x, NSMaxY(screen) - message.y - message.h, message.w, message.h);
    return isfinite(result->origin.y);
}
static void invalidateLocked(CSOwner *state, NSString *reason) {
    state.enabled = NO; state.generation++; state.reason = reason;
    for (CSWindow *row in state.windows.allValues) { row.pending = NO; row.awaitingReadback = NO; row.ready = NO; row.sequence++; }
}
static void invalidate(CSOwner *state, NSString *reason) {
    pthread_mutex_lock(&stateLock);
    invalidateLocked(state, reason);
    pthread_mutex_unlock(&stateLock);
}
static NSDictionary *snapshot(CSOwner *state) {
    NSMutableArray *rows = [NSMutableArray new]; BOOL ready = state.enabled && state.windows.count > 0;
    pthread_mutex_lock(&stateLock);
    for (NSNumber *wid in [state.windows.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        CSWindow *row = state.windows[wid]; ready &= row.ready && row.probeSequence > 0 && row.probeAckTime > 0;
        [rows addObject:@{@"wid":wid, @"object":[NSString stringWithFormat:@"%llx", (unsigned long long)row.object],
            @"minimum":@(row.minimum), @"ready":jsonBool(row.ready), @"pending":jsonBool(row.pending), @"in_flight":jsonBool(row.inFlight),
            @"awaiting_readback":jsonBool(row.awaitingReadback), @"dispatched_sequence":@(row.dispatchedSequence), @"sequence":@(row.sequence),
            @"t0":@(row.stamp),
            @"initial_probe_ack":@{@"sequence":@(row.probeSequence), @"t0":@(row.probeStamp), @"time":@(row.probeAckTime), @"frame":row.probeFrame ?: @[]},
            @"last_ack":@{@"sequence":@(row.applied), @"t0":@(row.ackStamp), @"time":@(row.ackTime), @"frame":row.accepted ?: @[]}}];
    }
    NSDictionary *result = @{@"schema":@1, @"version":@1, @"kind":@"configure-stream", @"installed":jsonBool(installed),
        @"enabled":jsonBool(state.enabled), @"inactive":jsonBool(!state.enabled && state.inFlight == 0 && !state.scheduled && state.callbacks == 0),
        @"in_flight":@(state.inFlight), @"drain_scheduled":jsonBool(state.scheduled), @"admitted_callbacks":@(state.callbacks),
        @"capability":@(ready ? 6 : 0), @"proof_kind":@"synchronous-frame-readback-v1", @"generation":@(state.generation),
        @"epoch":@(state.epoch), @"grant_sha256":state.grantSHA256 ?: @"", @"module_uuid":moduleUUID() ?: @"", @"target":state.grant[@"target"] ?: @{}, @"manager":state.grant[@"manager"] ?: @{},
        @"window_server":state.grant[@"window_server"] ?: @{}, @"ordinary_space":state.grant[@"ordinary_space"] ?: @0,
        @"not_before":@(state.floor), @"expires":@(state.expires), @"observed_at":@(clockNow()),
        @"connection":@(connection), @"reason":state.reason ?: @"never-enabled", @"windows":rows};
    pthread_mutex_unlock(&stateLock); return result;
}
static BOOL publish(CSOwner *state) {
    if (!installed || !setProperty || connection <= 0) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot(state) options:0 error:NULL]; pid_t pid = 0;
    return data && data.length <= 16384 && !connectionPID(connection, &pid) && pid == getpid() &&
        !setProperty(connection, connection, CSProperty, (__bridge CFDataRef)data);
}
static void drain(CSOwner *state);
static void scheduleLocked(CSOwner *state) {
    if (state.scheduled) return;
    state.scheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ drain(state); });
}
static void received(uint32_t type, void *data, size_t length, void *context, int cid) {
    (void)context;
    if (type != CSNotify || !data || cid != connection) return;
    pthread_mutex_lock(&stateLock);
    CSOwner *state = owner; uint64_t generation = state.generation;
    if (!state.enabled) { pthread_mutex_unlock(&stateLock); return; }
    state.callbacks++;
    pthread_mutex_unlock(&stateLock);
    @try {
        CSMessage message;
        if (length == sizeof(message)) memcpy(&message, data, sizeof(message));
        else if (length == sizeof(message) + 12) {
            uint32_t header; memcpy(&header, data, sizeof(header)); if (header != CSNotify) return;
            memcpy(&message, (const uint8_t *)data + 12, sizeof(message));
        } else return;
        double now = clockNow();
        if (message.magic != CSMagic || !message.wid || !isfinite(message.t0) || message.t0 > now || message.t0 < now - .2 ||
            !isfinite(message.x) || !isfinite(message.y) || !isfinite(message.w) || !isfinite(message.h) ||
            fabs(message.x) > 65536 || fabs(message.y) > 65536 || message.w > 65536 || message.h > 65536) return;
        BOOL cancel = message.w == 0 && message.h == 0;
        if (!cancel && (message.w < 1 || message.h < 1)) return;
        pthread_mutex_lock(&stateLock);
        CSWindow *row = state.windows[@(message.wid)];
        // Equal-tick cancellation wins. Cancellation retires this complete lease;
        // another ON needs an explicitly reviewed, newer epoch and fresh probes.
        if (owner == state && state.enabled && state.generation == generation && now < state.expires &&
            message.t0 > state.floor && row && (message.t0 > row.stamp || (cancel && message.t0 == row.stamp))) {
            row.stamp = message.t0; row.sequence++;
            if (cancel) invalidateLocked(state, @"stream-cancelled-new-epoch-required");
            else { row.pending = YES; row.newest = message; }
            scheduleLocked(state);
        }
        pthread_mutex_unlock(&stateLock);
    } @catch (NSException *exception) {
        (void)exception; invalidate(state, @"receive-exception-revoked");
    } @finally {
        pthread_mutex_lock(&stateLock);
        state.callbacks--;
        if (!state.enabled && !state.callbacks) scheduleLocked(state);
        pthread_mutex_unlock(&stateLock);
    }
}
static BOOL acknowledgeReadback(CSOwner *state, CSWindow *row, uint64_t sid) {
    if (!row.awaitingReadback) return YES;
    uint64_t generation = state.generation;
    NSArray *actual = actualFrame(row.window);
    if (!leaseValid(state) || !ordinarySpace(sid) || !windowValid(state, row)) {
        invalidate(state, @"post-setter-readback-authority-revoked"); return NO;
    }
    if (!frameMatches(actual, row.dispatched, 1)) {
        if (clockNow() - row.dispatchedAt > .2) { invalidate(state, @"actual-frame-readback-timeout"); return NO; }
        return YES; // AppKit returned; actual WS geometry is not acknowledged yet.
    }
    pthread_mutex_lock(&stateLock);
    if (state.enabled && state.generation == generation && row.awaitingReadback && clockNow() < state.expires) {
        row.accepted = actual; row.applied = row.dispatchedSequence; row.ackStamp = row.dispatched.t0; row.ackTime = clockNow();
        if (!row.probeAckTime && row.probeSequence == row.dispatchedSequence) {
            row.probeFrame = actual; row.probeAckTime = row.ackTime; row.ready = YES;
        }
        row.awaitingReadback = NO; state.reason = @"synchronous-frame-readback-acknowledged";
    }
    pthread_mutex_unlock(&stateLock); return YES;
}
static void drain(CSOwner *state) {
    @try {
        if (owner != state) return;
        uint64_t sid = [state.grant[@"ordinary_space"] unsignedLongLongValue];
        if (!leaseValid(state) || !ordinarySpace(sid)) { invalidate(state, @"lease-or-space-revoked"); return; }
        for (CSWindow *row in state.windows.allValues) {
            if (!acknowledgeReadback(state, row, sid)) break;
            pthread_mutex_lock(&stateLock);
            BOOL pending = state.enabled && row.pending && !row.inFlight && (row.ready || !row.awaitingReadback), ready = row.ready;
            CSMessage message = row.newest; uint64_t sequence = row.sequence, generation = state.generation;
            if (pending) row.pending = NO;
            pthread_mutex_unlock(&stateLock);
            if (!pending) continue;
            NSWindow *window = row.window; NSRect cocoa = NSZeroRect;
            if (message.t0 < clockNow() - .2 || !windowValid(state, row) || !cocoaFrame(message, &cocoa) ||
                message.w + .01 < (double)(row.minimum & 0xffff) / 2 || message.h + .01 < (double)(row.minimum >> 16) / 2 ||
                (!ready && !frameMatches(actualFrame(window), message, .01))) {
                invalidate(state, @"binding-minimum-or-current-frame-probe-refused"); break;
            }
            // Recheck the whole authority for this WID after conversion and
            // immediately before committing native entry. Cohort-start checks
            // alone do not cover expiry/death/Space changes between windows.
            if (!leaseValid(state) || !ordinarySpace(sid) || !windowValid(state, row) ||
                message.t0 < clockNow() - .2) { invalidate(state, @"pre-entry-authority-revoked"); break; }
            pthread_mutex_lock(&stateLock);
            BOOL current = state.enabled && state.generation == generation && row.sequence == sequence && clockNow() < state.expires;
            BOOL probe = current && !ready && row.probeSequence == 0;
            if (current) {
                state.inFlight++; row.inFlight = YES;
                if (probe) { row.probeSequence = sequence; row.probeStamp = message.t0; }
            }
            pthread_mutex_unlock(&stateLock);
            if (!current) continue;
            @try {
                // Public synchronous setter, already used by the legacy public
                // fallback. This overload does not request an AppKit animation.
                // No module-owned native completion or deferred setter exists.
                [window setFrame:cocoa display:YES];
                pthread_mutex_lock(&stateLock);
                if (state.enabled && state.generation == generation) {
                    row.dispatched = message; row.dispatchedSequence = sequence;
                    row.dispatchedAt = clockNow(); row.awaitingReadback = YES;
                }
                pthread_mutex_unlock(&stateLock);
            } @finally {
                pthread_mutex_lock(&stateLock);
                state.inFlight--; row.inFlight = NO;
                pthread_mutex_unlock(&stateLock);
            }
            if (!acknowledgeReadback(state, row, sid)) break;
        }
    } @catch (NSException *exception) {
        (void)exception; invalidate(state, @"synchronous-frame-drain-exception-revoked");
    } @finally {
        pthread_mutex_lock(&stateLock); state.scheduled = NO;
        for (CSWindow *row in state.windows.allValues)
            if (state.enabled && row.pending && !row.inFlight && (row.ready || !row.awaitingReadback)) { scheduleLocked(state); break; }
        pthread_mutex_unlock(&stateLock);
        @try { if (!publish(state)) invalidate(state, @"status-publication-failed"); }
        @catch (NSException *exception) { (void)exception; invalidate(state, @"drain-publication-exception-revoked"); }
    }
}
static BOOL installObserver(NSString *uuid) {
    if (!resolveNative(uuid)) return NO;
    if (installed) return YES;
    CFTypeRef prior = NULL;
    int priorResult = copyProperty(connection, connection, CSProperty, &prior);
    BOOL occupied = prior != NULL;
    if (prior) CFRelease(prior);
    // Never replace another retained receiver, even an apparently inactive one.
    // Absence must be established before registering our one callback.
    if (priorResult || occupied) return NO;
    if (registerNotify(connection, (void *)received, CSNotify, NULL)) return NO;
    installed = YES;
    closeObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        CSOwner *state = owner;
        @try {
            for (CSWindow *row in state.windows.allValues) if (row.window == note.object) { invalidate(state, @"bound-window-closing"); publish(state); break; }
        } @catch (NSException *exception) { (void)exception; invalidate(state, @"close-observation-exception-revoked"); }
    }];
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 50000000), 50000000, 5000000);
    dispatch_source_set_event_handler(timer, ^{
        CSOwner *state = owner; if (!state) return;
        @try {
            if (state.enabled) {
                BOOL valid = leaseValid(state) && ordinarySpace([state.grant[@"ordinary_space"] unsignedLongLongValue]);
                for (CSWindow *row in state.windows.allValues) valid &= windowValid(state, row);
                if (!valid) invalidate(state, @"binding-lease-or-space-revoked");
            }
            pthread_mutex_lock(&stateLock);
            for (CSWindow *row in state.windows.allValues) if (state.enabled && row.awaitingReadback) { scheduleLocked(state); break; }
            pthread_mutex_unlock(&stateLock);
            if (!publish(state)) invalidate(state, @"status-publication-failed");
        } @catch (NSException *exception) { (void)exception; invalidate(state, @"timer-validation-exception-revoked"); }
    });
    dispatch_resume(timer); return YES;
}
static NSString *enable(NSDictionary *request) {
    NSString *rawSHA256 = nil;
    NSDictionary *target = selfIdentity(), *grant = target ? readGrant(target, &rawSHA256) : nil;
    double now = clockNow();
    if (!grant || ![grant[@"schema"] isEqual:@1] || ![grant[@"kind"] isEqual:@"configure-stream-v1"] ||
        ![grant[@"scope"] isEqual:@"qualified-own-windows"] || ![grant[@"target"] isEqual:target] || ![grant[@"module_uuid"] isEqual:moduleUUID()] ||
        !integer(grant[@"epoch"], 1, (1ULL << 53) - 1) || ![request[@"epoch"] isEqual:grant[@"epoch"]] ||
        [grant[@"epoch"] unsignedLongLongValue] <= lastEpoch || !numeric(grant[@"expires"]) ||
        [grant[@"expires"] doubleValue] <= now || [grant[@"expires"] doubleValue] > now + 30 ||
        !integer(grant[@"ordinary_space"], 1, (1ULL << 53) - 1) ||
        !actorValid(grant[@"manager"], YES) || !actorValid(grant[@"window_server"], NO) ||
        !windowServerExecutable(grant[@"window_server"][@"executable"]) ||
        ![grant[@"allow_activation"] isEqual:@NO] || ![grant[@"allow_input"] isEqual:@NO] || ![grant[@"allow_restart"] isEqual:@NO]) return @"protected-exact-epoch-grant-required";
    NSArray *bindings = grant[@"windows"];
    if (![bindings isKindOfClass:NSArray.class] || bindings.count < 1 || bindings.count > CSMaxWindows ||
        (owner && (owner.enabled || owner.inFlight || owner.scheduled || owner.callbacks))) return @"bounded-inactive-cohort-required";
    if (!installObserver(grant[@"skylight_uuid"]) || !ordinarySpace([grant[@"ordinary_space"] unsignedLongLongValue])) return @"native-provenance-or-ordinary-space-refused";
    CSOwner *state = [CSOwner new]; state.grant = grant; state.grantSHA256 = rawSHA256; state.windows = [NSMutableDictionary new];
    state.epoch = [grant[@"epoch"] unsignedLongLongValue]; state.generation = ++nextGeneration;
    state.floor = clockNow(); state.expires = [grant[@"expires"] doubleValue]; state.reason = @"awaiting-current-frame-probes";
    for (id binding in bindings) {
        if (![binding isKindOfClass:NSDictionary.class]) return @"exact-window-object-bindings-required";
        id number = binding[@"wid"];
        if (!integer(number, 1, UINT32_MAX) || state.windows[number]) return @"unique-positive-exact-window-ids-required";
        CSWindow *row = [CSWindow new]; row.wid = [number unsignedIntValue];
        for (NSWindow *window in NSApp.windows) if (window.windowNumber == row.wid) {
            if (row.window) return @"ambiguous-window-object";
            row.window = window; row.object = (uintptr_t)(__bridge void *)window;
        }
        NSString *object = [NSString stringWithFormat:@"%llx", (unsigned long long)row.object];
        if (![binding[@"object"] isEqual:object]) return @"pre-reviewed-window-object-required";
        if (!row.window) return @"existing-native-window-required";
        row.minimum = knownMinimum(row.window);
        if (!windowValid(state, row)) return @"visible-bound-window-and-native-minimum-required";
        state.windows[number] = row;
    }
    state.enabled = YES;
    pthread_mutex_lock(&stateLock); owner = state; lastEpoch = state.epoch; pthread_mutex_unlock(&stateLock);
    if (!leaseValid(state) || !publish(state)) { invalidate(state, @"initial-publication-failed"); publish(state); return @"initial-status-unproved"; }
    return nil;
}
static NSDictionary *inspectBindings(void) {
    NSMutableArray *rows = [NSMutableArray new];
    for (NSWindow *window in NSApp.windows) {
        if (![window isKindOfClass:NSWindow.class] || [window isKindOfClass:NSPanel.class] ||
            window.windowNumber <= 0 || (uint64_t)window.windowNumber > UINT32_MAX ||
            !(window.styleMask & NSWindowStyleMaskTitled) || !(window.styleMask & NSWindowStyleMaskResizable) ||
            window.level != NSNormalWindowLevel || !window.isVisible || window.isMiniaturized) continue;
        if (rows.count == CSMaxWindows) return @{@"ok":jsonBool(NO), @"reason":@"own-window-inspection-bound-exceeded"};
        [rows addObject:@{@"wid":@(window.windowNumber),
            @"object":[NSString stringWithFormat:@"%llx", (unsigned long long)(uintptr_t)(__bridge void *)window]}];
    }
    return @{@"ok":jsonBool(YES), @"target":selfIdentity() ?: @{}, @"module_uuid":moduleUUID() ?: @"", @"windows":rows};
}
int hypr_configure_stream_v1_json(unsigned action, const char *request, char *output, unsigned capacity) {
    if (!output || capacity < 32768 || capacity > 65536) return -1;
    output[0] = 0;
    if (!NSThread.isMainThread || !NSApp) return -2;
    @try {
        NSDictionary *argument = nil;
        if (request) {
            size_t size = strnlen(request, 16385); if (size > 16384) return -3;
            id value = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:request length:size] options:0 error:NULL];
            if (![value isKindOfClass:NSDictionary.class]) return -3; argument = value;
        }
        NSString *error = nil;
        if (action == 1) error = enable(argument);
        else if (action == 2) {
            if (!owner || ![argument[@"epoch"] isEqual:@(owner.epoch)]) error = @"owned-epoch-required";
            else { invalidate(owner, @"explicit-off"); if (!publish(owner)) error = @"off-publication-unproved"; }
        } else if (action != 0) error = @"unknown-action";
        if (owner.enabled) {
            BOOL valid = leaseValid(owner) && ordinarySpace([owner.grant[@"ordinary_space"] unsignedLongLongValue]);
            for (CSWindow *row in owner.windows.allValues) valid &= windowValid(owner, row);
            if (!valid) { invalidate(owner, @"binding-or-lease-revoked-at-status"); publish(owner); }
        }
        NSDictionary *status = snapshot(owner);
        BOOL inactive = [status[@"inactive"] boolValue];
        if (action == 2 && !error && !inactive) error = @"off-revoked-queue-or-callback-still-pending";
        NSDictionary *result = @{@"ok":jsonBool(!error), @"error":error ?: @"", @"status":status,
            @"inspection":action == 0 ? inspectBindings() : @{}};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if (!data || data.length + 1 > capacity) return -4;
        memcpy(output, data.bytes, data.length); output[data.length] = 0;
        return error ? 1 : 0;
    } @catch (NSException *exception) {
        (void)exception;
        if (owner) { invalidate(owner, @"native-exception-revoked"); publish(owner); }
        const char *error = "{\"ok\":false,\"error\":\"native-exception-revoked\"}";
        if (strlen(error) + 1 <= capacity) strlcpy(output, error, capacity);
        return -5;
    }
}
