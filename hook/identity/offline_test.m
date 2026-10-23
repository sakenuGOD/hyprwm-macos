// Real Foundation KVO + fake window objects. Never creates NSApplication or NSWindow.
#import "identity.h"
#import "publisher.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>

@class FakeGroup;
@interface FakeWindow : NSObject
@property(nonatomic) NSInteger windowNumber;
@property(nonatomic, weak) FakeGroup *group;
@property(nonatomic) BOOL hidden, visible;
@property(nonatomic) NSUInteger lazyReads;
- (id)tabGroup;
- (id)_windowStackController;
- (BOOL)_isInHiddenWindowTab;
- (void)assignGroup:(FakeGroup *)group;
- (BOOL)isVisible;
- (BOOL)isMiniaturized;
- (BOOL)isKeyWindow;
- (BOOL)isMainWindow;
@end
@interface FakeGroup : NSObject
@property(nonatomic, copy) NSArray *windows;
@property(nonatomic, weak) FakeWindow *selectedWindow;
- (void)nestedSelect:(FakeWindow *)window;
- (void)detachAfterSelecting:(FakeWindow *)remaining detached:(FakeWindow *)detached;
@end
@interface UnreadyGroup : FakeGroup
@end
@implementation UnreadyGroup
- (FakeWindow *)selectedWindow { [NSException raise:NSInternalInconsistencyException format:@"transient unset selection"]; return nil; }
@end
@implementation FakeGroup
- (void)nestedSelect:(FakeWindow *)window {
    // Matches real AppKit trace: explicit KVO encloses its automatic setter KVO.
    [self willChangeValueForKey:@"selectedWindow"];
    self.selectedWindow = window;
    [self didChangeValueForKey:@"selectedWindow"];
}
- (void)detachAfterSelecting:(FakeWindow *)remaining detached:(FakeWindow *)detached {
    // Exact root live-v2 ordering: windows prior -> selected changed -> tabGroup
    // nil -> windows changed -> hidden flag clears, with NO order-on notification.
    [self willChangeValueForKey:@"windows"];
    detached.hidden = YES; remaining.hidden = NO;
    self.selectedWindow = remaining;
    [detached assignGroup:nil];
    _windows = @[remaining];
    [self didChangeValueForKey:@"windows"];
    detached.hidden = NO;
}
@end
@implementation FakeWindow
- (id)tabGroup { self.lazyReads++; return self.group; }
- (id)_windowStackController { return self.group; }
- (BOOL)_isInHiddenWindowTab { return self.hidden; }
- (BOOL)isVisible { return self.visible; }
- (BOOL)isMiniaturized { return NO; }
- (BOOL)isKeyWindow { return self.group.selectedWindow == self && self.visible; }
- (BOOL)isMainWindow { return [self isKeyWindow]; }
- (void)assignGroup:(FakeGroup *)group {
    [self willChangeValueForKey:@"tabGroup"];
    self.group = group;
    [self didChangeValueForKey:@"tabGroup"];
}
@end

static NSUInteger checks;
static void check(BOOL condition, const char *reason) {
    ++checks;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", reason); exit(1); }
}
static void notify(NSString *name, FakeWindow *window) {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:window];
}
static NSString *name(const char *symbol) {
    NSString *__unsafe_unretained *p = (NSString *__unsafe_unretained *)dlsym(RTLD_DEFAULT, symbol);
    check(p != NULL, symbol);
    return *p;
}
static NSDictionary *lastCause(HIIdentityJournal *journal, NSString *cause) {
    for (NSDictionary *event in [journal.snapshot[@"events"] reverseObjectEnumerator])
        if ([event[@"cause"] isEqual:cause]) return event;
    return nil;
}
static NSDictionary *windowRecord(HIIdentityJournal *journal, NSInteger wid) {
    for (NSDictionary *record in journal.snapshot[@"windows"])
        if ([record[@"wid"] integerValue] == wid) return record;
    return nil;
}

