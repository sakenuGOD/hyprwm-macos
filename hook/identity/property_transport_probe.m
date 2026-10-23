// ROOT-ONLY LIVE PROBE. Offline selftest never loads SkyLight or connects to WS.
// Creates/releases only its own connection; producer never accepts a write target.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>

static const NSUInteger wireLimit = 65536;
static NSString *const propertyKey = @"hyprwm.identity.probe.v1";
static volatile sig_atomic_t stopped;
static void stopSignal(int signalNumber) { (void)signalNumber; stopped = 1; }

typedef int (*NewConnection)(const void *, int *);
typedef int (*ReleaseConnection)(int);
typedef int (*ConnectionPID)(int, pid_t *);
typedef int (*SetProperty)(int, int, CFStringRef, CFTypeRef);
typedef int (*CopyProperty)(int, int, CFStringRef, CFTypeRef *);
typedef struct {
    void *handle;
    NewConnection create;
    ReleaseConnection release;
    ConnectionPID pid;
    SetProperty set;
    CopyProperty copy;
    int own;
} Transport;

static void output(NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout); fflush(stdout);
}

static NSMutableDictionary *envelope(NSString *launch, NSUInteger revision, BOOL installed) {
    return [@{ @"schema": @1, @"pid": @(getpid()), @"launch": launch,
               @"generation": @1, @"revision": @(revision), @"installed": @(installed),
               @"probe": @{ @"null": NSNull.null, @"utf8": @"тест",
                            @"flags": @[@YES, @NO, NSNull.null], @"padding": @"" } } mutableCopy];
}

static NSData *encoded(NSDictionary *value) {
    return [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
}

static NSData *sizedEnvelope(NSString *launch, NSUInteger revision, BOOL installed, NSUInteger requestedBytes) {
    NSMutableDictionary *value = envelope(launch, revision, installed);
    NSUInteger base = encoded(value).length;
    if (requestedBytes && requestedBytes < base) return nil;
    if (requestedBytes) {
        NSMutableDictionary *probe = [value[@"probe"] mutableCopy];
        probe[@"padding"] = [@"" stringByPaddingToLength:requestedBytes - base withString:@"x" startingAtIndex:0];
        value[@"probe"] = probe;
    }
    return encoded(value);
}

static NSDictionary *decode(NSData *data) {
    if (!data || data.length > wireLimit) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static BOOL payloadValid(NSDictionary *value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"schema"] isEqual:@1]) return NO;
    for (NSString *key in @[@"pid", @"generation", @"revision", @"installed"])
        if (![value[key] isKindOfClass:NSNumber.class]) return NO;
    if (![value[@"launch"] isKindOfClass:NSString.class]) return NO;
    id probe = value[@"probe"];
    if (![probe isKindOfClass:NSDictionary.class] || probe[@"null"] != NSNull.null ||
        ![probe[@"utf8"] isEqual:@"тест"] || ![probe[@"flags"] isEqual:@[@YES, @NO, NSNull.null]]) return NO;
    NSString *padding = probe[@"padding"];
    if (![padding isKindOfClass:NSString.class]) return NO;
    return [padding rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"x"] invertedSet]].location == NSNotFound;
}

static int transportOpen(Transport *t) {
    t->handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    if (!t->handle) { output(@{ @"event": @"load_failed" }); return 2; }
    t->create = dlsym(t->handle, "SLSNewConnection");
    t->release = dlsym(t->handle, "SLSReleaseConnection");
    t->pid = dlsym(t->handle, "SLSConnectionGetPID");
    t->set = dlsym(t->handle, "SLSSetConnectionProperty");
    t->copy = dlsym(t->handle, "SLSCopyConnectionProperty");
    if (!t->create || !t->release || !t->pid || !t->set || !t->copy) {
        output(@{ @"event": @"symbols_missing" }); return 2;
    }
    int result = t->create(NULL, &t->own);
    pid_t owner = 0;
    int pidResult = result == 0 && t->own ? t->pid(t->own, &owner) : -1;
    if (result || !t->own || pidResult || owner != getpid()) {
        output(@{ @"event": @"own_connection_failed", @"return": @(result), @"pid_return": @(pidResult),
                  @"connection": @(t->own), @"owner_pid": @(owner), @"pid": @(getpid()) });
        if (t->own) t->release(t->own);
        t->own = 0; return 2;
    }
    return 0;
}

static int transportClose(Transport *t) {
    int result = t->own ? t->release(t->own) : 0;
    output(@{ @"event": @"released", @"connection": @(t->own), @"return": @(result) });
    t->own = 0;
    // Do not dlclose a framework with initialized process-global runtime state.
    return result ? 1 : 0;
}

