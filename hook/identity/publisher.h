#import <Foundation/Foundation.h>

// Foundation-only transport worker. Input must already be immutable main-thread
// metadata; the worker never receives NSWindow/NSWindowTabGroup objects.
@interface HIIdentityPublisher : NSObject
- (instancetype)initWithWriter:(int (^)(NSData *))writer didPublish:(void (^)(void))notify;
- (void)submit:(NSDictionary *)snapshot;
- (void)revoke:(NSDictionary *)snapshot;
// Offline tests only; never wait on this from application main during production.
+ (void)drainForTesting;
@end

// Caller is main-thread journal owner. Produces only JSON-compatible immutable
// scalars/containers, with bounded records and event history.
NSDictionary *HIIdentityWireSnapshot(NSDictionary *snapshot);
