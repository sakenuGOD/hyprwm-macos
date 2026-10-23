#import "lifecycle.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <ptrauth.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <uuid/uuid.h>
// Compile with -fobjc-arc-exceptions: failed preparation must release the leases.

typedef void (*HLCVoidMethod)(id,SEL);
typedef uint32_t (*HLCWIDMethod)(id,SEL);
typedef id (*HLCCurrentMethod)(id,SEL);
typedef id (*HLCNativeGetter)(id);
typedef void (*HLCGroupMethod)(id,SEL,id,int,id);
typedef void (^HLCOperation)(id);
typedef void (*HLCAddOperation)(id,HLCOperation);
typedef void (*HLCProperty)(void *,uint32_t,CFStringRef,CFTypeRef);
static HLCVoidMethod originalFinish,originalOrderOut;
static HLCWIDMethod nativeWID;
static HLCNativeGetter windowNative;
static HLCCurrentMethod currentOrdering;
static HLCGroupMethod serverOrder;
static HLCAddOperation addOperation;
static HLCProperty setProperty;
static HLCMarker makeMarker;
static Method finishMethod,orderMethod;
static Class orderingClass,serverStateClass;
static SEL currentSelector,groupSelector,widSelector,entangleSelector,orderingGroupSelector;
static pthread_mutex_t *transactionLock;
static CFStringRef markerKey;
static _Atomic(bool) active;
static BOOL owned,stopping;
static _Atomic(uint64_t) callbackDepth,pendingActions,marked,refused,exceptions,installGeneration;

// A lease outlives the copied native operation, including an ordering which
// discards it without executing. The instance carries its originating image's
// counter; retained predecessor images never free that storage.
@interface HLCActionLeaseV1 : NSObject {
    _Atomic(uint64_t) *_counter;
}
- (instancetype)initWithCounter:(_Atomic(uint64_t) *)counter;
@end
@implementation HLCActionLeaseV1
- (instancetype)initWithCounter:(_Atomic(uint64_t) *)counter {
    if((self=[super init])) { _counter=counter;atomic_fetch_add(counter,1); }
    return self;
}
- (void)dealloc { if(_counter)atomic_fetch_sub(_counter,1); }
@end

typedef struct HLCCloseScope {
    __unsafe_unretained NSWindow *window;
    __unsafe_unretained id native;
    __unsafe_unretained NSString *marker;
    uint32_t wid;
    uint64_t generation;
    struct HLCCloseScope *previous;
} HLCCloseScope;
static _Thread_local HLCCloseScope *closeScope;
#ifdef HLC_QUALIFIER
// Own-process fixture only: observes offsets/opcodes of its own transaction.
extern void HLCQualify(const char *,void *,uint32_t);
#define HLC_TRACE(phase,t,w) HLCQualify(phase,t,w)
#else
#define HLC_TRACE(phase,t,w) ((void)0)
#endif

