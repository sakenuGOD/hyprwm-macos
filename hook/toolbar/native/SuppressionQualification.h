// Read only. Never runs appmenuctl/LLDB, loads owner code, or changes menus.
#import <libproc.h>
#import <sys/proc_info.h>
#import <sys/stat.h>
#import <fcntl.h>
static BOOL leaseTrue(id value) { return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue]; }
static BOOL leaseSHA(id value) { return [value isKindOfClass:NSString.class]&&[value length]==64&&[value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound; }
static BOOL suppressionLeaseValid(NSDictionary *lease,NSDictionary *actual,NSString *expectedSHA,NSTimeInterval now) {
    if(![lease isKindOfClass:NSDictionary.class]||![lease[@"schema"] isEqual:@1]||![lease[@"kind"] isEqual:@"native-menu-suppression-qualification"]||!leaseSHA(expectedSHA)||![lease[@"module_sha256"] isEqual:expectedSHA]||![actual isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"enabled",@"current_menu_matches",@"apple_preserved",@"right_preserved",@"headings_hidden",@"detached",@"not_stopped_after_detach"])if(!leaseTrue(lease[key]))return NO;
    NSDictionary *identity=lease[@"identity"];if(![identity isKindOfClass:NSDictionary.class])return NO;
    for(NSString *key in @[@"pid",@"uid",@"birth_sec",@"birth_usec",@"executable"])if(!actual[key]||![identity[key] isEqual:actual[key]])return NO;
    id issued=lease[@"qualified_at"],expires=lease[@"valid_until"];
    if(![issued isKindOfClass:NSNumber.class]||![expires isKindOfClass:NSNumber.class])return NO;
    double start=[issued doubleValue],end=[expires doubleValue];return isfinite(now)&&isfinite(start)&&isfinite(end)&&start<=now+2&&end>now&&end>start&&end-start<=300&&now-start<=300;
}
static NSDictionary *frontIdentity(void) {
    pid_t pid=NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;struct proc_bsdinfo info={0};char path[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(pid<=0||proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info)||info.pbi_uid!=getuid()||proc_pidpath(pid,path,sizeof(path))<=0)return nil;
    return @{@"pid":@(pid),@"uid":@(info.pbi_uid),@"birth_sec":@(info.pbi_start_tvsec),@"birth_usec":@(info.pbi_start_tvusec),@"executable":@(path)};
}
static NSDictionary *readPrivateSuppressionLease(NSString *path) {
    if(![path isKindOfClass:NSString.class]||!path.isAbsolutePath||![path.stringByResolvingSymlinksInPath isEqual:path])return nil;
    struct stat parent={0};if(lstat(path.stringByDeletingLastPathComponent.fileSystemRepresentation,&parent)||!S_ISDIR(parent.st_mode)||parent.st_uid!=getuid()||(parent.st_mode&0777)!=0700)return nil;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;struct stat file={0};
    if(fstat(fd,&file)||!S_ISREG(file.st_mode)||file.st_uid!=getuid()||(file.st_mode&0777)!=0600||file.st_size<=0||file.st_size>16384){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)file.st_size];NSUInteger offset=0;while(offset<data.length){ssize_t n=read(fd,(char *)data.mutableBytes+offset,data.length-offset);if(n<=0){close(fd);return nil;}offset+=(NSUInteger)n;}close(fd);
    id lease=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];return [lease isKindOfClass:NSDictionary.class]?lease:nil;
}