static NSData *copyData(Transport *t, int target, NSMutableDictionary *result) {
    CFTypeRef copied = NULL;
    int code = t->copy(t->own, target, (__bridge CFStringRef)propertyKey, &copied);
    result[@"copy_return"] = @(code);
    NSData *data;
    if (copied) {
        BOOL isData = CFGetTypeID(copied) == CFDataGetTypeID();
        result[@"is_cfdata"] = @(isData);
        if (!code && isData) data = [(__bridge NSData *)copied copy];
        CFRelease(copied);
    } else result[@"is_cfdata"] = @NO;
    if (data) result[@"bytes"] = @(data.length);
    return data;
}

static BOOL publish(Transport *t, NSData *data, NSString *action) {
    if (!data || data.length > wireLimit) {
        output(@{ @"event": @"rejected_before_ws", @"action": action,
                  @"bytes": @(data.length), @"limit": @(wireLimit), @"set_called": @NO });
        return NO;
    }
    NSDictionary *value = decode(data);
    int code = t->set(t->own, t->own, (__bridge CFStringRef)propertyKey, (__bridge CFDataRef)data);
    NSMutableDictionary *result = [@{ @"event": action, @"connection": @(t->own), @"pid": @(getpid()),
        @"launch": value[@"launch"], @"revision": value[@"revision"], @"installed": value[@"installed"],
        @"set_return": @(code), @"bytes": @(data.length), @"limit": @(wireLimit) } mutableCopy];
    NSData *readback = copyData(t, t->own, result);
    BOOL equal = [data isEqualToData:readback];
    result[@"own_readback_equal"] = @(equal);
    result[@"null_ok"] = @(payloadValid(decode(readback)));
    output(result);
    return !code && equal && payloadValid(decode(readback));
}

static int consumer(int target, pid_t expectedPID, NSString *expectedLaunch, NSUInteger expectedRevision) {
    Transport t = {0};
    int result = transportOpen(&t);
    if (result) return result;
    pid_t actualPID = 0;
    int pidCode = t.pid(target, &actualPID);
    NSMutableDictionary *report = [@{ @"event": @"remote_read", @"connection": @(target),
        @"reader_connection": @(t.own), @"owner_pid": @(actualPID), @"pid_return": @(pidCode) } mutableCopy];
    NSData *data;
    if (!pidCode && actualPID == expectedPID) data = copyData(&t, target, report);
    NSDictionary *value = decode(data);
    BOOL valid = value && payloadValid(value) && [value[@"pid"] intValue] == expectedPID &&
        [value[@"launch"] isEqual:expectedLaunch] && [value[@"revision"] unsignedIntegerValue] == expectedRevision;
    report[@"valid"] = @(valid);
    report[@"null_ok"] = @(payloadValid(value));
    if (value) {
        report[@"launch"] = value[@"launch"] ?: NSNull.null;
        report[@"revision"] = value[@"revision"] ?: NSNull.null;
        report[@"installed"] = value[@"installed"] ?: NSNull.null;
        id probe = value[@"probe"];
        if ([probe isKindOfClass:NSDictionary.class] && [probe[@"padding"] isKindOfClass:NSString.class])
            report[@"padding_bytes"] = @([probe[@"padding"] length]);
    }
    output(report);
    int closeResult = transportClose(&t);
    return valid && !closeResult ? 0 : 1;
}

