#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <libproc.h>
#import <dlfcn.h>
#import <ptrauth.h>
#import <uuid/uuid.h>
#import <pthread.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdatomic.h>
#import <signal.h>
#include "../src/managed_process_identity.c"

// Constructor-free. All AppKit/Dock work is explicit and actual-main only.
static NSString *const DSDock=@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock";
static NSString *const DSDockUUID=@"073A7E75-21BB-3427-8180-9B9B3B80212B";
static NSString *const DSSky=@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight";
static NSString *const DSSkyUUID=@"CD5F2362-8462-38D4-8C57-0BCD4E04F962";
static NSDictionary *DSLease,*DSTicketCatalog,*DSPendingTarget,*DSBoundPeer;
static pthread_mutex_t DSPeerLock=PTHREAD_MUTEX_INITIALIZER;
static atomic_uint DSQueued;
static NSDictionary *DSCurrentPeer(void){pthread_mutex_lock(&DSPeerLock);NSDictionary *peer=DSBoundPeer?:DSLease[@"peer"];pthread_mutex_unlock(&DSPeerLock);return peer;}
static void DSSetPeer(NSDictionary *peer){pthread_mutex_lock(&DSPeerLock);DSBoundPeer=peer;pthread_mutex_unlock(&DSPeerLock);}

static NSString *DSTicket,*DSPendingID;
static NSMutableSet *DSConsumed;
static uint64_t DSExpires,DSDispatchCount;
static atomic_uint DSEpoch;
static atomic_bool DSEnabled;
static dispatch_source_t DSServer;
#ifdef HYPR_DS_FIXTURE
static id DSFixtureActor;
static Class DSFixtureActorClass,DSFixtureSpaceClass;
static NSDictionary *DSFixtureCatalog;
static NSDictionary *DSFixtureChangeCatalog;
static id DSFixtureChangeActor;
static NSUInteger DSFixtureReads,DSFixtureChangeAt;
#endif
static uint64_t DSNow(void){struct timespec t={0};clock_gettime(CLOCK_MONOTONIC,&t);return(uint64_t)t.tv_sec*1000000000+t.tv_nsec;}
static BOOL DSString(id v,NSUInteger n){return[v isKindOfClass:NSString.class]&&[v length]>0&&[v length]<=n&&[v rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound;}
static BOOL DSUInt(id v){return[v isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)v)!=CFBooleanGetTypeID()&&[v doubleValue]>0&&[v doubleValue]<9007199254740992.0&&[v doubleValue]==[v unsignedLongLongValue];}
static NSDictionary *DSFail(NSString *why){BOOL main=pthread_main_np();return@{@"ok":@NO,@"error":why?:@"refused",@"acknowledged":@NO,@"pending":main?@(DSPendingID!=nil):NSNull.null,@"native_dispatches":main?@(DSDispatchCount):NSNull.null};}
static NSDictionary *DSIdentity(pid_t pid){uint64_t b[4]={0},after[4]={0};char p[PROC_PIDPATHINFO_MAXSIZE]={0},again[PROC_PIDPATHINFO_MAXSIZE]={0};
 if(managed_process_identity(pid,b)||proc_pidpath(pid,p,sizeof(p))<=0||managed_process_identity(pid,after)||memcmp(b,after,sizeof(b))||proc_pidpath(pid,again,sizeof(again))<=0||strcmp(p,again))return nil;
 return@{@"pid":@(pid),@"uid":@(b[1]),@"sec":@(b[2]),@"usec":@(b[3]),@"path":@(p)};}
static NSString *DSUUID(const struct mach_header *h){if(!h||h->magic!=MH_MAGIC_64||h->ncmds>256||h->sizeofcmds>1048576)return nil;
 const uint8_t *p=(const uint8_t*)h+32,*end=p+h->sizeofcmds;for(uint32_t n=0;n<h->ncmds;n++){if(p+8>end)return nil;const struct load_command *c=(const void*)p;if(c->cmdsize<8||c->cmdsize>(uintptr_t)(end-p))return nil;
 if(c->cmd==LC_UUID&&c->cmdsize>=sizeof(struct uuid_command)){char s[37];uuid_unparse_upper(((const struct uuid_command*)c)->uuid,s);return@(s);}p+=c->cmdsize;}return nil;}
