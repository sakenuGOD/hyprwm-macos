#import "RepresentationNative.h"
#import <mach-o/dyld.h>
#import <libproc.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/proc_info.h>
#import <fcntl.h>
#import <unistd.h>
#import <math.h>
#import <notify.h>
#ifdef HYPR_FIRST_MAP
#import "admission.h"
#import "grant.h"
static BOOL firstMapOwned;
static int firstMapResult;
#endif

// No constructor, +load, app creation, activation, input, command proxies, or dlclose.
// The existing retained-handle loader invokes the ten-argument entry on actual main.
static BOOL externalFirstMap;
static NSMenu *root;
static NSArray *headings,*viewRecords;
static NSDictionary *identity;
static uint32_t lease;
static NSString *capability,*endpoint,*endpointDirectory,*moduleUUID,*lastError;
static NSMutableArray *observers;
static BOOL enabled,staged,installed,tripped,popupPending,snapshotQueued,applying;
static NSUInteger epoch,callbacks,depth,maxDepth,windowCallbacks;
static uint32_t inactivePublishes,appliedPublishes,inactiveAppliedPublishes,refusedPublishes;
static uint32_t nativeReentries,applyReentries;
static BOOL lastPublishAppActive,lastPublishWorkspaceActive,lastPublishApplied;
static id ownedGroupingImpl;
static NSTimeInterval windowStart;
static dispatch_queue_t ioQueue;
static dispatch_source_t acceptSource;
static NSMutableSet *connections;
static int listenFD=-1;
static dev_t socketDevice;static ino_t socketInode;
static void Publish(id object,SEL selector);
static NSDictionary *Snapshot(BOOL privateReply);
static void ScheduleSnapshot(void);
static BOOL Off(void);
static void CountPublish(BOOL appActive,BOOL workspaceActive,BOOL applied){
    BOOL inactive=!(appActive&&workspaceActive);
    if(inactive&&inactivePublishes<UINT32_MAX)inactivePublishes++;
    if(applied&&appliedPublishes<UINT32_MAX)appliedPublishes++;
    if(inactive&&applied&&inactiveAppliedPublishes<UINT32_MAX)inactiveAppliedPublishes++;
    if(!applied&&refusedPublishes<UINT32_MAX)refusedPublishes++;
    lastPublishAppActive=appActive;lastPublishWorkspaceActive=workspaceActive;lastPublishApplied=applied;
}
static NSDictionary *PublishDiagnostics(void){
    return @{@"schema":@1,@"inactive":@(inactivePublishes),@"applied":@(appliedPublishes),@"inactive_applied":@(inactiveAppliedPublishes),@"refused":@(refusedPublishes),@"last_app_active":@(lastPublishAppActive),@"last_workspace_active":@(lastPublishWorkspaceActive),@"last_applied":@(lastPublishApplied),@"native_reentries":@(nativeReentries),@"apply_reentries":@(applyReentries)};
}

