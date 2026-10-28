// Appearance-only repair. No force(w), configure, observers, input or activation.
#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include "Appearance.h"
#include <dlfcn.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <sys/proc_info.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif
static const char *const AppKitPath="/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit";
static const uint8_t AppKitUUID[16]={0x3c,0x90,0xc2,0x55,0xd2,0x39,0x3b,0x5c,0x92,0x13,0x9c,0x5d,0x38,0x3b,0xef,0x9c};
static __weak NSWindow *tracked;
static BOOL saved,originalMain,originalControls;
static int savedMode;
static uint32_t savedWID;
static uint64_t savedSec,savedUsec;
static BOOL uuidOf(const void *base,uint8_t uuid[16]) {
 if(!base)return NO;const struct mach_header_64 *h=base;
 if(h->magic!=MH_MAGIC_64 || h->ncmds>512 || h->sizeofcmds>1048576)return NO;
 const uint8_t *p=(const void *)(h+1),*end=p+h->sizeofcmds;
 for(unsigned i=0;i<h->ncmds;i++){
  if(end-p<8)return NO;const struct load_command *c=(const void *)p;
  if(c->cmdsize<8 || c->cmdsize>(size_t)(end-p))return NO;
  if(c->cmd==LC_UUID && c->cmdsize==sizeof(struct uuid_command)){memcpy(uuid,((const struct uuid_command *)c)->uuid,16);return YES;}p+=c->cmdsize;
 }return NO;
}
static int hex(char c){return c>='0'&&c<='9'?c-'0':c>='a'&&c<='f'?c-'a'+10:c>='A'&&c<='F'?c-'A'+10:-1;}
static BOOL current(int32_t pid,uint32_t uid,uint64_t sec,uint64_t usec,const char *path,const uint8_t uuid[16]) {
 struct proc_bsdinfo b={0};char actual[PROC_PIDPATHINFO_MAXSIZE]={0};uint8_t loaded[16]={0};
 return pid==getpid() && uid==getuid() && proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&b,sizeof(b))==sizeof(b) &&
  b.pbi_uid==uid && b.pbi_start_tvsec==sec && b.pbi_start_tvusec==usec && proc_pidpath(pid,actual,sizeof(actual))>0 &&
  !strcmp(path,actual) && uuidOf(_dyld_get_image_header(0),loaded) && !memcmp(uuid,loaded,16);
}
static BOOL nativeMethod(id object,Class base,const char *name,const char *encoding) {
 if(!object || !base)return NO;const char *owner=class_getImageName(base);if(!owner || strcmp(owner,AppKitPath))return NO;
 SEL selector=sel_registerName(name);Method actual=class_getInstanceMethod(object_getClass(object),selector),native=class_getInstanceMethod(base,selector);
 if(!actual || !native || strcmp(method_getTypeEncoding(actual),encoding) || strcmp(method_getTypeEncoding(native),encoding) ||
    method_getImplementation(actual)!=method_getImplementation(native))return NO;
 const void *address=(const void *)method_getImplementation(actual);
#if __has_feature(ptrauth_calls)
 // Inspection only; no raw code invocation or PAC manipulation in dispatch.
 address=ptrauth_strip(address,ptrauth_key_function_pointer);
#endif
 Dl_info info={0};uint8_t uuid[16]={0};return dladdr(address,&info) && info.dli_fname && !strcmp(info.dli_fname,AppKitPath) &&
  uuidOf(info.dli_fbase,uuid) && !memcmp(uuid,AppKitUUID,16);
}
static BOOL get(NSWindow *w,const char *selector){return ((BOOL(*)(id,SEL))objc_msgSend)(w,sel_registerName(selector));}
static void set(NSWindow *w,const char *selector,BOOL value){((void(*)(id,SEL,BOOL))objc_msgSend)(w,sel_registerName(selector),value);}
static BOOL methods(NSWindow *w) {
 for(const char **p=(const char *[]){"_forceMainAppearance","_hasActiveControls","_hasKeyAppearance","_sharesParentFirstResponder",NULL};*p;p++)
  if(!nativeMethod(w,NSWindow.class,*p,"B16@0:8"))return NO;
 for(const char **p=(const char *[]){"_setForceMainAppearance:","_setForceActiveControls:",NULL};*p;p++)
  if(!nativeMethod(w,NSWindow.class,*p,"v20@0:8B16"))return NO;
 return nativeMethod(w,NSWindow.class,"hasKeyAppearance","B16@0:8") &&
  nativeMethod(w,NSWindow.class,"windowNumber","q16@0:8") && nativeMethod(w,NSWindow.class,"isKeyWindow","B16@0:8") &&
  nativeMethod(w,NSWindow.class,"isMainWindow","B16@0:8");
}
typedef struct {BOOL active,visible,key,main;NSRect frame;NSInteger animation;NSUInteger style,collection;
 uintptr_t keyObject,mainObject,responder;} Truth;