static BOOL DSPlatform(void){
#ifdef HYPR_DS_FIXTURE
 return YES;
#else
 char build[64]={0};size_t n=sizeof(build);return sysctlbyname("kern.osversion",build,&n,NULL,0)==0&&!strcmp(build,"25G241")&&[DSIdentity(getpid())[@"path"]isEqual:DSDock]&&[DSUUID(_dyld_get_image_header(0))isEqual:DSDockUUID];
#endif
}
static IMP DSMethod(id obj,const char *sel,const char *types,uintptr_t unslid,NSString **why){Method m=class_getInstanceMethod(object_getClass(obj),sel_registerName(sel));
 if(!m||strcmp(method_getTypeEncoding(m),types)){*why=@"native_method_abi";return NULL;}IMP imp=method_getImplementation(m);void *code=ptrauth_strip((void*)imp,ptrauth_key_function_pointer);Dl_info d={0};const struct mach_header *main=_dyld_get_image_header(0);
 if(!dladdr(code,&d)||d.dli_fbase!=main||![DSUUID(d.dli_fbase)isEqual:DSUUID(main)]){*why=@"native_method_image";return NULL;}
#ifndef HYPR_DS_FIXTURE
 if(![DSDock isEqual:@(d.dli_fname)]||(uintptr_t)code-(uintptr_t)main+0x100000000ULL!=unslid){*why=@"native_method_address";return NULL;}
#else
 (void)unslid;
#endif
 return imp;}
static id DSActor(NSString **why){
#ifdef HYPR_DS_FIXTURE
 id actor=DSFixtureActor;Class expected=DSFixtureActorClass;
#else
 const struct mach_header_64 *h=(const void*)_dyld_get_image_header(0);const uint8_t *p=(const void*)(h+1);BOOL found=NO;
 for(uint32_t n=0;n<h->ncmds;n++){const struct load_command *c=(const void*)p;if(c->cmd==LC_SEGMENT_64){const struct segment_command_64 *s=(const void*)c;
 if(!strcmp(s->segname,"__DATA")&&c->cmdsize>=sizeof(*s)+s->nsects*sizeof(struct section_64)){const struct section_64 *v=(const void*)(s+1);for(uint32_t k=0;k<s->nsects;k++)if(!strcmp(v[k].sectname,"__common")&&v[k].addr<=0x100488028ULL&&v[k].addr+v[k].size>=0x100488030ULL)found=YES;}}p+=c->cmdsize;}
 if(!found){*why=@"canonical_slot_section";return nil;}void *raw=NULL;memcpy(&raw,(const uint8_t*)h+0x488028,sizeof(raw));id actor=(__bridge id)raw;Class expected=objc_getClass("Spaces");
#endif
 if(!actor||!expected||object_getClass(actor)!=expected){*why=@"canonical_actor_class";return nil;}
 if(!DSMethod(actor,"allUserSpaces","@16@0:8",0x1001ea164,why)||!DSMethod(actor,"anySwitchingOccurring","B16@0:8",0x1001ea074,why)||!DSMethod(actor,"currentSpaceForDisplayUUID:","@24@0:8@16",0x1001ee1b4,why)||!DSMethod(actor,"switchToUserSpace:","B24@0:8q16",0x1001eab94,why))return nil;return actor;}
#ifndef HYPR_DS_FIXTURE
static void *DSNative(const char *name){void *raw=dlsym(RTLD_DEFAULT,name),*code=ptrauth_strip(raw,ptrauth_key_function_pointer);Dl_info d={0};
 if(!code||!dladdr(code,&d)||!d.dli_fname||![DSSky isEqual:@(d.dli_fname)]||![DSUUID(d.dli_fbase)isEqual:DSSkyUUID])return NULL;
 return ptrauth_sign_unauthenticated(code,ptrauth_key_function_pointer,0);}
