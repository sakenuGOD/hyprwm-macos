// B15: private retained-handle receipt discovery + exact owner peer; never logs a capability.
#import <CommonCrypto/CommonDigest.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <poll.h>
#import <errno.h>
#import <stdarg.h>
// Temporary B15 diagnostics: protocol metadata only, never receipt credentials or menu text.
static void B15BarTrace(NSString *format,...) NS_FORMAT_FUNCTION(1,2);
static void B15BarTrace(NSString *format,...){
    const char *enabled=getenv("HYPRWM_BAR_TRACE");if(!enabled||!*enabled)return;
    va_list args;va_start(args,format);NSString *line=[[NSString alloc] initWithFormat:format arguments:args];va_end(args);
    fprintf(stderr,"HYPRWM_BAR_TRACE %.3f %s\n",NSProcessInfo.processInfo.systemUptime*1000,line.UTF8String);
}
static NSString *B15TraceID(id value){
    if(![value isKindOfClass:NSString.class]||[value length]!=64||[value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location!=NSNotFound)return @"invalid";
    return [value substringToIndex:8];
}
static NSNumber *B15TraceEpoch(id value){return positiveInteger(value)?value:@0;}
static NSString *B15TraceRPCError(id value){return [@[@"endpoint_session_refused",@"operation_refused",@"stale_or_ineligible_original_submenu"] containsObject:value]?value:@"unrecognized";}
static NSData *B15PrivateFile(NSString *path,NSUInteger limit){
    if(![path isKindOfClass:NSString.class]||!path.isAbsolutePath||![path.stringByResolvingSymlinksInPath isEqual:path])return nil;
    struct stat parent={0};if(lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=getuid()||(parent.st_mode&0777)!=0700)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;struct stat s={0};
    if(fstat(fd,&s)||!S_ISREG(s.st_mode)||s.st_uid!=getuid()||(s.st_mode&0777)!=0600||s.st_size<=0||(NSUInteger)s.st_size>limit){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)s.st_size];NSUInteger offset=0;while(offset<data.length){ssize_t n=read(fd,(char*)data.mutableBytes+offset,data.length-offset);if(n<=0){close(fd);return nil;}offset+=(NSUInteger)n;}close(fd);return data;
}
static NSString *B15SHA(NSData *data){if(!data)return nil;unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);NSMutableString *text=[NSMutableString new];for(unsigned i=0;i<sizeof(digest);i++)[text appendFormat:@"%02x",digest[i]];return text;}
static NSString *B15UUID(NSString *uuid){return [uuid isKindOfClass:NSString.class]?[[uuid stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString]:@"";}
static BOOL B15SameBirth(NSDictionary *actual,NSDictionary *expected){if(![actual isKindOfClass:NSDictionary.class]||![expected isKindOfClass:NSDictionary.class])return NO;for(NSString *key in @[@"pid",@"uid",@"birth_sec",@"birth_usec",@"executable"])if(!actual[key]||![actual[key] isEqual:expected[key]])return NO;return YES;}
// A retained dlopen handle is an opaque uintptr_t, including PAC bits on arm64e.
// Keep its exact integer representation; the WID/SID validator's 2^53 limit does not apply.
static BOOL B15RetainedHandle(id value){
    if(![value isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    const char *type=[value objCType];if(!type||type[1])return NO;
    switch(type[0]){
        case 'c':case 's':case 'i':case 'l':case 'q':if([value longLongValue]<=0)return NO;break;
        case 'C':case 'S':case 'I':case 'L':case 'Q':break;
        default:return NO;
    }
    uint64_t exact=[value unsignedLongLongValue];return exact>0&&(uint64_t)(uintptr_t)exact==exact;
}
static NSDictionary *B15Birth(pid_t pid){struct proc_bsdinfo info={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};if(pid<=0||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid()||proc_pidpath(pid,path,sizeof(path))<=0)return nil;return @{@"pid":@(pid),@"uid":@(info.pbi_uid),@"birth_sec":@(info.pbi_start_tvsec),@"birth_usec":@(info.pbi_start_tvusec),@"executable":@(path)};}
static NSDictionary *B15Binding(NSDictionary *settings,NSDictionary *front){
    NSData *stateData=B15PrivateFile(settings[@"b15_menu_state_path"],4*1024*1024);id state=stateData?[NSJSONSerialization JSONObjectWithData:stateData options:0 error:NULL]:nil;
    if(![state isKindOfClass:NSDictionary.class]||![state[@"payload"] isKindOfClass:NSDictionary.class])return nil;
    id owners=state[@"payload"][@"owners"];if(![owners isKindOfClass:NSDictionary.class]||[owners count]>512)return nil;
    id hashes=settings[@"b15_menu_module_sha256"];NSArray *allowed=[hashes isKindOfClass:NSArray.class]?hashes:[hashes isKindOfClass:NSString.class]?@[hashes]:@[];
    if(!allowed.count||allowed.count>8)return nil;for(id sha in allowed)if(!leaseSHA(sha))return nil;
    for(id owner in [owners allValues]){
        if(![owner isKindOfClass:NSDictionary.class])continue;id proof=owner[@"proof"];if(![proof isKindOfClass:NSDictionary.class])continue;id binding=proof[@"_binding"];
        id candidate=proof[@"native"];if(![candidate isKindOfClass:NSDictionary.class]||!B15SameBirth(candidate[@"identity"],front))continue;
        if(![proof isKindOfClass:NSDictionary.class]||![binding isKindOfClass:NSDictionary.class]||![allowed containsObject:proof[@"module_sha256"]])continue;
        for(NSString *key in @[@"ok",@"detached",@"not_stopped_after_detach",@"handle_retained",@"identity_after_detach",@"identity_after_state_query"]){if(!leaseTrue(proof[key])){proof=nil;break;}}if(!proof)continue;
        if(!B15RetainedHandle(binding[@"handle"])||!B15RetainedHandle(proof[@"retained_handle"])||![binding[@"handle"] isEqual:proof[@"retained_handle"]])continue;
        NSData *receiptData=B15PrivateFile(binding[@"postflight"],1024*1024);if(!receiptData||![B15SHA(receiptData) isEqual:binding[@"postflight_sha256"]])continue;
        id receipt=[NSJSONSerialization JSONObjectWithData:receiptData options:0 error:NULL];if(![receipt isKindOfClass:NSDictionary.class]||![receipt[@"native"] isEqual:proof[@"native"]]||![receipt[@"module_sha256"] isEqual:proof[@"module_sha256"]]||![receipt[@"retained_handle"] isEqual:proof[@"retained_handle"]])continue;
        NSDictionary *native=receipt[@"native"];if(![native isKindOfClass:NSDictionary.class])continue;NSDictionary *identity=native[@"identity"];
        if(![native isKindOfClass:NSDictionary.class]||![native[@"version"] isEqual:@7]||!B15SameBirth(identity,front)||!B15SameBirth(B15Birth([front[@"pid"] intValue]),identity)||![B15UUID(native[@"module_uuid"]) isEqual:B15UUID(receipt[@"module_uuid"])])continue;
        if(B15UUID(native[@"module_uuid"]).length!=32||B15UUID(receipt[@"module_uuid"]).length!=32)continue;
        if(![native[@"endpoint"] isKindOfClass:NSString.class]||![native[@"capability"] isKindOfClass:NSString.class]||[native[@"capability"] length]!=64||!positiveInteger(native[@"lease"]))continue;
        return @{@"identity":identity,@"endpoint":native[@"endpoint"],@"capability":native[@"capability"],@"lease":native[@"lease"],@"module_uuid":native[@"module_uuid"]};
    }return nil;
}
static int B15Connect(NSDictionary *binding){
    NSString *path=binding[@"endpoint"];struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    if(!path.isAbsolutePath||![path.stringByResolvingSymlinksInPath isEqual:path]||![path getFileSystemRepresentation:address.sun_path maxLength:sizeof(address.sun_path)])return -1;
    struct stat parent={0},before={0},after={0};if(lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=getuid()||(parent.st_mode&0777)!=0700||lstat(path.fileSystemRepresentation,&before)||!S_ISSOCK(before.st_mode)||before.st_uid!=getuid()||(before.st_mode&0777)!=0600)return -1;
    int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return -1;fcntl(fd,F_SETFD,FD_CLOEXEC);fcntl(fd,F_SETFL,O_NONBLOCK);address.sun_len=SUN_LEN(&address);
    if(connect(fd,(struct sockaddr*)&address,address.sun_len)){if(errno!=EINPROGRESS){close(fd);return -1;}struct pollfd wait={fd,POLLOUT,0};int error=0;socklen_t size=sizeof(error);if(poll(&wait,1,500)<=0||getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size)||error){close(fd);return -1;}}
    uid_t uid;gid_t gid;pid_t pid=-1;socklen_t length=sizeof(pid);
    if(getpeereid(fd,&uid,&gid)||uid!=getuid()||getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&length)||pid!=[binding[@"identity"][@"pid"] intValue]||!B15SameBirth(B15Birth(pid),binding[@"identity"])||lstat(path.fileSystemRepresentation,&after)||before.st_dev!=after.st_dev||before.st_ino!=after.st_ino){close(fd);return -1;}
    return fd;
}
static BOOL B15Send(int fd,NSDictionary *binding,NSDictionary *command){NSMutableDictionary *request=[command mutableCopy];for(NSString *key in @[@"identity",@"capability",@"lease"])request[key]=binding[key];NSData *json=[NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];if(!json||json.length>8190)return NO;NSMutableData *line=[json mutableCopy];[line appendBytes:"\n" length:1];int noSignal=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));return send(fd,line.bytes,line.length,0)==(ssize_t)line.length;}
// Native first application-menu heading may use the single U+0014 marker.
// Normalize only its display label; the original heading ID/epoch still route the submenu.
static NSDictionary *B15PresentationSnapshot(id value,NSDictionary *binding){
    if(![value isKindOfClass:NSDictionary.class])return value;
    id headings=value[@"headings"];if(![headings isKindOfClass:NSArray.class]||![headings count])return value;
    id first=headings[0];if(![first isKindOfClass:NSDictionary.class]||![first[@"title"] isEqual:@"\x14"])return value;
    NSDictionary *owner=binding[@"identity"];pid_t pid=[owner[@"pid"] intValue];
    if(![value[@"identity"] isEqual:owner]||!B15SameBirth(B15Birth(pid),owner))return nil;
    NSString *name=[NSRunningApplication runningApplicationWithProcessIdentifier:pid].localizedName;
    if(!boundedString(name,256)||!name.length)return nil;
    NSMutableDictionary *row=[first mutableCopy];row[@"title"]=name;
    NSMutableArray *rows=[headings mutableCopy];rows[0]=row;
    NSMutableDictionary *snapshot=[value mutableCopy];snapshot[@"headings"]=rows;return snapshot;
}
static BOOL B15SnapshotValid(id value,NSDictionary *binding){
    if(![value isKindOfClass:NSDictionary.class]||![value[@"schema"] isEqual:@1]||![value[@"version"] isEqual:@7]||!leaseTrue(value[@"ok"])||![value[@"identity"] isEqual:binding[@"identity"]]||![B15UUID(value[@"module_uuid"]) isEqual:B15UUID(binding[@"module_uuid"])])return NO;
    if(!positiveInteger(value[@"epoch"])||![value[@"headings"] isKindOfClass:NSArray.class]||[value[@"headings"] count]>128)return NO;
    NSMutableSet *ids=[NSMutableSet new];for(id row in value[@"headings"]){if(![row isKindOfClass:NSDictionary.class]||!boundedString(row[@"id"],64)||[row[@"id"] length]!=64||[ids containsObject:row[@"id"]]||!boundedString(row[@"title"],256)||!boolean(row[@"enabled"]))return NO;[ids addObject:row[@"id"]];}
    if(leaseTrue(value[@"suppressed"])){for(NSString *key in @[@"enabled",@"current_menu_matches",@"active",@"hook_owned",@"original_items_unchanged",@"apple_preserved"])if(!leaseTrue(value[key]))return NO;
        if(![value[@"apple_frame"] isKindOfClass:NSArray.class]||[value[@"apple_frame"] count]!=4)return NO;for(id n in value[@"apple_frame"])if(![n isKindOfClass:NSNumber.class]||boolean(n)||!isfinite([n doubleValue]))return NO;}
    return YES;
}
@interface B15AppMenuClient:NSObject
@property NSDictionary *settings,*snapshot;
@property(copy) void(^changed)(void);
@property dispatch_queue_t queue;
@property dispatch_source_t reader,registryWatch,firstSnapshotDeadline;
@property NSDictionary *binding,*front;
// front/generation/snapshot/watchRequested are main-owned. These two mirror the
// current attempt only on the serial client queue, alongside reader/binding.
@property NSDictionary *watchFront;
@property NSUInteger watchGeneration;
@property BOOL watchRequested;
@property BOOL waitingForSnapshot;
@property NSMutableData *input;
@property NSUInteger generation;
@property NSString *reason;
- (void)refresh:(NSDictionary*)front;
- (void)refresh:(NSDictionary*)front force:(BOOL)force;
- (void)popup:(NSString*)heading epoch:(NSNumber*)epoch anchor:(NSPoint)point;
- (void)close;
- (void)cancelFirstSnapshotDeadline;
- (void)armFirstSnapshotDeadline:(NSUInteger)generation;
@end
@implementation B15AppMenuClient
- (instancetype)init {if((self=[super init])){self.queue=dispatch_queue_create("dev.hyprwm.b15.client",DISPATCH_QUEUE_SERIAL);self.reason=@"not-connected";}return self;}
- (void)publish:(NSDictionary*)snapshot reason:(NSString*)reason generation:(NSUInteger)generation {dispatch_async(dispatch_get_main_queue(),^{if(self.generation!=generation){B15BarTrace(@"watch-discard generation=%lu current=%lu epoch=%@",(unsigned long)generation,(unsigned long)self.generation,B15TraceEpoch(snapshot[@"epoch"]));return;}B15BarTrace(@"watch-publish generation=%lu epoch=%@ suppressed=%d pending=%d reason=%@",(unsigned long)generation,B15TraceEpoch(snapshot[@"epoch"]),leaseTrue(snapshot[@"suppressed"]),leaseTrue(snapshot[@"popup_pending"]),reason);self.waitingForSnapshot=NO;self.snapshot=snapshot;if(!snapshot)self.watchRequested=NO;self.reason=reason;if(self.changed)self.changed();});}
- (void)cancelFirstSnapshotDeadline {if(self.firstSnapshotDeadline){dispatch_source_cancel(self.firstSnapshotDeadline);self.firstSnapshotDeadline=nil;}}
- (void)armFirstSnapshotDeadline:(NSUInteger)generation {
    [self cancelFirstSnapshotDeadline];self.firstSnapshotDeadline=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
    dispatch_source_set_timer(self.firstSnapshotDeadline,dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),DISPATCH_TIME_FOREVER,0);
    __weak B15AppMenuClient *weak=self;
    dispatch_source_set_event_handler(self.firstSnapshotDeadline,^{B15AppMenuClient *client=weak;if(!client||!client.firstSnapshotDeadline||!client.reader||client.generation!=generation||client.watchGeneration!=generation)return;
        B15BarTrace(@"watch-first-snapshot-timeout generation=%lu",(unsigned long)generation);[client closeReader];[client publish:nil reason:@"menu-initial-snapshot-timeout" generation:generation];});
    dispatch_resume(self.firstSnapshotDeadline);
}
- (void)closeReader {[self cancelFirstSnapshotDeadline];if(self.reader){dispatch_source_cancel(self.reader);self.reader=nil;}self.binding=nil;self.input=nil;}
- (void)close {self.generation++;self.watchRequested=NO;self.waitingForSnapshot=NO;self.snapshot=nil;dispatch_async(self.queue,^{[self closeReader];if(self.registryWatch){dispatch_source_cancel(self.registryWatch);self.registryWatch=nil;}});}
- (void)registryChanged {
    // Called on the client queue: an unrelated owner write must not tear down a
    // healthy watch. Re-read/authenticate the current owner's actual binding.
    NSUInteger generation=self.watchGeneration;NSDictionary *front=self.watchFront;
    if(generation!=self.generation)return;
    NSDictionary *binding=front?B15Binding(self.settings,front):nil;
    if(generation!=self.generation||(self.reader&&[binding isEqual:self.binding]))return;
    dispatch_async(dispatch_get_main_queue(),^{if(self.generation==generation)[self refresh:frontIdentity() force:YES];});
}
- (void)watchRegistry {
    if(self.registryWatch)return;id statePath=self.settings[@"b15_menu_state_path"];if(![statePath isKindOfClass:NSString.class])return;NSString *directory=[statePath stringByDeletingLastPathComponent];struct stat s={0};if(!directory.isAbsolutePath||lstat(directory.fileSystemRepresentation,&s)||!S_ISDIR(s.st_mode)||s.st_uid!=getuid()||(s.st_mode&0777)!=0700)return;
    int fd=open(directory.fileSystemRepresentation,O_EVTONLY|O_CLOEXEC);if(fd<0)return;
    self.registryWatch=dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,fd,DISPATCH_VNODE_WRITE|DISPATCH_VNODE_RENAME|DISPATCH_VNODE_DELETE,self.queue);__weak B15AppMenuClient *weak=self;
    dispatch_source_set_event_handler(self.registryWatch,^{B15AppMenuClient *client=weak;if(client)[client registryChanged];});dispatch_source_set_cancel_handler(self.registryWatch,^{close(fd);});dispatch_resume(self.registryWatch);
}
- (void)refresh:(NSDictionary*)front {[self refresh:front force:NO];}
- (void)refresh:(NSDictionary*)front force:(BOOL)force {
    if(![self.settings[@"b15_menu_enabled"] isEqual:@YES])return;
    if(!force&&self.watchRequested&&B15SameBirth(self.front,front))return;
    B15BarTrace(@"watch-refresh front_pid=%d prior_epoch=%@ generation=%lu",[front[@"pid"] intValue],B15TraceEpoch(self.snapshot[@"epoch"]),(unsigned long)(self.generation+1));
    self.front=front;self.watchRequested=YES;self.waitingForSnapshot=YES;NSUInteger generation=++self.generation;self.snapshot=nil;self.reason=@"native-menu-watch-pending";
    dispatch_async(self.queue,^{if(generation!=self.generation)return;self.watchFront=front;self.watchGeneration=generation;[self watchRegistry];[self closeReader];NSDictionary *binding=front?B15Binding(self.settings,front):nil;int fd=binding?B15Connect(binding):-1;
        if(fd<0||!B15Send(fd,binding,@{@"op":@"watch"})){if(fd>=0)close(fd);[self publish:nil reason:@"qualified-menu-owner-unavailable" generation:generation];return;}
        self.binding=binding;self.input=[NSMutableData new];self.reader=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,self.queue);dispatch_source_set_cancel_handler(self.reader,^{close(fd);});[self armFirstSnapshotDeadline:generation];
        dispatch_source_set_event_handler(self.reader,^{if(generation!=self.generation)return;uint8_t bytes[8192];ssize_t count=recv(fd,bytes,sizeof(bytes),0);
            if(count<=0){[self closeReader];[self publish:nil reason:@"menu-endpoint-closed" generation:generation];return;}[self.input appendBytes:bytes length:(NSUInteger)count];
            if(self.input.length>131072){[self closeReader];[self publish:nil reason:@"menu-endpoint-overflow" generation:generation];return;}
            while(YES){const uint8_t *buffer=self.input.bytes;NSUInteger index=0;while(index<self.input.length&&buffer[index]!='\n')index++;if(index==self.input.length)break;
                NSData *line=[self.input subdataWithRange:NSMakeRange(0,index)];[self.input replaceBytesInRange:NSMakeRange(0,index+1) withBytes:NULL length:0];id snapshot=[NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];snapshot=B15PresentationSnapshot(snapshot,binding);
                if(!B15SnapshotValid(snapshot,binding)||!B15SameBirth(B15Birth([front[@"pid"] intValue]),front)){[self closeReader];[self publish:nil reason:@"menu-owner-or-snapshot-changed" generation:generation];return;}
                [self cancelFirstSnapshotDeadline];[self publish:snapshot reason:leaseTrue(snapshot[@"suppressed"])?@"native-representation-hidden":@"native-representation-not-hidden" generation:generation];}
        });dispatch_resume(self.reader);
    });
}
- (void)popup:(NSString*)heading epoch:(NSNumber*)epoch anchor:(NSPoint)point {
    NSDictionary *front=self.front;NSUInteger generation=self.generation;
    B15BarTrace(@"popup-request id=%@ request_epoch=%@ watch_epoch=%@ generation=%lu",B15TraceID(heading),B15TraceEpoch(epoch),B15TraceEpoch(self.snapshot[@"epoch"]),(unsigned long)generation);
    dispatch_async(self.queue,^{if(generation!=self.generation){B15BarTrace(@"popup-skip predicate=generation_changed request_epoch=%@ generation=%lu current=%lu",B15TraceEpoch(epoch),(unsigned long)generation,(unsigned long)self.generation);return;}NSDictionary *binding=self.binding;if(!binding||!B15SameBirth(B15Birth([front[@"pid"] intValue]),front)){B15BarTrace(@"popup-skip predicate=binding_or_birth request_epoch=%@",B15TraceEpoch(epoch));return;}int fd=B15Connect(binding);if(fd<0){B15BarTrace(@"popup-skip predicate=connect_failed request_epoch=%@",B15TraceEpoch(epoch));return;}
        BOOL sent=B15Send(fd,binding,@{@"op":@"popup",@"heading":heading,@"epoch":epoch,@"anchor":@[@(point.x),@(point.y)]});
        B15BarTrace(@"popup-send sent=%d request_epoch=%@",sent,B15TraceEpoch(epoch));
        if(sent){struct pollfd wait={fd,POLLIN,0};int ready=poll(&wait,1,500);B15BarTrace(@"popup-poll ready=%d request_epoch=%@",ready,B15TraceEpoch(epoch));if(ready>0){char bytes[4096];ssize_t n=recv(fd,bytes,sizeof(bytes),0);B15BarTrace(@"popup-recv bytes=%zd request_epoch=%@",n,B15TraceEpoch(epoch));if(n>0){id reply=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)n] options:0 error:NULL];B15BarTrace(@"popup-reply ok=%d error=%@ request_epoch=%@ reply_epoch=%@",leaseTrue(reply[@"ok"]),leaseTrue(reply[@"ok"])?@"none":B15TraceRPCError(reply[@"error"]),B15TraceEpoch(epoch),B15TraceEpoch(reply[@"epoch"]));if(!leaseTrue(reply[@"ok"]))[self publish:nil reason:@"original-submenu-request-refused" generation:generation];}}}close(fd);
    });
}
@end
