#import "grant.h"
#import "admission.h"
#import "client.h"
#include <pwd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <uuid/uuid.h>
#include <notify.h>
#include <stdio.h>

static NSDictionary *ReadGrant(NSString *directory,NSString *filename) {
    struct stat parent={0};
    if (lstat(directory.fileSystemRepresentation,&parent) || !S_ISDIR(parent.st_mode) ||
        parent.st_uid!=getuid() || (parent.st_mode&077)) return nil;
    NSString *path=[directory stringByAppendingPathComponent:filename];
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
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
    NSDictionary *grant=ReadGrant(directory,container?[NSString stringWithFormat:@"g3%d",getpid()]:@"grants-v3.json");if(!grant)return 0;
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
        if(hypradmission_is_installed() && !hypradmission_is_accepting() && hypradmission_uninstall()!=0)return -1;
        return hypradmission_is_accepting() || hypradmission_install(socket,12,NULL)==0 ? 1:-1;
    }
    return 0;
}

static int currentGrant(void) {
    if(!NSThread.isMainThread || !NSApp)return -1;
    struct proc_bsdinfo info={0};char executable[PROC_PIDPATHINFO_MAXSIZE]={0};
    if(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&info,sizeof(info))!=sizeof(info) ||
       proc_pidpath(getpid(),executable,sizeof(executable))<=0)return -1;
    const struct mach_header_64 *header=(const void *)_dyld_get_image_header(0);
    if(!header || header->magic!=MH_MAGIC_64 || header->ncmds>2048 || header->sizeofcmds>1048576)return -1;
    const uint8_t *cursor=(const void *)(header+1),*end=cursor+header->sizeofcmds;
    NSString *mainUUID=nil;
    for(uint32_t i=0;i<header->ncmds;i++) {
        if((size_t)(end-cursor)<sizeof(struct load_command))return -1;
        const struct load_command *command=(const void *)cursor;
        if(command->cmdsize<8 || command->cmdsize>(size_t)(end-cursor))return -1;
        if(command->cmd==LC_UUID) {
            if(mainUUID || command->cmdsize!=sizeof(struct uuid_command))return -1;
            char value[37];uuid_unparse_upper(((const struct uuid_command *)command)->uuid,value);
            mainUUID=@(value);
        }
        cursor+=command->cmdsize;
    }
    if(cursor!=end || !mainUUID)return -1;
    return HAInstallGranted(@{@"pid":@(getpid()),@"uid":@(getuid()),
        @"birth_sec":@(info.pbi_start_tvsec),@"birth_usec":@(info.pbi_start_tvusec),
        @"executable":@(executable),@"main_uuid":mainUUID});
}

static BOOL desiredEnabled;
static void publishReadiness(void) {
    static int token=-1;
    if(token<0) {
        char name[96];snprintf(name,sizeof(name),"hyprwm.admission.v3.cap.%d",getpid());
        if(notify_register_check(name,&token)!=NOTIFY_STATUS_OK)return;
    }
    notify_set_state(token,hypradmission_is_accepting()?1:0);
}

int HAInstallCurrentGrant(void) {
    desiredEnabled=YES;
    int result=currentGrant();
    if(result==1) {
        desiredEnabled=YES;
        static int requestToken=-1;
        if(requestToken<0) {
            char name[96];snprintf(name,sizeof(name),"hyprwm.admission.v3.request.%d",getpid());
            int status=notify_register_dispatch(name,&requestToken,dispatch_get_main_queue(),^(int token){
                uint64_t enabled=0;
                if(notify_get_state(token,&enabled)!=NOTIFY_STATUS_OK)return;
                if(enabled==0){desiredEnabled=NO;hypradmission_uninstall();}
                else if(enabled==1){desiredEnabled=YES;currentGrant();}
                publishReadiness();
            });
            if(status!=NOTIFY_STATUS_OK) {
                requestToken=-1;hypradmission_uninstall();publishReadiness();return -1;
            }
            static id drainObserver;
            drainObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidUpdateNotification
                object:NSApp queue:nil usingBlock:^(NSNotification *notification){
                    (void)notification;
                    if(hypradmission_is_installed() && !hypradmission_is_accepting()) {
                        if(hypradmission_uninstall()==0 && desiredEnabled)currentGrant();
                        publishReadiness();
                    }
                }];
            (void)drainObserver;
        }
    }
    publishReadiness();
    return result;
}