#endif
static BOOL DSOwnerGeneration(void){if(!DSPlatform()||![DSIdentity(getpid())isEqual:DSLease[@"owner"]])return NO;
#ifdef HYPR_DS_FIXTURE
 return YES;
#else
 NSDictionary *g=DSLease[@"generation"];if(![g isKindOfClass:NSDictionary.class])return NO;NSDictionary *ws=g[@"window_server"];return[g[@"build"]isEqual:@"25G241"]&&[g[@"sky_uuid"]isEqual:DSSkyUUID]&&[ws isKindOfClass:NSDictionary.class]&&[DSIdentity([ws[@"pid"]intValue])isEqual:ws]&&[ws[@"path"]isEqual:@"/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"];
#endif
}
static BOOL DSGeneration(void){NSDictionary *peer=DSCurrentPeer();return DSOwnerGeneration()&&[DSIdentity([peer[@"pid"]intValue])isEqual:peer];}
static BOOL DSPeerBirthGone(NSDictionary *peer){
 uint64_t b[4]={0};pid_t pid=[peer[@"pid"]intValue];if(pid<=0)return NO;
 if(!managed_process_identity(pid,b))return b[2]!=[peer[@"sec"]unsignedLongLongValue]||b[3]!=[peer[@"usec"]unsignedLongLongValue];
 return kill(pid,0)<0 && errno==ESRCH;
}
static NSDictionary *DSReadSnapshot(NSString **why,BOOL ownerOnly){if(!(ownerOnly?DSOwnerGeneration():DSGeneration())){*why=@"session_generation";return nil;}
#ifdef HYPR_DS_FIXTURE
 if(DSFixtureChangeAt&&++DSFixtureReads==DSFixtureChangeAt){DSFixtureCatalog=DSFixtureChangeCatalog;if(DSFixtureChangeActor)DSFixtureActor=DSFixtureChangeActor;}else if(!DSFixtureChangeAt)DSFixtureReads++;return DSFixtureCatalog;
#else
 int(*cidFn)(void)=DSNative("SLSMainConnectionID");CFArrayRef(*copy)(int)=DSNative("SLSCopyManagedDisplaySpaces");uint64_t(*current)(int,CFStringRef)=DSNative("SLSManagedDisplayGetCurrentSpace");uint64_t(*active)(int)=DSNative("SLSGetActiveSpace");
 if(!cidFn||!copy||!current||!active){*why=@"native_getter_provenance";return nil;}
 NSDictionary *session=CFBridgingRelease(CGSessionCopyCurrentDictionary());
 if(!session||![session[(__bridge NSString*)kCGSessionOnConsoleKey]boolValue]||[session[@"CGSSessionScreenIsLocked"]boolValue]||CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonLeft)||CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState,kCGMouseButtonRight)){*why=@"session_locked_offconsole_or_drag";return nil;}
 int cid=cidFn();uint64_t before=active(cid);NSArray *raw=CFBridgingRelease(copy(cid));if(![raw isKindOfClass:NSArray.class]||raw.count!=1){*why=@"single_display_catalog";return nil;}
 NSDictionary *display=raw[0];if(![display isKindOfClass:NSDictionary.class]){*why=@"display_shape";return nil;}NSString *name=display[@"Display Identifier"];NSArray *spaces=display[@"Spaces"];NSMutableArray *rows=[NSMutableArray new];NSMutableSet *ids=[NSMutableSet new];
 if(!DSString(name,128)||![[NSUUID alloc]initWithUUIDString:name]||![spaces isKindOfClass:NSArray.class]||!spaces.count||spaces.count>64){*why=@"bounded_catalog";return nil;}
 for(NSDictionary *s in spaces){if(![s isKindOfClass:NSDictionary.class]){*why=@"space_shape";return nil;}NSNumber *sid=s[@"id64"]?:s[@"ManagedSpaceID"],*type=s[@"type"];NSString *uuid=s[@"uuid"]?:s[@"UUID"];
 if(!DSUInt(sid)||[ids containsObject:sid]||![type isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)type)==CFBooleanGetTypeID()||[type doubleValue]!=[type integerValue]||![uuid isKindOfClass:NSString.class]||uuid.length>128||(s[@"ManagedSpaceID"]&&![s[@"ManagedSpaceID"]isEqual:sid])||(s[@"UUID"]&&![s[@"UUID"]isEqual:uuid])){*why=@"space_identity";return nil;}
 [ids addObject:sid];[rows addObject:@{@"sid":sid,@"uuid":uuid,@"type":type}];}
 NSDictionary *c=display[@"Current Space"];NSNumber *catalogCurrent=[c isKindOfClass:NSDictionary.class]?(c[@"id64"]?:c[@"ManagedSpaceID"]):nil;uint64_t getter=current(cid,(__bridge CFStringRef)name),after=active(cid);
 if(!DSUInt(catalogCurrent)||![ids containsObject:catalogCurrent]||before!=after||getter!=after||getter!=catalogCurrent.unsignedLongLongValue||!(ownerOnly?DSOwnerGeneration():DSGeneration())){*why=@"unstable_native_current";return nil;}
 return@{@"display":name,@"spaces":rows,@"current":@(getter),@"active":@(after)};
