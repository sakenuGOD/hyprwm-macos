// Explicit own-process fault fixture. No window is ordered, activated or drawn.
#define HYPRADMISSION_OWNED_DIAGNOSTICS 1
#import "admission.m"
#include <stdio.h>

@interface HALeaseFixtureWindow:NSWindow
@property NSInteger fixtureWID;
@end
@implementation HALeaseFixtureWindow
- (NSInteger)windowNumber {return self.fixtureWID;}
@end
static unsigned checks,failures,alphaCalls;
static BOOL alphaFails;
static void check(BOOL value,const char *name) {
    checks++;if(!value)failures++;printf("%s %s\n",value?"PASS":"FAIL",name);
}
static int fake_connection(void) {return 1;}
static int fake_alpha(int cid,uint32_t wid,float value) {
    (void)cid;(void)wid;(void)value;alphaCalls++;return alphaFails ? -1:0;
}
static void pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0) [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:end];
}
static void offer(NSMutableDictionary *r,unsigned attempt) {
    r[@"key"]=@{@"attempt":@(attempt)};
    r[@"offer"]=@{@"presentation":[NSString stringWithFormat:@"hyprwm.admit.owned-%d-%u",getpid(),attempt],
        @"service":@"owned-only",@"lease":@"owned-only",@"revision":@1};
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc!=3 || strcmp(argv[1],"--owned-only")) return 2;
    setvbuf(stdout,NULL,_IOLBF,0);
    check(hypradmission_install(@"/tmp/not-used",12,NULL)==-1,"unconfigured server refused");
    [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    char executable[PROC_PIDPATHINFO_MAXSIZE]={0};proc_pidpath(getpid(),executable,sizeof(executable));
    HASetServerExecutable(@(executable));
    check(hypradmission_install(@"/tmp/not-used",12,NULL)==0,"native qualification and install");
    if(!installed)return 3;
    NSString *originalLaunch=launch;
    HALeaseFixtureWindow *w=[[HALeaseFixtureWindow alloc] initWithContentRect:NSMakeRect(10,10,300,200)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    w.releasedWhenClosed=NO;w.fixtureWID=123456;
    NSMutableDictionary *r=record(w);NSUInteger first=[r[@"object"] unsignedIntegerValue];
    setAlpha=fake_alpha;mainConnection=fake_connection;
    offer(r,1);check(begin_presentation(w,r),"first owned presentation");
    alphaFails=YES;
    check(!finish_presentation(w,r) && r[@"presentationToken"] && [r[@"releaseDue"] boolValue],"failed alpha retains token");
    check(hypradmission_uninstall()==-3 && installed && stopping && owns_source(),"failed cleanup stops new admissions and retains install owner");
    check(!begin_presentation(w,r),"unresolved lease cannot be overwritten");
    alphaFails=NO;
    [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidUpdateNotification object:NSApp];
    check(!r[@"presentationToken"],"application update recovers alpha");
    offer(r,2);check(begin_presentation(w,r),"new lease after recovery");
    check(finish_presentation(w,r),"release previous lease");
    pump(.2);offer(r,3);check(begin_presentation(w,r),"same object reopened with distinct lease");
    NSNumber *newToken=r[@"presentationToken"];
    pump(.35);check(r[@"presentationToken"]==newToken,"old timeout cannot release replacement lease");
    unsigned before=alphaCalls;w.fixtureWID++;
    check(finish_presentation(w,r) && alphaCalls==before,"old lease cannot mutate replacement native WID");
    check(hypradmission_uninstall()==0 && !source[@"owner"],"successful cleanup releases own token");
    check(hypradmission_install(@"/tmp/not-used",12,NULL)==0 && [launch isEqual:originalLaunch],"reinstall preserves source nonce");
    r=record(w);check([r[@"object"] unsignedIntegerValue]>first,"object sequence survives reinstall");
    check([r[@"preexisting"] boolValue],"warm install excludes preexisting unordered window");
    [w close];
    check([r[@"preexisting"] boolValue],"close does not erase preexisting exclusion");
    void *image=dlopen(argv[2],RTLD_NOW|RTLD_LOCAL);check(image!=NULL,"second client image loaded in owned process");
    int (*otherInstall)(NSString*,double,HAEventCallback)=image?dlsym(image,"hypradmission_install"):NULL;
    int (*otherOff)(void)=image?dlsym(image,"hypradmission_uninstall"):NULL;
    void (*otherServer)(NSString*)=image?dlsym(image,"HASetServerExecutable"):NULL;
    NSDictionary *(*otherState)(void)=image?dlsym(image,"hypradmission_owned_state"):NULL;
    if(!otherInstall||!otherOff||!otherServer||!otherState)return 4;
    otherServer(@(executable));
    check(otherInstall(@"/tmp/not-used",12,NULL)==-6,"two images cannot own source concurrently");
    check(hypradmission_uninstall()==0,"first image hands off after cleanup");
    check(otherInstall(@"/tmp/not-used",12,NULL)==0 && [otherState()[@"source_launch"] isEqual:originalLaunch],"second image reuses exact source");
    NSString *successor=source[@"owner"];
    check(hypradmission_uninstall()==0 && [source[@"owner"] isEqual:successor],"old off cannot clear successor owner");
    check(otherOff()==0 && !source[@"owner"],"successor releases itself");
    printf("RESULT %u checks %u failures; no windows ordered\n",checks,failures);
    return failures?1:0;
} }
