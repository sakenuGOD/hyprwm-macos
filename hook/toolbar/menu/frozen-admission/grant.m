#import "grant.h"
#import "admission.h"
#import "client.h"
#include <pwd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static NSDictionary *ReadGrant(NSString *directory,NSString *filename) {
    struct stat parent={0};
    if (lstat(directory.fileSystemRepresentation,&parent) || !S_ISDIR(parent.st_mode) ||
        parent.st_uid!=getuid() || (parent.st_mode&077)) return nil;
    NSString *path=[directory stringByAppendingPathComponent:filename];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return nil;
    struct stat before={0},after={0};NSMutableData *bytes=nil;
    if(!fstat(fd,&before) && S_ISREG(before.st_mode) && before.st_uid==getuid() && !(before.st_mode&077) && before.st_size>0 && before.st_size<=65536) {
        bytes=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t count=0;
        while(count<bytes.length) {ssize_t n=read(fd,(uint8_t *)bytes.mutableBytes+count,bytes.length-count);if(n<=0)break;count+=(size_t)n;}
        if(count!=bytes.length || fstat(fd,&after) || before.st_dev!=after.st_dev || before.st_ino!=after.st_ino ||
           before.st_size!=after.st_size || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec) bytes=nil;
    }
    close(fd);
    id grant=bytes?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:NULL]:nil;
    if(![grant isKindOfClass:NSDictionary.class] || ![grant[@"schema"] isEqual:@1] ||
       ![grant[@"targets"] isKindOfClass:NSArray.class] || [grant[@"targets"] count]>128)return nil;
    return grant;
}
int HAInstallGranted(NSDictionary *identity) {
    if (!NSThread.isMainThread || ![identity isKindOfClass:NSDictionary.class]) return -1;
    struct passwd record={0},*user=NULL;char userBuffer[16384];
    if (getpwuid_r(getuid(),&record,userBuffer,sizeof(userBuffer),&user) || !user || user->pw_uid!=getuid() || !user->pw_dir) return 0;
    NSString *home=NSHomeDirectory(),*realHome=@(user->pw_dir);
    BOOL container=![home isEqual:realHome] && [home hasPrefix:[realHome stringByAppendingPathComponent:@"Library/Containers/"]] && [home hasSuffix:@"/Data"];
    NSString *directory=container?[home stringByAppendingPathComponent:@".hwm"]:[realHome stringByAppendingPathComponent:@"Library/Application Support/HyprWM/first-map"];
    NSDictionary *grant=ReadGrant(directory,container?[NSString stringWithFormat:@"g%d",getpid()]:@"grants.json");if(!grant)return 0;
    NSArray *birth=@[identity[@"pid"]?:NSNull.null,identity[@"uid"]?:NSNull.null,
        identity[@"birth_sec"]?:NSNull.null,identity[@"birth_usec"]?:NSNull.null];
    for(id target in grant[@"targets"]) {
        if(![target isKindOfClass:NSDictionary.class] || ![target[@"birth"] isEqual:birth] ||
           ![target[@"executable"] isEqual:identity[@"executable"]] || ![target[@"main_uuid"] isEqual:identity[@"main_uuid"]])continue;
        NSString *server=target[@"server_executable"];
        if(![server isKindOfClass:NSString.class] || !server.isAbsolutePath || server.length>4095)return -1;
        HASetServerExecutable(server);
        NSString *socket=container?[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"s%d",getpid()]]:[NSString stringWithFormat:@"/tmp/hyprwm-admission-%d/service.sock",getuid()];
        if(container && ![target[@"socket"] isEqual:socket])return -1;
        return hypradmission_install(socket,12,NULL)==0 ? 1:-1;
    }
    return 0;
}