#endif
}
static NSDictionary *DSSnapshot(NSString **why){return DSReadSnapshot(why,NO);}
static BOOL DSBusy(id actor,NSString *display,NSString **why){IMP imp=DSMethod(actor,"anySwitchingOccurring","B16@0:8",0x1001ea074,why);if(!imp)return YES;
 if(((BOOL(*)(id,SEL))imp)(actor,sel_registerName("anySwitchingOccurring")))return YES;
#ifndef HYPR_DS_FIXTURE
 bool(*animating)(int,CFStringRef)=DSNative("SLSManagedDisplayIsAnimating");int(*cid)(void)=DSNative("SLSMainConnectionID");if(!animating||!cid){*why=@"native_busy_getter";return YES;}if(animating(cid(),(__bridge CFStringRef)display))return YES;
#else
 (void)display;
#endif
 return NO;}
static NSArray *DSMap(id actor,NSDictionary *catalog,NSString **why){IMP imp=DSMethod(actor,"allUserSpaces","@16@0:8",0x1001ea164,why);if(!imp)return nil;
 id objects=((id(*)(id,SEL))imp)(actor,sel_registerName("allUserSpaces"));NSArray *ordinary=[catalog[@"spaces"]filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row,NSDictionary *b){(void)b;return[row[@"type"]isEqual:@0];}]];
 if(![objects isKindOfClass:NSArray.class]||[objects count]!=ordinary.count||ordinary.count>64){*why=@"native_list_count";return nil;}NSUInteger index=0;
 for(id object in objects){
#ifdef HYPR_DS_FIXTURE
 Class expected=DSFixtureSpaceClass;
#else
 Class expected=objc_getClass("ManagedSpace");
#endif
 if(!expected||object_getClass(object)!=expected){*why=@"managed_space_class";return nil;}
 IMP sid=DSMethod(object,"spid","Q16@0:8",0x1001df374,why),uuid=DSMethod(object,"uuid","@16@0:8",0x1001df2f4,why),user=DSMethod(object,"userSpace","B16@0:8",0x1001df444,why),full=DSMethod(object,"fullscreen","B16@0:8",0x1001df43c,why);if(!sid||!uuid||!user||!full)return nil;
 id u=((id(*)(id,SEL))uuid)(object,sel_registerName("uuid"));NSDictionary *row=ordinary[index++];
 if(((uint64_t(*)(id,SEL))sid)(object,sel_registerName("spid"))!=[row[@"sid"]unsignedLongLongValue]||![u isKindOfClass:NSString.class]||![u isEqual:row[@"uuid"]]||!((BOOL(*)(id,SEL))user)(object,sel_registerName("userSpace"))||((BOOL(*)(id,SEL))full)(object,sel_registerName("fullscreen"))){*why=@"native_list_catalog_mismatch";return nil;}}
 IMP current=DSMethod(actor,"currentSpaceForDisplayUUID:","@24@0:8@16",0x1001ee1b4,why);if(!current)return nil;id source=((id(*)(id,SEL,id))current)(actor,sel_registerName("currentSpaceForDisplayUUID:"),catalog[@"display"]);NSUInteger sourceIndex=[objects indexOfObjectIdenticalTo:source];
 if(sourceIndex==NSNotFound||![ordinary[sourceIndex][@"sid"]isEqual:catalog[@"current"]]||![catalog[@"active"]isEqual:catalog[@"current"]]){*why=@"actor_current_catalog_mismatch";return nil;}return ordinary;}