static int producer(unsigned lifetimeSeconds) {
    Transport t = {0};
    int result = transportOpen(&t);
    if (result) return result;
    NSString *launch = NSUUID.UUID.UUIDString;
    NSUInteger revision = 1;
    BOOL installed = YES, healthy = YES;
    NSData *last = sizedEnvelope(launch, revision, installed, 0);
    healthy = publish(&t, last, @"ready");
    struct sigaction action = {0}; action.sa_handler = stopSignal;
    sigemptyset(&action.sa_mask); sigaction(SIGINT, &action, NULL); sigaction(SIGTERM, &action, NULL);
    double deadline = NSProcessInfo.processInfo.systemUptime + lifetimeSeconds;
    NSMutableData *line = [NSMutableData new];
    while (healthy && !stopped && NSProcessInfo.processInfo.systemUptime < deadline) {
        struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
        int ready = poll(&input, 1, 200);
        if (ready < 0) { if (errno == EINTR) continue; break; }
        if (!ready) continue;
        char byte;
        ssize_t count = read(STDIN_FILENO, &byte, 1);
        if (count <= 0) break;
        if (byte != '\n') {
            if (line.length >= 128) { output(@{ @"event": @"command_too_long" }); break; }
            [line appendBytes:&byte length:1]; continue;
        }
        NSString *command = [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
        [line setLength:0];
        command = [command stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([command isEqual:@"quit"]) break;
        if ([command isEqual:@"oversize"]) {
            NSData *tooLarge = sizedEnvelope(launch, revision + 1, YES, wireLimit + 1);
            BOOL rejected = !publish(&t, tooLarge, command);
            NSMutableDictionary *report = [@{ @"event": @"oversize_preserved", @"rejected": @(rejected),
                                              @"revision": @(revision) } mutableCopy];
            NSData *after = copyData(&t, t.own, report);
            report[@"unchanged"] = @([after isEqualToData:last]); output(report);
            healthy = rejected && [after isEqualToData:last];
        } else if ([command isEqual:@"fit"] || [command isEqual:@"put-null"] || [command isEqual:@"tombstone"]) {
            installed = ![command isEqual:@"tombstone"];
            last = sizedEnvelope(launch, ++revision, installed, [command isEqual:@"fit"] ? wireLimit : 0);
            healthy = publish(&t, last, command);
        } else output(@{ @"event": @"unknown_command", @"command": command ?: @"invalid-utf8" });
    }
    // Retain the connection after the explicit tombstone command so a second
    // process can read it; EOF/quit/deadline/signal then releases only this connection.
    if (installed) {
        NSData *tombstone = sizedEnvelope(launch, ++revision, NO, 0);
        healthy = publish(&t, tombstone, @"cleanup_tombstone") && healthy;
    }
    int closeResult = transportClose(&t);
    return healthy && !closeResult ? 0 : 1;
}

static unsigned checks;
static void check(BOOL condition, const char *message) {
    ++checks;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}
static int offline(void) {
    NSString *launch = @"offline-no-skylight";
    NSData *normal = sizedEnvelope(launch, 1, YES, 0);
    check(payloadValid(decode(normal)), "JSON null, booleans, UTF8 survive encoding");
    check([decode(normal)[@"launch"] isEqual:launch], "launch identity roundtrip");
    NSData *exact = sizedEnvelope(launch, 2, YES, wireLimit);
    check(exact.length == wireLimit && payloadValid(decode(exact)), "exact wire ceiling payload");
    NSData *oversize = sizedEnvelope(launch, 3, YES, wireLimit + 1);
    check(oversize.length == wireLimit + 1 && decode(oversize) == nil, "oversize rejected before parsing/IPC");
    check(sizedEnvelope(launch, 3, YES, 1) == nil, "impossible requested size rejected");
    NSData *tombstone = sizedEnvelope(launch, 4, NO, 0);
    check([decode(tombstone)[@"installed"] isEqual:@NO] && payloadValid(decode(tombstone)), "explicit tombstone");
    CFDataRef cfData = CFDataCreate(kCFAllocatorDefault, exact.bytes, (CFIndex)exact.length);
    CFErrorRef error = NULL;
    CFDataRef plist = CFPropertyListCreateData(kCFAllocatorDefault, cfData, kCFPropertyListBinaryFormat_v1_0, 0, &error);
    check(plist != NULL && error == NULL, "CFData carrier is property-list serializable");
    CFPropertyListRef copy = CFPropertyListCreateWithData(kCFAllocatorDefault, plist, 0, NULL, &error);
    check(copy && CFGetTypeID(copy) == CFDataGetTypeID() && CFEqual(copy, cfData), "CFData property-list roundtrip");
    CFRelease(copy); CFRelease(plist); CFRelease(cfData); if (error) CFRelease(error);
    check(!payloadValid(@{ @"schema": @1, @"probe": @"malformed" }), "malformed nested payload rejected");
    output(@{ @"event": @"offline_pass", @"checks": @(checks), @"skylight_loaded": @NO, @"ws_calls": @0 });
    return 0;
}

static BOOL positiveInteger(const char *text, unsigned long *out) {
    if (!text || !*text || *text == '-') return NO;
    char *end = NULL; errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !end || *end || !value || value > INT_MAX) return NO;
    *out = value; return YES;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--offline-selftest") == 0) return offline();
        if (argc == 3 && strcmp(argv[1], "producer") == 0) {
            unsigned long seconds;
            if (positiveInteger(argv[2], &seconds) && seconds <= 120) return producer((unsigned)seconds);
        }
        if (argc == 6 && strcmp(argv[1], "consumer") == 0) {
            unsigned long cid, pid, revision;
            if (positiveInteger(argv[2], &cid) && positiveInteger(argv[3], &pid) && positiveInteger(argv[5], &revision))
                return consumer((int)cid, (pid_t)pid, [NSString stringWithUTF8String:argv[4]], revision);
        }
        fprintf(stderr, "Root live only: %s producer 60 | consumer CID PID LAUNCH REVISION\n"
                "No WS: %s --offline-selftest\nProducer stdin: put-null, fit, oversize, tombstone, quit\n", argv[0], argv[0]);
        return 2;
    }
}
