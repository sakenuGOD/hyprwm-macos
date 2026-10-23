#define HLC_QUALIFIER 1
#import "../lifecycle.m"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>

static NSMutableArray *events;
static NSMutableDictionary<NSNumber *,NSValue *> *transactions;
static NSMutableDictionary<NSNumber *,NSNumber *> *lengths;
static NSUInteger serial;
static BOOL cancelled;
static BOOL marker(NSWindow *,uint32_t,char [256]);
static void output(NSDictionary *);
@interface MockNative:NSObject
- (id)orderingGroup;
- (void)_entangleContextWithCommit;
@end
@implementation MockNative
- (id)orderingGroup {return @[self];}
- (void)_entangleContextWithCommit {}
@end
@interface MockWindow:NSObject
@property id native;
@end
@implementation MockWindow
@end
@interface MockOrdering:NSObject
@end
@implementation MockOrdering
@end
@interface MockLocal:NSObject
- (void)orderGroup:(id)window op:(int)op againstWindow:(id)against;
@end
@interface MockServer:NSObject {@public void *_transaction;}
@end
@implementation MockServer
@end
static unsigned localCalls,nativeCalls,fallbackCalls;
static MockOrdering *mockOrdering;
static MockLocal *mockLocal;
static MockServer *mockServer;
static HLCOperation delayed;
static NSString *unitMode;
static unsigned char packet[512];
static struct {char prefix[32];unsigned char *bytes;uint64_t count,capacity;} fakeTransaction;
static pthread_mutex_t mockMutex=PTHREAD_MUTEX_INITIALIZER;
@implementation MockLocal
- (void)orderGroup:(id)window op:(int)op againstWindow:(id)against {
    assert(window && !op && !against);++localCalls;
}
@end
static id mock_current(id object,SEL selector) {
    (void)object;(void)selector;
    if([unitMode isEqual:@"preparation"])@throw [NSException exceptionWithName:@"OwnedPreparation" reason:nil userInfo:nil];
    return mockOrdering;
}
static uint32_t mock_wid(id object,SEL selector) {(void)object;(void)selector;return 73;}
static id mock_native(id window) {return ((MockWindow *)window).native;}
static void mock_fallback(id object,SEL selector) {(void)object;(void)selector;++fallbackCalls;}
static void mock_order(id state,SEL selector,id window,int op,id against) {
    (void)selector;assert(state==mockServer && window && !op && !against);
    ++nativeCalls;packet[fakeTransaction.count++]=2;
}
static void mock_property(void *transaction,uint32_t wid,CFStringRef key,CFTypeRef value) {
    assert(transaction==&fakeTransaction && wid==73 && key);
    packet[fakeTransaction.count++]=8;
    if(value && [unitMode isEqual:@"off-after-set"])atomic_store(&active,false);
}
static void mock_add(id ordering,HLCOperation operation) {
    assert(ordering==mockOrdering);operation(mockLocal);
    if([unitMode isEqual:@"deferred-off"] || [unitMode isEqual:@"reopened"] || [unitMode isEqual:@"stale-generation"]) {
        delayed=[operation copy];return;
    }
    operation(mockServer);
    if([unitMode isEqual:@"after-enqueue"])@throw [NSException exceptionWithName:@"OwnedAfterEnqueue" reason:nil userInfo:nil];
}
static int unit(NSString *mode) {
    assert(NSApp==nil);HLCConfig config={1,marker};assert(HLCInstall(&config)==0);
    HLCVoidMethod savedOrderOut=originalOrderOut;
    unitMode=mode;mockOrdering=[MockOrdering new];mockLocal=[MockLocal new];mockServer=[MockServer new];
    assert(ivar_getOffset(class_getInstanceVariable(MockServer.class,"_transaction"))==8);
    fakeTransaction.bytes=packet;fakeTransaction.capacity=sizeof(packet);mockServer->_transaction=&fakeTransaction;
    orderingClass=MockOrdering.class;serverStateClass=MockServer.class;
    currentOrdering=mock_current;nativeWID=mock_wid;windowNative=mock_native;
    serverOrder=mock_order;setProperty=mock_property;addOperation=mock_add;transactionLock=&mockMutex;
    originalOrderOut=mock_fallback;
    MockNative *native=[MockNative new];MockWindow *window=[MockWindow new];window.native=native;
    NSString *value=@"HLC1:00000000000000000000000000000001:00000000000000000000000000000049:0000000000000001";
    @autoreleasepool {
        HLCCloseScope scope={(NSWindow *)window,native,value,73,atomic_load(&installGeneration),NULL};closeScope=&scope;
        BOOL threw=NO;
        @try {hlc_order_out(native,sel_registerName("orderGroupOut"));}
        @catch(NSException *error) {threw=YES;assert([error.name isEqual:@"OwnedAfterEnqueue"]);}
        closeScope=NULL;
        assert(threw==[mode isEqual:@"after-enqueue"]);
        if([mode isEqual:@"preparation"])assert(fallbackCalls==1 && nativeCalls==0 && localCalls==0);
        else if(delayed) {
            assert(atomic_load(&pendingActions)==1 && localCalls==1 && !nativeCalls && !fallbackCalls);
            if([mode isEqual:@"deferred-off"])assert(HLCUninstall()==-3);
            else if([mode isEqual:@"reopened"])window.native=[MockNative new];
            else atomic_fetch_add(&installGeneration,1);
            delayed(mockServer);delayed=nil;
            assert(nativeCalls==1 && fakeTransaction.count==1 && packet[0]==2);
        } else {
            assert(localCalls==1 && nativeCalls==1 && !fallbackCalls);
            assert(fakeTransaction.count==3 && packet[0]==8 && packet[1]==2 && packet[2]==8);
        }
    }
    assert(!atomic_load(&pendingActions) && !atomic_load(&callbackDepth));
    assert(pthread_mutex_trylock(&mockMutex)==0);pthread_mutex_unlock(&mockMutex);
    originalOrderOut=savedOrderOut;assert(HLCUninstall()==0);assert(NSApp==nil);
    output(@{@"pass":@YES,@"case":mode,@"local":@(localCalls),@"native":@(nativeCalls),@"fallback":@(fallbackCalls),@"trace":events,@"state":HLCState()});return 0;
}
static void output(NSDictionary *value) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);fflush(stdout);
}
void HLCQualify(const char *phase,void *transaction,uint32_t wid) {
    NSMutableDictionary *event=[@{@"phase":@(phase),@"wid":@(wid),@"main":@(NSThread.isMainThread)} mutableCopy];
    if(transaction) {
        uint64_t count=0;unsigned char *bytes=NULL;
        memcpy(&bytes,(char *)transaction+0x20,sizeof(bytes));
        memcpy(&count,(char *)transaction+0x28,sizeof(count));
        assert(count<1048576 && bytes);
        NSNumber *key=@(wid);NSValue *prior=transactions[key];
        if(!strcmp(phase,"before_set"))transactions[key]=[NSValue valueWithPointer:transaction];
        else {
            assert(prior && prior.pointerValue==transaction);
            uint64_t old=[lengths[key] unsignedLongLongValue];assert(count>old);
            unsigned opcode=bytes[old];
            assert(opcode==(!strcmp(phase,"after_order")?2:8));
            event[@"opcode"]=@(opcode);
        }
        lengths[key]=@(count);event[@"length"]=@(count);
        event[@"same_transaction"]=@YES;
    }
    [events addObject:event];
}
static BOOL marker(NSWindow *window,uint32_t wid,char out[256]) {
    assert(window.windowNumber==wid && window.visible);
    if(window.sheetParent || window.attachedSheet || window.level!=0 || (window.styleMask&NSWindowStyleMaskUtilityWindow))return NO;
    ++serial;
    snprintf(out,256,"HLC1:%032llx:%032llx:%016llx",(unsigned long long)getpid(),(unsigned long long)wid,(unsigned long long)serial);
    return YES;
}
@interface CloseDelegate:NSObject<NSApplicationDelegate,NSWindowDelegate>
@property NSMutableArray<NSWindow *> *windows;
@property NSString *directory;
@end
@implementation CloseDelegate
- (NSWindow *)window {
    NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(180,170,560,340)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed=NO;w.title=@"HyprWM owned close-operation fixture";w.delegate=self;
    w.contentView.wantsLayer=YES;
    w.contentView.layer.backgroundColor=[NSColor colorWithSRGBRed:.08 green:.18 blue:.25 alpha:.7].CGColor;
    [self.windows addObject:w];[w makeKeyAndOrderFront:nil];return w;
}
- (BOOL)windowShouldClose:(NSWindow *)window {(void)window;return !cancelled;}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;self.windows=[NSMutableArray new];
    HLCConfig config={1,marker};int installed=HLCInstall(&config);
    assert(installed==0);assert([HLCState()[@"owned"] boolValue]);
    NSWindow *w=[self window];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        NSUInteger before=events.count;
        [w orderOut:nil];[w makeKeyAndOrderFront:nil];assert(events.count==before);
        cancelled=YES;[w performClose:nil];assert(w.visible && events.count==before);
        cancelled=NO;[w performClose:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            @autoreleasepool {
                NSDictionary *state=HLCState();assert([state[@"marked"] unsignedLongLongValue]==1);
                assert([state[@"exceptions"] unsignedLongLongValue]==0);
                int off=HLCUninstall();assert(off==0);
                assert(![HLCState()[@"owned"] boolValue]);
                assert(events.count==5);
                output(@{@"pass":@YES,@"case":@"own-native-close-operation",@"install":@(installed),@"off":@(off),@"trace":events,@"state":state});
            }
            [NSApp terminate:nil];
        });
    });
}
@end
int main(int argc,const char **argv) {@autoreleasepool {
    events=[NSMutableArray new];transactions=[NSMutableDictionary new];lengths=[NSMutableDictionary new];
    assert(argc==2);
    if(!strncmp(argv[1],"--unit=",7))return unit(@(argv[1]+7));
    if(!strcmp(argv[1],"--metadata")) {
        assert(NSApp==nil);HLCConfig cfg={1,marker};assert(HLCInstall(&cfg)==0);
        assert(NSApp==nil);assert(HLCUninstall()==0);assert(NSApp==nil);
        output(@{@"pass":@YES,@"case":@"metadata-no-NSApp",@"state":HLCState()});return 0;
    }
    assert(!strcmp(argv[1],"--live"));
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CloseDelegate *delegate=[CloseDelegate new];NSApp.delegate=delegate;[NSApp run];
}return 0;}