static NSDictionary *DSCommandPeer(NSDictionary *r,unsigned epoch,NSDictionary *peer);
static NSDictionary *DSCommand(NSDictionary *r,unsigned epoch){return DSCommandPeer(r,epoch,nil);}
static BOOL DSAuth(NSDictionary *r){return DSLease&&[r[@"nonce"]isEqual:DSLease[@"nonce"]]&&[r[@"epoch"]isEqual:DSLease[@"epoch"]]&&[r[@"owner"]isEqual:DSLease[@"owner"]];}
static NSDictionary *DSSocketPeer(int fd){uid_t uid=0;gid_t gid=0;pid_t pid=0;socklen_t size=sizeof(pid);
 if(getpeereid(fd,&uid,&gid)||uid!=getuid()||getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size)||size!=sizeof(pid))return nil;
 NSDictionary *peer=DSIdentity(pid);return [peer[@"uid"]isEqual:@(uid)]?peer:nil;}
static void DSWrite(int fd,NSDictionary *r){NSData *d=[NSJSONSerialization dataWithJSONObject:r options:0 error:NULL];if(d.length>32768)return;const uint8_t *p=d.bytes;size_t left=d.length;uint64_t end=DSNow()+250000000ULL;while(left&&DSNow()<end){ssize_t n=send(fd,p,left,MSG_NOSIGNAL);if(n<=0)return;p+=n;left-=n;}if(!left)send(fd,"\n",1,MSG_NOSIGNAL);}
static void DSClient(int fd){int flags=fcntl(fd,F_GETFL);if(flags<0||fcntl(fd,F_SETFL,flags&~O_NONBLOCK)){close(fd);return;}int no=1;if(setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&no,sizeof(no))){close(fd);return;}struct timeval timeout={0,250000};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
 NSDictionary *peer=DSSocketPeer(fd);if(!peer){DSWrite(fd,DSFail(@"peer_identity"));close(fd);return;}char bytes[16385]={0};size_t used=0;uint64_t readEnd=DSNow()+250000000ULL;while(used<16384&&DSNow()<readEnd){ssize_t n=recv(fd,bytes+used,16384-used,0);if(n<=0)break;used+=n;if(memchr(bytes,'\n',used))break;}
 char *end=memchr(bytes,'\n',used);if(!end){close(fd);return;}NSDictionary *r=end?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:end-bytes] options:0 error:NULL]:nil;
 if(![r isKindOfClass:NSDictionary.class]){DSWrite(fd,DSFail(@"authenticated_frame_required"));close(fd);return;}
 if(![peer isEqual:DSCurrentPeer()]&&![r[@"op"]isEqual:@"rebind"]){DSWrite(fd,DSFail(@"peer_identity"));close(fd);return;}
 if(![r isKindOfClass:NSDictionary.class]||!DSAuth(r)||!atomic_load(&DSEnabled)){DSWrite(fd,DSFail(@"authenticated_frame_required"));close(fd);return;}
 if([r[@"op"]isEqual:@"cancel"])atomic_fetch_add(&DSEpoch,1);unsigned epoch=atomic_load(&DSEpoch);dispatch_semaphore_t done=dispatch_semaphore_create(0);__block NSDictionary *answer=nil;__block atomic_bool abandoned=false;
 atomic_fetch_add(&DSQueued,1);dispatch_async(dispatch_get_main_queue(),^{atomic_fetch_sub(&DSQueued,1);@try{if(!atomic_load(&abandoned)&&atomic_load(&DSEnabled))answer=DSCommandPeer(r,epoch,peer);}@catch(NSException *e){(void)e;answer=DSFail(@"native_exception_no_retry");}dispatch_semaphore_signal(done);});
 if(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,300*NSEC_PER_MSEC))!=0){atomic_store(&abandoned,true);DSWrite(fd,DSFail(@"main_dispatch_unconfirmed_no_retry"));}else DSWrite(fd,answer?:DSFail(@"cancelled"));close(fd);}
