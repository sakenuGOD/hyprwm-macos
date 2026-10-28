// Actual proposed production code; Carbon registration is replaced with in-memory fakes.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <assert.h>
static NSMutableDictionary<NSNumber *,NSNumber *> *registered;
static unsigned registers, unregisters, nextRef=1;
static NSInteger failingKey=-1;
static OSStatus fakeRegister(UInt32 key,UInt32 mods,EventHotKeyID identity,EventTargetRef target,OptionBits options,EventHotKeyRef *out) {
    (void)mods;(void)identity;(void)target;(void)options; registers++;
    if((NSInteger)key==failingKey){failingKey=-1;return eventHotKeyExistsErr;}
    *out=(EventHotKeyRef)(uintptr_t)nextRef++;
    registered[@((uintptr_t)*out)]=@(key);return noErr;
}
static OSStatus fakeUnregister(EventHotKeyRef ref){unregisters++;[registered removeObjectForKey:@((uintptr_t)ref)];return noErr;}
static EventTargetRef fakeTarget(void){return NULL;}
#define RegisterEventHotKey fakeRegister
#define UnregisterEventHotKey fakeUnregister
#define GetApplicationEventTarget fakeTarget
#define main watcher_application_main
#include "../keys/hyprkeys.m"
#undef main
static NSData *encode(id object){return [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingFragmentsAllowed error:nil];}
static NSDictionary *binding(int key,NSString *word){return @{@"keycode":@(key),@"mods":@0x1800,@"cmd":@[@"focus",word],@"desc":word};}
static unsigned checks;
#define CHECK(...) do{checks++;assert((__VA_ARGS__));}while(0)
int main(void){@autoreleasepool{
    registered=[NSMutableDictionary dictionary];
    NSArray *arguments=@[@"exec",@"/Applications/My Terminal.app",@"a\"b",@"c\\d",@"$(id)",@"",@"Привет",@"line\nbreak"];
    NSData *wire=commandData(arguments);
    CHECK(wire && ((const char *)wire.bytes)[wire.length-1]=='\n');
    CHECK([[NSJSONSerialization JSONObjectWithData:wire options:0 error:nil] isEqual:arguments]);
    CHECK(!commandData(@[]));CHECK(!commandData(@[@1]));CHECK(!commandData((id)@"bad"));
    NSDictionary *left=binding(3,@"left"),*right=binding(4,@"right");
    NSData *original=encode(@[left,right]);CHECK(acceptBindings(original,NO));CHECK(registered.count==2);
    unsigned beforeRegisters=registers,beforeUnregisters=unregisters;
    CHECK(!acceptBindings([@"{" dataUsingEncoding:NSUTF8StringEncoding],YES));
    CHECK(!acceptBindings(encode(@[left,left]),YES));
    CHECK(registers==beforeRegisters && unregisters==beforeUnregisters);
    CHECK([gAcceptedData isEqual:original] && [gBinds isEqual:@[left,right]]);
    NSMutableDictionary *disabled=[right mutableCopy];disabled[@"enabled"]=@NO;
    NSData *edited=encode(@[binding(16,@"left"),disabled]);CHECK(acceptBindings(edited,YES));
    CHECK(registered.count==1 && [[registered allValues] containsObject:@16]);
    CHECK([gAcceptedData isEqual:edited]);
    failingKey=7;NSData *rejected=encode(@[binding(6,@"left"),binding(7,@"right")]);
    CHECK(!acceptBindings(rejected,YES));
    CHECK(registered.count==1 && [[registered allValues] containsObject:@16]);
    CHECK([gAcceptedData isEqual:edited] && [gBinds isEqual:@[binding(16,@"left"),disabled]]);
    gRepeat=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(gRepeat,DISPATCH_TIME_FOREVER,NSEC_PER_SEC,0);dispatch_resume(gRepeat);
    CHECK(acceptBindings(original,YES));CHECK(!gRepeat);CHECK(registered.count==2);
    CHECK(!validateBindingRows(@[@{@"keycode":@YES,@"mods":@0x1800,@"cmd":@[@"retile"]}]));
    CHECK(!validateBindingRows(@[@{@"keycode":@128,@"mods":@0x1800,@"cmd":@[@"retile"]}]));
    CHECK(!validateBindingRows(@[@{@"keycode":@3,@"mods":@0x400,@"cmd":@[@"retile"]}]));
    CHECK(!validateBindingRows(@[@{@"keycode":@3.5,@"mods":@0x1800,@"cmd":@[@"retile"]}]));
    CHECK(!validateBindingRows(@[@{@"keycode":@3,@"mods":@0x1800,@"cmd":@[@"retile"],@"enabled":@1}]));
    CHECK(!validateBindingRows(@[@{@"keycode":@3,@"mods":@0x1800,@"cmd":@"retile"}]));
    CHECK(validateBindingRows(@[left,@{@"keycode":@3,@"mods":@0x1800,@"cmd":@[@"retile"],@"enabled":@NO}]));
    CHECK(!acceptBindings([NSMutableData dataWithLength:262145],YES));CHECK([gAcceptedData isEqual:original]);
    CHECK(!validateBindingRows([NSArray arrayWithObjects:(id[]){left} count:1].description));
    NSMutableArray *tooMany=[NSMutableArray array];for(int i=0;i<4097;i++)[tooMany addObject:left];CHECK(!validateBindingRows(tooMany));
    NSData *malformed=[@"{" dataUsingEncoding:NSUTF8StringEncoding];
    beforeRegisters=registers;beforeUnregisters=unregisters;
    CHECK(reloadBindingData(malformed));CHECK(gReloadRejected && [gAttemptedData isEqual:malformed]);
    CHECK(!reloadBindingData(malformed));
    CHECK(reloadBindingData(original));CHECK(!gReloadRejected && !gAttemptedData);
    CHECK(registers==beforeRegisters && unregisters==beforeUnregisters && [gAcceptedData isEqual:original]);
    CHECK(!reloadBindingData(original));
    failingKey=7;
    CHECK(reloadBindingData(rejected));CHECK(gReloadRejected && [gAcceptedData isEqual:original]);
    beforeRegisters=registers;beforeUnregisters=unregisters;
    CHECK(!reloadBindingData(rejected));CHECK(registers==beforeRegisters && unregisters==beforeUnregisters);
    CHECK(reloadBindingData(original));CHECK(!gReloadRejected && !gAttemptedData);
    CHECK(registers==beforeRegisters && unregisters==beforeUnregisters);
    CHECK(reloadBindingData(rejected));CHECK(!gReloadRejected && [gAcceptedData isEqual:rejected]);
    CHECK(acceptBindings(encode(@[]),YES));CHECK(registered.count==0);
    puts([[NSString stringWithFormat:@"%u checks passed; no OS hotkey registration, socket, GUI or metadata writes",checks] UTF8String]);
}return 0;}
