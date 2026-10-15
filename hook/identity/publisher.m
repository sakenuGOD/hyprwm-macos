#import "publisher.h"

static const NSUInteger wireLimit = 65536, maxWindows = 128, maxGroups = 128, maxEvents = 32;
static NSUInteger publicationCounter;
static dispatch_queue_t publisherQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("hyprwm.identity.publisher", DISPATCH_QUEUE_SERIAL); });
    return queue; // Shared across sessions: old tombstone precedes new install data.
}

static id immutableCopy(id value, NSUInteger *budget) {
    if (!*budget) return nil;
    --*budget;
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary new];
        for (NSString *key in value) {
            id item = immutableCopy(value[key], budget);
            if (!item) return nil;
            result[[key copy]] = item;
        }
        return [result copy];
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray new];
        for (id item in value) {
            id copied = immutableCopy(item, budget);
            if (!copied) return nil;
            [result addObject:copied];
        }
        return [result copy];
    }
    return [value copy];
}

NSDictionary *HIIdentityWireSnapshot(NSDictionary *snapshot) {
    NSMutableDictionary *wire = [NSMutableDictionary new];
    for (NSString *key in @[@"schema", @"pid", @"launch", @"generation", @"installed", @"seq",
                            @"revision", @"settled_revision", @"reconcile_pending", @"capabilities", @"history_pruned"])
        if (snapshot[key]) wire[key] = snapshot[key];
    wire[@"transport"] = @"ws-connection-v1";
    NSSet *liveWindows = [NSSet setWithArray:snapshot[@"live_objects"] ?: @[]];
    NSSet *liveGroups = [NSSet setWithArray:snapshot[@"live_groups"] ?: @[]];
    NSMutableArray *windows = [NSMutableArray new], *groups = [NSMutableArray new];
    BOOL complete = ![snapshot[@"reconcile_pending"] boolValue];
    for (NSDictionary *window in snapshot[@"windows"]) {
        if (![liveWindows containsObject:window[@"object"]]) continue;
        if (windows.count >= maxWindows) { complete = NO; continue; }
        [windows addObject:window];
        if (![window[@"group_known"] boolValue] || ![window[@"group_kvo"] boolValue] ||
            window[@"hidden_tab"] == NSNull.null) complete = NO;
    }
    for (NSDictionary *group in snapshot[@"groups"]) {
        if (![liveGroups containsObject:group[@"group"]]) continue;
        if (groups.count >= maxGroups || [group[@"members"] count] > maxWindows) { complete = NO; continue; }
        [groups addObject:group];
        if (![group[@"membership_kvo"] boolValue] || ![group[@"selection_kvo"] boolValue]) complete = NO;
    }
    if (windows.count != liveWindows.count || groups.count != liveGroups.count ||
        [snapshot[@"sampling_failed_groups"] count]) complete = NO;
    NSArray *events = snapshot[@"events"] ?: @[];
    NSUInteger start = events.count > maxEvents ? events.count - maxEvents : 0;
    wire[@"windows"] = windows; wire[@"groups"] = groups;
    wire[@"events"] = [events subarrayWithRange:NSMakeRange(start, events.count - start)];
    wire[@"dropped_events"] = @([snapshot[@"dropped_events"] unsignedIntegerValue] + start);
    wire[@"complete"] = @(complete); wire[@"gap"] = @NO;
    NSUInteger budget = 8192;
    NSDictionary *copy = immutableCopy(wire, &budget);
    if (copy) return copy;
    wire[@"windows"] = @[]; wire[@"groups"] = @[]; wire[@"events"] = @[];
    wire[@"complete"] = @NO; wire[@"gap"] = @YES;
    return [wire copy];
}

@interface HIIdentityPublisher ()
@property(nonatomic, copy) int (^writer)(NSData *);
@property(nonatomic, copy) void (^notify)(void);
@property(nonatomic) NSDictionary *pending;
@property(nonatomic) BOOL draining;
@property(nonatomic) BOOL revoked;
@end
@implementation HIIdentityPublisher
- (instancetype)initWithWriter:(int (^)(NSData *))writer didPublish:(void (^)(void))notify {
    self = [super init];
    if (self) { _writer = [writer copy]; _notify = [notify copy]; }
    return self;
}
- (void)enqueue:(NSDictionary *)snapshot revoke:(BOOL)revoke {
    NSAssert(NSThread.isMainThread, @"Publish only immutable snapshots copied on main");
    @synchronized (self) {
        if (self.revoked) return;
        NSMutableDictionary *wire = [snapshot mutableCopy];
        wire[@"publication"] = @(++publicationCounter);
        if (revoke) {
            self.revoked = YES;
            wire[@"installed"] = @NO; wire[@"complete"] = @YES;
            wire[@"reconcile_pending"] = @NO;
            wire[@"windows"] = @[]; wire[@"groups"] = @[]; wire[@"events"] = @[];
        }
        self.pending = [wire copy]; // Exactly one pending snapshot, replacing older work.
        if (self.draining) return;
        self.draining = YES;
    }
    dispatch_async(publisherQueue(), ^{
        for (;;) {
            @autoreleasepool {
                NSDictionary *next;
                @synchronized (self) {
                    next = self.pending; self.pending = nil;
                    if (!next) { self.draining = NO; return; }
                }
                NSMutableDictionary *value = [next mutableCopy];
                NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
                while (data.length > wireLimit && [value[@"events"] count]) {
                    NSArray *events = value[@"events"];
                    value[@"events"] = [events subarrayWithRange:NSMakeRange(1, events.count - 1)];
                    value[@"dropped_events"] = @([value[@"dropped_events"] unsignedIntegerValue] + 1);
                    data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
                }
                if (data.length > wireLimit) {
                    value[@"windows"] = @[]; value[@"groups"] = @[]; value[@"events"] = @[];
                    value[@"complete"] = @NO; value[@"gap"] = @YES;
                    data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:NULL];
                }
                if (data && data.length <= wireLimit && self.writer(data) == 0 && self.notify) self.notify();
            }
        }
    });
}
- (void)submit:(NSDictionary *)snapshot { [self enqueue:snapshot revoke:NO]; }
- (void)revoke:(NSDictionary *)snapshot { [self enqueue:snapshot revoke:YES]; }
+ (void)drainForTesting { dispatch_sync(publisherQueue(), ^{}); }
@end