static BOOL DSStart(NSString *path){NSString *parent=path.stringByDeletingLastPathComponent;struct stat dir={0},before={0};
 if(!path.isAbsolutePath||![path isEqual:path.stringByResolvingSymlinksInPath]||lstat(parent.fileSystemRepresentation,&dir)||!S_ISDIR(dir.st_mode)||dir.st_uid!=getuid()||(dir.st_mode&0077)||lstat(path.fileSystemRepresentation,&before)==0||errno!=ENOENT)return NO;
 struct sockaddr_un address={.sun_family=AF_UNIX};if(strlen(path.fileSystemRepresentation)>=sizeof(address.sun_path))return NO;strcpy(address.sun_path,path.fileSystemRepresentation);
 int fd=socket(AF_UNIX,SOCK_STREAM,0);if(fd<0)return NO;fcntl(fd,F_SETFD,FD_CLOEXEC);fcntl(fd,F_SETFL,O_NONBLOCK);struct stat descriptor={0},file={0};
 if(bind(fd,(const struct sockaddr*)&address,sizeof(address))){close(fd);return NO;}
 if(lstat(path.fileSystemRepresentation,&file)||!S_ISSOCK(file.st_mode)||file.st_uid!=getuid()){close(fd);return NO;}
 if(chmod(path.fileSystemRepresentation,0600)||listen(fd,4)||fstat(fd,&descriptor)){close(fd);if(!lstat(path.fileSystemRepresentation,&before)&&before.st_dev==file.st_dev&&before.st_ino==file.st_ino)unlink(path.fileSystemRepresentation);return NO;}
 DSServer=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,fd,0,dispatch_queue_create("hyprwm.dockspaces.current-life",DISPATCH_QUEUE_SERIAL));if(!DSServer){close(fd);if(!lstat(path.fileSystemRepresentation,&before)&&before.st_dev==file.st_dev&&before.st_ino==file.st_ino)unlink(path.fileSystemRepresentation);return NO;}
 dispatch_source_set_event_handler(DSServer,^{for(unsigned n=0;n<4;n++){int client=accept(fd,NULL,NULL);if(client<0)break;@autoreleasepool{DSClient(client);}}});
 dispatch_source_set_cancel_handler(DSServer,^{struct stat actual={0};if(!fstat(fd,&actual)&&actual.st_dev==descriptor.st_dev&&actual.st_ino==descriptor.st_ino)close(fd);if(!lstat(path.fileSystemRepresentation,&actual)&&actual.st_dev==file.st_dev&&actual.st_ino==file.st_ino)unlink(path.fileSystemRepresentation);});dispatch_resume(DSServer);return YES;}
