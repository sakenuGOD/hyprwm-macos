// Private typed own-window placement only. No foreign window/Space activation API.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <unistd.h>

// Exact local getter ABI provenance (read only, sources not changed):
// hook/swift/Sources/CAX/sys.c
//   extern int SLSMainConnectionID(void);
// Move ABI verified in local SkyLight SLSMoveWindowsToManagedSpace:
// enabled branch tail-calls objc_autoreleasePoolPop; no status result is returned.
// The legacy branch likewise does not form a CGError result.
//   extern uint64_t SLSGetActiveSpace(int);
// existing frozen native-companion-v1/native/metadata.m:28,83:
//   CFArrayRef (*SLSCopySpacesForWindows)(int,int,CFArrayRef); mask7
// No guessed AddWindowsToSpaces signature or undocumented fallback.
typedef int (*OwnMainConnection)(void);
typedef void (*OwnMoveToSpace)(int,CFArrayRef,uint64_t);
typedef uint64_t (*OwnActiveSpace)(int);
typedef CFArrayRef (*OwnCopySpaces)(int,int,CFArrayRef);
static BOOL ownActiveWitnessMatches(uint64_t before,uint64_t after) {return before>0&&after>0&&before==after;}
static uint64_t ownCurrentActiveSpace(void) {
    void *image=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    OwnMainConnection connection=image?(OwnMainConnection)dlsym(image,"SLSMainConnectionID"):NULL;OwnActiveSpace active=image?(OwnActiveSpace)dlsym(image,"SLSGetActiveSpace"):NULL;
    uint64_t sid=connection&&active?active(connection()):0;if(image)dlclose(image);return sid;
}
static BOOL ownPlacementPreflight(pid_t owner, NSInteger expected, NSInteger number, uint64_t sid, NSSet *catalog, BOOL ordinary, BOOL enabled) {
    return enabled && ordinary && owner==getpid() && expected>0 && expected==number && sid>0 && sid<(1ULL<<53) && [catalog containsObject:@(sid)];
}
// IncludingWindow omits some never-ordered windows even when All contains their exact own row.
static BOOL ownUniqueCGOwnerInRows(NSArray *rows,uint32_t wid,pid_t expectedPID) {
    if(![rows isKindOfClass:NSArray.class]||rows.count>8192||wid==0||expectedPID<=0)return NO;
    NSUInteger matches=0;BOOL owner=NO;
    for(id value in rows){
        if(![value isKindOfClass:NSDictionary.class])return NO;
        id number=value[(id)kCGWindowNumber];
        if([number isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)number)!=CFBooleanGetTypeID()&&[number doubleValue]==(double)wid){matches++;id pid=value[(id)kCGWindowOwnerPID];owner=[pid isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)pid)!=CFBooleanGetTypeID()&&[pid doubleValue]==(double)expectedPID;}
    }
    return matches==1&&owner;
}
static BOOL ownUniqueCGOwner(uint32_t wid) {
    NSArray *all=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll,kCGNullWindowID));
    return ownUniqueCGOwnerInRows(all,wid,getpid());
}
static NSDictionary *placeOwnPanelWithScope(NSWindow *window, uint64_t sid, NSSet *ordinaryCatalog, BOOL enabled, BOOL currentOnly) {
    NSInteger number=window.windowNumber; if(number<=0||(uint64_t)number>UINT32_MAX)return @{@"ok":@NO,@"reason":@"invalid-own-window-number"};
    uint32_t ownID=(uint32_t)number;BOOL ownerOK=ownUniqueCGOwner(ownID);
    if (!ownerOK||!ownPlacementPreflight(getpid(),number,number,sid,ordinaryCatalog,[ordinaryCatalog containsObject:@(sid)],enabled)) return @{@"ok":@NO,@"reason":@"owned-window-preflight-refused",@"cg_witness_source":@"All+unique-exact-WID+owner",@"cg_unique_owner":@(ownerOK),@"own_pid":@(getpid()),@"own_wid":@(ownID)};
    void *image=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    OwnMainConnection connection=image?(OwnMainConnection)dlsym(image,"SLSMainConnectionID"):NULL;
    OwnMoveToSpace move=image?(OwnMoveToSpace)dlsym(image,"SLSMoveWindowsToManagedSpace"):NULL;
    OwnActiveSpace active=image?(OwnActiveSpace)dlsym(image,"SLSGetActiveSpace"):NULL;
    OwnCopySpaces spaces=image?(OwnCopySpaces)dlsym(image,"SLSCopySpacesForWindows"):NULL;
    if (!connection||!move||!active||!spaces) {if(image)dlclose(image);return @{@"ok":@NO,@"reason":@"exact-typed-symbol-unavailable"};}
    int cid=connection();uint64_t before=active(cid);if(currentOnly&&before!=sid){dlclose(image);return @{@"ok":@NO,@"reason":@"probe-target-no-longer-current-before-private-call"};}if(!before){dlclose(image);return @{@"ok":@NO,@"reason":@"active-space-witness-unavailable"};}NSArray *ids=@[@(ownID)];
    NSArray *prior=CFBridgingRelease(spaces(cid,7,(__bridge CFArrayRef)ids));
    move(cid,(__bridge CFArrayRef)ids,sid);
    NSArray *after=CFBridgingRelease(spaces(cid,7,(__bridge CFArrayRef)ids)); uint64_t current=active(cid);
    BOOL membership=[after isKindOfClass:NSArray.class]&&after.count==1&&[after[0] isKindOfClass:NSNumber.class]&&[after[0] unsignedLongLongValue]==sid;
    BOOL ok=membership&&ownActiveWitnessMatches(before,current);
    NSDictionary *report=@{@"ok":@(ok),@"reason":ok?@"own-membership-verified":before!=current?@"active-space-changed-refused":@"own-membership-not-verified",@"own_pid":@(getpid()),@"own_wid":@(ownID),@"requested_sid":@(sid),@"before_membership":prior?:@[],@"after_membership":after?:@[],@"native_call_completed":@YES,@"active_before":@(before),@"active_after":@(current),@"foreign_window_acted_on":@NO,@"space_activation_api_called":@NO};
    dlclose(image);return report;
}
static NSDictionary *placeOwnPanel(NSWindow *window,uint64_t sid,NSSet *catalog,BOOL enabled) {return placeOwnPanelWithScope(window,sid,catalog,enabled,NO);}
static NSDictionary *verifyOwnPanelAfterOrder(NSWindow *window, uint64_t sid, uint64_t expectedActive) {
    NSInteger number=window.windowNumber;if(number<=0||(uint64_t)number>UINT32_MAX)return @{@"ok":@NO,@"reason":@"invalid-own-window-number"};
    uint32_t wid=(uint32_t)number;
    if(!ownUniqueCGOwner(wid))return @{@"ok":@NO,@"reason":@"own-window-identity-lost",@"cg_witness_source":@"All+unique-exact-WID+owner"};
    void *image=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    OwnMainConnection connection=image?(OwnMainConnection)dlsym(image,"SLSMainConnectionID"):NULL;OwnActiveSpace active=image?(OwnActiveSpace)dlsym(image,"SLSGetActiveSpace"):NULL;OwnCopySpaces spaces=image?(OwnCopySpaces)dlsym(image,"SLSCopySpacesForWindows"):NULL;
    if(!connection||!active||!spaces){if(image)dlclose(image);return @{@"ok":@NO,@"reason":@"exact-typed-getter-unavailable"};}
    int cid=connection();NSArray *membership=CFBridgingRelease(spaces(cid,7,(__bridge CFArrayRef)@[@(wid)]));uint64_t current=active(cid);
    BOOL ok=ownActiveWitnessMatches(expectedActive,current)&&[membership isKindOfClass:NSArray.class]&&membership.count==1&&[membership[0] isKindOfClass:NSNumber.class]&&[membership[0] unsignedLongLongValue]==sid;
    NSDictionary *result=@{@"ok":@(ok),@"reason":ok?@"own-membership-verified-after-order":@"own-membership-or-active-changed-after-order",@"stage":@"after-order",@"own_pid":@(getpid()),@"own_wid":@(wid),@"requested_sid":@(sid),@"after_membership":membership?:@[],@"active_before":@(expectedActive),@"active_after":@(current),@"space_activation_api_called":@NO,@"foreign_window_acted_on":@NO};dlclose(image);return result;
}