static BOOL hlc_native(void *code,NSString *path,NSString *uuid,uintptr_t unslid) {
    Dl_info info={0};code=ptrauth_strip(code,ptrauth_key_function_pointer);
    if(!code || !dladdr(code,&info) || !info.dli_fname || ![path isEqual:@(info.dli_fname)])return NO;
    const struct mach_header_64 *header=info.dli_fbase;
    if(!header || header->magic!=MH_MAGIC_64 || header->sizeofcmds>1048576)return NO;
    const uint8_t *cursor=(const void *)(header+1),*end=cursor+header->sizeofcmds;
    BOOL imageMatches=NO;
    for(uint32_t i=0;i<header->ncmds;i++) {
        if((size_t)(end-cursor)<sizeof(struct load_command))return NO;
        const struct load_command *command=(const void *)cursor;
        if(command->cmdsize<sizeof(*command) || command->cmdsize>(size_t)(end-cursor))return NO;
        if(command->cmd==LC_UUID && command->cmdsize>=sizeof(struct uuid_command)) {
            char text[37];uuid_unparse_upper(((const struct uuid_command *)command)->uuid,text);
            imageMatches=[uuid isEqual:@(text)];
        }
        cursor+=command->cmdsize;
    }
    if(!imageMatches)return NO;
    for(uint32_t i=0;i<_dyld_image_count();i++)
        if((const void *)_dyld_get_image_header(i)==header)
            return (uintptr_t)code-(uintptr_t)_dyld_get_image_vmaddr_slide(i)==unslid;
    return NO;
}
static Method hlc_owned_method(Class cls,SEL selector,const char *encoding,uintptr_t address) {
    unsigned count=0;Method found=NULL;Method *methods=class_copyMethodList(cls,&count);
    for(unsigned i=0;i<count;i++)if(method_getName(methods[i])==selector){found=methods[i];break;}
    free(methods);
    if(!found || strcmp(method_getTypeEncoding(found),encoding) ||
       !hlc_native((void *)method_getImplementation(found),@"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
                   @"3C90C255-D239-3B5C-9213-9C5D383BEF9C",address))return NULL;
    return found;
}
static BOOL hlc_marker_format(const char bytes[256]) {
    if(bytes[87] || memcmp(bytes,"HLC1:",5) || bytes[37]!=':' || bytes[70]!=':')return NO;
    for(unsigned i=5;i<87;i++) {
        if(i==37 || i==70)continue;
        if(!((bytes[i]>='0' && bytes[i]<='9') || (bytes[i]>='a' && bytes[i]<='f')))return NO;
    }
    return YES;
}
static void *hlc_appkit_address(uintptr_t unslid,BOOL code) {
    const char *path="/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const char *name=_dyld_get_image_name(i);
        if(!name || strcmp(name,path))continue;
        void *value=(void *)(unslid+(uintptr_t)_dyld_get_image_vmaddr_slide(i));
        if(!hlc_native(value,@(path),@"3C90C255-D239-3B5C-9213-9C5D383BEF9C",unslid))return NULL;
        return code?ptrauth_sign_unauthenticated(value,ptrauth_key_function_pointer,0):value;
    }
    return NULL;
}

