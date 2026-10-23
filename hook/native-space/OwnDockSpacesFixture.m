#define HYPR_DS_FIXTURE 1
#include "DockSpacesBridge.m"
#import <CoreFoundation/CoreFoundation.h>

@interface DSOwnSpace:NSObject
@property uint64_t spid;
@property NSString *uuid;
@end
@implementation DSOwnSpace
- (BOOL)userSpace{return YES;}
- (BOOL)fullscreen{return NO;}
@end
@interface DSOwnSpaces:NSObject
@property NSArray *objects;
@property id current;
@property NSUInteger calls;
@property NSInteger lastIndex;
@property BOOL busy;
@end
@implementation DSOwnSpaces
- (NSArray *)allUserSpaces{return self.objects;}
- (BOOL)anySwitchingOccurring{return self.busy;}
- (id)currentSpaceForDisplayUUID:(id)display{(void)display;return self.current;}
- (BOOL)switchToUserSpace:(NSInteger)index{
    self.calls++;self.lastIndex=index;self.current=self.objects[(NSUInteger)index];
    NSMutableDictionary *next=[DSFixtureCatalog mutableCopy];next[@"current"]=@([self.current spid]);next[@"active"]=next[@"current"];DSFixtureCatalog=next;
    return YES;
}
@end
static void DSOwnBadSwitch(id self,SEL cmd,NSInteger index){(void)self;(void)cmd;(void)index;}
static NSDictionary *DSOwnRun(NSDictionary *request){NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];NSMutableData *z=[data mutableCopy];[z appendBytes:"\0" length:1];char out[32768]={0};
    int result=hypr_dockspaces_v1_json(z.bytes,out,sizeof(out));(void)result;return[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:out length:strlen(out)] options:0 error:NULL]?:@{};}
static NSDictionary *DSOwnRequest(NSString *op,NSDictionary *extra){NSMutableDictionary *r=[@{@"op":op,@"owner":DSIdentity(getpid()),@"nonce":DSLease[@"nonce"]?:@"",@"epoch":DSLease[@"epoch"]?:@""}mutableCopy];[r addEntriesFromDictionary:extra?:@{}];return r;}
static NSDictionary *DSOwnSwitch(NSDictionary *status,NSDictionary *target,NSString *requestID){return DSOwnRequest(@"switch-existing",@{@"ticket":status[@"ticket"],@"source":status[@"catalog"],@"target":target,@"request_id":requestID});}
static BOOL DSOwnDelayedFirstWrite;
static NSDictionary *DSOwnNetwork(NSString *path,NSDictionary *request){int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={.sun_family=AF_UNIX};strlcpy(a.sun_path,path.fileSystemRepresentation,sizeof(a.sun_path));struct timeval timeout={1,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    if(fd<0||connect(fd,(const void*)&a,sizeof(a))){if(fd>=0)close(fd);return@{};}int noSignal=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));if(DSOwnDelayedFirstWrite)usleep(20000);NSData *data=[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];send(fd,data.bytes,data.length,0);send(fd,"\n",1,0);char bytes[32769]={0};size_t used=0;
    while(used<32768){ssize_t n=recv(fd,bytes+used,32768-used,0);if(n<=0)break;used+=n;if(memchr(bytes,'\n',used))break;}close(fd);char *end=memchr(bytes,'\n',used);return end?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:end-bytes] options:0 error:NULL]:@{};}
static NSDictionary *DSOwnNetworkFromThread(NSString *path,NSDictionary *request){dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *reply;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{reply=DSOwnNetwork(path,request);dispatch_semaphore_signal(done);});
    uint64_t end=DSNow()+2000000000ULL;while(dispatch_semaphore_wait(done,DISPATCH_TIME_NOW)!=0&&DSNow()<end)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.005,true);return reply?:@{};}