int main(void) {
    @autoreleasepool {
        check(NSApp == nil, "offline fixture never creates NSApp");
        check(hypridentity_install() == -1, "production install needs real app");
        FakeWindow *a = [FakeWindow new], *b = [FakeWindow new], *other = [FakeWindow new];
        a.windowNumber = 11; b.windowNumber = 12; other.windowNumber = 99;
        a.visible = YES;
        FakeGroup *group = [FakeGroup new];
        group.windows = @[a, b]; group.selectedWindow = a;
        [a assignGroup:group]; [b assignGroup:group];
        HIIdentityJournal *journal = [[HIIdentityJournal alloc] initWithWindows:@[a, other]];
        check([journal.snapshot[@"windows"] count] == 3, "hidden sibling discovered through native members");
        check(a.lazyReads + b.lazyReads + other.lazyReads == 0, "install has no lazy getter side effect");
        [group nestedSelect:b];
        a.hidden = YES; a.visible = NO; b.hidden = NO; b.visible = YES;
        notify(name("NSWindowDidOrderOnScreenNotification"), b);
        notify(name("NSWindowDidOrderOffScreenNotification"), a);
        NSDictionary *selected = lastCause(journal, @"group_changed");
        check([selected[@"before"][@"selected_wid"] integerValue] == 11, "prior selected member retained");
        check([selected[@"depth"] unsignedIntegerValue] == 1 && [selected[@"outermost"] boolValue],
              "nested KVO exports outermost logical transition once");
        check([selected[@"group"][@"selected_wid"] integerValue] == 12, "selected change exported");
        check([lastCause(journal, @"order_off")[@"window"][@"phase"] isEqual:@"tab_hidden"], "tab order-out distinct");
        NSNumber *bObject = lastCause(journal, @"order_on")[@"window"][@"object"];
        // Match verified AppKit ordering: cleanup runs before WillClose. Objects stay retained.
        group.windows = @[a];
        group.selectedWindow = a;
        [b assignGroup:nil];
        notify(NSWindowWillCloseNotification, b);
        b.visible = NO;
        notify(name("NSWindowDidOrderOffScreenNotification"), b);
        notify(@"NSWindowDidCloseNotification", b);
        NSDictionary *closed = lastCause(journal, @"did_close");
        check([closed[@"previous_group"][@"members"] count] == 2, "membership survives pre-WillClose cleanup");
        check([closed[@"window"][@"phase"] isEqual:@"closed"], "retained close exported without backing destroy");
        b.visible = YES;
        notify(name("NSWindowDidOrderOnScreenNotification"), b);
        NSDictionary *reopened = lastCause(journal, @"order_on");
        check([reopened[@"window"][@"object"] isEqual:bObject], "same retained window identity survives reopen");
        check(reopened[@"window"][@"group"] == NSNull.null, "detached reopened window has no invented group");
        check([reopened[@"before"][@"phase"] isEqual:@"closed"], "reopen includes closed presentation history");
        // Rejoin before detach: the first live fixture's detach-after-reopen was a no-op.
        group.windows = @[a, b]; [b assignGroup:group]; [group nestedSelect:b];
        a.hidden = YES; a.visible = YES; b.hidden = NO; b.visible = YES;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        [group detachAfterSelecting:a detached:b];
        check([windowRecord(journal, 12)[@"hidden_tab"] isEqual:@YES],
              "live detach replay exposes callback-time stale hidden flag");
        NSUInteger detachSequence = [journal.snapshot[@"seq"] unsignedIntegerValue];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        check([windowRecord(journal, 12)[@"hidden_tab"] isEqual:@NO] &&
              [windowRecord(journal, 12)[@"phase"] isEqual:@"ordered"],
              "settled detach is standalone visible, never cached as hidden tab");
        check([journal.snapshot[@"seq"] unsignedIntegerValue] == detachSequence + 1 &&
              [lastCause(journal, @"settled")[@"windows"] count] == 1,
              "one deferred reconcile coalesces the complete detach burst");
        NSUInteger settledSequence = [journal.snapshot[@"seq"] unsignedIntegerValue];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        check([journal.snapshot[@"seq"] unsignedIntegerValue] == settledSequence,
              "settled reconcile does not poll or schedule itself");
        // Weak registry must not extend object lifetime. Foundation itself tears down KVO on deallocation.
        __weak FakeWindow *weakTemporary;
        @autoreleasepool {
            FakeWindow *temporary = [FakeWindow new];
            temporary.windowNumber = 55; weakTemporary = temporary;
            [journal observeWindow:temporary];
        }
        check(weakTemporary == nil, "observer does not retain window");
        __weak FakeGroup *weakTemporaryGroup;
        @autoreleasepool {
            FakeWindow *temporary = [FakeWindow new];
            temporary.windowNumber = 56;
            FakeGroup *temporaryGroup = [FakeGroup new];
            temporaryGroup.windows = @[temporary]; temporaryGroup.selectedWindow = temporary;
            [temporary assignGroup:temporaryGroup]; weakTemporaryGroup = temporaryGroup;
            [journal observeWindow:temporary];
        }
        check(weakTemporaryGroup == nil, "observer does not retain group or its window graph");
        FakeWindow *unreadyWindow = [FakeWindow new]; unreadyWindow.windowNumber = 57;
        UnreadyGroup *unreadyGroup = [UnreadyGroup new]; unreadyGroup.windows = @[unreadyWindow];
        [unreadyWindow assignGroup:unreadyGroup];
        [journal observeWindow:unreadyWindow];
        check(lastCause(journal, @"sampling_unavailable") != nil,
              "partially established native stack cannot crash identity observation");
        // Queue a foreign-thread notification, then uninstall before its deferred main callback.
        dispatch_semaphore_t posted = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            notify(NSWindowWillCloseNotification, a);
            dispatch_semaphore_signal(posted);
        });
        check(dispatch_semaphore_wait(posted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
              "foreign notification queued without AppKit reads on foreign thread");
        NSUInteger oldGeneration = journal.generation;
        [group nestedSelect:a]; // Queue a group settle too; teardown must suppress it.
        [journal uninstall];
        NSUInteger finalSequence = [journal.snapshot[@"seq"] unsignedIntegerValue];
        notify(NSWindowWillCloseNotification, a);
        group.selectedWindow = nil;
        check([journal.snapshot[@"seq"] unsignedIntegerValue] == finalSequence, "uninstall removes all owned callbacks");
        HIIdentityJournal *second = [[HIIdentityJournal alloc] initWithWindows:@[a]];
        check(second.generation > oldGeneration, "reinstall changes generation");
        NSUInteger beforeDeferred = [second.snapshot[@"seq"] unsignedIntegerValue];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, false);
        check([journal.snapshot[@"seq"] unsignedIntegerValue] == finalSequence,
              "queued old-generation callback ignored after uninstall");
        check([second.snapshot[@"seq"] unsignedIntegerValue] == beforeDeferred,
              "old-generation callback cannot touch new journal");
        for (NSUInteger i = 0; i < 300; ++i) notify(NSWindowDidBecomeKeyNotification, a);
        check([second.snapshot[@"events"] count] == 256, "event storage bounded");
        check([second.snapshot[@"dropped_events"] unsignedIntegerValue] > 0, "overflow visible to consumer");
        check(a.lazyReads + b.lazyReads + other.lazyReads == 0, "KVO Prior never reads public lazy getter");
        NSData *json = [NSJSONSerialization dataWithJSONObject:second.snapshot options:NSJSONWritingSortedKeys error:NULL];
        check(json.length > 0, "all exported values are JSON-compatible");
        [second uninstall];
        // Retained closed windows must not turn scalar history into an unbounded log.
        HIIdentityJournal *history = [[HIIdentityJournal alloc] initWithWindows:@[]];
        NSMutableArray *retained = [NSMutableArray new];
        for (NSUInteger i = 0; i < 300; ++i) {
            FakeWindow *window = [FakeWindow new]; window.windowNumber = (NSInteger)i + 1000;
            [retained addObject:window]; [history observeWindow:window];
            notify(@"NSWindowDidCloseNotification", window);
        }
        check([history.snapshot[@"windows"] count] <= 256 && [history.snapshot[@"history_pruned"] unsignedIntegerValue] > 0,
              "retained closed scalar history is bounded");
        NSDictionary *bounded = HIIdentityWireSnapshot(history.snapshot);
        check([bounded[@"windows"] count] <= 128 && ![bounded[@"complete"] boolValue] && [bounded[@"events"] count] <= 32,
              "wire capacity loss is explicit incomplete, never missing-window proof");
        [history uninstall];

        // Hold the first publication while newer facts, revocation and reinstall queue.
        // Shared serial transport must emit old data -> tombstone -> new generation.
        NSMutableArray *published = [NSMutableArray new];
        dispatch_semaphore_t writing = dispatch_semaphore_create(0), releaseWrite = dispatch_semaphore_create(0);
        __block BOOL firstWrite = YES, offMain = YES;
        int (^writer)(NSData *) = ^int(NSData *data) {
            offMain &= !NSThread.isMainThread;
            if (firstWrite) {
                firstWrite = NO; dispatch_semaphore_signal(writing);
                if (dispatch_semaphore_wait(releaseWrite, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) return 1000;
            }
            [published addObject:[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL]];
            return 0;
        };
        HIIdentityPublisher *publisher = [[HIIdentityPublisher alloc] initWithWriter:writer didPublish:nil];
        [publisher submit:bounded];
        check(dispatch_semaphore_wait(writing, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
              "publisher never blocks AppKit main on its writer");
        [publisher submit:bounded]; [publisher submit:bounded];
        [publisher revoke:bounded]; [publisher submit:bounded]; // ignored after revocation
        NSMutableDictionary *newInstall = [bounded mutableCopy];
        newInstall[@"generation"] = @([bounded[@"generation"] unsignedIntegerValue] + 1);
        HIIdentityPublisher *replacement = [[HIIdentityPublisher alloc] initWithWriter:writer didPublish:nil];
        [replacement submit:[newInstall copy]];
        dispatch_semaphore_signal(releaseWrite);
        [HIIdentityPublisher drainForTesting];
        check(offMain && published.count == 3, "latest-only queue drops superseded work and keeps tombstone");
        check([published[1][@"installed"] isEqual:@NO] && [published[1][@"windows"] count] == 0 &&
              [published[2][@"generation"] isEqual:newInstall[@"generation"]],
              "old session cannot overwrite tombstone or new install");
        check([published[0][@"publication"] unsignedIntegerValue] < [published[1][@"publication"] unsignedIntegerValue] &&
              [published[1][@"publication"] unsignedIntegerValue] < [published[2][@"publication"] unsignedIntegerValue],
              "publication order remains monotonic across publisher sessions");
        NSMutableDictionary *oversized = [bounded mutableCopy];
        oversized[@"events"] = @[@{ @"padding": [@"" stringByPaddingToLength:70000 withString:@"x" startingAtIndex:0] }];
        __block NSData *boundedBytes;
        HIIdentityPublisher *sizePublisher = [[HIIdentityPublisher alloc] initWithWriter:^int(NSData *data) {
            boundedBytes = data; return 0;
        } didPublish:nil];
        [sizePublisher submit:[oversized copy]]; [HIIdentityPublisher drainForTesting];
        check(boundedBytes.length <= 65536, "serialized wire byte ceiling enforced before native writer");
        check(NSApp == nil, "NSApp remains nil after all cases");
        printf("PASS %lu offline identity checks; Foundation KVO exercised; AppKit live ordering NOT tested\n", (unsigned long)checks);
    }
}