static Truth truth(NSWindow *w){return (Truth){NSApp.isActive,w.visible,w.keyWindow,w.mainWindow,w.frame,w.animationBehavior,w.styleMask,w.collectionBehavior,
 (uintptr_t)(__bridge void *)NSApp.keyWindow,(uintptr_t)(__bridge void *)NSApp.mainWindow,(uintptr_t)(__bridge void *)w.firstResponder};}
static BOOL same(Truth a,Truth b){return a.active==b.active && a.visible==b.visible && a.key==b.key && a.main==b.main &&
 NSEqualRects(a.frame,b.frame) && a.animation==b.animation && a.style==b.style && a.collection==b.collection &&
 a.keyObject==b.keyObject && a.mainObject==b.mainObject && a.responder==b.responder;}
static BOOL eligible(NSWindow *w){return [w isKindOfClass:NSWindow.class] && ![w isKindOfClass:NSPanel.class] &&
 (w.styleMask&NSWindowStyleMaskTitled) && (w.styleMask&NSWindowStyleMaskResizable) && !(w.styleMask&NSWindowStyleMaskFullScreen) &&
 w.level==NSNormalWindowLevel && !w.isSheet && !w.sheetParent && !w.parentWindow && !w.attachedSheet && NSApp.modalWindow!=w &&
 !get(w,"_sharesParentFirstResponder");}