static Method OwnedMethod(Class cls,SEL selector){unsigned count=0;Method found=NULL;Method *items=class_copyMethodList(cls,&count);for(unsigned n=0;n<count;n++)if(method_getName(items[n])==selector){found=items[n];break;}free(items);return found;}
static NSString *RandomToken(void){uint8_t bytes[32];arc4random_buf(bytes,sizeof(bytes));NSMutableString *s=[NSMutableString new];for(unsigned n=0;n<sizeof(bytes);n++)[s appendFormat:@"%02x",bytes[n]];return s;}
static NSDictionary *Identity(void){struct proc_bsdinfo b={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&b,sizeof(b))!=sizeof(b)||proc_pidpath(getpid(),path,sizeof(path))<=0)return nil;NSString *uuid=ImageUUID((const struct mach_header_64*)_dyld_get_image_header(0));return uuid?@{@"pid":@(getpid()),@"uid":@(b.pbi_uid),@"birth_sec":@(b.pbi_start_tvsec),@"birth_usec":@(b.pbi_start_tvusec),@"executable":@(path),@"main_uuid":uuid}:nil;}
static BOOL Active(void){return NSApp && NSApp.active && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==getpid();}
static BOOL SameIdentity(void){return identity && [identity isEqual:Identity()];}
static BOOL HooksOwned(void){return installed && OwnedMethod(NSClassFromString(@"NSMenuBarImpl"),method_getName(publishMethod))==publishMethod && method_getImplementation(publishMethod)==(IMP)Publish;}
// NSMenuBarReplicantWindow's convertRectToScreen: adds only X on this qualified
// AppKit. Translate its window-base rect explicitly to the Cocoa screen space
// used by NSScreen and popUpMenuPositioningItem:atLocation:inView:nil.
static BOOL ReplicantCocoaRect(NSRect local,NSRect window,NSRect screen,NSRect *result){
    CGFloat values[]={local.origin.x,local.origin.y,local.size.width,local.size.height,window.origin.x,window.origin.y,window.size.width,window.size.height,screen.origin.x,screen.origin.y,screen.size.width,screen.size.height};
    for(unsigned n=0;n<12;n++)if(!isfinite(values[n]))return NO;
    if(local.size.width<=0||local.size.height<=0||window.size.width<=0||window.size.height<14||window.size.height>64||screen.size.width<=0||screen.size.height<=0)return NO;
    if(!NSContainsRect(NSMakeRect(0,0,window.size.width,window.size.height),local)||!NSContainsRect(screen,window)||fabs(NSMaxY(window)-NSMaxY(screen))>3)return NO;
    NSRect cocoa=NSOffsetRect(local,window.origin.x,window.origin.y);if(!NSContainsRect(screen,cocoa))return NO;
    if(result)*result=cocoa;return YES;
}
static BOOL AppleCocoaRect(NSView *view,NSRect *result){
    NSWindow *window=view.window;Class cls=object_getClass(window);const char *image=cls?class_getImageName(cls):NULL;
    if(cls!=NSClassFromString(@"NSMenuBarReplicantWindow")||!image||![AppKitPath isEqual:@(image)])return NO;
    Method frame=class_getInstanceMethod(cls,@selector(frame)),nativeFrame=class_getInstanceMethod(NSWindow.class,@selector(frame));Dl_info origin={0};
    if(!frame||frame!=nativeFrame)return NO;
    char returns[128]={0};method_getReturnType(frame,returns,sizeof(returns));if(method_getNumberOfArguments(frame)!=2||strcmp(returns,@encode(NSRect)))return NO;
    void *code=ptrauth_strip((void*)method_getImplementation(frame),ptrauth_key_function_pointer);
    if(!dladdr(code,&origin)||!origin.dli_fname||![AppKitPath isEqual:@(origin.dli_fname)]||![AppKitUUID isEqual:ImageUUID(origin.dli_fbase)])return NO;
    NSRect local=[view convertRect:view.bounds toView:nil],windowFrame=window.frame;
    for(NSScreen *screen in NSScreen.screens)if(ReplicantCocoaRect(local,windowFrame,screen.frame,result))return YES;
    return NO;
}
static NSArray *Views(id impl,id *representation){
    if(object_getClass(impl)!=NSClassFromString(@"NSMenuBarImpl")||!DispatchMatches(impl,barRepresentationGetter))return nil;
    id rep=ObjectCall(barRepresentationGetter,impl);
    if(![rep isKindOfClass:NSClassFromString(@"NSMenuBarRepresentation")]||!DispatchMatches(rep,rootBackingGetter)||!DispatchMatches(rep,layoutMethod))return nil;
    id backing=ObjectCall(rootBackingGetter,rep);
    if(![backing isKindOfClass:NSClassFromString(@"_NSMenuBarBackingView")]||!DispatchMatches(backing,arrangedGetter))return nil;
    id views=ObjectCall(arrangedGetter,backing);
    if(![views isKindOfClass:NSArray.class]||[views count]>128)return nil;
    for(id view in views)if(![view isKindOfClass:NSClassFromString(@"NSMenuItemView")]||!DispatchMatches(view,menuItemGetter)||!DispatchMatches(view,viewHiddenSetter))return nil;
    if(representation)*representation=rep;return views;
}
static BOOL RestoreRecords(NSArray *records){
    for(NSDictionary *record in records){if(![record[@"changed"] boolValue])continue;id view=record[@"view"],item=record[@"item"];
        if(!DispatchMatches(view,menuItemGetter)||ObjectCall(menuItemGetter,view)!=item||!DispatchMatches(view,viewHiddenSetter)){lastError=@"restore_view_epoch_refused";return NO;}}
    for(NSDictionary *record in records){if(![record[@"changed"] boolValue])continue;NSView *view=record[@"view"];NSMenuItem *item=record[@"item"];
        // A native model change supersedes our prior view write; preserve it.
        if(item.hidden!=[record[@"model_hidden"] boolValue])continue;
        BOOL prior=[record[@"prior"] boolValue];if(view.hidden&&view.hidden!=prior)((void(*)(id,SEL,BOOL))OriginalIMP(viewHiddenSetter))(view,method_getName(viewHiddenSetter),prior);}
    return YES;
}
static BOOL RestoreViews(void){BOOL ok=RestoreRecords(viewRecords);if(ok)viewRecords=nil;return ok;}
static BOOL Capture(void){
    NSMenu *next=NSApp.mainMenu;
    if(!next||next.numberOfItems<1||next.numberOfItems>128||!DispatchMatches(next,menuImplGetter)){lastError=@"eligible_existing_menu_required";return NO;}
    NSMutableArray *rows=[NSMutableArray new];
    for(NSMenuItem *item in next.itemArray){if(!DispatchMatches(item,appleGetter)){lastError=@"apple_dispatch_changed";return NO;}if(BoolCall(appleGetter,item))continue;
        [rows addObject:@{@"item":item,@"submenu":item.submenu?:NSNull.null,@"title":item.title?:@"",@"id":RandomToken()}];}
    NSUInteger visible=0;for(NSDictionary *row in rows){NSMenuItem *item=row[@"item"];if(!item.hidden&&item.submenu)visible++;}
    if(!rows.count||!visible){lastError=@"no_visible_original_headings";return NO;}
    if(!RestoreViews())return NO;root=next;headings=rows;epoch++;return YES;
}
static BOOL TreeMatches(void){
    if(!root||NSApp.mainMenu!=root)return NO;NSUInteger n=0;
    for(NSMenuItem *item in root.itemArray){if(!DispatchMatches(item,appleGetter))return NO;if(BoolCall(appleGetter,item))continue;
        if(n>=headings.count)return NO;NSDictionary *row=headings[n++];if(row[@"item"]!=item||row[@"submenu"]!=(item.submenu?:NSNull.null)||![row[@"title"] isEqual:item.title?:@""])return NO;}
    return n==headings.count;
}
static void Trip(NSString *reason){if(tripped)return;tripped=YES;lastError=reason;BOOL ok=Off();if(!ok)lastError=[reason stringByAppendingString:@":cleanup_refused"];ScheduleSnapshot();}
static BOOL Apply(id impl){
    // The owned representation can publish before both activation witnesses agree.
    // Hide it synchronously here; foreground eligibility still gates Snapshot/popup.
    if(!enabled||tripped||!SameIdentity())return NO;
    if(!TreeMatches()&&!Capture())return NO;
    if(ObjectCall(menuImplGetter,root)!=impl)return NO;id rep=nil;NSArray *views=Views(impl,&rep);if(!views)return NO;
    NSMutableArray *records=[NSMutableArray new];NSUInteger apples=0;
    for(NSView *view in views){NSMenuItem *item=ObjectCall(menuItemGetter,view);
        if(!DispatchMatches(item,appleGetter))return NO;
        if(BoolCall(appleGetter,item)){if(view.hidden||item.hidden)return NO;apples++;continue;}
        BOOL found=NO;for(NSDictionary *row in headings)if(row[@"item"]==item){found=YES;break;}if(!found)return NO;
        NSDictionary *saved=nil;for(NSDictionary *old in viewRecords)if(old[@"view"]==view&&old[@"item"]==item){saved=old;break;}
        // Layout has just restored native visibility; preserve that value for OFF.
        if(saved && [saved[@"model_hidden"] boolValue]!=item.hidden)saved=nil;
        [records addObject:saved?:@{@"view":view,@"item":item,@"prior":@(view.hidden),@"representation":rep,@"model_hidden":@(item.hidden),@"changed":@(!view.hidden)}];}
    if(apples!=1||records.count!=headings.count)return NO;
    NSMutableArray *retired=[NSMutableArray new];for(NSDictionary *old in viewRecords){BOOL remains=NO;for(NSDictionary *next in records)if(old[@"view"]==next[@"view"]&&old[@"item"]==next[@"item"]){remains=YES;break;}if(!remains)[retired addObject:old];}
    if(!RestoreRecords(retired))return NO;viewRecords=records;
    for(NSDictionary *record in records){NSView *view=record[@"view"];if(!view.hidden)((void(*)(id,SEL,BOOL))OriginalIMP(viewHiddenSetter))(view,method_getName(viewHiddenSetter),YES);if(!enabled)return NO;}
    lastError=nil;return YES;
}
static BOOL GroupingState(id impl,BOOL *grouped){
    if(object_getClass(impl)!=NSClassFromString(@"NSMenuBarImpl")||groupingOffset!=297||
       !DispatchMatches(impl,beginGroupingMethod)||!DispatchMatches(impl,endGroupingMethod))return NO;
    unsigned char value=0;memcpy(&value,(const unsigned char*)(__bridge const void*)impl+groupingOffset,1);
    if(value>1)return NO;*grouped=value!=0;return YES;
}
static BOOL ReleaseOwnedGrouping(void){
    id impl=ownedGroupingImpl;if(!impl)return YES;
    BOOL active=NO;
    if(!GroupingState(impl,&active)){lastError=@"native_layout_group_cleanup_refused";return NO;}
    @try {
        if(active)((void(*)(id,SEL))OriginalIMP(endGroupingMethod))(impl,method_getName(endGroupingMethod));
    } @catch(NSException *exception){(void)exception;lastError=@"native_layout_group_cleanup_exception";return NO;}
    if(!GroupingState(impl,&active)||active){lastError=@"native_layout_group_cleanup_unconfirmed";return NO;}
    ownedGroupingImpl=nil;return YES;
}
static BOOL ApplyGrouped(id impl){
    BOOL grouped=NO,opened=NO,applied=NO;
    if(ownedGroupingImpl){lastError=@"native_layout_group_cleanup_pending";return NO;}
    if(!GroupingState(impl,&grouped)){lastError=@"native_layout_group_state_refused";return NO;}
    @try {
        if(!grouped){
            ((void(*)(id,SEL))OriginalIMP(beginGroupingMethod))(impl,method_getName(beginGroupingMethod));opened=YES;ownedGroupingImpl=impl;
            BOOL active=NO;if(!GroupingState(impl,&active)||!active){lastError=@"native_layout_group_begin_refused";return NO;}
        }
        // Native nested viewDidLayout now only marks pending layout. End's
        // native CA completion publishes after the complete view vector.
        applied=Apply(impl);
    } @finally {
        if(opened){
            if(!ReleaseOwnedGrouping()){applied=NO;Trip(@"native_layout_group_cleanup_refused");}
        }
    }
    return applied;
}
static void Publish(id object,SEL selector){depth++;maxDepth=MAX(maxDepth,depth);
    @try {@try {
        if(enabled && NSApp.mainMenu && DispatchMatches(NSApp.mainMenu,menuImplGetter) && ObjectCall(menuImplGetter,NSApp.mainMenu)==object){
            BOOL appActive=NSApp.active,workspaceActive=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier==getpid(),applied=NO;
            callbacks++;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;if(now-windowStart>=1){windowStart=now;windowCallbacks=0;}windowCallbacks++;
            @try {
                // Native publication may nest without reentering our view edits.
                // Keep suppression before publication, with one writer per Apply.
                if(depth>128||windowCallbacks>128)Trip(@"bounded_publish_recursion_or_storm");
                else if(applying){if(applyReentries<UINT32_MAX)applyReentries++;}
                else {
                    if(depth>1&&nativeReentries<UINT32_MAX)nativeReentries++;
                    applying=YES;
                    @try {applied=ApplyGrouped(object);}
                    @finally {applying=NO;}
                }
            }
            @finally {CountPublish(appActive,workspaceActive,applied);}
        }
    } @finally {((void(*)(id,SEL))OriginalIMP(publishMethod))(object,selector);}}
    @finally {depth--;if(!depth)ScheduleSnapshot();}
}

