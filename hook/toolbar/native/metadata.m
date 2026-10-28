// Original read-only bar helper. No setters, AX, input, injection or pixel capture.
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreWLAN/CoreWLAN.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioHardwareService.h>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#include <libproc.h>
#include <sys/proc_info.h>

static int emit(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data || data.length > 1048576) return 3;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout); return 0;
}
static NSString *bounded(NSString *value, NSUInteger count) {
    return [value isKindOfClass:NSString.class] ? [value substringToIndex:MIN(value.length,count)] : @"";
}
// Compare only the published native identity/topology. Fullscreen catalog
// dictionaries also contain TileLayoutManager Age/ConfigAge clocks, which
// change on every read even when display, membership and active Space agree.
static NSArray *catalogDisplays(NSArray *rawDisplays,int cid,
        uint64_t (*displayCurrent)(int,CFStringRef),BOOL *consistent) {
    if (![rawDisplays isKindOfClass:NSArray.class] || rawDisplays.count!=1) return nil;
    NSMutableArray *displays=[NSMutableArray new];
    NSMutableSet *ids=[NSMutableSet new];
    for (id rawDisplay in rawDisplays) {
        if (![rawDisplay isKindOfClass:NSDictionary.class]) return nil;
        NSDictionary *display=rawDisplay;
        NSString *identifier=display[@"Display Identifier"];
        NSArray *rawSpaces=display[@"Spaces"];
        NSDictionary *current=display[@"Current Space"];
        if (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] ||
            ![rawSpaces isKindOfClass:NSArray.class] || !rawSpaces.count || rawSpaces.count>64 ||
            ![current isKindOfClass:NSDictionary.class]) return nil;
        NSNumber *currentID=current[@"id64"]?:current[@"ManagedSpaceID"];
        if (![currentID isKindOfClass:NSNumber.class]) return nil;
        uint64_t getter=displayCurrent(cid,(__bridge CFStringRef)identifier);
        if (currentID.unsignedLongLongValue!=getter) *consistent=NO;
        NSMutableArray *rows=[NSMutableArray new];
        for (id rawSpace in rawSpaces) {
            if (![rawSpace isKindOfClass:NSDictionary.class]) return nil;
            NSDictionary *space=rawSpace;
            NSNumber *sid=space[@"id64"]?:space[@"ManagedSpaceID"],*type=space[@"type"];
            NSString *uuid=space[@"uuid"]?:space[@"UUID"];
            if (![sid isKindOfClass:NSNumber.class] || ![type isKindOfClass:NSNumber.class] ||
                sid.unsignedLongLongValue==0 || sid.unsignedLongLongValue>=(1ULL<<53) ||
                ![uuid isKindOfClass:NSString.class] || uuid.length>128 || [ids containsObject:sid]) return nil;
            [ids addObject:sid];[rows addObject:@{@"sid":sid,@"type":type,@"uuid":uuid}];
        }
        [displays addObject:@{@"display":identifier,@"current_catalog":currentID,@"current_getter":@(getter),@"spaces":rows}];
    }
    return displays;
}
// This path deliberately does not initialize HyprWM/LiveSys or any AX monitor.
static int snapshot(void) {
    void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    int (*connection)(void) = image ? dlsym(image,"SLSMainConnectionID") : NULL;
    CFArrayRef (*spaces)(int,int,CFArrayRef) = image ? dlsym(image,"SLSCopySpacesForWindows") : NULL;
    CFArrayRef (*displaySpaces)(int) = image ? dlsym(image,"SLSCopyManagedDisplaySpaces") : NULL;
    uint64_t (*activeSpace)(int) = image ? dlsym(image,"SLSGetActiveSpace") : NULL;
    uint64_t (*displayCurrent)(int,CFStringRef) = image ? dlsym(image,"SLSManagedDisplayGetCurrentSpace") : NULL;
    int (*orderedIn)(int,uint32_t,uint8_t *)=image?dlsym(image,"SLSWindowIsOrderedIn"):NULL;
    if (!connection || !spaces || !displaySpaces || !activeSpace || !displayCurrent || !orderedIn)
        return emit(@{@"schema":@1,@"available":@NO,@"reason":@"native-readonly-symbol-unavailable",@"windows":@[]});
    int cid=connection(); uint64_t activeBefore=activeSpace(cid);
    NSArray *rawDisplays=CFBridgingRelease(displaySpaces(cid));
    NSDictionary *session=CFBridgingRelease(CGSessionCopyCurrentDictionary());
    if (![rawDisplays isKindOfClass:NSArray.class] || rawDisplays.count!=1 || !session) return 4;
    BOOL consistent=YES;
    NSArray *displays=catalogDisplays(rawDisplays,cid,displayCurrent,&consistent);
    if (!displays) return 4;
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID));
    if (!list || list.count>8192) return 4;
    NSMutableArray *windows = [NSMutableArray new];
    NSMutableDictionary *applications = [NSMutableDictionary new];
    for (NSDictionary *row in list) {
        if ([row[(id)kCGWindowLayer] intValue]!=0) continue;
        NSNumber *wid=row[(id)kCGWindowNumber], *pid=row[(id)kCGWindowOwnerPID];
        if (!wid || pid.intValue<=0) continue;
        NSRunningApplication *app = applications[pid];
        if (!app) { app=[NSRunningApplication runningApplicationWithProcessIdentifier:pid.intValue]; if(app) applications[pid]=app; }
        // Native NSRunningApplication policy excludes platform agents/accessories.
        if (!app || app.activationPolicy!=NSApplicationActivationPolicyRegular) continue;
        if(windows.count>=512)return 4;
        struct proc_bsdinfo birth={0};
        if(proc_pidinfo(pid.intValue,PROC_PIDTBSDINFO,0,&birth,sizeof(birth))!=sizeof(birth) || birth.pbi_pid!=(uint32_t)pid.intValue)return 4;
        CGRect bounds=CGRectZero;
        if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&bounds))return 4;
        NSArray *members = CFBridgingRelease(spaces(cid,7,(__bridge CFArrayRef)@[wid]));
        if (![members isKindOfClass:NSArray.class] || members.count>64) return 4;
        uint8_t ordered=0;if(orderedIn(cid,wid.unsignedIntValue,&ordered)!=0 || ordered>1)return 4;
        [windows addObject:@{@"wid":wid,@"pid":pid,@"spaces":members,
            @"ordered_in":(ordered?@YES:@NO),
            @"bundle":bounded(app.bundleIdentifier,256),@"app":bounded(app.localizedName,128),
            @"title":bounded(row[(id)kCGWindowName],256),@"onscreen":([row[(id)kCGWindowIsOnscreen] boolValue]?@YES:@NO),
            @"app_hidden":app.hidden?@YES:@NO,@"app_terminated":app.terminated?@YES:@NO,
            @"alpha":row[(id)kCGWindowAlpha]?:@0,@"layer":row[(id)kCGWindowLayer]?:@0,
            @"bounds":@[@(bounds.origin.x),@(bounds.origin.y),@(bounds.size.width),@(bounds.size.height)],
            @"process_birth":@[@(birth.pbi_pid),@(birth.pbi_uid),@(birth.pbi_start_tvsec),@(birth.pbi_start_tvusec)]}];
    }
    uint64_t activeAfter=activeSpace(cid);
    NSArray *afterDisplays=CFBridgingRelease(displaySpaces(cid));
    BOOL afterConsistent=YES;
    NSArray *afterCatalog=catalogDisplays(afterDisplays,cid,displayCurrent,&afterConsistent);
    uint64_t activeFinal=activeSpace(cid);
    char build[128]={0};size_t buildSize=sizeof(build);
    if (sysctlbyname("kern.osversion",build,&buildSize,NULL,0)) return 4;
    NSDictionary *catalog=@{@"schema":@1,@"mode":@"native-readonly",@"source":@"SkyLight.read-only",
        @"os_build":[NSString stringWithUTF8String:build],@"setter_called":@NO,
        @"locked":@([session[@"CGSSessionScreenIsLocked"] boolValue]),
        @"consistent":(consistent && afterConsistent && activeBefore==activeAfter && activeAfter==activeFinal && [displays isEqual:afterCatalog] ? @YES : @NO),
        @"active_before":@(activeBefore),@"active_after":@(activeAfter),@"displays":displays};
    return emit(@{@"schema":@1,@"available":@YES,@"windows":windows,@"catalog":catalog,
        @"source":@"CoreGraphics+NSRunningApplication+SkyLight.read-only",@"census_scope":@"all-spaces",@"census_complete":@YES,@"metadata_revision":@3,@"titles_permission":@(CGPreflightScreenCaptureAccess())});
}
static NSDictionary *battery(void) {
    CFTypeRef info=IOPSCopyPowerSourcesInfo(); if(!info) return @{@"present":@NO};
    NSArray *sources=CFBridgingRelease(IOPSCopyPowerSourcesList(info));
    NSDictionary *result=@{@"present":@NO};
    for (id entry in sources) {
        NSDictionary *desc=(__bridge NSDictionary *)IOPSGetPowerSourceDescription(info,(__bridge CFTypeRef)entry);
        if (![desc[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) continue;
        double current=[desc[@kIOPSCurrentCapacityKey] doubleValue], maximum=[desc[@kIOPSMaxCapacityKey] doubleValue];
        result=@{@"present":@YES,@"percent":@(maximum>0 ? 100*current/maximum : 0),
            @"charging":@([desc[@kIOPSIsChargingKey] boolValue]),@"ac":@([desc[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue])}; break;
    }
    CFRelease(info); return result;
}
// Pure classification seam. Missing/untyped Active is unknown, never false.
static NSDictionary *wifi_state(BOOL available,BOOL powered,id active) {
    if(!available)return @{@"available":@NO,@"connected":NSNull.null,@"connection_state":@"unknown"};
    BOOL known=active && CFGetTypeID((__bridge CFTypeRef)active)==CFBooleanGetTypeID();
    NSString *state=!powered?@"off":!known?@"unknown":[active boolValue]?@"connected":@"disconnected";
    id connected=!powered?@NO:known?@([active boolValue]):NSNull.null;
    return @{@"available":@YES,@"powered":@(powered),@"connected":connected,@"connection_state":state};
}
static NSDictionary *wifi(void) {
    CWInterface *interface=[[CWWiFiClient sharedWiFiClient] interface];
    if(!interface)return wifi_state(NO,NO,nil);
    NSString *name=interface.interfaceName;
    NSString *key=name.length?[NSString stringWithFormat:@"State:/Network/Interface/%@/Link",name]:nil;
    id link=key?CFBridgingRelease(SCDynamicStoreCopyValue(NULL,(__bridge CFStringRef)key)):nil;
    id active=[link isKindOfClass:NSDictionary.class]?link[(__bridge NSString *)kSCPropNetLinkActive]:nil;
    // No SSID/BSSID, Location request, association request, scan or setter.
    return wifi_state(YES,interface.powerOn,active);
}
static NSDictionary *volume(void) {
    AudioDeviceID device=kAudioObjectUnknown;
    AudioObjectPropertyAddress addr={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(device);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&addr,0,NULL,&size,&device)!=noErr) return @{@"available":@NO};
    Float32 scalar=0; size=sizeof(scalar);
    addr=(AudioObjectPropertyAddress){kAudioHardwareServiceDeviceProperty_VirtualMainVolume,kAudioDevicePropertyScopeOutput,kAudioObjectPropertyElementMain};
    if(AudioObjectGetPropertyData(device,&addr,0,NULL,&size,&scalar)!=noErr) {
        addr.mSelector=kAudioDevicePropertyVolumeScalar;
        if(AudioObjectGetPropertyData(device,&addr,0,NULL,&size,&scalar)!=noErr) return @{@"available":@NO};
    }
    return @{@"available":@YES,@"percent":@(MAX(0,MIN(100,scalar*100)))};
}
static int metrics(void) {
    host_cpu_load_info_data_t cpu={0}; mach_msg_type_number_t cpuCount=HOST_CPU_LOAD_INFO_COUNT;
    host_statistics(mach_host_self(),HOST_CPU_LOAD_INFO,(host_info_t)&cpu,&cpuCount);
    vm_statistics64_data_t vm={0}; mach_msg_type_number_t vmCount=HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(),HOST_VM_INFO64,(host_info64_t)&vm,&vmCount);
    uint64_t total=0; size_t size=sizeof(total); sysctlbyname("hw.memsize",&total,&size,NULL,0);
    vm_size_t page=0;host_page_size(mach_host_self(),&page);
    // Application + wired + compressor pages; excludes reclaimable file cache.
    uint64_t used=((uint64_t)vm.active_count+vm.wire_count+vm.compressor_page_count)*page;
    return emit(@{@"schema":@1,@"cpu_ticks":@[@(cpu.cpu_ticks[CPU_STATE_USER]),@(cpu.cpu_ticks[CPU_STATE_SYSTEM]),@(cpu.cpu_ticks[CPU_STATE_IDLE]),@(cpu.cpu_ticks[CPU_STATE_NICE])],
        @"memory":@{@"used":@(used),@"total":@(total)}});
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=2) return 2;
    if(!strcmp(argv[1],"snapshot")) return snapshot();
    if(!strcmp(argv[1],"metrics")) return metrics();
    if(!strcmp(argv[1],"system")) return emit(@{@"schema":@1,@"battery":battery(),@"wifi":wifi(),@"volume":volume()});
    return 2;
} }
