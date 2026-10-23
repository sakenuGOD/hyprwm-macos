// No AppKit/NSApplication. Native protocol/deadline probe used by offline tests.
#import "client.h"
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) return 2;
        signal(SIGPIPE,SIG_DFL);
        if (argc>3) HASetServerExecutable(@(argv[3]));
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        double started = HAClock(), deadline = started + atof(argv[2]) / 1000;
        NSDictionary *key = @{@"pid": @(getpid()), @"launch": NSUUID.UUID.UUIDString,
                              @"generation": @1, @"object": @1, @"wid": @1001, @"attempt": @1};
        NSDictionary *request = @{@"schema": @1, @"transport": @"fixture-uds-v1", @"op": @"prepare",
             @"key": key, @"deadline": @(deadline), @"minimum": @[@100, @100],
             @"facts": @{@"normal": @YES, @"resizable": @YES, @"panel": @NO, @"sheet": @NO,
                         @"parent": @NO, @"modal": @NO, @"level": @0, @"grouped": @NO,
                         @"group_known": @YES, @"title": @"client probe"}};
        NSDictionary *reply = HAExchange(path, request, deadline);
        BOOL apply = HAOfferUsable(reply, request, HAClock());
        NSDictionary *result = @{@"event": @"client_probe", @"apply": @(apply), @"reply": reply ?: NSNull.null,
                                 @"elapsed_ms": @((HAClock() - started) * 1000)};
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        puts([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
        return 0;
    }
}
