#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <ptrauth.h>
#import <uuid/uuid.h>
static NSString *const AppKitPath=@"/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";
static NSString *const AppKitUUID=@"3C90C255-D239-3B5C-9213-9C5D383BEF9C";
static NSMutableArray *qualifications;
static NSString *ImageUUID(const struct mach_header_64 *h) {
    if(!h || h->magic!=MH_MAGIC_64)return nil;
    const uint8_t *p=(const void *)(h+1);
    for(uint32_t n=0;n<h->ncmds;n++) {const struct load_command *lc=(const void *)p;
        if(lc->cmdsize<sizeof(*lc))return nil;
        if(lc->cmd==LC_UUID) {char text[37];uuid_unparse_upper(((const struct uuid_command *)lc)->uuid,text);return @(text);}p+=lc->cmdsize;}
    return nil;
}
static Method Qualified(Class cls,NSString *name,uintptr_t expected,const char *result,const char *argument) {
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(name));BOOL valid=m!=NULL;NSString *reason=@"";uintptr_t address=0;
    char ret[32]={0},arg[32]={0};Dl_info image={0};
    if(m) {method_getReturnType(m,ret,sizeof(ret));
        valid=method_getNumberOfArguments(m)==(argument?3u:2u) && !strcmp(ret,result);
        if(argument){method_getArgumentType(m,2,arg,sizeof(arg));valid=valid && !strcmp(arg,argument);}
        void *code=ptrauth_strip((void *)method_getImplementation(m),ptrauth_key_function_pointer);
        if(!dladdr(code,&image) || !image.dli_fname || ![AppKitPath isEqual:@(image.dli_fname)] || ![AppKitUUID isEqual:ImageUUID(image.dli_fbase)])valid=NO;
        else {const struct mach_header_64 *h=image.dli_fbase;const uint8_t *p=(const void *)(h+1);uint64_t text=0;
            for(uint32_t n=0;n<h->ncmds;n++){const struct load_command *lc=(const void *)p;
                if(lc->cmd==LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname,"__TEXT"))text=((const struct segment_command_64 *)lc)->vmaddr;p+=lc->cmdsize;}
            address=(uintptr_t)code-(uintptr_t)image.dli_fbase+text;valid=valid && text && address==expected;}}
    if(!valid)reason=@"exact AppKit image/UUID/IMP/ABI mismatch";
    [qualifications addObject:@{@"class":NSStringFromClass(cls)?:@"missing",@"selector":name,@"ok":@(valid),@"reason":reason,@"unslid":[NSString stringWithFormat:@"0x%llx",(unsigned long long)address],@"encoding":m?@(method_getTypeEncoding(m)):@""}];
    return valid?m:NULL;
}
static Method representationGetter,representationSetter,menuImplGetter,barRepresentationGetter,appleGetter,barHideMethod;
static Method rootBackingGetter,arrangedGetter,menuItemGetter,layoutMethod;
static Method viewHiddenSetter,publishMethod;
static Method beginGroupingMethod,endGroupingMethod;
static ptrdiff_t groupingOffset=-1;
enum { PinnedMethodCount=14 };
static Method pinnedMethods[PinnedMethodCount];static IMP pinnedIMPs[PinnedMethodCount];
static IMP OriginalIMP(Method m){for(unsigned i=0;i<PinnedMethodCount;i++)if(pinnedMethods[i]==m)return pinnedIMPs[i];abort();}
static BOOL Qualify(void) {
    qualifications=[NSMutableArray new];
    representationGetter=Qualified(NSMenuItem.class,@"isHiddenInRepresentation",0x185424640,@encode(BOOL),NULL);
    representationSetter=Qualified(NSMenuItem.class,@"setHiddenInRepresentation:",0x185424670,"v",@encode(BOOL));
    menuImplGetter=Qualified(NSMenu.class,@"_menuImplIfExists",0x1849D2A18,"@",NULL);
    barRepresentationGetter=Qualified(NSClassFromString(@"NSMenuBarImpl"),@"activeRepresentationView",0x1859B5AE4,"@",NULL);
    appleGetter=Qualified(NSMenuItem.class,@"_isAppleMenuItem",0x1853470E0,@encode(BOOL),NULL);
    rootBackingGetter=Qualified(NSClassFromString(@"NSMenuBarRepresentation"),@"_rootBackingView",0x18543EAA4,"@",NULL);
    arrangedGetter=Qualified(NSClassFromString(@"_NSMenuBarBackingView"),@"arrangedSubviews",0x18543E534,"@",NULL);
    menuItemGetter=Qualified(NSClassFromString(@"NSMenuItemView"),@"menuItem",0x1853ACAB4,"@",NULL);
    layoutMethod=Qualified(NSClassFromString(@"NSMenuBarRepresentation"),@"layoutMenuBarImmediately",0x185440360,"v",NULL);
    viewHiddenSetter=Qualified(NSView.class,@"setHidden:",0x184A13098,"v",@encode(BOOL));
    publishMethod=Qualified(NSClassFromString(@"NSMenuBarImpl"),@"viewDidLayout",0x1859B75F8,"v",NULL);
    Class implClass=NSClassFromString(@"NSMenuBarImpl");
    beginGroupingMethod=Qualified(implClass,@"beginGroupingLayoutChanges",0x1859B74D0,"v",NULL);
    endGroupingMethod=Qualified(implClass,@"endGroupingLayoutChanges",0x1859B7530,"v",NULL);
    // This native group is a BOOL, not a nesting counter. Observe it only;
    // an existing AppKit group must never be closed by our scope.
    unsigned ivarCount=0;Ivar *ivars=class_copyIvarList(implClass,&ivarCount);BOOL groupValid=NO;
    for(unsigned i=0;i<ivarCount;i++)if(!strcmp(ivar_getName(ivars[i]),"_isGroupingLayoutChanges")){
        const char *type=ivar_getTypeEncoding(ivars[i]);ptrdiff_t offset=ivar_getOffset(ivars[i]);
        groupValid=sizeof(BOOL)==1&&type&&!strcmp(type,@encode(BOOL))&&offset==297&&class_getInstanceSize(implClass)==312;
        if(groupValid)groupingOffset=offset;
    }
    free(ivars);
    [qualifications addObject:@{@"class":@"NSMenuBarImpl",@"ivar":@"_isGroupingLayoutChanges",@"ok":@(groupValid),@"offset":@(groupingOffset)}];
    if(!groupValid)return NO;
    Class cls=NSClassFromString(@"NSMenuBarRepresentation");Method m=class_getInstanceMethod(cls,NSSelectorFromString(@"setHidden:forMenuItemAtIndex:"));
    // Reuse exact IMP qualification, then validate this selector's two explicit arguments.
    if(m) {char ret[8]={0},a[8]={0},b[8]={0};method_getReturnType(m,ret,sizeof(ret));method_getArgumentType(m,2,a,sizeof(a));method_getArgumentType(m,3,b,sizeof(b));
        IMP imp=method_getImplementation(m);Dl_info d={0};void *code=ptrauth_strip((void*)imp,ptrauth_key_function_pointer);
        BOOL ok=method_getNumberOfArguments(m)==4 && !strcmp(ret,"v") && !strcmp(a,@encode(BOOL)) && !strcmp(b,@encode(NSInteger)) && dladdr(code,&d) && d.dli_fname && [AppKitPath isEqual:@(d.dli_fname)] && [AppKitUUID isEqual:ImageUUID(d.dli_fbase)];
        uintptr_t address=0;
        if(ok){const struct mach_header_64 *h=d.dli_fbase;const uint8_t *p=(const void *)(h+1);uint64_t text=0;
            for(uint32_t i=0;i<h->ncmds;i++){const struct load_command *lc=(const void*)p;if(lc->cmd==LC_SEGMENT_64&&!strcmp(((const struct segment_command_64*)lc)->segname,"__TEXT"))text=((const struct segment_command_64*)lc)->vmaddr;p+=lc->cmdsize;}address=(uintptr_t)code-(uintptr_t)d.dli_fbase+text;ok=text && address==0x18543F048;}
        [qualifications addObject:@{@"class":@"NSMenuBarRepresentation",@"selector":@"setHidden:forMenuItemAtIndex:",@"ok":@(ok),@"unslid":[NSString stringWithFormat:@"0x%llx",(unsigned long long)address],@"encoding":@(method_getTypeEncoding(m))}];if(ok)barHideMethod=m;}
    Method methods[]={representationGetter,representationSetter,menuImplGetter,barRepresentationGetter,appleGetter,barHideMethod,rootBackingGetter,arrangedGetter,menuItemGetter,layoutMethod,viewHiddenSetter,publishMethod,beginGroupingMethod,endGroupingMethod};
    for(unsigned i=0;i<PinnedMethodCount;i++){if(!methods[i])return NO;pinnedMethods[i]=methods[i];pinnedIMPs[i]=method_getImplementation(methods[i]);}
    return YES;
}
static id ObjectCall(Method m,id object){return ((id(*)(id,SEL))OriginalIMP(m))(object,method_getName(m));}
static BOOL BoolCall(Method m,id object){return ((BOOL(*)(id,SEL))OriginalIMP(m))(object,method_getName(m));}
static BOOL DispatchMatches(id object,Method method){Method actual=object?class_getInstanceMethod(object_getClass(object),method_getName(method)):NULL;return actual && method_getImplementation(actual)==OriginalIMP(method);}
static NSArray *Frame(NSRect r){return @[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)];}
