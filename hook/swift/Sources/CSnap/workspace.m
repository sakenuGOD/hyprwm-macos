// Read-only named public/native metadata. No setter, input, AX, attachment or constructor.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>
#include <string.h>
#include "../../../src/managed_process_identity.c"
extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int,CFStringRef);

static NSArray *workspaceIdentity(int pid) {
    uint64_t birth[4]={0};char path[4096]={0};
    if(managed_process_identity(pid,birth)||proc_pidpath(pid,path,sizeof path)<=0)return nil;
    return @[@(birth[0]),@(birth[1]),@(birth[2]),@(birth[3]),[NSString stringWithUTF8String:path]];
}
static char *workspaceJSON(id object) {
    if(!object)return NULL;
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if(!data||!data.length||data.length>262144)return NULL;
    char *result=malloc(data.length+1);if(!result)return NULL;
    memcpy(result,data.bytes,data.length);result[data.length]=0;return result;
}
char *hs_workspace_identity_json(int pid) { @autoreleasepool { return workspaceJSON(workspaceIdentity(pid)); } }
char *hs_workspace_diagnostic_json(void) {
    @autoreleasepool {
        char build[128]={0};size_t size=sizeof build;
        if(sysctlbyname("kern.osversion",build,&size,NULL,0)||strcmp(build,"25G241"))return NULL;
        NSString *imageUUID=nil;
        uint32_t count=_dyld_image_count();if(count>4096)return NULL;
        for(uint32_t i=0;i<count;i++) {
            const char *name=_dyld_get_image_name(i);
            if(!name||![[NSString stringWithUTF8String:name] hasSuffix:@"/SkyLight"])continue;
            const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
            if(!header||header->magic!=MH_MAGIC_64||header->ncmds>256||header->sizeofcmds>1048576)return NULL;
            const unsigned char *cursor=(const void *)(header+1),*end=cursor+header->sizeofcmds;
            for(uint32_t n=0;n<header->ncmds;n++) {
                if(end-cursor<8)return NULL;
                const struct load_command *command=(const void *)cursor;
                if(command->cmdsize<8||command->cmdsize>(size_t)(end-cursor))return NULL;
                if(command->cmd==LC_UUID&&command->cmdsize==sizeof(struct uuid_command))
                    imageUUID=[[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
                cursor+=command->cmdsize;
            }
        }
        if(![imageUUID isEqual:@"CD5F2362-8462-38D4-8C57-0BCD4E04F962"])return NULL;
        int pids[8192],bytes=proc_listpids(PROC_ALL_PIDS,0,pids,sizeof pids);
        if(bytes<=0||bytes>=(int)sizeof pids)return NULL;
        NSArray *server=nil,*dock=nil;
        for(int i=0;i<bytes/(int)sizeof(int);i++) {
            if(pids[i]<=0)continue;
            char path[4096]={0};if(proc_pidpath(pids[i],path,sizeof path)<=0)continue;
            NSString *text=[NSString stringWithUTF8String:path];
            if([text hasPrefix:@"/System/Library/PrivateFrameworks/SkyLight.framework/"]&&[text hasSuffix:@"/WindowServer"]) {
                if(server)return NULL;server=workspaceIdentity(pids[i]);if(!server)return NULL;
            }
            if([text isEqual:@"/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"]) {
                NSArray *candidate=workspaceIdentity(pids[i]);if(!candidate)return NULL;
                if([candidate[1] unsignedIntValue]!=getuid())continue;
                if(dock)return NULL;dock=candidate;
            }
        }
        if(!server||!dock)return NULL;
        int cid=SLSMainConnectionID();uint64_t before=SLSGetActiveSpace(cid);
        CFArrayRef raw=SLSCopyManagedDisplaySpaces(cid);CFDictionaryRef session=CGSessionCopyCurrentDictionary();
        if(!raw||!session){if(raw)CFRelease(raw);if(session)CFRelease(session);return NULL;}
        NSArray *catalog=CFBridgingRelease(raw);NSDictionary *state=CFBridgingRelease(session);
        if(![catalog isKindOfClass:NSArray.class]||catalog.count!=1)return NULL;
        NSMutableArray *displays=[NSMutableArray new];BOOL consistent=YES;
        for(NSDictionary *display in catalog) {
            if(![display isKindOfClass:NSDictionary.class])return NULL;
            NSString *identifier=display[@"Display Identifier"];NSArray *spaces=display[@"Spaces"];
            if(![identifier isKindOfClass:NSString.class]||identifier.length>128||![[NSUUID alloc] initWithUUIDString:identifier]||
               ![spaces isKindOfClass:NSArray.class]||!spaces.count||spaces.count>64)return NULL;
            NSMutableArray *rows=[NSMutableArray new];
            for(NSDictionary *space in spaces) {
                if(![space isKindOfClass:NSDictionary.class])return NULL;
                id sid=space[@"id64"]?:space[@"ManagedSpaceID"],uuid=space[@"uuid"]?:space[@"UUID"],type=space[@"type"];
                if(!sid||![uuid isKindOfClass:NSString.class]||!type)return NULL;
                [rows addObject:@{@"sid":sid,@"uuid":uuid,@"type":type}];
            }
            NSDictionary *current=display[@"Current Space"];
            if(![current isKindOfClass:NSDictionary.class])return NULL;
            id currentID=current[@"id64"]?:current[@"ManagedSpaceID"];
            uint64_t getter=SLSManagedDisplayGetCurrentSpace(cid,(__bridge CFStringRef)identifier);
            if(!currentID)return NULL;if([currentID unsignedLongLongValue]!=getter)consistent=NO;
            [displays addObject:@{@"display":identifier,@"current_catalog":currentID,@"current_getter":@(getter),@"spaces":rows}];
        }
        uint64_t after=SLSGetActiveSpace(cid);
        if(![server isEqual:workspaceIdentity([server[0] intValue])]||![dock isEqual:workspaceIdentity([dock[0] intValue])])return NULL;
        return workspaceJSON(@{@"mode":@"native-diagnostic",@"setter_called":@NO,@"observer_identity":workspaceIdentity(getpid())?:@[],
            @"generation":@[[NSString stringWithUTF8String:build],imageUUID,server,dock],@"connection_id":@(cid),
            @"active_before":@(before),@"active_after":@(after),@"displays":displays,
            @"locked":@([state[@"CGSSessionScreenIsLocked"] boolValue]),@"consistent":@((BOOL)(consistent&&before==after))});
    }
}