static int result(int code,NSString *reason,NSMutableDictionary *row,char *output,uint32_t capacity) {
 row[@"schema"]=@1;row[@"code"]=@(code);row[@"ok"]=code==HWA_OK?@YES:@NO;row[@"reason"]=reason;
 row[@"saved_originals"]=saved?@YES:@NO;row[@"record_mode"]=!saved?@"none":savedMode==HWA_ON_MAIN_ONLY?@"main-only":@"both";row[@"focus_actions"]=@NO;row[@"configure_called"]=@NO;
 NSData *data=[NSJSONSerialization dataWithJSONObject:row options:NSJSONWritingSortedKeys error:nil];
 if(!data || data.length+1>capacity)return HWA_ARGUMENT;memcpy(output,data.bytes,data.length);output[data.length]=0;return code;
}
int hyprappearance_v1_json(int action,int32_t pid,uint32_t uid,uint64_t sec,uint64_t usec,const char *path,const char *uuidText,uint32_t wid,char *output,uint32_t capacity) {
 if(!output || capacity<8192)return HWA_ARGUMENT;output[0]=0;
 if(action<0 || action>3 || !path || strnlen(path,1024)>=1024 || path[0]!='/' || !uuidText || strnlen(uuidText,33)!=32 || !wid || !sec || usec>=1000000)return HWA_ARGUMENT;
 uint8_t uuid[16]={0},nonzero=0;for(unsigned i=0;i<16;i++){int a=hex(uuidText[i*2]),b=hex(uuidText[i*2+1]);if(a<0||b<0)return HWA_ARGUMENT;uuid[i]=(a<<4)|b;nonzero|=uuid[i];}if(!nonzero)return HWA_ARGUMENT;
 if(!pthread_main_np())return HWA_THREAD;
 @autoreleasepool{@try{
  NSMutableDictionary *row=[@{@"action":@(action),@"pid":@(pid),@"wid":@(wid),@"mutation_attempted":@NO} mutableCopy];
  if(!current(pid,uid,sec,usec,path,uuid))return result(HWA_IDENTITY,@"exact-process-identity-refusal",row,output,capacity);
  if(!NSApp)return result(HWA_NO_APP,@"no-existing-NSApplication",row,output,capacity);
  if(!nativeMethod(NSApp,NSApplication.class,"windows","@16@0:8"))return result(HWA_PROVENANCE,@"native-window-registry-refusal",row,output,capacity);
  NSArray *windows=NSApp.windows;if(windows.count>256)return result(HWA_WINDOW,@"window-bound-refusal",row,output,capacity);
  NSWindow *window=nil;for(NSWindow *candidate in windows){if(candidate.windowNumber!=(NSInteger)wid)continue;if(window && window!=candidate)return result(HWA_WINDOW,@"ambiguous-window",row,output,capacity);window=candidate;}
  if(!window){
   if(action==HWA_OFF && saved && !tracked && savedWID==wid && savedSec==sec && savedUsec==usec){saved=NO;tracked=nil;return result(HWA_OK,@"original-window-deallocated-no-write",row,output,capacity);}
   return result(HWA_WINDOW,@"exact-window-not-found",row,output,capacity);
  }
  if(!nativeMethod(NSApp,NSApplication.class,"isActive","B16@0:8"))return result(HWA_PROVENANCE,@"native-activation-truth-getter-refusal",row,output,capacity);
  if(!methods(window))return result(HWA_PROVENANCE,@"native-method-encoding-or-image-refusal",row,output,capacity);
  BOOL forceMain=get(window,"_forceMainAppearance"),controls=get(window,"_hasActiveControls"),keyAppearance=get(window,"_hasKeyAppearance");
  row[@"force_main"]=forceMain?@YES:@NO;row[@"active_controls_derived"]=controls?@YES:@NO;
  row[@"has_key_appearance"]=keyAppearance?@YES:@NO;row[@"eligible"]=eligible(window)?@YES:@NO;
  Truth publicTruth=truth(window);row[@"app_active"]=publicTruth.active?@YES:@NO;row[@"is_key_window"]=publicTruth.key?@YES:@NO;row[@"is_main_window"]=publicTruth.main?@YES:@NO;row[@"visible"]=publicTruth.visible?@YES:@NO;
  row[@"native_methods_verified"]=@YES;row[@"appkit_uuid"]=@"3c90c255d2393b5c92139c5d383bef9c";
  if(action==HWA_STATUS)return result(HWA_OK,@"read-only-status",row,output,capacity);
  if(!eligible(window))return result(HWA_INELIGIBLE,@"regular-nonforwarding-window-required",row,output,capacity);
  if(saved && (tracked!=window || savedWID!=wid || savedSec!=sec || savedUsec!=usec))return result(HWA_OTHER_TRACKED,@"another-original-window-is-tracked",row,output,capacity);
  BOOL isOn=action==HWA_ON || action==HWA_ON_MAIN_ONLY;
  BOOL mainOnly=action==HWA_ON_MAIN_ONLY || (action==HWA_OFF && savedMode==HWA_ON_MAIN_ONLY);
  if(isOn && saved){if(savedMode!=action)return result(HWA_OTHER_TRACKED,@"mode-change-requires-explicit-off",row,output,capacity);return result(HWA_OK,@"already-on-originals-preserved",row,output,capacity);}
  if(action==HWA_OFF && !saved)return result(HWA_OK,@"already-off-no-write",row,output,capacity);
  // _hasActiveControls is raw-force OR native key appearance on this image.
  // Only a false native key branch lets us observe/store the original raw bit.
  if(action==HWA_ON && keyAppearance)return result(HWA_ORIGINAL_AMBIGUOUS,@"original-force-active-bit-ambiguous-while-key",row,output,capacity);
  Truth before=truth(window);
  if(!current(pid,uid,sec,usec,path,uuid) || window.windowNumber!=(NSInteger)wid)return result(HWA_IDENTITY,@"fresh-identity-refusal",row,output,capacity);
  if(isOn){savedMode=action;originalMain=forceMain;if(!mainOnly)originalControls=controls;savedWID=wid;savedSec=sec;savedUsec=usec;tracked=window;saved=YES;}
  row[@"original_force_main"]=originalMain?@YES:@NO;row[@"original_force_active_known"]=mainOnly?@NO:@YES;if(!mainOnly)row[@"original_force_active"]=originalControls?@YES:@NO;
  row[@"applied_mode"]=mainOnly?@"main-only":@"both";row[@"force_active_setter_called"]=mainOnly?@NO:@YES;
  row[@"mutation_attempted"]=@YES;
  set(window,"_setForceMainAppearance:",isOn?YES:originalMain);
  if(!mainOnly)set(window,"_setForceActiveControls:",isOn?YES:originalControls);
  BOOL afterMain=get(window,"_forceMainAppearance"),afterControls=get(window,"_hasActiveControls");
  BOOL unchanged=same(before,truth(window));row[@"nonappearance_state_unchanged"]=unchanged?@YES:@NO;
  row[@"force_main_after"]=afterMain?@YES:@NO;row[@"active_controls_derived_after"]=afterControls?@YES:@NO;
  BOOL expectedMain=isOn?YES:originalMain;
  BOOL appearanceOK=afterMain==expectedMain && (mainOnly?afterControls==controls:action==HWA_ON?afterControls:(!get(window,"_hasKeyAppearance")?afterControls==originalControls:YES));
  if(action==HWA_OFF && appearanceOK && unchanged){tracked=nil;saved=NO;}
  return result(appearanceOK && unchanged?HWA_OK:HWA_VERIFY,appearanceOK && unchanged?@"appearance-bits-applied-native-focus-unchanged":@"verification-failed-originals-retained",row,output,capacity);
 }@catch(NSException *exception){(void)exception;return HWA_EXCEPTION;}}
}