@interface H7RepresentationConnectionR3:NSObject
@property dispatch_io_t channel;
@property NSMutableData *input;
@property BOOL watching,closed,busy,received;
@property NSDictionary *pendingReply;
- (void)send:(NSDictionary*)reply close:(BOOL)close;
- (void)finish;
@end
static void CloseEndpoint(void){
    if(acceptSource){dispatch_source_cancel(acceptSource);acceptSource=nil;}
    struct stat s={0};if(endpoint&&lstat(endpoint.fileSystemRepresentation,&s)==0&&S_ISSOCK(s.st_mode)&&s.st_uid==getuid()&&s.st_dev==socketDevice&&s.st_ino==socketInode)unlink(endpoint.fileSystemRepresentation);
    if(endpointDirectory)rmdir(endpointDirectory.fileSystemRepresentation);
    endpoint=nil;endpointDirectory=nil;capability=nil;
    if(ioQueue)dispatch_async(ioQueue,^{for(H7RepresentationConnectionR3 *connection in [connections copy])[connection finish];});
}
static BOOL Off(void){
    enabled=NO;BOOL hookRestored=YES;
#ifdef HYPR_FIRST_MAP
    BOOL firstMapRestored=!firstMapOwned || hypradmission_uninstall()==0;
    firstMapOwned=hypradmission_is_installed();
    if(!firstMapRestored)lastError=@"first_map_release_refused";
#endif
    if(installed){if(!HooksOwned()){lastError=@"foreign_publish_hook_restore_refused";hookRestored=NO;}else{method_setImplementation(publishMethod,OriginalIMP(publishMethod));installed=NO;}}
    BOOL restored=RestoreViews();
    BOOL groupReleased=ReleaseOwnedGrouping();
    for(id observer in observers)[NSNotificationCenter.defaultCenter removeObserver:observer];observers=nil;
    CloseEndpoint();
    // Cleanup always removes the endpoint and observers, including partial refusal.
    if(hookRestored&&restored&&groupReleased
#ifdef HYPR_FIRST_MAP
       &&firstMapRestored
#endif
       ){
        if(root&&NSApp.mainMenu==root&&DispatchMatches(root,menuImplGetter)){id impl=ObjectCall(menuImplGetter,root),rep=nil;
            if(!depth&&Views(impl,&rep))((void(*)(id,SEL))OriginalIMP(layoutMethod))(rep,method_getName(layoutMethod));
            else if(impl&&DispatchMatches(impl,publishMethod))((void(*)(id,SEL))OriginalIMP(publishMethod))(impl,method_getName(publishMethod));}
        identity=nil;lease=0;root=nil;headings=nil;staged=NO;return YES;
    }
    return NO; // Binding/records retained for explicit exact-session cleanup retry.
}
static NSDictionary *Snapshot(BOOL privateReply){
    BOOL current=SameIdentity()&&TreeMatches();BOOL suppressed=enabled&&!tripped&&!lastError&&HooksOwned()&&current&&Active();
    NSMutableArray *rows=[NSMutableArray new];NSArray *appleFrame=@[];NSUInteger apples=0,matched=0;BOOL appleCorrect=NO;id impl=current?ObjectCall(menuImplGetter,root):nil,rep=nil;NSArray *views=impl?Views(impl,&rep):nil;
    if(!views)suppressed=NO;
    for(NSView *view in views){NSMenuItem *item=ObjectCall(menuItemGetter,view);if(!DispatchMatches(item,appleGetter)){suppressed=NO;continue;}
        if(BoolCall(appleGetter,item)){
            apples++;if(view.hidden||item.hidden)suppressed=NO;
            NSRect frame=NSZeroRect;
            if(!AppleCocoaRect(view,&frame)||frame.size.width<8||frame.size.width>100||frame.size.height<14||frame.size.height>64)suppressed=NO;else {appleFrame=Frame(frame);appleCorrect=!view.hidden&&!item.hidden;}
        }else{
            NSDictionary *saved=nil;for(NSDictionary *record in viewRecords)if(record[@"view"]==view&&record[@"item"]==item&&record[@"representation"]==rep){saved=record;break;}
            if(!saved||!view.hidden)suppressed=NO;else matched++;
        }}
    if(apples!=1||matched!=headings.count)suppressed=NO;
    for(NSDictionary *row in headings){NSMenuItem *item=row[@"item"];if(item.hidden||!item.submenu)continue;[rows addObject:@{@"id":row[@"id"],@"title":item.title?:@"",@"enabled":@(item.enabled)}];}
    NSMutableDictionary *status=[@{@"schema":@1,@"ok":@YES,@"version":@7,@"prepared":@((BOOL)(identity!=nil)),@"enabled":@(enabled),@"current_menu_matches":@(current),@"explicit_inactive_stage":@(staged),@"active":@(Active()),@"suppressed":@(suppressed),@"hook_owned":@(HooksOwned()),@"original_items_unchanged":@YES,@"apple_preserved":@((BOOL)(apples==1&&appleCorrect&&appleFrame.count==4)),@"right_status_items_touched":@NO,@"identity":Identity()?:@{},@"module_uuid":moduleUUID?:@"",@"appkit_uuid":AppKitUUID,@"epoch":@(epoch),@"headings":rows,@"apple_frame":appleFrame,@"callbacks":@(callbacks),@"max_depth":@(maxDepth),@"failsafe":@(tripped),@"error":lastError?:@"",@"popup_pending":@(popupPending)} mutableCopy];
    status[@"external_first_map"]=@(externalFirstMap);
    status[@"publish_diagnostics"]=PublishDiagnostics();
    status[@"native_layout_group_owned"]=@((BOOL)(ownedGroupingImpl!=nil));
#ifdef HYPR_FIRST_MAP
    status[@"first_map_installed"]=@(firstMapOwned);
    status[@"first_map_grant_result"]=@(firstMapResult);
#endif
    if(privateReply&&endpoint&&capability){status[@"endpoint"]=endpoint;status[@"capability"]=capability;status[@"lease"]=@(lease);}
    return status;
}
static void ScheduleSnapshot(void){if(snapshotQueued||!ioQueue)return;snapshotQueued=YES;dispatch_async(dispatch_get_main_queue(),^{snapshotQueued=NO;NSDictionary *status=Snapshot(NO);dispatch_async(ioQueue,^{for(H7RepresentationConnectionR3 *connection in [connections copy])if(connection.watching)[connection send:status close:NO];});});}
static BOOL RequestIdentity(NSDictionary *request){return [request[@"identity"] isKindOfClass:NSDictionary.class]&&[request[@"identity"] isEqual:identity]&&[request[@"capability"] isKindOfClass:NSString.class]&&[request[@"capability"] isEqual:capability]&&[request[@"lease"] isEqual:@(lease)];}
static void HandleRequest(H7RepresentationConnectionR3 *connection,NSDictionary *request){
    if(!RequestIdentity(request)||!SameIdentity()){[connection send:@{@"ok":@NO,@"error":@"endpoint_session_refused"} close:YES];return;}
    NSString *op=request[@"op"];
    if([op isEqual:@"watch"]||[op isEqual:@"snapshot"]){connection.watching=[op isEqual:@"watch"];[connection send:Snapshot(NO) close:!connection.watching];return;}
    if(![op isEqual:@"popup"]){[connection send:@{@"ok":@NO,@"error":@"operation_refused"} close:YES];return;}
    NSDictionary *status=Snapshot(NO);NSMenuItem *item=nil;
    for(NSDictionary *row in headings)if([row[@"id"] isEqual:request[@"heading"]])item=row[@"item"];
    NSArray *anchor=request[@"anchor"];BOOL bounded=[anchor isKindOfClass:NSArray.class]&&anchor.count==2;NSPoint point=NSZeroPoint;
    if(bounded){for(id number in anchor)if(![number isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID()||!isfinite([number doubleValue]))bounded=NO;if(bounded)point=NSMakePoint([anchor[0] doubleValue],[anchor[1] doubleValue]);}
    BOOL onscreen=NO;for(NSScreen *screen in NSScreen.screens)if(NSPointInRect(point,screen.frame))onscreen=YES;
    if(![status[@"suppressed"] boolValue]||popupPending||![request[@"epoch"] isEqual:@(epoch)]||!item||item.menu!=root||!item.submenu||item.hidden||!item.enabled||!bounded||!onscreen){[connection send:@{@"ok":@NO,@"error":@"stale_or_ineligible_original_submenu"} close:YES];return;}
    NSMenu *submenu=item.submenu;NSMenu *expectedRoot=root;NSUInteger expectedEpoch=epoch;popupPending=YES;
    // The socket reply is queued first. No socket completion waits on menu tracking.
    [connection send:@{@"ok":@YES,@"queued":@YES,@"epoch":@(epoch)} close:YES];
    dispatch_async(dispatch_get_main_queue(),^{@try {BOOL stillOnscreen=NO;for(NSScreen *screen in NSScreen.screens)if(NSPointInRect(point,screen.frame))stillOnscreen=YES;
        if([Snapshot(NO)[@"suppressed"] boolValue]&&root==expectedRoot&&epoch==expectedEpoch&&item.menu==root&&item.submenu==submenu&&!item.hidden&&item.enabled&&stillOnscreen)[submenu popUpMenuPositioningItem:nil atLocation:point inView:nil];} @finally {popupPending=NO;ScheduleSnapshot();}});
}
@implementation H7RepresentationConnectionR3
- (void)finish {if(self.closed)return;self.closed=YES;self.watching=NO;dispatch_io_close(self.channel,DISPATCH_IO_STOP);[connections removeObject:self];}
- (void)send:(NSDictionary*)reply close:(BOOL)close {
    dispatch_async(ioQueue,^{if(self.closed)return;
        // Bound each watcher to one outstanding publication; a slow peer is closed.
        if(self.busy){if(self.watching&&!close){self.pendingReply=reply;return;}[self finish];return;}self.busy=YES;
        NSData *json=[NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];if(!json||json.length>65535){[self finish];return;}
        NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];dispatch_data_t data=dispatch_data_create(line.bytes,line.length,ioQueue,^{(void)line;});
        dispatch_io_write(self.channel,0,data,ioQueue,^(bool done,dispatch_data_t remaining,int error){(void)remaining;if(done){self.busy=NO;if(error||close)[self finish];else if(self.pendingReply){NSDictionary *latest=self.pendingReply;self.pendingReply=nil;[self send:latest close:NO];}}});
    });
}
@end
static BOOL StartEndpoint(void){
    if(!ioQueue){ioQueue=dispatch_queue_create("dev.hyprwm.appmenus.v7",DISPATCH_QUEUE_SERIAL);connections=[NSMutableSet new];}
    // NSTemporaryDirectory respects the host's sandbox. No chdir or global namespace edits.
    NSString *template=[[NSTemporaryDirectory() stringByResolvingSymlinksInPath] stringByAppendingPathComponent:@"hym7.XXXXXX"];char path[PATH_MAX];if(![template getFileSystemRepresentation:path maxLength:sizeof(path)]||!mkdtemp(path))return NO;
    endpointDirectory=@(path);if(chmod(path,0700)){rmdir(path);endpointDirectory=nil;return NO;}
    endpoint=[endpointDirectory stringByAppendingPathComponent:@"m.sock"];struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    if(endpoint.length>=sizeof(address.sun_path)||![endpoint getFileSystemRepresentation:address.sun_path maxLength:sizeof(address.sun_path)]){CloseEndpoint();return NO;}
    address.sun_len=SUN_LEN(&address);listenFD=socket(AF_UNIX,SOCK_STREAM,0);
    if(listenFD<0||fcntl(listenFD,F_SETFL,O_NONBLOCK)||fcntl(listenFD,F_SETFD,FD_CLOEXEC)||bind(listenFD,(struct sockaddr*)&address,address.sun_len)||chmod(endpoint.fileSystemRepresentation,0600)||listen(listenFD,8)){if(listenFD>=0)close(listenFD);listenFD=-1;CloseEndpoint();return NO;}
    struct stat info={0};if(lstat(endpoint.fileSystemRepresentation,&info)||!S_ISSOCK(info.st_mode)||info.st_uid!=getuid()){close(listenFD);listenFD=-1;CloseEndpoint();return NO;}socketDevice=info.st_dev;socketInode=info.st_ino;capability=RandomToken();
    int server=listenFD;acceptSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,server,0,ioQueue);
    dispatch_source_set_cancel_handler(acceptSource,^{close(server);});
    dispatch_source_set_event_handler(acceptSource,^{for(unsigned n=0;n<8;n++){int fd=accept(server,NULL,NULL);if(fd<0)break;uid_t uid;gid_t gid;
        if(getpeereid(fd,&uid,&gid)||uid!=getuid()||connections.count>=8){close(fd);continue;}
        fcntl(fd,F_SETFL,O_NONBLOCK);fcntl(fd,F_SETFD,FD_CLOEXEC);H7RepresentationConnectionR3 *connection=[H7RepresentationConnectionR3 new];connection.input=[NSMutableData new];
        connection.channel=dispatch_io_create(DISPATCH_IO_STREAM,fd,ioQueue,^(int error){(void)error;close(fd);});[connections addObject:connection];
        dispatch_io_set_low_water(connection.channel,1);dispatch_io_set_high_water(connection.channel,8192);
        dispatch_io_read(connection.channel,0,SIZE_MAX,ioQueue,^(bool done,dispatch_data_t data,int error){
            if(connection.closed)return;if(error||done){[connection finish];return;}
            if(data)dispatch_data_apply(data,^bool(dispatch_data_t region,size_t offset,const void *bytes,size_t length){(void)region;(void)offset;[connection.input appendBytes:bytes length:length];return YES;});
            if(connection.input.length>8192){[connection finish];return;}
            const uint8_t *bytes=connection.input.bytes;NSUInteger length=connection.input.length,index=0;while(index<length&&bytes[index]!='\n')index++;
            if(index<length){if(connection.received||index+1!=length){[connection finish];return;}connection.received=YES;NSData *line=[connection.input copy];[connection.input setLength:0];id request=[NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];if(![request isKindOfClass:NSDictionary.class]){[connection finish];return;}dispatch_async(dispatch_get_main_queue(),^{HandleRequest(connection,request);});}
        });
    }});dispatch_resume(acceptSource);return YES;
}
static BOOL ExternalFirstMapReady(void){
    char name[96];snprintf(name,sizeof(name),"hyprwm.admission.v3.cap.%d",getpid());
    int token=-1;uint64_t state=0;
    if(notify_register_check(name,&token)!=NOTIFY_STATUS_OK)return NO;
    BOOL ready=notify_get_state(token,&state)==NOTIFY_STATUS_OK&&state==1;
    notify_cancel(token);return ready;
}
static BOOL Enable(BOOL inactive,BOOL external){
    if(external&&!ExternalFirstMapReady()){lastError=@"external_first_map_not_ready";return NO;}
    externalFirstMap=external;
    if(!NSApp||!NSApp.mainMenu||(!inactive&&!Active())){lastError=@"eligible_existing_menu_required";return NO;}
    tripped=NO;callbacks=0;maxDepth=0;windowCallbacks=0;lastError=nil;
    inactivePublishes=appliedPublishes=inactiveAppliedPublishes=refusedPublishes=0;
    nativeReentries=applyReentries=0;
    lastPublishAppActive=lastPublishWorkspaceActive=lastPublishApplied=NO;
    if(!Qualify()){lastError=@"native_qualification_failed";return NO;}
    Method owned=OwnedMethod(NSClassFromString(@"NSMenuBarImpl"),method_getName(publishMethod));
    if(!owned||owned!=publishMethod||method_getImplementation(owned)!=OriginalIMP(publishMethod)){lastError=@"native_publish_method_ownership";return NO;}
    if(!Capture()||!StartEndpoint())return NO;
    IMP previous=method_setImplementation(owned,(IMP)Publish);
    if(previous!=OriginalIMP(publishMethod)){if(method_getImplementation(owned)==(IMP)Publish)method_setImplementation(owned,previous);CloseEndpoint();lastError=@"native_publish_slot_changed_during_install";return NO;}installed=YES;enabled=YES;staged=inactive;windowStart=NSProcessInfo.processInfo.systemUptime;
    observers=[NSMutableArray new];
    for(NSNotificationName name in @[NSApplicationDidBecomeActiveNotification,NSMenuDidAddItemNotification,NSMenuDidRemoveItemNotification,NSMenuDidChangeItemNotification]){
        id token=[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){(void)note;if(!enabled)return;if(TreeMatches()&&[note.object isKindOfClass:NSMenu.class]&&note.object!=root)return;if(!TreeMatches()&&!Capture()){lastError=@"root_change_capture_refused";ScheduleSnapshot();return;}
            if(Active()){id impl=ObjectCall(menuImplGetter,root),rep=nil;if(Views(impl,&rep))((void(*)(id,SEL))OriginalIMP(layoutMethod))(rep,method_getName(layoutMethod));}ScheduleSnapshot();}];[observers addObject:token];}
    id stop=[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationWillTerminateNotification object:NSApp queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){(void)note;Off();}];[observers addObject:stop];
    if(Active()){id impl=ObjectCall(menuImplGetter,root),rep=nil;if(Views(impl,&rep))((void(*)(id,SEL))OriginalIMP(layoutMethod))(rep,method_getName(layoutMethod));}