int main(int argc,const char **argv){@autoreleasepool{
    signal(SIGPIPE,SIG_DFL); // Test the host's default disposition, not the launching shell's policy.
    if(argc==2&&!strcmp(argv[1],"--write-closed")) {
        int pair[2];if(socketpair(AF_UNIX,SOCK_STREAM,0,pair))return 2;
        close(pair[1]);DSWrite(pair[0],@{@"ok":@NO});close(pair[0]);return 0;
    }
    if(argc==4&&!strcmp(argv[1],"--disconnect")) {
        int fd=socket(AF_UNIX,SOCK_STREAM,0);struct sockaddr_un a={.sun_family=AF_UNIX};
        strlcpy(a.sun_path,argv[2],sizeof(a.sun_path));
        if(fd<0||connect(fd,(const void*)&a,sizeof(a))){if(fd>=0)close(fd);return 2;}
        const char *frame=!strcmp(argv[3],"partial")?"{":!strcmp(argv[3],"full")?"{}\n":"";
        if(*frame)send(fd,frame,strlen(frame),MSG_NOSIGNAL);
        close(fd);return 0;
    }
    if(argc==2&&!strcmp(argv[1],"--lease-peer")){char release;return read(STDIN_FILENO,&release,1)==1?0:2;}
    // Child mode only connects to the parent's own fixture socket. Its different
    // kernel PID/birth must be rejected even though UID and executable match.
    if(argc==3&&!strcmp(argv[1],"--wrong-peer")){NSDictionary *reply=DSOwnNetwork(@(argv[2]),@{});return[reply[@"error"]isEqual:@"peer_identity"]?0:3;}
    NSMutableArray *checks=[NSMutableArray new];
#define CHECK(v,name) do { BOOL passed=(BOOL)(v); [checks addObject:@{@"name":name,@"pass":@(passed)}]; fprintf(stderr,"%s: %s\n",[name UTF8String],passed?"PASS":"FAIL"); fflush(stderr); } while(0)
    DSOwnSpaces *actor=[DSOwnSpaces new];NSMutableArray *objects=[NSMutableArray new],*rows=[NSMutableArray new];NSArray *ids=@[@11,@42,@103,@890,@2048];
    for(NSUInteger n=0;n<ids.count;n++){DSOwnSpace *s=[DSOwnSpace new];s.spid=[ids[n]unsignedLongLongValue];s.uuid=n?[NSString stringWithFormat:@"owned-uuid-%lu",(unsigned long)n]:@"";[objects addObject:s];[rows addObject:@{@"sid":ids[n],@"uuid":s.uuid,@"type":@0}];}
    actor.objects=objects;actor.current=objects[0];DSFixtureActor=actor;DSFixtureActorClass=DSOwnSpaces.class;DSFixtureSpaceClass=DSOwnSpace.class;
    DSFixtureCatalog=@{@"display":@"A153F1CB-1FEA-4D06-B86F-C51369AC1795",@"spaces":rows,@"current":@11,@"active":@11};NSDictionary *original=DSFixtureCatalog;
    char folder[]="/private/tmp/hypr-ds-fixture.XXXXXX";if(!mkdtemp(folder))return 2;NSString *directory=@(folder),*path=[directory stringByAppendingPathComponent:@"s"];
    NSDictionary *install=@{@"op":@"install",@"owner":DSIdentity(getpid()),@"peer":DSIdentity(getpid()),@"generation":@{},@"nonce":[@"f" stringByPaddingToLength:64 withString:@"f" startingAtIndex:0],@"epoch":@"own-current-lifetime",@"socket":path};
    NSDictionary *result=DSOwnRun(install);CHECK([result[@"ok"]boolValue],@"explicit_constructor_free_install");
    NSDictionary *target=@{@"display":original[@"display"],@"sid":@2048,@"uuid":rows[4][@"uuid"],@"type":@0};
    NSDictionary *status=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([status[@"ok"]boolValue]&&[status[@"ticket"]length]>0,@"status_yields_bounded_existing_ticket");
    NSMutableDictionary *bad=[DSOwnSwitch(status,target,@"raw-ordinal-red")mutableCopy];bad[@"ordinal"]=@4;result=DSOwnRun(bad);CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"raw_ordinal_from_client_refused");
    NSMutableDictionary *wrongTarget=[target mutableCopy];wrongTarget[@"uuid"]=@"wrong-uuid";result=DSOwnRun(DSOwnSwitch(status,wrongTarget,@"wrong-uuid-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"exact_target_uuid_required");
    status=DSOwnRun(DSOwnRequest(@"status",nil));actor.objects=@[objects[4],objects[1],objects[2],objects[3],objects[0]];result=DSOwnRun(DSOwnSwitch(status,target,@"wrong-order-red"));CHECK([result[@"error"]isEqual:@"native_list_catalog_mismatch"]&&actor.calls==0,@"actual_native_cardinal_order_crosschecked");actor.objects=objects;
    actor.current=objects[1];result=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([result[@"error"]isEqual:@"actor_current_catalog_mismatch"],@"actor_current_crosschecked_against_catalog");actor.current=objects[0];
    Class badClass=objc_allocateClassPair(DSOwnSpaces.class,"DSOwnWrongABI",0);class_addMethod(badClass,sel_registerName("switchToUserSpace:"),(IMP)DSOwnBadSwitch,"v24@0:8q16");objc_registerClassPair(badClass);
    DSFixtureActor=[badClass new];DSFixtureActorClass=badClass;result=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([result[@"error"]isEqual:@"native_method_abi"]&&actor.calls==0,@"void_switch_ABI_refused_before_dispatch");DSFixtureActor=actor;DSFixtureActorClass=DSOwnSpaces.class;
    Class unsignedClass=objc_allocateClassPair(DSOwnSpaces.class,"DSOwnUnsignedIndexABI",0);class_addMethod(unsignedClass,sel_registerName("switchToUserSpace:"),method_getImplementation(class_getInstanceMethod(DSOwnSpaces.class,sel_registerName("switchToUserSpace:"))),"B24@0:8Q16");objc_registerClassPair(unsignedClass);
    DSFixtureActor=[unsignedClass new];DSFixtureActorClass=unsignedClass;result=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([result[@"error"]isEqual:@"native_method_abi"]&&actor.calls==0,@"unsigned_raw_SID_ABI_refused");DSFixtureActor=[NSObject new];DSFixtureActorClass=DSOwnSpaces.class;
    result=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([result[@"error"]isEqual:@"canonical_actor_class"]&&actor.calls==0,@"wrong_actual_receiver_refused");DSFixtureActor=actor;
    actor.busy=YES;status=DSOwnRun(DSOwnRequest(@"status",nil));CHECK([status[@"busy"]boolValue]&&[status[@"ticket"]length]==0&&actor.calls==0,@"native_busy_has_no_ticket");actor.busy=NO;
    status=DSOwnRun(DSOwnRequest(@"status",nil));NSMutableArray *newRows=[rows mutableCopy];newRows[4]=@{@"sid":@2048,@"uuid":@"changed-uuid",@"type":@0};NSMutableDictionary *changed=[original mutableCopy];changed[@"spaces"]=newRows;DSFixtureCatalog=changed;
    result=DSOwnRun(DSOwnSwitch(status,target,@"stale-topology-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"stale_topology_cannot_send");DSFixtureCatalog=original;
    status=DSOwnRun(DSOwnRequest(@"status",nil));NSMutableDictionary *moved=[original mutableCopy];moved[@"current"]=@42;moved[@"active"]=@42;DSFixtureChangeCatalog=moved;DSFixtureChangeAt=DSFixtureReads+2;
    result=DSOwnRun(DSOwnSwitch(status,target,@"final-send-fence-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"source_changes_at_final_send_fence_refused");DSFixtureChangeAt=0;DSFixtureCatalog=original;
    status=DSOwnRun(DSOwnRequest(@"status",nil));DSOwnSpaces *replacement=[DSOwnSpaces new];replacement.objects=objects;replacement.current=objects[0];DSFixtureChangeCatalog=original;DSFixtureChangeActor=replacement;DSFixtureChangeAt=DSFixtureReads+2;
    result=DSOwnRun(DSOwnSwitch(status,target,@"final-actor-fence-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0&&replacement.calls==0,@"canonical_actor_replacement_at_final_send_refused");DSFixtureChangeAt=0;DSFixtureChangeActor=nil;DSFixtureActor=actor;
    status=DSOwnRun(DSOwnRequest(@"status",nil));DSExpires=DSNow()-1;result=DSOwnRun(DSOwnSwitch(status,target,@"expired-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"expired_ticket_cannot_send");
    status=DSOwnRun(DSOwnRequest(@"status",nil));DSOwnRun(DSOwnRequest(@"cancel",nil));result=DSOwnRun(DSOwnSwitch(status,target,@"cancelled-red"));CHECK(![result[@"ok"]boolValue]&&actor.calls==0,@"cancel_invalidates_unconsumed_ticket");
    status=DSOwnRun(DSOwnRequest(@"status",nil));NSDictionary *request=DSOwnSwitch(status,target,@"one-native-dispatch");result=DSOwnRun(request);
    CHECK([result[@"native_dispatched"]boolValue]&&actor.calls==1&&actor.lastIndex==4,@"single_dispatch_sid2048_maps_to_index4");CHECK(![result[@"acknowledged"]boolValue]&&[result[@"pending"]boolValue],@"native_BOOL_is_pending_not_durable_ACK");
    result=DSOwnRun(request);CHECK(![result[@"ok"]boolValue]&&actor.calls==1,@"one_shot_replay_never_dispatches_twice");
    status=DSOwnRun(DSOwnRequest(@"status",nil));CHECK(![status[@"acknowledged"]boolValue]&&[status[@"catalog"][@"spaces"]isEqual:rows],@"no_create_destroy_reorder_or_fake_ACK");
    NSMutableDictionary *badNonce=[DSOwnRequest(@"status",nil)mutableCopy];badNonce[@"nonce"]=@"wrong";result=DSOwnNetworkFromThread(path,badNonce);CHECK(![result[@"ok"]boolValue],@"endpoint_nonce_authentication");
    result=DSOwnNetworkFromThread(path,DSOwnRequest(@"status",nil));CHECK([result[@"ok"]boolValue]&&actor.calls==1,@"current_lifetime_endpoint_works_without_debugger");
    DSOwnDelayedFirstWrite=YES;result=DSOwnNetworkFromThread(path,DSOwnRequest(@"status",nil));DSOwnDelayedFirstWrite=NO;CHECK([result[@"ok"]boolValue]&&actor.calls==1,@"endpoint_waits_for_client_final_preflight_before_first_write");
    NSTask *child=[NSTask new];child.executableURL=[NSURL fileURLWithPath:DSIdentity(getpid())[@"path"]];child.arguments=@[@"--wrong-peer",path];child.standardOutput=NSFileHandle.fileHandleWithNullDevice;child.standardError=NSFileHandle.fileHandleWithNullDevice;NSError *launchError=nil;
    BOOL launched=[child launchAndReturnError:&launchError];uint64_t end=DSNow()+2000000000ULL;while(launched&&child.running&&DSNow()<end)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.005,true);
    CHECK(launched&&!child.running&&child.terminationStatus==0,@"same_uid_same_executable_different_birth_rejected");
    NSTask *closedWriter=[NSTask new];closedWriter.executableURL=[NSURL fileURLWithPath:DSIdentity(getpid())[@"path"]];closedWriter.arguments=@[@"--write-closed"];
    closedWriter.standardOutput=NSFileHandle.fileHandleWithNullDevice;closedWriter.standardError=NSFileHandle.fileHandleWithNullDevice;
    BOOL writerLaunched=[closedWriter launchAndReturnError:nil];if(writerLaunched)[closedWriter waitUntilExit];
    CHECK(writerLaunched&&closedWriter.terminationReason==NSTaskTerminationReasonExit&&closedWriter.terminationStatus==0,@"closed_reply_cannot_signal_host_without_socket_option_assumption");
    for(NSString *mode in @[@"empty",@"partial",@"full"]) {
        BOOL survived=YES;
        for(int attempt=0;attempt<3;attempt++) {
            NSTask *early=[NSTask new];early.executableURL=[NSURL fileURLWithPath:DSIdentity(getpid())[@"path"]];early.arguments=@[@"--disconnect",path,mode];
            early.standardOutput=NSFileHandle.fileHandleWithNullDevice;early.standardError=NSFileHandle.fileHandleWithNullDevice;
            BOOL started=[early launchAndReturnError:nil];uint64_t until=DSNow()+2000000000ULL;
            while(started&&early.running&&DSNow()<until)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.005,true);
            NSDictionary *alive=DSOwnNetworkFromThread(path,DSOwnRequest(@"status",nil));
            survived=survived&&started&&!early.running&&early.terminationStatus==0&&[alive[@"ok"]boolValue]&&actor.calls==1;
        }
        CHECK(survived,[@"early_disconnect_survives_" stringByAppendingString:mode]);
    }
    NSDictionary *oldStatus=DSOwnRun(DSOwnRequest(@"status",nil));NSString *oldTicket=DSTicket;unsigned oldEpoch=atomic_load(&DSEpoch);
    NSTask *oldPeer=[NSTask new];NSPipe *release=[NSPipe pipe];oldPeer.executableURL=[NSURL fileURLWithPath:DSIdentity(getpid())[@"path"]];oldPeer.arguments=@[@"--lease-peer"];oldPeer.standardInput=release;oldPeer.standardOutput=NSFileHandle.fileHandleWithNullDevice;oldPeer.standardError=NSFileHandle.fileHandleWithNullDevice;
    BOOL oldLaunched=[oldPeer launchAndReturnError:nil];NSDictionary *oldIdentity=oldLaunched?DSIdentity(oldPeer.processIdentifier):nil;CHECK(oldIdentity!=nil,@"owned_peer_birth_observed");DSSetPeer(oldIdentity);
    NSDictionary *successor=DSIdentity(getpid()),*rebind=DSOwnRequest(@"rebind",nil);
    result=DSCommandPeer(rebind,atomic_load(&DSEpoch),successor);CHECK(![result[@"ok"]boolValue]&&[DSTicket isEqual:oldTicket]&&atomic_load(&DSEpoch)==oldEpoch,@"rebind_refuses_live_old_birth_without_changing_ticket");
    [release.fileHandleForWriting writeData:[NSData dataWithBytes:"x" length:1]];[oldPeer waitUntilExit];CHECK(!oldPeer.running&&oldPeer.terminationStatus==0&&DSPeerBirthGone(oldIdentity),@"old_peer_naturally_exits");
    DSPendingID=@"unconfirmed-native-outcome";DSPendingTarget=target;result=DSCommandPeer(rebind,atomic_load(&DSEpoch),successor);CHECK(![result[@"ok"]boolValue]&&DSPendingID!=nil&&[DSTicket isEqual:oldTicket],@"rebind_preserves_unresolved_dispatch");DSPendingID=nil;DSPendingTarget=nil;
    atomic_store(&DSQueued,1);result=DSCommandPeer(rebind,atomic_load(&DSEpoch),successor);CHECK(![result[@"ok"]boolValue]&&[DSCurrentPeer() isEqual:oldIdentity],@"rebind_refuses_queued_work");atomic_store(&DSQueued,0);
    NSMutableDictionary *forged=[successor mutableCopy];forged[@"uid"]=@([successor[@"uid"]intValue]+1);result=DSCommandPeer(rebind,atomic_load(&DSEpoch),forged);CHECK(![result[@"ok"]boolValue]&&[DSCurrentPeer() isEqual:oldIdentity],@"rebind_rejects_forged_socket_identity");
    NSMutableDictionary *wrongAuth=[rebind mutableCopy];wrongAuth[@"nonce"]=@"wrong";result=DSCommandPeer(wrongAuth,atomic_load(&DSEpoch),successor);CHECK(![result[@"ok"]boolValue]&&[DSTicket isEqual:oldTicket],@"rebind_requires_existing_private_nonce");
    result=DSOwnNetworkFromThread(path,rebind);CHECK([result[@"rebound"]boolValue]&&[DSCurrentPeer() isEqual:successor]&&DSTicket==nil&&DSTicketCatalog==nil&&atomic_load(&DSEpoch)>oldEpoch&&actor.calls==1&&DSDispatchCount==1,@"rebind_exact_successor_invalidates_tickets_without_dispatch");
    result=DSOwnRun(DSOwnSwitch(oldStatus,target,@"rebind-old-ticket"));CHECK(![result[@"ok"]boolValue]&&actor.calls==1,@"rebind_old_ticket_never_dispatches");
    result=DSOwnNetworkFromThread(path,DSOwnRequest(@"status",nil));CHECK([result[@"ok"]boolValue]&&[result[@"ticket"]length]>0&&[DSConsumed containsObject:@"one-native-dispatch"],@"rebind_new_status_works_consumed_ids_survive");
    DSOwnRun(DSOwnRequest(@"cancel",@{@"shutdown":@YES}));end=DSNow()+1000000000ULL;while(access(path.fileSystemRepresentation,F_OK)==0&&DSNow()<end)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.005,true);
    CHECK(access(path.fileSystemRepresentation,F_OK)!=0,@"cancel_shutdown_removes_exact_owned_socket");BOOL removed=rmdir(directory.fileSystemRepresentation)==0;CHECK(removed,@"owned_runtime_directory_cleaned");
    BOOL ok=checks.count>=16;for(NSDictionary *check in checks)ok=ok&&[check[@"pass"]boolValue];
    NSDictionary *report=@{@"ok":@(ok),@"checks":checks,@"native_dispatches":@(actor.calls),@"last_native_index":@(actor.lastIndex),@"identity":DSIdentity(getpid()),@"fixture_macro":@YES,@"actual_Dock_or_WindowServer_contact":@NO,@"AppKit_or_GUI_created":@NO,@"posted_input":@NO,@"child_exited":@(launched&&!child.running),@"socket_cleaned":@(removed)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);return ok?0:1;
}}
