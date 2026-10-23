// Root-operated Mission Control spaces-bar controls only. No NSApplication,
// windows, AX prompts, desktop-window attributes, or raw Space mutations.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <dlfcn.h>
#include <unistd.h>
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <math.h>

@interface MCControl : NSObject
@property AXUIElementRef element;
@property NSDictionary *metadata;
@end
@implementation MCControl
- (void)dealloc { if (_element) CFRelease(_element); }
@end

static unsigned visited;
static BOOL truncated;
static double deadline;
static NSMutableArray<NSDictionary *> *discovery;
static NSMutableArray<MCControl *> *controls;
static NSMutableArray *seen;
static BOOL inspectSpaceActions,inspectThumbnailIdentifiers;
static NSMutableArray *spaceActionMetadata,*thumbnailMetadata,*spaceNodeMetadata;
static NSDictionary *ownedThumbnailReceipt;
static NSMutableArray<MCControl *> *ownedThumbnailMatches;
static NSString *stringAttribute(AXUIElementRef node,CFStringRef name);
static NSArray *children(AXUIElementRef node,CFStringRef attribute);
static NSDictionary *typedGeometry(AXUIElementRef node);

static BOOL thumbnailScope(NSString *identifier) {
    return [identifier hasPrefix:@"mc.windows"]||[identifier hasPrefix:@"mc.app-windows"]||[identifier isEqual:@"appexpose.windows"]||
        (ownedThumbnailReceipt&&[identifier isEqual:@"appexpose.recents"]);
}
static void scanThumbnailIdentifiers(AXUIElementRef node,unsigned depth,NSString *scopeIdentifier) {
    if(depth>7||visited>=128||CFAbsoluteTimeGetCurrent()>deadline){truncated=YES;return;}
    for(id previous in seen)if(CFEqual((__bridge CFTypeRef)previous,node))return;
    [seen addObject:(__bridge id)node];visited++;
    NSString *role=stringAttribute(node,kAXRoleAttribute);
    // Dock's MC/App Exposé thumbnail subtree is a server UI, not the source
    // application's AX tree. Even here, read IDs/roles only; no Title/Value,
    // descriptions, pixels, positions, or AXPress permission are introduced.
    [thumbnailMetadata addObject:@{@"identifier":stringAttribute(node,kAXIdentifierAttribute),@"role":role,@"depth":@(depth)}];
    if(ownedThumbnailReceipt && [role isEqual:@"AXButton"]) {
        // Root explicitly permits comparing transient thumbnail titles against
        // one attested owned-fixture title. No other title is emitted or saved.
        NSString *title=stringAttribute(node,kAXTitleAttribute);
        if([title isEqual:ownedThumbnailReceipt[@"title"]]) {
            CFArrayRef actions=NULL,attributes=NULL;
            BOOL press=!AXUIElementCopyActionNames(node,&actions)&&actions&&[(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction];
            if(actions)CFRelease(actions);
            NSMutableDictionary *metadata=[@{@"identifier":stringAttribute(node,kAXIdentifierAttribute),@"role":role,@"matched_own_title":@YES,@"press":@(press),@"scope_identifier":scopeIdentifier} mutableCopy];
            if(!AXUIElementCopyAttributeNames(node,&attributes)&&attributes) {
                if(CFArrayGetCount(attributes)>64)truncated=YES;
                else metadata[@"attribute_names"]=[(__bridge NSArray *)attributes copy];
                CFRelease(attributes);
            }
            MCControl *entry=[MCControl new];entry.element=(AXUIElementRef)CFRetain(node);entry.metadata=metadata;
            [ownedThumbnailMatches addObject:entry];
        }
    }
    if([role isEqual:@"AXDockItem"])return;
    for(id child in children(node,kAXChildrenAttribute))
        if(CFGetTypeID((__bridge CFTypeRef)child)==AXUIElementGetTypeID())scanThumbnailIdentifiers((__bridge AXUIElementRef)child,depth+1,scopeIdentifier);
}

static NSDictionary *dockIdentity(pid_t pid) {
    struct proc_bsdinfo info = {0}; char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof info) != sizeof info ||
        info.pbi_pid != (uint32_t)pid || info.pbi_uid != getuid() || !info.pbi_start_tvsec ||
        proc_pidpath(pid, path, sizeof path) <= 0 ||
        strcmp(path, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock")) return nil;
    return @{@"pid": @(pid), @"uid": @(info.pbi_uid), @"start_sec": @(info.pbi_start_tvsec),
             @"start_usec": @(info.pbi_start_tvusec), @"path": @(path)};
}
static NSString *stringAttribute(AXUIElementRef node, CFStringRef name) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(node, name, &value) || !value) return @"";
    NSString *text = CFGetTypeID(value) == CFStringGetTypeID() ? [(__bridge NSString *)value copy] : @"";
    CFRelease(value);
    if (text.length > 160) { truncated = YES; return @""; }
    return text;
}
static NSArray *children(AXUIElementRef node, CFStringRef attribute) {
    CFIndex count = 0;
    if (AXUIElementGetAttributeValueCount(node, attribute, &count) || count <= 0) return @[];
    if (count > 32) truncated = YES;
    CFArrayRef values = NULL;
    if (AXUIElementCopyAttributeValues(node, attribute, 0, MIN(count, 32), &values) || !values) return @[];
    return CFBridgingRelease(values);
}
static BOOL mcRoot(NSString *identifier) {
    NSString *normalized = [[[identifier lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""]
        stringByReplacingOccurrencesOfString:@" " withString:@""];
    return [@[@"mc", @"missioncontrol", @"missioncontrolwindow"] containsObject:normalized];
}
static BOOL spacesScope(NSString *identifier) {
    return [identifier hasPrefix:@"mc.spaces"] ||
        [@[@"spaces-bar", @"spaces bar", @"mission-control-spaces-bar"] containsObject:identifier];
}
static void scanContext(AXUIElementRef node,unsigned depth,BOOL inMC,BOOL inSpaces,BOOL inAppExpose) {
    if (depth > 7 || visited >= 128 || CFAbsoluteTimeGetCurrent() > deadline) { truncated = YES; return; }
    for (id previous in seen) if (CFEqual((__bridge CFTypeRef)previous, node)) return;
    [seen addObject:(__bridge id)node];
    visited++;
    NSString *role = stringAttribute(node, kAXRoleAttribute);
    if ([role isEqualToString:@"AXDockItem"]) return;
    NSString *identifier = stringAttribute(node, kAXIdentifierAttribute);
    BOOL root = mcRoot(identifier), appRoot=[identifier isEqual:@"appexpose"], spaces = spacesScope(identifier);
    // The system spaces bar can lack an identifier. Its immediate Mission
    // Control group description is a scope marker, never an action target.
    if (inMC && !inSpaces && [role isEqualToString:@"AXGroup"]) {
        NSString *description = stringAttribute(node, kAXDescriptionAttribute);
        spaces |= [@[@"spaces bar", @"Spaces bar", @"Spaces Bar", @"панель рабочих столов"] containsObject:description];
    }
    inMC |= root; inAppExpose |= appRoot; inSpaces |= inMC && spaces;
    if(inspectSpaceActions && inSpaces)[spaceNodeMetadata addObject:@{@"identifier":identifier,@"role":role,@"depth":@(depth)}];
    BOOL group = [@[@"AXApplication", @"AXGroup", @"AXList", @"AXScrollArea", @"AXWindow", @"AXUnknown"] containsObject:role];
    if (root || appRoot || (!inSpaces && group && depth <= 3))
        [discovery addObject:@{@"identifier": identifier, @"role": role, @"depth": @(depth)}];
    if (inSpaces && ([@[@"AXButton", @"AXRadioButton", @"AXTabButton"] containsObject:role])) {
        CFArrayRef actions = NULL;
        BOOL press = !AXUIElementCopyActionNames(node, &actions) && actions &&
            [(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction];
        if (actions) CFRelease(actions);
        MCControl *entry = [MCControl new]; entry.element = (AXUIElementRef)CFRetain(node);
        entry.metadata = @{@"identifier": identifier, @"role": role,
            @"description": stringAttribute(node, kAXDescriptionAttribute), @"press": @(press)};
        [controls addObject:entry];
        if(inspectSpaceActions) {
            CFArrayRef names=NULL;
            if(!AXUIElementCopyActionNames(node,&names)&&names) {
                if(CFArrayGetCount(names)>16)truncated=YES;
                else [spaceActionMetadata addObject:@{@"control":entry.metadata,@"actions":[(__bridge NSArray *)names copy],@"geometry_diagnostic":typedGeometry(node)}];
                CFRelease(names);
            }
        }
    }
    // A Dock Mission Control subtree also contains app-window thumbnails.
    // Discover IDs/roles through a few opaque group ancestors. Never descend
    // into the app-window thumbnail region or read titles/values/window data.
    if(thumbnailScope(identifier)) {
        BOOL appScope=[identifier isEqual:@"appexpose.windows"]||[identifier isEqual:@"appexpose.recents"];
        if(inspectThumbnailIdentifiers && (appScope?inAppExpose:inMC)) {
            [thumbnailMetadata addObject:@{@"identifier":identifier,@"role":role,@"depth":@(depth)}];
            for(id child in children(node,kAXChildrenAttribute))
                if(CFGetTypeID((__bridge CFTypeRef)child)==AXUIElementGetTypeID())scanThumbnailIdentifiers((__bridge AXUIElementRef)child,depth+1,identifier);
        }
        return;
    }
    // Recents contents depend on Dock version; no document/window inference.
    // Their exact subtree is diagnostic only with an attested own receipt.
    // Ordinary/identifier-only inspection never reads these item titles.
    if(inAppExpose && !inMC && !appRoot)return;
    if (depth && !inSpaces && !root && !appRoot && !(group && depth < 3)) return;
    for (id child in children(node, kAXChildrenAttribute))
        if (CFGetTypeID((__bridge CFTypeRef)child) == AXUIElementGetTypeID())
            scanContext((__bridge AXUIElementRef)child,depth+1,inMC,inSpaces,inAppExpose);
}
static void scan(AXUIElementRef node,unsigned depth,BOOL inMC,BOOL inSpaces) {
    scanContext(node,depth,inMC,inSpaces,NO);
}
static NSDictionary *inspect(pid_t pid) {
    NSDictionary *identity = dockIdentity(pid);
    if (!identity) return @{@"error": @"Dock PID/path/native birth identity unavailable"};
    if (!AXIsProcessTrusted()) return @{@"dock": identity, @"error": @"AX access unavailable; no prompt requested"};
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return @{@"dock": identity, @"error": @"AX application unavailable"};
    AXUIElementSetMessagingTimeout(app, .2);
    visited = 0; truncated = NO; deadline = CFAbsoluteTimeGetCurrent()+3;
    discovery = [NSMutableArray new]; controls = [NSMutableArray new]; seen = [NSMutableArray new];
    spaceActionMetadata=[NSMutableArray new];thumbnailMetadata=[NSMutableArray new];spaceNodeMetadata=[NSMutableArray new];
    ownedThumbnailMatches=[NSMutableArray new];
    scan(app, 0, NO, NO);
    // Some Dock versions expose Mission Control through AXWindows separately.
    for (id child in children(app, kAXWindowsAttribute)) {
        AXUIElementRef node = (__bridge AXUIElementRef)child;
        if (CFGetTypeID(node) == AXUIElementGetTypeID()) scan(node, 1, NO, NO);
    }
    CFRelease(app);
    if (![identity isEqual:dockIdentity(pid)]) return @{@"error": @"Dock native generation changed during inspect"};
    NSMutableArray *rows = [NSMutableArray new];
    for (MCControl *entry in controls) [rows addObject:entry.metadata];
    NSMutableDictionary *result=[@{@"mode": @"inspect", @"dock": identity, @"time": @(CFAbsoluteTimeGetCurrent()), @"scope": @"Mission Control spaces bar only",
             @"discovery": discovery, @"controls": rows, @"visited": @(visited), @"truncated": @(truncated)} mutableCopy];
    if(inspectSpaceActions){result[@"spaces_action_metadata"]=spaceActionMetadata;result[@"spaces_node_identifiers_only"]=spaceNodeMetadata;}
    if(inspectThumbnailIdentifiers){
        result[@"thumbnail_identifiers_only"]=thumbnailMetadata;result[@"thumbnail_actions_authorized"]=@NO;
        result[@"thumbnail_scope_observed"]=@((BOOL)(thumbnailMetadata.count>0));
        NSMutableArray *scopes=[NSMutableArray new];
        for(NSDictionary *row in thumbnailMetadata)if(thumbnailScope(row[@"identifier"])&&![scopes containsObject:row[@"identifier"]])[scopes addObject:row[@"identifier"]];
        result[@"observed_thumbnail_scopes"]=scopes;
    }
    if(ownedThumbnailReceipt){NSMutableArray *matches=[NSMutableArray new];for(MCControl *entry in ownedThumbnailMatches)[matches addObject:entry.metadata];result[@"owned_thumbnail_matches"]=matches;}
    return result;
}
static NSDictionary *spaceSnapshot(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW|RTLD_LOCAL);
    int (*mainCID)(void) = lib ? dlsym(lib, "SLSMainConnectionID") : NULL;
    uint64_t (*active)(int) = lib ? dlsym(lib, "SLSGetActiveSpace") : NULL;
    CFArrayRef (*copy)(int) = lib ? dlsym(lib, "SLSCopyManagedDisplaySpaces") : NULL;
    if (!mainCID || !active || !copy) return @{@"error": @"native managed Space read APIs unavailable"};
    int cid = mainCID(); CFArrayRef data = copy(cid);
    if (!data) return @{@"error": @"native managed Space snapshot unavailable"};
    NSMutableArray *rows = [NSMutableArray new];
    for (NSDictionary *display in (__bridge NSArray *)data) {
        NSMutableArray *spaces = [NSMutableArray new];
        for (NSDictionary *space in display[@"Spaces"]) {
            NSMutableDictionary *row = [NSMutableDictionary new];
            for (NSString *key in @[@"id64", @"ManagedSpaceID", @"type", @"uuid", @"UUID"])
                if (space[key]) row[key] = space[key];
            [spaces addObject:row];
        }
        NSDictionary *current = display[@"Current Space"];
        [rows addObject:@{@"display": display[@"Display Identifier"] ?: @"",
                         @"current": current[@"id64"] ?: current[@"ManagedSpaceID"] ?: @0, @"spaces": spaces}];
    }
    CFRelease(data);
    return @{@"active": @(active(cid)), @"displays": rows};
}
static NSDictionary *boundedJSON(NSString *path) {
    NSData *data=[NSData dataWithContentsOfFile:path];if(!data||data.length>262144)return nil;
    id result=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [result isKindOfClass:NSDictionary.class]?result:nil;
}
static BOOL ownFixtureFence(NSDictionary *receipt) {
    if(![receipt isKindOfClass:NSDictionary.class]||![receipt[@"generation"] isKindOfClass:NSArray.class]||[receipt[@"generation"] count]!=4||
       ![receipt[@"title"] isKindOfClass:NSString.class]||![receipt[@"title"] hasPrefix:@"Hyprwm QA "]||[receipt[@"title"] length]>160||
       ![receipt[@"executable"] isKindOfClass:NSString.class]||![receipt[@"executable_sha256"] isKindOfClass:NSString.class]||[receipt[@"executable_sha256"] length]!=64||
       ![receipt[@"frame"] isKindOfClass:NSArray.class]||[receipt[@"frame"] count]!=4||
       ![receipt[@"time"] isKindOfClass:NSNumber.class]||CFAbsoluteTimeGetCurrent()-[receipt[@"time"] doubleValue]>60||CFAbsoluteTimeGetCurrent()<[receipt[@"time"] doubleValue])return NO;
    NSArray *generation=receipt[@"generation"];
    for(id n in generation)if(![n isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)n)==CFBooleanGetTypeID()||strchr("fd",[n objCType][0])||[n longLongValue]<0)return NO;
    id number=receipt[@"wid"];if(![number isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID()||strchr("fd",[number objCType][0])||[number unsignedLongLongValue]>UINT32_MAX)return NO;
    pid_t pid=[generation[0] intValue];uint32_t wid=[number unsignedIntValue];if(pid<=0||!wid)return NO;
    for(id n in receipt[@"frame"])if(![n isKindOfClass:NSNumber.class]||!isfinite([n doubleValue]))return NO;
    struct proc_bsdinfo info={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof info)!=sizeof info||info.pbi_uid!=getuid()||
       info.pbi_uid!=[generation[1] unsignedIntValue]||info.pbi_start_tvsec!=[generation[2] unsignedLongLongValue]||
       info.pbi_start_tvusec!=[generation[3] unsignedLongLongValue]||proc_pidpath(pid,path,sizeof path)<=0)return NO;
    NSString *executable=@(path);
    if(![executable isEqual:receipt[@"executable"]]||![executable hasPrefix:[NSHomeDirectory() stringByAppendingString:@"/Library/Caches/HyprWM/owned-fixtures/"]]||
       ![executable hasSuffix:@"/OwnedFixture.app/Contents/MacOS/fixture"])return NO;
    int fd=open(path,O_RDONLY|O_NOFOLLOW);struct stat st={0};
    if(fd<0)return NO;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||st.st_size<4096||st.st_size>8*1024*1024){close(fd);return NO;}
    CC_SHA256_CTX context;CC_SHA256_Init(&context);unsigned char bytes[16384];ssize_t count;
    while((count=read(fd,bytes,sizeof bytes))>0)CC_SHA256_Update(&context,bytes,(CC_LONG)count);
    close(fd);if(count<0)return NO;unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(digest,&context);
    NSMutableString *hash=[NSMutableString new];for(unsigned i=0;i<sizeof digest;i++)[hash appendFormat:@"%02x",digest[i]];
    if(![hash isEqual:receipt[@"executable_sha256"]])return NO;
    void *lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
    int (*cidFn)(void)=lib?dlsym(lib,"SLSMainConnectionID"):NULL;int (*ownerFn)(int,uint32_t,int *)=lib?dlsym(lib,"SLSGetWindowOwner"):NULL;
    int (*pidFn)(int,pid_t *)=lib?dlsym(lib,"SLSConnectionGetPID"):NULL;
    int (*boundsFn)(int,uint32_t,CGRect *)=lib?dlsym(lib,"SLSGetWindowBounds"):NULL;
    int owner=0;pid_t nativePID=0;
    CGRect box=CGRectZero;NSArray *frame=receipt[@"frame"];
    return cidFn&&ownerFn&&pidFn&&boundsFn&&!ownerFn(cidFn(),wid,&owner)&&!pidFn(owner,&nativePID)&&nativePID==pid&&
        !boundsFn(cidFn(),wid,&box)&&isfinite(box.size.width)&&isfinite(box.size.height)&&box.size.width>0&&box.size.height>0&&
        fabs(box.size.width-[frame[2] doubleValue])<=1&&fabs(box.size.height-[frame[3] doubleValue])<=1;
}
static NSDictionary *inspectOwnedThumbnail(pid_t dockPID,NSString *receiptPath,BOOL press,NSString *inspectionPath) {
    NSDictionary *receipt=boundedJSON(receiptPath),*identity=dockIdentity(dockPID);
    if(!identity||!ownFixtureFence(receipt))return @{@"error":@"fresh exact owned fixture PID/birth/WID/title/path/hash receipt required"};
    ownedThumbnailReceipt=receipt;inspectThumbnailIdentifiers=YES;
    NSDictionary *inspection=inspect(dockPID);NSMutableDictionary *result=[inspection mutableCopy];
    result[@"mode"]=press?@"press-owned-thumbnail":@"inspect-owned-thumbnail";result[@"own_target"]=receipt;
    if(inspection[@"error"]||[inspection[@"truncated"] boolValue]||!ownFixtureFence(receipt)||![identity isEqual:dockIdentity(dockPID)]) {
        result[@"error"]=@"complete bounded Dock subtree and exact fresh owned window fence required";return result;
    }
    if(![inspection[@"thumbnail_scope_observed"] boolValue]) {
        result[@"error"]=@"known Dock window thumbnail scope unavailable; no native availability verdict or AXPress";return result;
    }
    if(!press)return result;
    NSDictionary *expected=boundedJSON(inspectionPath);double now=CFAbsoluteTimeGetCurrent();
    if(![expected[@"mode"] isEqual:@"inspect-owned-thumbnail"]||![expected[@"own_target"] isEqual:receipt]||![expected[@"dock"] isEqual:identity]||
       ![expected[@"time"] isKindOfClass:NSNumber.class]||now-[expected[@"time"] doubleValue]>60||now<[expected[@"time"] doubleValue]||
       [expected[@"truncated"] boolValue]||ownedThumbnailMatches.count!=1||[expected[@"owned_thumbnail_matches"] count]!=1||
       ![ownedThumbnailMatches[0].metadata isEqual:expected[@"owned_thumbnail_matches"][0]]||![ownedThumbnailMatches[0].metadata[@"press"] boolValue]) {
        result[@"error"]=@"unique exact known-owned title/role/action inspection receipt required; no AXPress";return result;
    }
    MCControl *entry=ownedThumbnailMatches[0];
    if(![stringAttribute(entry.element,kAXTitleAttribute) isEqual:receipt[@"title"]]||![stringAttribute(entry.element,kAXRoleAttribute) isEqual:@"AXButton"]||
       !ownFixtureFence(receipt)||![identity isEqual:dockIdentity(dockPID)]) {result[@"error"]=@"owned title or native process/window fence changed immediately before press";return result;}
    AXError error=AXUIElementPerformAction(entry.element,kAXPressAction);result[@"ax_error"]=@(error);
    result[@"dock_fence_after"]=@([identity isEqual:dockIdentity(dockPID)]);if(error)result[@"error"]=@"owned thumbnail AXPress failed";return result;
}
static NSString *dockItemPath(AXUIElementRef node) {
    CFTypeRef value=NULL;if(AXUIElementCopyAttributeValue(node,kAXURLAttribute,&value)||!value)return @"";
    NSString *path=@"";
    if(CFGetTypeID(value)==CFURLGetTypeID())path=[(__bridge NSURL *)value path];
    else if(CFGetTypeID(value)==CFStringGetTypeID())path=[NSURL URLWithString:(__bridge NSString *)value].path;
    NSString *copy=[path copy];CFRelease(value);return copy?:@"";
}
static void findOwnedDockItems(AXUIElementRef node,unsigned depth,NSString *bundle,NSMutableArray<MCControl *> *items) {
    if(depth>3||visited++>=128||CFAbsoluteTimeGetCurrent()>deadline){truncated=YES;return;}
    NSString *role=stringAttribute(node,kAXRoleAttribute);
    if([role isEqual:@"AXDockItem"]) {
        if(![dockItemPath(node) isEqual:bundle])return;
        CFArrayRef actions=NULL;BOOL show=!AXUIElementCopyActionNames(node,&actions)&&actions&&[(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXShowMenuAction];if(actions)CFRelease(actions);
        MCControl *entry=[MCControl new];entry.element=(AXUIElementRef)CFRetain(node);entry.metadata=@{@"role":role,@"own_app_url":bundle,@"show_menu":@(show)};[items addObject:entry];return;
    }
    if(depth && ![@[@"AXGroup",@"AXList"] containsObject:role])return;
    for(id child in children(node,kAXChildrenAttribute))if(CFGetTypeID((__bridge CFTypeRef)child)==AXUIElementGetTypeID())findOwnedDockItems((__bridge AXUIElementRef)child,depth+1,bundle,items);
}
static void findOverviewItem(AXUIElementRef node,unsigned depth,NSMutableArray<MCControl *> *items) {
    if(depth>4||visited++>=128||CFAbsoluteTimeGetCurrent()>deadline){truncated=YES;return;}
    NSString *role=stringAttribute(node,kAXRoleAttribute);
    if([role isEqual:@"AXMenuItem"]) {
        NSString *title=stringAttribute(node,kAXTitleAttribute);
        if(![@[@"Show All Windows",@"Показать все окна"] containsObject:title])return;
        CFArrayRef actions=NULL;BOOL press=!AXUIElementCopyActionNames(node,&actions)&&actions&&[(__bridge NSArray *)actions containsObject:(__bridge NSString *)kAXPressAction];if(actions)CFRelease(actions);
        MCControl *entry=[MCControl new];entry.element=(AXUIElementRef)CFRetain(node);entry.metadata=@{@"role":role,@"title":title,@"press":@(press)};[items addObject:entry];return;
    }
    if(depth && ![role isEqual:@"AXMenu"])return;
    for(id child in children(node,kAXChildrenAttribute))if(CFGetTypeID((__bridge CFTypeRef)child)==AXUIElementGetTypeID())findOverviewItem((__bridge AXUIElementRef)child,depth+1,items);
}
static NSDictionary *openOwnedOverview(pid_t dockPID,NSString *receiptPath) {
    NSDictionary *receipt=boundedJSON(receiptPath),*identity=dockIdentity(dockPID);
    if(!identity||!ownFixtureFence(receipt)||!AXIsProcessTrusted())return @{@"error":@"fresh owned fixture receipt and Dock AX access required; no prompt"};
    NSString *bundle=[[[receipt[@"executable"] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    AXUIElementRef app=AXUIElementCreateApplication(dockPID);AXUIElementSetMessagingTimeout(app,.2);
    visited=0;truncated=NO;deadline=CFAbsoluteTimeGetCurrent()+3;NSMutableArray<MCControl *> *items=[NSMutableArray new];findOwnedDockItems(app,0,bundle,items);CFRelease(app);
    if(truncated||items.count!=1||![items[0].metadata[@"show_menu"] boolValue]||!ownFixtureFence(receipt)||![identity isEqual:dockIdentity(dockPID)]||![dockItemPath(items[0].element) isEqual:bundle])
        return @{@"error":@"unique exact owned application URL/AXShowMenu/native fences unavailable; no Dock action"};
    AXError menuError=AXUIElementPerformAction(items[0].element,kAXShowMenuAction);
    if(menuError)return @{@"error":@"owned Dock AXShowMenu failed",@"ax_error":@(menuError)};
    NSMutableArray<MCControl *> *overview=[NSMutableArray new];
    for(unsigned attempt=0;attempt<10;attempt++) {
        visited=0;truncated=NO;deadline=CFAbsoluteTimeGetCurrent()+.5;[overview removeAllObjects];
        // Never search another Dock item/root menu: ownership is this item only.
        findOverviewItem(items[0].element,0,overview);if(overview.count||truncated)break;usleep(50000);
    }
    if(truncated||overview.count!=1||![overview[0].metadata[@"press"] boolValue]||!ownFixtureFence(receipt)||![identity isEqual:dockIdentity(dockPID)]||![dockItemPath(items[0].element) isEqual:bundle])
        return @{@"error":@"Show All Windows is not uniquely linked beneath the exact owned Dock item; no overview AXPress",@"owned_menu_opened":@YES,@"own_app_url":bundle};
    if(![stringAttribute(overview[0].element,kAXRoleAttribute) isEqual:@"AXMenuItem"]||![stringAttribute(overview[0].element,kAXTitleAttribute) isEqual:overview[0].metadata[@"title"]])
        return @{@"error":@"owned overview menu item changed immediately before press",@"owned_menu_opened":@YES};
    AXError error=AXUIElementPerformAction(overview[0].element,kAXPressAction);
    NSMutableDictionary *result=[@{@"mode":@"open-owned-overview",@"dock":identity,@"own_target":receipt,@"own_app_url":bundle,@"control":overview[0].metadata,@"ax_error":@(error),@"dock_fence_after":@([identity isEqual:dockIdentity(dockPID)]),@"selection_claim":@NO} mutableCopy];
    if(error)result[@"error"]=@"owned overview AXPress failed";return result;
}
// Creation provenance is stronger than a historical empty-space number: the
// captured native before/after arrays must have exactly one newly appended
// ordinary Space, while every original display/Space identity remains intact.
static NSDictionary *createdSpaceProof(NSDictionary *create,NSDictionary *fresh) {
    if(![create[@"control"] isKindOfClass:NSDictionary.class] ||
       ![create[@"before_spaces"] isKindOfClass:NSDictionary.class] || ![create[@"after_spaces"] isKindOfClass:NSDictionary.class] ||
       ![create[@"ax_error"] isKindOfClass:NSNumber.class] || ![create[@"mode"] isEqual:@"press"] || [create[@"ax_error"] intValue] ||
       ![create[@"dock_fence_after"] boolValue] || ![create[@"control"][@"identifier"] isEqual:@"mc.spaces.add"] ||
       ![create[@"before_spaces"][@"displays"] isKindOfClass:NSArray.class] ||
       ![create[@"after_spaces"][@"displays"] isKindOfClass:NSArray.class] || fresh[@"error"])return nil;
    NSArray *before=create[@"before_spaces"][@"displays"],*after=create[@"after_spaces"][@"displays"],*current=fresh[@"displays"];
    if(![current isKindOfClass:NSArray.class]||before.count!=after.count||after.count!=current.count)return nil;
    NSDictionary *owned=nil;unsigned additions=0;
    for(NSUInteger d=0;d<before.count;d++) {
        NSDictionary *b=before[d],*a=after[d],*f=current[d];
        if(![b isKindOfClass:NSDictionary.class]||![a isKindOfClass:NSDictionary.class]||![f isKindOfClass:NSDictionary.class])return nil;
        if(![b[@"display"] isKindOfClass:NSString.class]||![b[@"display"] isEqual:a[@"display"]]||![a[@"display"] isEqual:f[@"display"]])return nil;
        NSArray *bs=b[@"spaces"],*as=a[@"spaces"],*fs=f[@"spaces"];
        if(![bs isKindOfClass:NSArray.class]||![as isKindOfClass:NSArray.class]||![as isEqual:fs])return nil;
        if([bs isEqual:as])continue;
        if(as.count!=bs.count+1||![[as subarrayWithRange:NSMakeRange(0,bs.count)] isEqual:bs])return nil;
        NSDictionary *s=as.lastObject;if(![s isKindOfClass:NSDictionary.class])return nil;
        uint64_t sid=[s[@"id64"] unsignedLongLongValue];NSString *uuid=s[@"uuid"]?:s[@"UUID"];
        if(!sid||![s[@"type"] isKindOfClass:NSNumber.class]||[s[@"type"] intValue]!=0||![uuid isKindOfClass:NSString.class]||!uuid.length||
           (s[@"ManagedSpaceID"] && [s[@"ManagedSpaceID"] unsignedLongLongValue]!=sid))return nil;
        unsigned ordinal=0;
        for(NSDictionary *entry in as) {if(![entry isKindOfClass:NSDictionary.class])return nil;if([entry[@"type"] intValue]==0)ordinal++;if(entry!=s && ([entry[@"id64"] unsignedLongLongValue]==sid||[(entry[@"uuid"]?:entry[@"UUID"]) isEqual:uuid]))return nil;}
        owned=@{@"display":a[@"display"],@"space_id":@(sid),@"space_uuid":uuid,@"ordinal":@(ordinal),@"type":@0};additions++;
    }
    return additions==1?owned:nil;
}
static NSDictionary *selectCreated(pid_t pid,NSString *createPath,NSString *receiptPath) {
    NSDictionary *create=boundedJSON(createPath),*expected=boundedJSON(receiptPath),*identity=dockIdentity(pid);
    double now=CFAbsoluteTimeGetCurrent();
    if(!create||!expected||![create[@"dock"] isEqual:identity]||![expected[@"dock"] isEqual:identity]||
       ![expected[@"mode"] isEqual:@"inspect"]||![expected[@"time"] isKindOfClass:NSNumber.class]||
       now-[expected[@"time"] doubleValue]>60||now<[expected[@"time"] doubleValue]||[expected[@"truncated"] boolValue])
        return @{@"error":@"fresh inspection and exact original Dock creation receipt required"};
    NSDictionary *before=spaceSnapshot(),*owned=createdSpaceProof(create,before);
    if(!owned)return @{@"error":@"created ordinary Space identity/ordinal or retained native Space arrays changed"};
    // The actual localized control shape on this host was inspected by root.
    // No arbitrary descriptions, generic Desktop names, or thumbnail branches.
    NSString *description=[NSString stringWithFormat:@"выйти на Рабочий стол %@",owned[@"ordinal"]];
    NSDictionary *row=@{@"identifier":@"",@"role":@"AXButton",@"description":description,@"press":@YES};
    NSArray *expectedMatches=[expected[@"controls"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id entry,NSDictionary *bindings){(void)bindings;return [entry isEqual:row];}]];
    NSDictionary *inspection=inspect(pid);NSMutableArray<MCControl *> *matches=[NSMutableArray new];
    for(MCControl *entry in controls)if([entry.metadata isEqual:row])[matches addObject:entry];
    if(expectedMatches.count!=1||matches.count!=1||inspection[@"error"]||[inspection[@"truncated"] boolValue]||![identity isEqual:dockIdentity(pid)])
        return @{@"error":@"exact created Desktop spaces-bar button missing, changed or ambiguous"};
    NSDictionary *fence=spaceSnapshot();
    if(![owned isEqual:createdSpaceProof(create,fence)]||![identity isEqual:dockIdentity(pid)]||
       ![stringAttribute(matches[0].element,kAXIdentifierAttribute) isEqual:@""]||
       ![stringAttribute(matches[0].element,kAXRoleAttribute) isEqual:@"AXButton"]||
       ![stringAttribute(matches[0].element,kAXDescriptionAttribute) isEqual:description])
        return @{@"error":@"final exact control/native created Space fence changed; no AXPress"};
    AXError error=AXUIElementPerformAction(matches[0].element,kAXPressAction);
    NSDictionary *after=spaceSnapshot();unsigned stable=0,samples=0;BOOL currentAck=NO;
    double started=CFAbsoluteTimeGetCurrent();
    while(!error && CFAbsoluteTimeGetCurrent()-started<3) {
        samples++;
        BOOL onDisplay=NO;
        for(NSDictionary *display in after[@"displays"])
            if([display[@"display"] isEqual:owned[@"display"]] && [display[@"current"] isEqual:owned[@"space_id"]])onDisplay=YES;
        BOOL exact=onDisplay && [after[@"active"] isEqual:owned[@"space_id"]] &&
            [owned isEqual:createdSpaceProof(create,after)] && [identity isEqual:dockIdentity(pid)];
        stable=exact?stable+1:0;
        if(stable>=3){currentAck=YES;break;}
        if(![identity isEqual:dockIdentity(pid)]||!createdSpaceProof(create,after))break;
        usleep(50000);after=spaceSnapshot();
    }
    NSMutableDictionary *result=[@{@"mode":@"select-created",@"dock":identity,@"created_space":owned,@"control":row,
        @"ax_error":@(error),@"before_spaces":fence,@"after_spaces":after,
        @"native_current_ack":@(currentAck),@"native_ack_samples":@(samples),@"native_ack_elapsed_ms":@((CFAbsoluteTimeGetCurrent()-started)*1000),
        @"dock_fence_after":@([identity isEqual:dockIdentity(pid)])} mutableCopy];
    if(error)result[@"error"]=@"AXPress failed";
    else if(!currentAck)result[@"error"]=@"single AXPress did not yield stable exact native created-Space current ACK; no repeated action performed";
    return result;
}
// Select one already-observed ordinary desktop to exit Mission Control. Unlike
// selectCreated this accepts the original desktop with an explicitly empty UUID.
// It never derives a native SID from the localized desktop number.
static NSDictionary *typedGeometry(AXUIElementRef node) {
    NSMutableDictionary *result=[NSMutableDictionary new];CFArrayRef names=NULL;
    AXError listError=AXUIElementCopyAttributeNames(node,&names);result[@"attribute_names_error"]=@(listError);
    if(names){if(CFArrayGetCount(names)<=64)result[@"attribute_names"]=[(__bridge NSArray *)names copy];else result[@"attribute_names_truncated"]=@YES;CFRelease(names);}
    for(NSString *name in @[@"AXPosition",@"AXSize",@"AXFrame"]) {
        CFTypeRef value=NULL;AXError error=AXUIElementCopyAttributeValue(node,(__bridge CFStringRef)name,&value);
        NSMutableDictionary *row=[@{@"ax_error":@(error),@"cf_type":value?@(CFGetTypeID(value)):NSNull.null} mutableCopy];
        if(value&&CFGetTypeID(value)==AXValueGetTypeID()) {
            AXValueType type=AXValueGetType((AXValueRef)value);row[@"ax_value_type"]=@(type);
            CGPoint point;CGSize size;CGRect frame;
            if(type==kAXValueCGPointType&&AXValueGetValue((AXValueRef)value,type,&point)&&isfinite(point.x)&&isfinite(point.y))row[@"point"]=@[@(point.x),@(point.y)];
            else if(type==kAXValueCGSizeType&&AXValueGetValue((AXValueRef)value,type,&size)&&isfinite(size.width)&&isfinite(size.height))row[@"size"]=@[@(size.width),@(size.height)];
            else if(type==kAXValueCGRectType&&AXValueGetValue((AXValueRef)value,type,&frame)&&isfinite(frame.origin.x)&&isfinite(frame.origin.y)&&isfinite(frame.size.width)&&isfinite(frame.size.height))row[@"rect"]=@[@(frame.origin.x),@(frame.origin.y),@(frame.size.width),@(frame.size.height)];
        }
        if(value)CFRelease(value);result[name]=row;
    }
    return result;
}
static NSDictionary *focusedApplicationIdentity(void) {
    // AXFocusedApplication transiently reports cannotComplete even when the
    // native foreground process is known. Read that public process directly,
    // then retain the same exact uid/birth/executable fences below.
    ProcessSerialNumber psn={0,0};pid_t pid=0;
    if(GetFrontProcess(&psn)||GetProcessPID(&psn,&pid)||pid<=0)return nil;
    struct proc_bsdinfo info={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof info)!=sizeof info||info.pbi_uid!=getuid()||!info.pbi_start_tvsec||proc_pidpath(pid,path,sizeof path)<=0)return nil;
    return @{@"pid":@(pid),@"uid":@(info.pbi_uid),@"sec":@(info.pbi_start_tvsec),@"usec":@(info.pbi_start_tvusec),@"path":@(path)};
}
static NSDictionary *waitOrdinaryNative(NSDictionary *base,NSDictionary *identity,pid_t pid,id sid,double deadline) {
    NSArray *displays=base[@"displays"];NSDictionary *display=displays[0];unsigned stable=0,samples=0;
    NSMutableArray *readbacks=[NSMutableArray new];NSDictionary *after=nil;BOOL ack=NO;
    while(CFAbsoluteTimeGetCurrent()<deadline) {
        after=spaceSnapshot();NSArray *fresh=after[@"displays"];samples++;
        BOOL topology=[fresh isKindOfClass:NSArray.class]&&fresh.count==1&&[fresh[0][@"display"] isEqual:display[@"display"]]&&[fresh[0][@"spaces"] isEqual:display[@"spaces"]]&&[identity isEqual:dockIdentity(pid)];
        BOOL exact=topology&&[after[@"active"] isEqual:sid]&&[fresh[0][@"current"] isEqual:sid];
        if(readbacks.count<24)[readbacks addObject:@{@"active":after[@"active"]?:NSNull.null,@"current":fresh.count==1?(fresh[0][@"current"]?:NSNull.null):NSNull.null,@"exact":@(exact)}];
        stable=exact?stable+1:0;if(stable>=3){ack=YES;break;}if(!topology)break;
        SInt32 run=CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);if(run==kCFRunLoopRunFinished||run==kCFRunLoopRunStopped)usleep(50000);
    }
    return @{@"acknowledged":@(ack),@"sid":sid,@"samples":@(samples),@"readbacks":readbacks,@"after_spaces":after?:NSNull.null};
}
// Retained Dock AX controls do not establish whether Mission Control is
// visible. Observe only native Dock surfaces, without titles or coordinates.
static int visibleDockOverview(pid_t pid) {
    CGDirectDisplayID displays[16];uint32_t count=0;
    if(CGGetActiveDisplayList(16,displays,&count)!=kCGErrorSuccess||!count||count>16)return -1;
    CFArrayRef native=CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
    if(!native)return -1;NSArray *rows=CFBridgingRelease(native);if(rows.count>8192)return -1;
    for(NSDictionary *row in rows) {
        if([row[(id)kCGWindowOwnerPID] intValue]!=pid||![row[(id)kCGWindowIsOnscreen] boolValue]||
           [row[(id)kCGWindowLayer] intValue]<0||[row[(id)kCGWindowAlpha] doubleValue]<=0)continue;
        CGRect box=CGRectZero;
        if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&box))return -1;
        for(uint32_t n=0;n<count;n++) {
            CGRect screen=CGDisplayBounds(displays[n]);
            if(fabs(box.origin.x-screen.origin.x)<=2&&fabs(box.origin.y-screen.origin.y)<=2&&
               fabs(box.size.width-screen.size.width)<=2&&fabs(box.size.height-screen.size.height)<=2)return 1;
        }
    }
    return 0;
}
static BOOL waitDockOverview(BOOL visible,NSDictionary *base,NSDictionary *identity,pid_t pid,double end) {
    unsigned stable=0;
    while(CFAbsoluteTimeGetCurrent()<end) {
        if(![identity isEqual:dockIdentity(pid)]||![base isEqual:spaceSnapshot()])return NO;
        int value=visibleDockOverview(pid);if(value<0)return NO;
        stable=value==(visible?1:0)?stable+1:0;if(stable>=(visible?8:4))return YES;
        SInt32 run=CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);
        if(run==kCFRunLoopRunFinished||run==kCFRunLoopRunStopped)usleep(50000);
    }
    return NO;
}
static NSDictionary *selectOrdinary(pid_t pid,NSString *targetPath,NSString *receiptPath) {
    NSDictionary *request=boundedJSON(targetPath),*expected=boundedJSON(receiptPath),*identity=dockIdentity(pid);
    NSDictionary *target=request[@"target"],*snapshot=request[@"snapshot"];
    double now=CFAbsoluteTimeGetCurrent();
    if(!identity||![request[@"dock"] isEqual:identity]||![target isKindOfClass:NSDictionary.class]||
       ![snapshot isKindOfClass:NSDictionary.class]||![target[@"display"] isKindOfClass:NSString.class]||
       ![target[@"uuid"] isKindOfClass:NSString.class]||[target[@"uuid"] length]>128||
       ![target[@"sid"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)target[@"sid"])==CFBooleanGetTypeID()||
       strchr("fd",[target[@"sid"] objCType][0])||![target[@"sid"] unsignedLongLongValue]||[target[@"sid"] unsignedLongLongValue]>=(1ULL<<53)||
       ![target[@"type"] isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)target[@"type"])==CFBooleanGetTypeID()||
       strchr("fd",[target[@"type"] objCType][0])||[target[@"type"] intValue]!=0||
       ![expected[@"dock"] isEqual:identity]||![expected[@"mode"] isEqual:@"inspect"]||
       ![expected[@"controls"] isKindOfClass:NSArray.class]||![expected[@"time"] isKindOfClass:NSNumber.class]||
       now-[expected[@"time"] doubleValue]>60||now<[expected[@"time"] doubleValue]||[expected[@"truncated"] boolValue])
        return @{@"error":@"exact ordinary target/native snapshot and fresh Dock inspection required"};
    NSDictionary *before=spaceSnapshot();NSArray *displays=before[@"displays"];
    if(![before isEqual:snapshot]||![displays isKindOfClass:NSArray.class]||displays.count!=1)
        return @{@"error":@"single-display exact ordinary Space snapshot changed; no AXPress"};
    NSDictionary *display=displays[0];NSArray *spaces=display[@"spaces"];unsigned ordinal=0,matchesNative=0;
    if(![display[@"display"] isEqual:target[@"display"]]||![spaces isKindOfClass:NSArray.class]||spaces.count>64)
        return @{@"error":@"target display differs from fresh bounded native list"};
    for(NSDictionary *space in spaces) {
        if(![space isKindOfClass:NSDictionary.class]||![space[@"type"] isKindOfClass:NSNumber.class])
            return @{@"error":@"invalid native Space metadata"};
        if([space[@"type"] intValue]!=0)continue;
        ordinal++;
        if([(space[@"id64"]?:space[@"ManagedSpaceID"]) isEqual:target[@"sid"]]) {
            if(![(space[@"uuid"]?:space[@"UUID"]) isEqual:target[@"uuid"]]||
               (space[@"ManagedSpaceID"]&&![space[@"ManagedSpaceID"] isEqual:target[@"sid"]]))
                return @{@"error":@"ordinary target UUID/native identity alias changed"};
            matchesNative++;
            break;
        }
    }
    if(matchesNative!=1||ordinal<1||ordinal>10)return @{@"error":@"exact ordinary target unavailable or outside supported ordinals"};
    NSString *description=[NSString stringWithFormat:@"выйти на Рабочий стол %u",ordinal];
    NSDictionary *row=@{@"identifier":@"",@"role":@"AXButton",@"description":description,@"press":@YES};
    NSArray *expectedMatches=[expected[@"controls"] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id entry,NSDictionary *bindings){(void)bindings;return [entry isEqual:row];}]];
    if(!waitDockOverview(YES,before,identity,pid,CFAbsoluteTimeGetCurrent()+2))
        return @{@"error":@"Mission Control did not visibly settle on the exact source Space; no Desktop AXPress"};
    NSDictionary *inspection=inspect(pid);NSMutableArray<MCControl *> *matches=[NSMutableArray new];
    for(MCControl *entry in controls)if([entry.metadata isEqual:row])[matches addObject:entry];
    if(expectedMatches.count!=1||matches.count!=1||inspection[@"error"]||[inspection[@"truncated"] boolValue]||
       ![identity isEqual:dockIdentity(pid)]||![before isEqual:spaceSnapshot()]||
       ![stringAttribute(matches[0].element,kAXIdentifierAttribute) isEqual:@""]||
       ![stringAttribute(matches[0].element,kAXRoleAttribute) isEqual:@"AXButton"]||
       ![stringAttribute(matches[0].element,kAXDescriptionAttribute) isEqual:description]||![identity isEqual:dockIdentity(pid)])
        return @{@"error":@"exact ordinary Desktop control/native final fence changed; no AXPress"};
    AXError error=AXUIElementPerformAction(matches[0].element,kAXPressAction);
    NSDictionary *after=spaceSnapshot();unsigned stable=0,samples=0;BOOL ack=NO;double started=CFAbsoluteTimeGetCurrent();
    NSMutableArray *readbacks=[NSMutableArray new];
    while(!error&&CFAbsoluteTimeGetCurrent()-started<3) {
        samples++;NSArray *fresh=after[@"displays"];
        BOOL exact=[fresh isKindOfClass:NSArray.class]&&fresh.count==1&&
            [fresh[0][@"display"] isEqual:display[@"display"]]&&[fresh[0][@"spaces"] isEqual:spaces]&&
            [fresh[0][@"current"] isEqual:target[@"sid"]]&&[after[@"active"] isEqual:target[@"sid"]]&&[identity isEqual:dockIdentity(pid)]&&visibleDockOverview(pid)==0;
        if(readbacks.count<64)[readbacks addObject:@{@"elapsed_ms":@((CFAbsoluteTimeGetCurrent()-started)*1000),
            @"active":after[@"active"]?:NSNull.null,@"current":fresh.count==1?(fresh[0][@"current"]?:NSNull.null):NSNull.null,
            @"exact":@(exact)}];
        stable=exact?stable+1:0;if(stable>=3){ack=YES;break;}
        if(![identity isEqual:dockIdentity(pid)]||![fresh isKindOfClass:NSArray.class]||fresh.count!=1||![fresh[0][@"spaces"] isEqual:spaces])break;
        // AXPress and the client SkyLight connection both deliver asynchronous
        // work. A sleeping main thread cannot drain their run-loop sources.
        // Pump ONLY this helper's normal run loop, never a target process.
        SInt32 run=CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);
        if(run==kCFRunLoopRunFinished||run==kCFRunLoopRunStopped)usleep(50000);
        after=spaceSnapshot();
    }
    NSMutableDictionary *result=[@{@"mode":@"select-ordinary",@"dock":identity,@"target":target,@"control":row,
        @"ax_error":@(error),@"before_spaces":before,@"after_spaces":after,@"native_current_ack":@(ack),
        @"native_ack_samples":@(samples),@"native_ack_elapsed_ms":@((CFAbsoluteTimeGetCurrent()-started)*1000),
        @"native_readbacks":readbacks,@"poll_runloop_pumped":@YES,
        @"selection_action":@"AXPress",@"overview_closed_ack":@(ack),
        @"dock_fence_after":@([identity isEqual:dockIdentity(pid)])} mutableCopy];
    if(error)result[@"error"]=@"ordinary Desktop AXPress failed";
    else if(!ack)result[@"error"]=@"single ordinary Desktop public action did not yield exact stable native ACK";
    return result;
}
static NSDictionary *createdOccupancy(pid_t pid,NSString *createPath) {
    NSDictionary *create=boundedJSON(createPath),*identity=dockIdentity(pid),*before=spaceSnapshot();
    NSDictionary *owned=createdSpaceProof(create,before);
    if(!identity||![create[@"dock"] isEqual:identity]||!owned)return @{@"error":@"exact original Dock and created native Space receipt required"};
    void *lib=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW|RTLD_LOCAL);
    int (*cidFn)(void)=lib?dlsym(lib,"SLSMainConnectionID"):NULL;
    CFArrayRef (*copy)(int,uint32_t,CFArrayRef,uint32_t,uint64_t *,uint64_t *)=lib?dlsym(lib,"SLSCopyWindowsWithOptionsAndTags"):NULL;
    int (*ownerFn)(int,uint32_t,int *)=lib?dlsym(lib,"SLSGetWindowOwner"):NULL;
    int (*pidFn)(int,pid_t *)=lib?dlsym(lib,"SLSConnectionGetPID"):NULL;
    int (*levelFn)(int,uint32_t,int *)=lib?dlsym(lib,"SLSGetWindowLevel"):NULL;
    if(!cidFn||!copy||!ownerFn||!pidFn||!levelFn)return @{@"error":@"native full-Space window metadata APIs unavailable"};
    int cid=cidFn();uint64_t set=0,clear=0;
    // Server RE: bit0 includes allocated/offscreen windows, bit1 sticky,
    // bit4 disables default tag4 exclusion, bit5 includes native proxy windows,
    // bit3 their associated source WID, bit9 super-sticky. No tags,
    // owner, level, tiling, alpha, AX, or onscreen filtering narrows occupancy.
    CFArrayRef raw=copy(cid,0,(__bridge CFArrayRef)@[owned[@"space_id"]],0x23f,&set,&clear);
    if(!raw)return @{@"error":@"native created-Space occupancy unavailable"};
    NSArray *windows=CFBridgingRelease(raw);
    if(![windows isKindOfClass:NSArray.class]||windows.count>512)return @{@"error":@"native occupancy malformed or over bounded512 windows"};
    NSMutableArray *occupants=[NSMutableArray new];BOOL complete=YES;
    for(id number in windows) {
        if(![number isKindOfClass:NSNumber.class]||![number unsignedIntValue]){complete=NO;continue;}
        uint32_t wid=[number unsignedIntValue];int owner=0,level=0;pid_t ownerPID=0;
        BOOL valid=!ownerFn(cid,wid,&owner)&&!pidFn(owner,&ownerPID)&&ownerPID>0&&!levelFn(cid,wid,&level);
        NSMutableDictionary *row=[@{@"wid":@(wid),@"owner_known":@(valid),@"owner_cid":@(owner),@"pid":@(ownerPID),@"level":@(level)} mutableCopy];
        if(valid) {
            struct proc_bsdinfo info={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};
            if(proc_pidinfo(ownerPID,PROC_PIDTBSDINFO,0,&info,sizeof info)==sizeof info && info.pbi_start_tvsec && proc_pidpath(ownerPID,path,sizeof path)>0)
                row[@"owner_identity"]=@{@"pid":@(ownerPID),@"uid":@(info.pbi_uid),@"start_sec":@(info.pbi_start_tvsec),@"start_usec":@(info.pbi_start_tvusec),@"path":@(path)};
            else complete=NO;
        } else complete=NO;
        [occupants addObject:row];
    }
    NSDictionary *after=spaceSnapshot();BOOL fenced=[identity isEqual:dockIdentity(pid)]&&[owned isEqual:createdSpaceProof(create,after)];
    NSMutableDictionary *result=[@{@"mode":@"created-occupancy",@"dock":identity,@"created_space":owned,@"options":@0x23f,
        @"occupants":occupants,@"complete":@(complete&&fenced),@"empty":@(complete&&fenced&&!windows.count),
        @"before_spaces":before,@"after_spaces":after,@"time":@(CFAbsoluteTimeGetCurrent()),@"removal_authorized":@NO} mutableCopy];
    if(!complete||!fenced)result[@"error"]=@"native occupancy identity/Space fence incomplete; no removal authorization";
    return result;
}
static int emit(NSDictionary *result) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:NULL];
    if (!data) return 3;
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
    return result[@"error"] ? 1 : 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    if(argc==3&&!strcmp(argv[1],"--overview-state")) {
        pid_t pid=(pid_t)strtol(argv[2],NULL,10);NSDictionary *identity=dockIdentity(pid);
        int visible=identity?visibleDockOverview(pid):-1;
        return emit(visible<0?@{@"error":@"exact Dock overview visibility unavailable"}:@{@"mode":@"overview-state",@"dock":identity,@"visible":@(visible==1)});
    }
    if(argc==7&&!strcmp(argv[1],"--select-ordinary")&&!strcmp(argv[3],"--target")&&!strcmp(argv[5],"--receipt"))
        return emit(selectOrdinary((pid_t)strtol(argv[2],NULL,10),@(argv[4]),@(argv[6])));
    if(argc==5&&!strcmp(argv[1],"--open-owned-overview")&&!strcmp(argv[3],"--fixture-receipt"))
        return emit(openOwnedOverview((pid_t)strtol(argv[2],NULL,10),@(argv[4])));
    if(argc==5&&!strcmp(argv[1],"--inspect-owned-thumbnail")&&!strcmp(argv[3],"--fixture-receipt"))
        return emit(inspectOwnedThumbnail((pid_t)strtol(argv[2],NULL,10),@(argv[4]),NO,nil));
    if(argc==7&&!strcmp(argv[1],"--press-owned-thumbnail")&&!strcmp(argv[3],"--fixture-receipt")&&!strcmp(argv[5],"--receipt"))
        return emit(inspectOwnedThumbnail((pid_t)strtol(argv[2],NULL,10),@(argv[4]),YES,@(argv[6])));
    if(argc==5&&!strcmp(argv[1],"--created-occupancy")&&!strcmp(argv[3],"--create"))
        return emit(createdOccupancy((pid_t)strtol(argv[2],NULL,10),@(argv[4])));
    if(argc==7&&!strcmp(argv[1],"--select-created")&&!strcmp(argv[3],"--create")&&!strcmp(argv[5],"--receipt"))
        return emit(selectCreated((pid_t)strtol(argv[2],NULL,10),@(argv[4]),@(argv[6])));
    if (argc==2 && !strcmp(argv[1],"--spaces")) return emit(spaceSnapshot());
    if (argc==3 && !strcmp(argv[1],"--inspect")) return emit(inspect((pid_t)strtol(argv[2],NULL,10)));
    if(argc==3&&!strcmp(argv[1],"--inspect-actions")){inspectSpaceActions=YES;return emit(inspect((pid_t)strtol(argv[2],NULL,10)));}
    if(argc==3&&!strcmp(argv[1],"--inspect-thumbnail-identifiers")){inspectThumbnailIdentifiers=YES;return emit(inspect((pid_t)strtol(argv[2],NULL,10)));}
    if (argc==6 && !strcmp(argv[1],"--press") && !strcmp(argv[4],"--receipt")) {
        pid_t pid=(pid_t)strtol(argv[2],NULL,10); NSString *identifier=@(argv[3]);
        NSData *data=[NSData dataWithContentsOfFile:@(argv[5])];
        if (!data || data.length>262144 || !identifier.length) return emit(@{@"error": @"invalid bounded inspection receipt/identifier"});
        id expected=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![expected isKindOfClass:NSDictionary.class] || ![expected[@"mode"] isEqual:@"inspect"] ||
            ![expected[@"controls"] isKindOfClass:NSArray.class] || ![expected[@"time"] isKindOfClass:NSNumber.class] ||
            CFAbsoluteTimeGetCurrent()-[expected[@"time"] doubleValue] > 60 ||
            CFAbsoluteTimeGetCurrent() < [expected[@"time"] doubleValue] ||
            [expected[@"truncated"] boolValue] || ![expected[@"dock"] isEqual:dockIdentity(pid)])
            return emit(@{@"error": @"fresh exact Dock inspection birth/path receipt required"});
        NSDictionary *fresh=inspect(pid);
        if (fresh[@"error"] || [fresh[@"truncated"] boolValue]) return emit(@{@"error": @"complete fresh spaces-bar inspection unavailable"});
        NSMutableArray<MCControl *> *matches=[NSMutableArray new];
        for (MCControl *entry in controls) if ([entry.metadata[@"identifier"] isEqual:identifier]) [matches addObject:entry];
        NSArray *expectedMatches=[expected[@"controls"] filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
                (void)bindings; return [row[@"identifier"] isEqual:identifier];
            }]];
        if (matches.count!=1 || expectedMatches.count!=1 || ![matches[0].metadata isEqual:expectedMatches[0]] ||
            ![matches[0].metadata[@"press"] boolValue] || ![fresh[@"dock"] isEqual:dockIdentity(pid)])
            return emit(@{@"error": @"identifier/action is missing, changed or ambiguous; no AX action performed"});
        NSDictionary *before=spaceSnapshot();
        if (before[@"error"] || ![fresh[@"dock"] isEqual:dockIdentity(pid)])
            return emit(@{@"error": @"native Space snapshot or final Dock fence failed; no AX action performed"});
        if ([identifier isEqual:@"mc.spaces.add"] &&
            !waitDockOverview(YES,before,fresh[@"dock"],pid,CFAbsoluteTimeGetCurrent()+2))
            return emit(@{@"error":@"Mission Control did not visibly settle on the exact original Space; no add AXPress"});
        if (![stringAttribute(matches[0].element,kAXIdentifierAttribute) isEqual:identifier] ||
            ![stringAttribute(matches[0].element,kAXRoleAttribute) isEqual:matches[0].metadata[@"role"]] ||
            ![fresh[@"dock"] isEqual:dockIdentity(pid)])
            return emit(@{@"error": @"exact control or Dock birth changed immediately before AXPress"});
        AXError error=AXUIElementPerformAction(matches[0].element,kAXPressAction);
        NSDictionary *after=spaceSnapshot();
        NSMutableDictionary *result=[@{@"mode": @"press", @"dock": fresh[@"dock"], @"control": matches[0].metadata,
            @"ax_error": @(error), @"before_spaces": before, @"after_spaces": after,
            @"dock_fence_after": @([fresh[@"dock"] isEqual:dockIdentity(pid)])} mutableCopy];
        if (error) result[@"error"]=@"AXPress failed";
        return emit(result);
    }
    fputs("--inspect DOCK_PID | --inspect-actions DOCK_PID | --inspect-thumbnail-identifiers DOCK_PID | --inspect-owned-thumbnail DOCK_PID --fixture-receipt own.json | --press-owned-thumbnail DOCK_PID --fixture-receipt own.json --receipt inspect.json | --open-owned-overview DOCK_PID --fixture-receipt own.json | --press DOCK_PID EXACT_AXIdentifier --receipt inspect.json | --select-created DOCK_PID --create create.json --receipt fresh-inspect.json | --created-occupancy DOCK_PID --create create.json | --spaces\n",stdout);
    return argc==2 && !strcmp(argv[1],"--help") ? 0 : 2;
} }
