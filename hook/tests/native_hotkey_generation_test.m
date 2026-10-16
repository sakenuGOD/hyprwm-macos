// Deliver captured Carbon registration tokens into the real production handler.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>
#include <assert.h>
static EventHotKeyID captured;
static int requests;
static BOOL failNextRegistration, badParameter;
static EventHotKeyID failed;
static OSStatus fakeRegister(UInt32 key,UInt32 mods,EventHotKeyID token,EventTargetRef target,OptionBits options,EventHotKeyRef *out){(void)key;(void)mods;(void)target;(void)options;if(failNextRegistration){failed=token;failNextRegistration=NO;return eventHotKeyExistsErr;}captured=token;*out=(EventHotKeyRef)1;return noErr;}
static OSStatus fakeUnregister(EventHotKeyRef ref){(void)ref;return noErr;}
static EventTargetRef fakeTarget(void){return NULL;}
static OSStatus fakeParameter(EventRef event,EventParamName name,EventParamType type,EventParamType *actual,ByteCount size,ByteCount *actualSize,void *value){(void)name;(void)type;(void)actual;if(badParameter)return paramErr;assert(size==sizeof(EventHotKeyID));memcpy(value,event,size);if(actualSize)*actualSize=size;return noErr;}
static UInt32 fakeKind(EventRef event){(void)event;return kEventHotKeyPressed;}
static int fakeSocket(int domain,int type,int protocol){(void)domain;(void)type;(void)protocol;requests++;return 991;}
static int fakeConnect(int fd,const struct sockaddr *address,socklen_t length){(void)fd;(void)address;(void)length;return -1;}
static int fakeClose(int fd){(void)fd;return 0;}
#define RegisterEventHotKey fakeRegister
#define UnregisterEventHotKey fakeUnregister
#define GetApplicationEventTarget fakeTarget
#define GetEventParameter fakeParameter
#define GetEventKind fakeKind
#define socket fakeSocket
#define connect fakeConnect
#define close fakeClose
#define main watcher_application_main
#include "../keys/hyprkeys.m"
#undef main
static NSData *rows(NSString *command,BOOL enabled){return [NSJSONSerialization dataWithJSONObject:@[@{@"keycode":@3,@"mods":@0x1800,@"cmd":@[command],@"enabled":@(enabled),@"desc":command}] options:0 error:nil];}
static void press(EventHotKeyID token){onHotKey(NULL,(EventRef)&token,NULL);dispatch_sync(gQ,^{});}
int main(void){@autoreleasepool{
 gQ=dispatch_queue_create("hyprwm.offline.handler",DISPATCH_QUEUE_SERIAL);
 assert(acceptBindings(rows(@"balance",YES),NO));EventHotKeyID old=captured;
 assert(acceptBindings(rows(@"retile",YES),YES));EventHotKeyID current=captured;
 press(old);if(requests!=0){puts("FAIL: stale registration token dispatched replacement command");return 1;}
 press(current);assert(requests==1);
 assert(acceptBindings(rows(@"retile",NO),YES));press(current);assert(requests==1);
 EventHotKeyID disabled={.signature=gBindingGeneration,.id=0};press(disabled);assert(requests==1);
 assert(acceptBindings(rows(@"balance",YES),YES));EventHotKeyID beforeFailure=captured;
 failNextRegistration=YES;assert(!acceptBindings(rows(@"retile",YES),YES));EventHotKeyID rollback=captured;
 press(beforeFailure);assert(requests==1);press(failed);assert(requests==1);press(rollback);assert(requests==2);
 badParameter=YES;press(rollback);assert(requests==2);
 puts("8 Carbon handler generation checks passed: old/current/disabled/forged-disabled/rollback-old/failed-candidate/rollback-current/malformed-event; all OS calls mocked");
}return 0;}