static NSDictionary *DSCommandPeer(NSDictionary *r,unsigned epoch,NSDictionary *peer){if(!pthread_main_np())return DSFail(@"actual_main_thread_required");NSString *op=r[@"op"],*why=nil;if(!DSString(op,32)||!DSPlatform())return DSFail(@"exact_dock_platform_required");
 if([op isEqual:@"install"]){if(DSLease)return DSFail(@"current_lifetime_already_bound");NSDictionary *self=DSIdentity(getpid()),*peer=r[@"peer"];NSString *nonce=r[@"nonce"];
 if(![r[@"owner"]isEqual:self]||![peer isKindOfClass:NSDictionary.class]||![DSIdentity([peer[@"pid"]intValue])isEqual:peer]||![peer[@"uid"]isEqual:@(getuid())]||![r[@"generation"]isKindOfClass:NSDictionary.class]||!DSString(nonce,64)||nonce.length!=64||!DSString(r[@"epoch"],128)||!DSString(r[@"socket"],103))return DSFail(@"explicit_owner_peer_nonce_required");
#ifndef HYPR_DS_FIXTURE
 if([peer[@"pid"]intValue]==getpid())return DSFail(@"separate_manager_peer_required");
#endif
 DSLease=[r copy];DSSetPeer(r[@"peer"]);NSDictionary *catalog=DSSnapshot(&why);id actor=DSActor(&why);if(!catalog||!actor||!DSMap(actor,catalog,&why)||DSBusy(actor,catalog[@"display"],&why)){DSLease=nil;return DSFail(why?:@"native_busy");}
 if(!DSStart(r[@"socket"])){DSLease=nil;return DSFail(@"private_endpoint_failed");}DSConsumed=[NSMutableSet new];atomic_store(&DSEpoch,1);atomic_store(&DSEnabled,true);return@{@"ok":@YES,@"installed":@YES,@"endpoint":r[@"socket"],@"acknowledged":@NO};}
 if(!DSAuth(r)||!atomic_load(&DSEnabled)||![DSIdentity(getpid())isEqual:DSLease[@"owner"]])return DSFail(@"current_lifetime_auth_required");
 if([op isEqual:@"rebind"]){
  NSDictionary *old=DSCurrentPeer();
  if(!peer||![DSIdentity([peer[@"pid"]intValue])isEqual:peer]||![peer[@"uid"]isEqual:@(getuid())]||![peer[@"path"]isEqual:DSLease[@"peer"][@"path"]]||!DSPeerBirthGone(old)||!DSOwnerGeneration())return DSFail(@"rebind_exact_successor_required");
  if(atomic_load(&DSQueued)||DSPendingID||DSPendingTarget)return DSFail(@"rebind_pending_work");
  NSDictionary *catalog=DSReadSnapshot(&why,YES);id actor=DSActor(&why);
  if(!catalog||!actor||!DSMap(actor,catalog,&why)||DSBusy(actor,catalog[@"display"],&why))return DSFail(why?:@"rebind_native_busy");
  if(!DSPeerBirthGone(old)||![DSIdentity([peer[@"pid"]intValue])isEqual:peer]||!DSOwnerGeneration()||atomic_load(&DSQueued))return DSFail(@"rebind_final_identity_fence");
  DSSetPeer(peer);atomic_fetch_add(&DSEpoch,1);DSTicket=nil;DSTicketCatalog=nil;DSExpires=0;
  return @{@"ok":@YES,@"rebound":@YES,@"native_dispatched":@NO,@"acknowledged":@NO,@"native_dispatches":@(DSDispatchCount)};
 }
 if([op isEqual:@"cancel"]){atomic_fetch_add(&DSEpoch,1);DSTicket=nil;DSTicketCatalog=nil;if([r[@"shutdown"]isEqual:@YES]){atomic_store(&DSEnabled,false);if(DSServer)dispatch_source_cancel(DSServer);}return@{@"ok":@YES,@"queued_cancelled":@YES,@"native_dispatched":@(DSPendingID!=nil),@"native_cancel_supported":@NO,@"acknowledged":@NO};}
 if(!DSGeneration())return DSFail(@"session_generation");
 if(epoch!=atomic_load(&DSEpoch))return DSFail(@"cancelled_epoch");NSDictionary *catalog=DSSnapshot(&why);id actor=DSActor(&why);NSArray *ordinary=(catalog&&actor)?DSMap(actor,catalog,&why):nil;if(!ordinary)return DSFail(why);
 BOOL busy=DSBusy(actor,catalog[@"display"],&why);if(why)return DSFail(why);BOOL observed=DSPendingID&&!busy&&[catalog[@"current"]isEqual:DSPendingTarget[@"sid"]];if(observed){DSPendingID=nil;DSPendingTarget=nil;}
 if([op isEqual:@"status"]){if(!busy&&!DSPendingID){DSTicket=NSUUID.UUID.UUIDString;DSTicketCatalog=catalog;DSExpires=DSNow()+1000000000ULL;}else{DSTicket=nil;DSTicketCatalog=nil;}return@{@"ok":@YES,@"busy":@(busy),@"pending":@(DSPendingID!=nil),@"native_observed":@(observed),@"acknowledged":@NO,@"catalog":catalog,@"ticket":DSTicket?:@"",@"expires_uptime_ns":@(DSExpires),@"native_dispatches":@(DSDispatchCount)};}
 if(![op isEqual:@"switch-existing"])return DSFail(@"operation_unknown");NSSet *keys=[NSSet setWithArray:r.allKeys],*allowed=[NSSet setWithArray:@[@"op",@"owner",@"nonce",@"epoch",@"ticket",@"source",@"target",@"request_id"]];
 if(![keys isEqual:allowed]||!DSString(r[@"request_id"],128)||DSConsumed.count>=4096||[DSConsumed containsObject:r[@"request_id"]]||!DSTicket||![r[@"ticket"]isEqual:DSTicket]||DSNow()>DSExpires||DSPendingID||busy)return DSFail(@"one_shot_existing_ticket_required");
 NSDictionary *prepared=DSTicketCatalog;DSTicket=nil;DSTicketCatalog=nil;[DSConsumed addObject:r[@"request_id"]];
 if(![r[@"source"]isKindOfClass:NSDictionary.class])return DSFail(@"source_catalog_shape");NSData *sourceJSON=[NSJSONSerialization dataWithJSONObject:r[@"source"] options:NSJSONWritingSortedKeys error:NULL],*preparedJSON=[NSJSONSerialization dataWithJSONObject:prepared options:NSJSONWritingSortedKeys error:NULL];
 if(![sourceJSON isEqual:preparedJSON]||![catalog isEqual:prepared])return DSFail(@"source_topology_changed");NSDictionary *target=r[@"target"];if(![target isKindOfClass:NSDictionary.class]||!DSUInt(target[@"sid"])||![target[@"type"]isKindOfClass:NSNumber.class]||CFGetTypeID((__bridge CFTypeRef)target[@"type"])==CFBooleanGetTypeID())return DSFail(@"exact_target_types");NSUInteger index=NSNotFound;
 for(NSUInteger n=0;n<ordinary.count;n++){NSDictionary *row=ordinary[n],*candidate=@{@"display":catalog[@"display"],@"sid":row[@"sid"],@"uuid":row[@"uuid"],@"type":@0};if([target isEqual:candidate])index=n;}
 if(index==NSNotFound)return DSFail(@"exact_existing_ordinary_target_required");if([target[@"sid"]isEqual:catalog[@"current"]])return@{@"ok":@YES,@"already_current":@YES,@"native_dispatched":@NO,@"acknowledged":@NO};
 NSDictionary *final=DSSnapshot(&why);id finalActor=DSActor(&why);NSArray *finalOrdinary=(final&&finalActor)?DSMap(finalActor,final,&why):nil;IMP switcher=finalActor?DSMethod(finalActor,"switchToUserSpace:","B24@0:8q16",0x1001eab94,&why):NULL;
 if(!final||![final isEqual:catalog]||finalActor!=actor||![finalOrdinary isEqual:ordinary]||!switcher||DSBusy(finalActor,catalog[@"display"],&why)||DSNow()>DSExpires||epoch!=atomic_load(&DSEpoch)||!DSGeneration())return DSFail(why?:@"final_source_lifetime_fence");
 DSPendingID=[r[@"request_id"]copy];DSPendingTarget=[target copy];DSDispatchCount++;BOOL accepted=((BOOL(*)(id,SEL,NSInteger))switcher)(actor,sel_registerName("switchToUserSpace:"),(NSInteger)index);
 return@{@"ok":@(accepted),@"native_dispatched":@YES,@"pending":@YES,@"native_index":@(index),@"request_id":DSPendingID,@"acknowledged":@NO,@"native_dispatches":@(DSDispatchCount)};}

__attribute__((visibility("default"))) int hypr_dockspaces_v1_json(const char *input,char *output,uint32_t capacity){if(!output||capacity<32768||capacity>262144)return 1;output[0]=0;if(!pthread_main_np())return 2;
 @autoreleasepool{@try{size_t n=input?strnlen(input,16385):0;id r=(n&&n<=16384)?[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:input length:n] options:0 error:NULL]:nil;
 NSDictionary *answer=[r isKindOfClass:NSDictionary.class]?DSCommand(r,atomic_load(&DSEpoch)):DSFail(@"bounded_json_object_required");NSData *data=[NSJSONSerialization dataWithJSONObject:answer options:NSJSONWritingSortedKeys error:NULL];if(!data||data.length+1>capacity)return 1;memcpy(output,data.bytes,data.length);output[data.length]=0;return[answer[@"ok"]boolValue]?0:4;
 }@catch(NSException *exception){(void)exception;const char *error="{\"ok\":false,\"error\":\"native_exception_no_retry\",\"acknowledged\":false}";strlcpy(output,error,capacity);return 5;}}}
