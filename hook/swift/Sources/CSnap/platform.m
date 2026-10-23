// Read-only identity of the private layouts used by the installed engine.
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/sysctl.h>

static NSString *platformUUID(NSString *framework, BOOL privateFramework) {
    NSString *prefix=[NSString stringWithFormat:@"/System/Library/%@/%@.framework/",
        privateFramework ? @"PrivateFrameworks" : @"Frameworks",framework];
    NSString *suffix=[@"/" stringByAppendingString:framework],*result=nil;
    uint32_t count=_dyld_image_count();if(count>4096)return nil;
    for(uint32_t i=0;i<count;i++) {
        const char *raw=_dyld_get_image_name(i);if(!raw)continue;
        NSString *name=[NSString stringWithUTF8String:raw];
        if(![name hasPrefix:prefix]||![name hasSuffix:suffix])continue;
        if(result)return nil;
        const struct mach_header_64 *header=(const void *)_dyld_get_image_header(i);
        if(!header||header->magic!=MH_MAGIC_64||header->ncmds>256||header->sizeofcmds>1048576)return nil;
        const unsigned char *cursor=(const void *)(header+1),*end=cursor+header->sizeofcmds;
        for(uint32_t n=0;n<header->ncmds;n++) {
            if(end-cursor<8)return nil;
            const struct load_command *command=(const void *)cursor;
            if(command->cmdsize<8||command->cmdsize>(size_t)(end-cursor))return nil;
            if(command->cmd==LC_UUID&&command->cmdsize==sizeof(struct uuid_command)) {
                if(result)return nil;
                result=[[NSUUID alloc] initWithUUIDBytes:((const struct uuid_command *)command)->uuid].UUIDString;
            }
            cursor+=command->cmdsize;
        }
    }
    return result;
}

char *hs_platform_fingerprint_json(void) {
    @autoreleasepool {
        NSDictionary *version=[NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
        NSString *build=version[@"ProductBuildVersion"];
        char kernelBuild[128]={0};size_t size=sizeof kernelBuild;
        BOOL consistent=[build isKindOfClass:NSString.class]&&
            !sysctlbyname("kern.osversion",kernelBuild,&size,NULL,0)&&[build isEqualToString:[NSString stringWithUTF8String:kernelBuild]];
        NSString *sky=platformUUID(@"SkyLight",YES),*quartz=platformUUID(@"QuartzCore",NO);
        // Only layouts already qualified on this build belong in this list.
        BOOL verified=consistent&&[build isEqualToString:@"25G241"]&&
            [sky isEqualToString:@"CD5F2362-8462-38D4-8C57-0BCD4E04F962"]&&
            [quartz isEqualToString:@"DF88B985-E9A5-310B-990F-1ECBB86CE4CC"];
        NSDictionary *result=@{@"verified":@(verified),@"stage":@"fingerprint",
            @"reason":verified ? @"qualified private framework layouts" : @"unverified macOS build or private framework UUID",
            @"fingerprint":@{@"ProductBuildVersion":build?:@"",@"SkyLight":sky?:@"",@"QuartzCore":quartz?:@""},
            @"legacy_window_manager_bridge":@"not used: native window census and AX classification"};
        NSData *bytes=[NSJSONSerialization dataWithJSONObject:result options:0 error:NULL];
        if(!bytes)return NULL;
        char *out=malloc(bytes.length+1);if(!out)return NULL;
        memcpy(out,bytes.bytes,bytes.length);out[bytes.length]=0;return out;
    }
}
