#import "identity.h"
#import "publisher.h"
#import "transport_native.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <unistd.h>

static char groupIdentityKey, windowIdentityKey, windowKVOContext, groupKVOContext;
static NSUInteger nextIdentity, nextGeneration;
static const NSUInteger eventLimit = 256;

static NSNumber *identity(id object, void *key) {
    if (!object) return nil;
    NSNumber *value = objc_getAssociatedObject(object, key);
    if (!value) {
        value = @(++nextIdentity);
        objc_setAssociatedObject(object, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return value;
}

static BOOL getterHasType(id object, SEL selector, char type) {
    Method method = class_getInstanceMethod(object_getClass(object), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return NO;
    char encoding[32];
    method_getReturnType(method, encoding, sizeof encoding);
    return encoding[0] == type;
}

static id existingGroupKnown(id window, BOOL *known) {
    if (known) *known = NO;
    SEL selector = NSSelectorFromString(@"_windowStackController");
    @try {
        if (!getterHasType(window, selector, '@')) return nil;
        id result = ((id (*)(id, SEL))objc_msgSend)(window, selector);
        if (known) *known = YES;
        return result;
    }
    @catch (NSException *exception) { (void)exception; return nil; }
}
static id existingGroup(id window) { return existingGroupKnown(window, NULL); }

static id hiddenTab(id window) {
    SEL selector = NSSelectorFromString(@"_isInHiddenWindowTab");
    @try { return getterHasType(window, selector, 'B') ? @(((BOOL (*)(id, SEL))objc_msgSend)(window, selector)) : NSNull.null; }
    @catch (NSException *exception) { (void)exception; return NSNull.null; }
}

static long long windowID(id object) {
    @try { return [object respondsToSelector:@selector(windowNumber)] ? (long long)[object windowNumber] : 0; }
    @catch (NSException *exception) { (void)exception; return 0; }
}

static NSString *notificationSymbol(const char *symbol) {
    NSString *__unsafe_unretained *value = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    return value ? *value : nil;
}

@interface HIIdentityJournal ()
@property(nonatomic, readwrite) BOOL installed;
@property(nonatomic, readwrite) NSUInteger generation;
@property(nonatomic) NSUInteger sequence;
@property(nonatomic) NSUInteger dropped;
@property(nonatomic) NSString *launch;
@property(nonatomic) NSMapTable *windows;
@property(nonatomic) NSMapTable *groups;
@property(nonatomic) NSMutableDictionary *windowRecords;
@property(nonatomic) NSMutableDictionary *groupRecords;
@property(nonatomic) NSMutableDictionary *groupPrior;
@property(nonatomic) NSMutableDictionary *priorMembership;
@property(nonatomic) NSMutableArray *events;
@property(nonatomic) NSMutableArray *notificationTokens;
@property(nonatomic) BOOL reconcilePending;
@property(nonatomic) NSUInteger reconcileRevision;
@property(nonatomic) NSUInteger settledRevision;
@property(nonatomic) NSUInteger historyPruned;
@property(nonatomic) NSMutableSet *samplingFailedGroups;
@property(nonatomic) HIIdentityPublisher *publisher;
@property(nonatomic) int publisherConnection;
@property(nonatomic) BOOL publicationScheduled;
@end

@implementation HIIdentityJournal
- (instancetype)initWithWindows:(NSArray *)windows {
    NSAssert(NSThread.isMainThread, @"Identity installation requires the application main thread");
    self = [super init];
    if (!self) return nil;
    static NSString *processNonce;
    static dispatch_once_t nonceOnce;
    dispatch_once(&nonceOnce, ^{ processNonce = NSUUID.UUID.UUIDString; });
    _launch = processNonce;
    _generation = ++nextGeneration;
    _installed = YES;
    _windows = [NSMapTable weakToStrongObjectsMapTable];
    _groups = [NSMapTable weakToStrongObjectsMapTable];
    _windowRecords = [NSMutableDictionary new];
    _groupRecords = [NSMutableDictionary new];
    _groupPrior = [NSMutableDictionary new];
    _priorMembership = [NSMutableDictionary new];
    _events = [NSMutableArray new];
    _notificationTokens = [NSMutableArray new];
    _samplingFailedGroups = [NSMutableSet new];
    for (id window in windows) [self observeWindow:window];
    [self installNotifications];
    [self emit:@"installed" details:@{ @"capabilities": @(hypridentity_capabilities()) }];
    return self;
}

- (void)emit:(NSString *)cause details:(NSDictionary *)details {
    if (!self.installed) return;
    NSMutableDictionary *event = [details mutableCopy];
    event[@"cause"] = cause;
    event[@"seq"] = @(++self.sequence);
    event[@"generation"] = @(self.generation);
    event[@"uptime_seconds"] = @(NSProcessInfo.processInfo.systemUptime);
    [self.events addObject:event];
    if (self.events.count > eventLimit) {
        [self.events removeObjectAtIndex:0];
        self.dropped++;
    }
    [self pruneScalarHistory];
    [self schedulePublication];
}

- (void)pruneScalarHistory {
    // Retained closed NSWindows are also history: weak lifetime alone is not a bound.
    if (self.windowRecords.count <= 256 && self.groupRecords.count <= 128) return;
    NSMutableSet *live = [NSMutableSet new];
    for (id window in self.windows.keyEnumerator) [live addObject:identity(window, &windowIdentityKey)];
    if (self.windowRecords.count > 256) {
        for (NSNumber *key in [self.windowRecords.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (self.windowRecords.count <= 256) break;
            if (![live containsObject:key] || [self.windowRecords[key][@"phase"] isEqual:@"closed"]) {
                [self.windowRecords removeObjectForKey:key];
                [self.priorMembership removeObjectForKey:key]; self.historyPruned++;
            }
        }
    }
    NSMutableSet *liveGroups = [NSMutableSet new];
    for (id group in self.groups.keyEnumerator) [liveGroups addObject:identity(group, &groupIdentityKey)];
    if (self.groupRecords.count > 128) {
        for (NSNumber *key in [self.groupRecords.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (self.groupRecords.count <= 128) break;
            BOOL historical = ![liveGroups containsObject:key];
            if (!historical) {
                historical = YES;
                for (NSDictionary *member in self.groupRecords[key][@"members"])
                    if (self.windowRecords[member[@"object"]] &&
                        ![self.windowRecords[member[@"object"]][@"phase"] isEqual:@"closed"]) historical = NO;
            }
            if (historical) {
                [self.groupRecords removeObjectForKey:key];
                [self.samplingFailedGroups removeObject:key]; self.historyPruned++;
            }
        }
    }
}

- (void)schedulePublication {
    if (!self.publisher || self.publicationScheduled) return;
    self.publicationScheduled = YES;
    HIIdentityPublisher *publisher = self.publisher;
    NSUInteger generation = self.generation;
    __weak HIIdentityJournal *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        HIIdentityJournal *owner = weakSelf;
        if (!owner.installed || owner.generation != generation || owner.publisher != publisher) return;
        owner.publicationScheduled = NO;
        [publisher submit:HIIdentityWireSnapshot(owner.snapshot)];
    });
}

- (void)stopTransport {
    HIIdentityPublisher *publisher = self.publisher;
    self.publisher = nil; self.publisherConnection = 0; self.publicationScheduled = NO;
    if (publisher) [publisher revoke:HIIdentityWireSnapshot(self.snapshot)];
}

- (NSArray *)membersOfGroup:(id)group {
    @try { return [[group windows] copy]; }
    @catch (NSException *exception) {
        [self emit:@"sampling_unavailable" details:@{ @"key": @"windows", @"exception": exception.name }];
        return nil;
    }
}

- (NSDictionary *)readGroup:(id)group {
    if (!group || ![group respondsToSelector:@selector(windows)] ||
        ![group respondsToSelector:@selector(selectedWindow)]) return nil;
    NSArray *members = [self membersOfGroup:group];
    NSNumber *groupKey = identity(group, &groupIdentityKey);
    if (!members) { [self.samplingFailedGroups addObject:groupKey]; return nil; }
    NSMutableArray *ids = [NSMutableArray new];
    for (id window in members) {
        [ids addObject:@{ @"object": identity(window, &windowIdentityKey), @"wid": @(windowID(window)) }];
    }
    id selected;
    @try { selected = [group selectedWindow]; }
    @catch (NSException *exception) {
        // KVO can run during a partially established stack. Its selected index may
        // temporarily have no valid window. Preserve the last proven metadata.
        [self emit:@"sampling_unavailable" details:@{ @"key": @"selectedWindow", @"exception": exception.name }];
        [self.samplingFailedGroups addObject:groupKey];
        return nil;
    }
    [self.samplingFailedGroups removeObject:groupKey];
    NSArray *keys = [self.groups objectForKey:group];
    return @{ @"group": groupKey, @"members": ids,
              @"membership_kvo": @([keys containsObject:@"windows"]),
              @"selection_kvo": @([keys containsObject:@"selectedWindow"]),
              @"selected": selected ? identity(selected, &windowIdentityKey) : NSNull.null,
              @"selected_wid": @(windowID(selected)) };
}

- (NSDictionary *)readWindow:(id)window {
    NSNumber *key = identity(window, &windowIdentityKey);
    BOOL groupKnown;
    id group = existingGroupKnown(window, &groupKnown);
    NSMutableDictionary *value = [@{ @"object": key, @"wid": @(windowID(window)),
        @"group_known": @(groupKnown), @"group_kvo": @([[self.windows objectForKey:window] containsObject:@"tabGroup"]),
        @"group": group ? identity(group, &groupIdentityKey) : NSNull.null,
        @"hidden_tab": hiddenTab(window), @"phase": self.windowRecords[key][@"phase"] ?: @"observed" } mutableCopy];
    for (NSString *selectorName in @[@"isVisible", @"isMiniaturized", @"isKeyWindow", @"isMainWindow"]) {
        if (!getterHasType(window, NSSelectorFromString(selectorName), 'B')) continue;
        @try { value[selectorName] = @(((BOOL (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(selectorName))); }
        @catch (NSException *exception) {
            value[selectorName] = NSNull.null;
            [self emit:@"sampling_unavailable" details:@{ @"key": selectorName, @"exception": exception.name }];
        }
    }
    if ([value[@"hidden_tab"] isEqual:@YES]) value[@"phase"] = @"tab_hidden";
    else if ([value[@"phase"] isEqual:@"tab_hidden"] && [value[@"isVisible"] isEqual:@YES])
        value[@"phase"] = @"ordered";
    return value;
}

- (void)observeGroup:(id)group {
    if (!group || [self.groups objectForKey:group]) return;
    NSMutableArray *ownedKeys = [NSMutableArray new];
    [self.groups setObject:ownedKeys forKey:group];
    for (NSString *key in @[@"windows", @"selectedWindow"]) {
        if (![group respondsToSelector:NSSelectorFromString(key)]) continue;
        @try {
            // No Old/New options: copy passive state ourselves, including on prior.
            [group addObserver:self forKeyPath:key options:NSKeyValueObservingOptionPrior context:&groupKVOContext];
            [ownedKeys addObject:key];
        } @catch (NSException *exception) {
            [self emit:@"observation_unavailable" details:@{ @"key": key, @"exception": exception.name }];
        }
    }
    NSDictionary *snapshot = [self readGroup:group];
    if (snapshot) self.groupRecords[snapshot[@"group"]] = snapshot;
    for (id window in [self membersOfGroup:group]) [self observeWindow:window];
}

- (void)observeWindow:(id)window {
    NSAssert(NSThread.isMainThread, @"Identity callbacks must remain on main");
    if (!self.installed || !window || ![window respondsToSelector:@selector(windowNumber)]) return;
    BOOL newlyObserved = ![self.windows objectForKey:window];
    if (newlyObserved) {
        NSMutableArray *ownedKeys = [NSMutableArray new];
        [self.windows setObject:ownedKeys forKey:window];
        if ([window respondsToSelector:@selector(tabGroup)]) {
            @try {
                // Old/New would invoke the public lazy-creating tabGroup getter.
                [window addObserver:self forKeyPath:@"tabGroup" options:NSKeyValueObservingOptionPrior context:&windowKVOContext];
                [ownedKeys addObject:@"tabGroup"];
            } @catch (NSException *exception) {
                [self emit:@"observation_unavailable" details:@{ @"key": @"tabGroup", @"exception": exception.name }];
            }
        }
    }
    [self observeGroup:existingGroup(window)];
    NSDictionary *snapshot = [self readWindow:window];
    self.windowRecords[snapshot[@"object"]] = snapshot;
    if (newlyObserved) [self emit:@"window_observed" details:@{ @"window": snapshot }];
}

- (void)scheduleReconcile {
    // AppKit clears _isInHiddenWindowTab AFTER its last detach KVO callback.
    // One deferred passive read completes a synchronous change burst. No timer,
    // self-rescheduling or observation of the lazy public tabGroup getter.
    if (!self.installed || self.reconcilePending) return;
    self.reconcilePending = YES;
    NSUInteger revision = ++self.reconcileRevision, generation = self.generation;
    __weak HIIdentityJournal *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        HIIdentityJournal *owner = weakSelf;
        if (!owner.installed || owner.generation != generation ||
            !owner.reconcilePending || owner.reconcileRevision != revision) return;
        NSMutableArray *changedWindows = [NSMutableArray new], *changedGroups = [NSMutableArray new];
        BOOL complete = YES;
        for (id group in owner.groups.keyEnumerator.allObjects) {
            NSDictionary *record = [owner readGroup:group];
            if (!record) { complete = NO; continue; }
            NSNumber *key = record[@"group"];
            if (![record isEqual:owner.groupRecords[key]]) [changedGroups addObject:record];
            owner.groupRecords[key] = record;
        }
        for (id window in owner.windows.keyEnumerator.allObjects) {
            NSDictionary *record = [owner readWindow:window];
            NSNumber *key = record[@"object"];
            if (![record isEqual:owner.windowRecords[key]]) [changedWindows addObject:record];
            owner.windowRecords[key] = record;
            // Detach can order in silently. Do not attach a future standalone close
            // to obsolete tab membership; retain evidence for an already closed tab.
            if (record[@"group"] == NSNull.null && [record[@"hidden_tab"] isEqual:@NO] &&
                [record[@"isVisible"] isEqual:@YES] &&
                ![record[@"phase"] isEqual:@"closed"] && ![record[@"phase"] isEqual:@"will_close"])
                [owner.priorMembership removeObjectForKey:key];
        }
        owner.reconcilePending = NO;
        owner.settledRevision = revision;
        [owner emit:@"settled" details:@{ @"revision": @(revision), @"complete": @(complete),
            @"windows": changedWindows, @"groups": changedGroups }];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &windowKVOContext && context != &groupKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    if (!NSThread.isMainThread) {
        // Do not read AppKit state on a foreign posting thread. This loses prior proof;
        // report the gap and reconcile on main, guarded against uninstall/reinstall.
        __weak HIIdentityJournal *weakSelf = self;
        __weak id weakObject = object;
        NSUInteger generation = self.generation;
        BOOL group = context == &groupKVOContext;
        dispatch_async(dispatch_get_main_queue(), ^{
            HIIdentityJournal *owner = weakSelf;
            id current = weakObject;
            if (!owner.installed || owner.generation != generation || !current) return;
            [owner emit:@"off_main_gap" details:@{ @"key": keyPath }];
            if (group) {
                NSDictionary *snapshot = [owner readGroup:current];
                if (snapshot) owner.groupRecords[snapshot[@"group"]] = snapshot;
            } else [owner observeWindow:current];
            [owner scheduleReconcile];
        });
        return;
    }
    if (!self.installed) return;
    BOOL prior = [change[NSKeyValueChangeNotificationIsPriorKey] boolValue];
    if (context == &groupKVOContext) {
        NSDictionary *snapshot = [self readGroup:object];
        if (!snapshot) return;
        NSNumber *groupKey = snapshot[@"group"];
        NSString *priorKey = [NSString stringWithFormat:@"%@:%@", groupKey, keyPath];
        NSMutableArray *stack = self.groupPrior[priorKey];
        if (prior) {
            if (!stack) { stack = [NSMutableArray new]; self.groupPrior[priorKey] = stack; }
            [stack addObject:snapshot];
            for (NSDictionary *member in snapshot[@"members"])
                self.priorMembership[member[@"object"]] = snapshot;
        }
        NSUInteger depth = stack.count;
        NSDictionary *before = stack.lastObject ?: self.groupRecords[groupKey] ?: @{};
        self.groupRecords[groupKey] = snapshot;
        [self emit:prior ? @"group_prior" : @"group_changed"
             details:@{ @"key": keyPath, @"group": snapshot, @"before": before,
                        @"depth": @(depth), @"outermost": @(depth == 1), @"paired": @(depth > 0) }];
        if (!prior) {
            if (depth) [stack removeLastObject];
            if (!stack.count) [self.groupPrior removeObjectForKey:priorKey];
            for (id window in [self membersOfGroup:object]) [self observeWindow:window];
            [self scheduleReconcile];
        }
    } else {
        NSDictionary *before = self.windowRecords[identity(object, &windowIdentityKey)] ?: @{};
        [self observeWindow:object];
        NSDictionary *snapshot = self.windowRecords[identity(object, &windowIdentityKey)];
        [self emit:prior ? @"window_group_prior" : @"window_group_changed"
             details:@{ @"window": snapshot, @"before": before }];
        if (!prior) [self scheduleReconcile];
    }
}

- (void)nativeNotification:(NSNotification *)notification cause:(NSString *)cause {
    if (!self.installed || ![notification.object respondsToSelector:@selector(windowNumber)]) return;
    id window = notification.object;
    NSNumber *key = identity(window, &windowIdentityKey);
    NSDictionary *before = self.windowRecords[key] ?: @{};
    id oldGroupKey = before[@"group"];
    NSDictionary *oldGroup = oldGroupKey && oldGroupKey != NSNull.null ? self.groupRecords[oldGroupKey] : nil;
    if ([cause isEqual:@"will_close"] || [cause isEqual:@"did_close"])
        oldGroup = self.priorMembership[key] ?: oldGroup;
    [self observeWindow:window];
    NSMutableDictionary *snapshot = [self.windowRecords[key] mutableCopy];
    if ([cause isEqual:@"order_on"]) snapshot[@"phase"] = @"ordered";
    else if ([cause isEqual:@"order_off"]) snapshot[@"phase"] = [snapshot[@"hidden_tab"] isEqual:@YES] ? @"tab_hidden" : @"offscreen";
    else if ([cause isEqual:@"will_close"]) snapshot[@"phase"] = @"will_close";
    else if ([cause isEqual:@"did_close"]) snapshot[@"phase"] = @"closed";
    if ([cause isEqual:@"order_on"] && snapshot[@"group"] == NSNull.null)
        [self.priorMembership removeObjectForKey:key]; // a detached/reopened standalone window starts a new presentation
    self.windowRecords[key] = snapshot;
    NSMutableDictionary *details = [@{ @"window": snapshot, @"before": before,
                                       @"notification": notification.name } mutableCopy];
    if (oldGroup) details[@"previous_group"] = oldGroup;
    [self emit:cause details:details];
}

- (void)installNotifications {
    NSMutableArray *definitions = [NSMutableArray arrayWithArray:@[
        @[NSWindowWillCloseNotification, @"will_close"], @[@"NSWindowDidCloseNotification", @"did_close"],
        @[NSWindowDidBecomeKeyNotification, @"key"], @[NSWindowDidResignKeyNotification, @"resign_key"],
        @[NSWindowDidMiniaturizeNotification, @"minimized"], @[NSWindowDidDeminiaturizeNotification, @"deminimized"],
        @[NSWindowWillBeginSheetNotification, @"sheet_begin"], @[NSWindowDidEndSheetNotification, @"sheet_end"]
    ]];
    const char *symbols[] = {"NSWindowWillOrderOnScreenNotification", "NSWindowDidOrderOnScreenNotification",
        "NSWindowWillOrderOffScreenNotification", "NSWindowDidOrderOffScreenNotification"};
    NSArray *causes = @[@"will_order_on", @"order_on", @"will_order_off", @"order_off"];
    for (unsigned i = 0; i < 4; ++i) {
        NSString *name = notificationSymbol(symbols[i]);
        if (name) [definitions addObject:@[name, causes[i]]];
    }
    __weak HIIdentityJournal *weakSelf = self;
    NSUInteger installedGeneration = self.generation;
    for (NSArray *definition in definitions) {
        id token = [NSNotificationCenter.defaultCenter addObserverForName:definition[0] object:nil queue:nil
            usingBlock:^(NSNotification *notification) {
                HIIdentityJournal *owner = weakSelf;
                if (!NSThread.isMainThread) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        HIIdentityJournal *current = weakSelf;
                        if (current.installed && current.generation == installedGeneration) {
                            [current emit:@"off_main_gap" details:@{ @"notification": notification.name }];
                            [current nativeNotification:notification cause:definition[1]];
                        }
                    });
                } else if (owner.installed && owner.generation == installedGeneration)
                    [owner nativeNotification:notification cause:definition[1]];
            }];
        [self.notificationTokens addObject:token];
    }
}

- (NSDictionary *)snapshot {
    NSAssert(NSThread.isMainThread, @"Read the identity snapshot on main");
    NSMutableArray *liveObjects = [NSMutableArray new], *liveGroups = [NSMutableArray new];
    for (id window in self.windows.keyEnumerator) [liveObjects addObject:identity(window, &windowIdentityKey)];
    for (id group in self.groups.keyEnumerator) [liveGroups addObject:identity(group, &groupIdentityKey)];
    return @{ @"schema": @1, @"pid": @(getpid()), @"launch": self.launch,
              @"generation": @(self.generation), @"installed": @(self.installed),
              @"capabilities": @(hypridentity_capabilities()), @"seq": @(self.sequence),
              @"reconcile_pending": @(self.reconcilePending),
              @"revision": @(self.reconcileRevision), @"settled_revision": @(self.settledRevision),
              @"history_pruned": @(self.historyPruned), @"sampling_failed_groups": self.samplingFailedGroups.allObjects,
              @"dropped_events": @(self.dropped), @"events": [self.events copy],
              @"windows": self.windowRecords.allValues, @"groups": self.groupRecords.allValues,
              @"live_objects": liveObjects, @"live_groups": liveGroups };
}

- (void)uninstall {
    NSAssert(NSThread.isMainThread, @"Uninstall identity observers on main");
    if (!self.installed) return;
    [self stopTransport];
    [self emit:@"uninstalled" details:@{}];
    self.installed = NO;
    self.reconcilePending = NO;
    for (id token in self.notificationTokens) [NSNotificationCenter.defaultCenter removeObserver:token];
    [self.notificationTokens removeAllObjects];
    for (NSMapTable *map in @[self.windows, self.groups]) {
        void *context = map == self.windows ? &windowKVOContext : &groupKVOContext;
        for (id object in map.keyEnumerator.allObjects)
            for (NSString *key in [map objectForKey:object])
                [object removeObserver:self forKeyPath:key context:context];
        [map removeAllObjects];
    }
    [self.groupPrior removeAllObjects];
    [self.priorMembership removeAllObjects];
}
- (void)dealloc { if (_installed) [self uninstall]; }
@end

static HIIdentityJournal *installedJournal;
unsigned hypridentity_capabilities(void) { return 1u | 2u | 4u | 8u; } // group, selected, hidden-tab, lifecycle
int hypridentity_install(void) {
    if (!NSThread.isMainThread) return -2;
    if (installedJournal.installed) return 0;
    if (!NSApp) return -1;
    installedJournal = [[HIIdentityJournal alloc] initWithWindows:NSApp.windows];
    return 0;
}
int hypridentity_uninstall(void) {
    if (!NSThread.isMainThread) return -2;
    [installedJournal uninstall];
    installedJournal = nil;
    return 0;
}
char *hypridentity_copy_json(void) {
    if (!NSThread.isMainThread || !installedJournal.installed) return NULL;
    NSData *data = [NSJSONSerialization dataWithJSONObject:installedJournal.snapshot options:NSJSONWritingSortedKeys error:NULL];
    if (!data) return NULL;
    char *result = malloc(data.length + 1);
    if (!result) return NULL;
    memcpy(result, data.bytes, data.length);
    result[data.length] = 0;
    return result;
}
int hypridentity_transport_start(int ownConnection) {
    if (!NSThread.isMainThread) return -2;
    if (!installedJournal.installed) return -1;
    if (installedJournal.publisher) return installedJournal.publisherConnection == ownConnection ? 0 : -3;
    int error;
    int (^writer)(NSData *) = HIIdentityNativeWriter(ownConnection, &error);
    if (!writer) return error;
    installedJournal.publisherConnection = ownConnection;
    installedJournal.publisher = [[HIIdentityPublisher alloc] initWithWriter:writer didPublish:^{ HIIdentityPostHint(); }];
    [installedJournal schedulePublication];
    return 0;
}
int hypridentity_transport_stop(void) {
    if (!NSThread.isMainThread) return -2;
    [installedJournal stopTransport];
    return 0;
}