#ifdef HYPR_FIRST_MAP
    @try {firstMapResult=external?-1:HAInstallGranted(identity);}
    @finally {firstMapOwned=hypradmission_is_installed();}
#endif
    ScheduleSnapshot();return YES;
}
__attribute__((visibility("default"))) int hypr_appmenus_v1_json(int action,int32_t pid,uint32_t uid,uint64_t sec,uint64_t usec,const char *path,const char *uuidText,uint32_t flags,char *output,uint32_t capacity){
    if(!output||capacity<32768||capacity>1048576)return 1;output[0]=0;if(!pthread_main_np())return 2;
    @autoreleasepool {@try {
        NSDictionary *actual=Identity();NSString *uuid=[actual[@"main_uuid"] stringByReplacingOccurrencesOfString:@"-" withString:@""];
        if(action<0||action>4||!actual||pid!=getpid()||uid!=[actual[@"uid"] unsignedIntValue]||sec!=[actual[@"birth_sec"] unsignedLongLongValue]||usec!=[actual[@"birth_usec"] unsignedLongLongValue]||!path||strnlen(path,PROC_PIDPATHINFO_MAXSIZE)>=PROC_PIDPATHINFO_MAXSIZE||![actual[@"executable"] isEqual:@(path)]||!uuidText||strnlen(uuidText,33)!=32||[uuid caseInsensitiveCompare:@(uuidText)]!=NSOrderedSame)return 3;
        if(action && !(flags&0x7fffffff))return 1;
        NSDictionary *answer=nil;
        if(action==0){if(!qualifications)Qualify();answer=Snapshot(YES);}
        else if(action==2){if(!identity||![identity isEqual:actual]||lease!=(flags&0x7fffffff))answer=@{@"ok":@NO,@"error":@"ownership_mismatch"};else{BOOL ok=Off();answer=ok?@{@"ok":@YES,@"enabled":@NO}:@{@"ok":@NO,@"error":lastError?:@"off_refused"};}}
        else if(identity)answer=@{@"ok":@NO,@"error":@"already_bound"};
        else {identity=actual;lease=flags&0x7fffffff;Dl_info d={0};if(dladdr((void*)hypr_appmenus_v1_json,&d))moduleUUID=ImageUUID(d.dli_fbase);
            if(Enable(action==3||action==4,action==4))answer=Snapshot(YES);else{NSString *why=lastError?:@"endpoint_or_native_prepare_refused";Off();identity=nil;lease=0;answer=@{@"ok":@NO,@"error":why,@"status":@{@"prepared":@NO}};}}
        NSData *json=[NSJSONSerialization dataWithJSONObject:answer options:0 error:NULL];if(!json||json.length+1>capacity)return 1;memcpy(output,json.bytes,json.length);output[json.length]=0;return [answer[@"ok"] boolValue]?0:4;
    } @catch(NSException *exception){(void)exception;return 5;}}
}