// Replace only the accepted close's ONE ordering operation. The native helper
// invokes this block first against local ordering state, then copies the SAME
// block before it can flush against server state. A pending WID or two separate
// precommit actions cannot establish this operation identity.
static BOOL hlc_enqueue(id nativeWindow,HLCCloseScope *scope,NSString *value) {
    BOOL enteringOperation=NO;
    @try {
    id ordering=currentOrdering(orderingClass,currentSelector);
    if(!ordering || object_getClass(ordering)!=orderingClass)return NO;
    const uint32_t wid=scope->wid;
    const uint64_t generation=scope->generation;
    NSWindow *window=scope->window;
    HLCActionLeaseV1 *lease=[[HLCActionLeaseV1 alloc] initWithCounter:&pendingActions];
    if(!lease)return NO;
    HLCOperation operation=^(id state) {
        (void)lease; // Native's copied block retains our code/identity lease.
        if(object_getClass(state)!=serverStateClass) {
            HLC_TRACE("local",NULL,wid);
            ((HLCGroupMethod)objc_msgSend)(state,groupSelector,nativeWindow,0,nil);
            return;
        }
        id current=windowNative(window);
        BOOL eligible=atomic_load(&active) && atomic_load(&installGeneration)==generation &&
            nativeWID(nativeWindow,widSelector)==wid && (!current || current==nativeWindow);
        void *transaction=NULL;
        if(eligible)memcpy(&transaction,(const char *)(__bridge const void *)state+8,sizeof(transaction));
        if(!transaction) {serverOrder(state,groupSelector,nativeWindow,0,nil);return;}
        BOOL set=NO,dispatched=NO;
        @try {
            HLC_TRACE("before_set",transaction,wid);
            setProperty(transaction,wid,markerKey,(__bridge CFStringRef)value);set=YES;
            HLC_TRACE("after_set",transaction,wid);
            dispatched=YES;
            serverOrder(state,groupSelector,nativeWindow,0,nil);
            HLC_TRACE("after_order",transaction,wid);
            atomic_fetch_add(&marked,1);
        } @finally {
            // OFF cannot skip CLEAR after SET. Neither call commits or queries a
            // different transaction; both append directly to this state's T.
            if(set) {
                setProperty(transaction,wid,markerKey,NULL);
                HLC_TRACE("after_clear",transaction,wid);
            }
            if(!dispatched)serverOrder(state,groupSelector,nativeWindow,0,nil);
        }
    };
    if(pthread_mutex_lock(transactionLock))return NO;
    @try {
        id group=((HLCCurrentMethod)objc_msgSend)(nativeWindow,orderingGroupSelector);
        for(id member in group)((HLCVoidMethod)objc_msgSend)(member,entangleSelector);
        // againstWindow is nil for orderGroupOut, so its native entanglement is
        // a no-op. Keep the native call shape and its local state dispatch.
        ((HLCVoidMethod)objc_msgSend)(nil,entangleSelector);
        enteringOperation=YES;
        addOperation(ordering,operation);
    } @finally {pthread_mutex_unlock(transactionLock);}
    return YES;
    } @catch(NSException *exception) {
        // After entering AddOperation local/server execution may have happened;
        // replaying original orderGroupOut could close a second time.
        if(enteringOperation)@throw;
        (void)exception;atomic_fetch_add(&exceptions,1);
        return NO;
    }
}
static void hlc_finish(NSWindow *window,SEL selector) {
    atomic_fetch_add(&callbackDepth,1);
    NSString * __attribute__((objc_precise_lifetime)) value=nil;
    HLCCloseScope scope={window,nil,nil,0,atomic_load(&installGeneration),closeScope};
    @try {
        if(atomic_load(&active) && NSThread.isMainThread && window.visible) {
            NSInteger number=window.windowNumber;
            if(number>0 && (uint64_t)number<=UINT32_MAX) {
                scope.native=windowNative(window);
                if(scope.native && nativeWID(scope.native,widSelector)==(uint32_t)number) {
                    char bytes[256]={0};
                    // The lower native order runs after AppKit has cleared its
                    // visible model bit. Bind the last shown lease here, at the
                    // accepted semantic close, before invoking native teardown.
                    if(makeMarker(window,(uint32_t)number,bytes) && hlc_marker_format(bytes)) {
                        value=CFBridgingRelease(CFStringCreateWithCString(NULL,bytes,kCFStringEncodingASCII));
                        if(value) {scope.marker=value;scope.wid=(uint32_t)number;}
                        else atomic_fetch_add(&refused,1);
                    } else atomic_fetch_add(&refused,1);
                }
            }
        }
    } @catch(NSException *exception) { (void)exception;atomic_fetch_add(&exceptions,1); }
    if(scope.wid)closeScope=&scope;
    @try { originalFinish(window,selector); }
    @finally { if(scope.wid)closeScope=scope.previous;atomic_fetch_sub(&callbackDepth,1); }
}
static void hlc_order_out(id nativeWindow,SEL selector) {
    atomic_fetch_add(&callbackDepth,1);
    @try {
        // Our preparation cannot prevent the original order operation, even if a
        // local lookup/allocation raises. Preserve exceptions from the original.
        NSString *value=nil;HLCCloseScope *scope=closeScope;
        @try {
            if(atomic_load(&active) && NSThread.isMainThread && scope && scope->wid &&
               scope->generation==atomic_load(&installGeneration) &&
               nativeWindow==scope->native &&
               nativeWID(nativeWindow,widSelector)==scope->wid) {
                value=scope->marker;
            }
        } @catch(NSException *exception) { (void)exception;atomic_fetch_add(&exceptions,1); }
        if(value && hlc_enqueue(nativeWindow,scope,value))return;
        originalOrderOut(nativeWindow,selector);
    } @finally { atomic_fetch_sub(&callbackDepth,1); }
}
int HLCInstall(const HLCConfig *config) {
    if(!NSThread.isMainThread || !config || config->schema!=1 || !config->marker)return -1;
    if(owned)return stopping?-3:1;
    if(atomic_load(&installGeneration)==UINT64_MAX)return -5;
    Class nativeClass=objc_getClass("NSCGSWindow");orderingClass=objc_getClass("_NSCGSWindowOrdering");
    serverStateClass=objc_getClass("_NSCGSWindowServerOrderingState");
    SEL finish=sel_registerName("_finishClosingWindow"),order=sel_registerName("orderGroupOut");
    widSelector=sel_registerName("windowID");currentSelector=sel_registerName("currentOrdering");
    groupSelector=sel_registerName("orderGroup:op:againstWindow:");
    orderingGroupSelector=sel_registerName("orderingGroup");entangleSelector=sel_registerName("_entangleContextWithCommit");
    finishMethod=hlc_owned_method(NSWindow.class,finish,"v16@0:8",0x185738ca4);
    orderMethod=hlc_owned_method(nativeClass,order,"v16@0:8",0x184be133c);
    Method wid=hlc_owned_method(nativeClass,widSelector,"I16@0:8",0x18598cff4);
    // objc_direct getter: a pure native ivar read, absent from runtime method
    // lists. Resolve its pinned code rather than inventing an ObjC selector.
    HLCNativeGetter getter=(HLCNativeGetter)hlc_appkit_address(0x184a9b514,YES);
    Method current=hlc_owned_method(object_getClass(orderingClass),currentSelector,"@16@0:8",0x184ae62ac);
    Method group=hlc_owned_method(orderingClass,groupSelector,"v36@0:8@16i24@28",0x184bb26c4);
    Method server=hlc_owned_method(serverStateClass,groupSelector,"v36@0:8@16i24@28",0x184bb30a8);
    Method members=hlc_owned_method(nativeClass,orderingGroupSelector,"@16@0:8",0x184c3c0f8);
    Method entangle=hlc_owned_method(nativeClass,entangleSelector,"v16@0:8",0x185990b0c);
    HLCAddOperation operation=(HLCAddOperation)hlc_appkit_address(0x184afbfc8,YES);
    pthread_mutex_t *mutex=hlc_appkit_address(0x1ecfa4108,NO);
    HLCProperty property=(HLCProperty)dlsym(RTLD_DEFAULT,"SLSTransactionSetWindowProperty");
    if(!finishMethod || !orderMethod || !wid || !getter || !current || !group || !server || !members || !entangle || !operation || !mutex ||
       !hlc_native((void *)property,@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
                   @"CD5F2362-8462-38D4-8C57-0BCD4E04F962",0x186dce220))return -2;
    markerKey=CFSTR("org.hyprwm.lifecycle.accepted-close.v1");
    nativeWID=(HLCWIDMethod)method_getImplementation(wid);
    windowNative=getter;
    currentOrdering=(HLCCurrentMethod)method_getImplementation(current);
    serverOrder=(HLCGroupMethod)method_getImplementation(server);
    addOperation=operation;transactionLock=mutex;setProperty=property;makeMarker=config->marker;
    originalFinish=(HLCVoidMethod)method_getImplementation(finishMethod);
    originalOrderOut=(HLCVoidMethod)method_getImplementation(orderMethod);
    method_setImplementation(finishMethod,(IMP)hlc_finish);
    method_setImplementation(orderMethod,(IMP)hlc_order_out);
    if(method_getImplementation(finishMethod)!=(IMP)hlc_finish || method_getImplementation(orderMethod)!=(IMP)hlc_order_out) {
        if(method_getImplementation(finishMethod)==(IMP)hlc_finish)method_setImplementation(finishMethod,(IMP)originalFinish);
        if(method_getImplementation(orderMethod)==(IMP)hlc_order_out)method_setImplementation(orderMethod,(IMP)originalOrderOut);
        return -4;
    }
    atomic_fetch_add(&installGeneration,1);
    stopping=NO;owned=YES;atomic_store(&active,true);return 0;
}
int HLCUninstall(void) {
    if(!NSThread.isMainThread)return -1;
    if(!owned)return 0;
    if(method_getImplementation(finishMethod)!=(IMP)hlc_finish || method_getImplementation(orderMethod)!=(IMP)hlc_order_out)return -4;
    if(atomic_load(&callbackDepth))return -2;
    stopping=YES;atomic_store(&active,false);
    if(atomic_load(&pendingActions))return -3;
    method_setImplementation(finishMethod,(IMP)originalFinish);
    method_setImplementation(orderMethod,(IMP)originalOrderOut);
    if(method_getImplementation(finishMethod)!=(IMP)originalFinish || method_getImplementation(orderMethod)!=(IMP)originalOrderOut)return -4;
    owned=NO;stopping=NO;return 0;
}
NSDictionary *HLCState(void) {
    return @{@"schema":@1,@"owned":@(owned),@"active":@(atomic_load(&active)),@"stopping":@(stopping),
             @"callbacks":@(atomic_load(&callbackDepth)),@"pending_actions":@(atomic_load(&pendingActions)),
             @"marked":@(atomic_load(&marked)),@"refused":@(atomic_load(&refused)),@"exceptions":@(atomic_load(&exceptions)),
             @"install_generation":@(atomic_load(&installGeneration))};
}
