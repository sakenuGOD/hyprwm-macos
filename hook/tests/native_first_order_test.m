// Deferred windows only: no ordering, activation or owner-app mutation.
#define HYPRFORCE_TEST 1
#define NPFX "hyprfirstordertest"
#import "../active/hyprforce.m"
int main(void) { @autoreleasepool {
    [NSApplication sharedApplication];
    notify_register_check("hyprfirstordertest.next", &tok[T_NEXT]);
    notify_set_state(tok[T_NEXT],0);
    NSWindow *regular=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,400,300)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    regular.animationBehavior=NSWindowAnimationBehaviorDefault;
    will_order(regular);
    if(regular.animationBehavior!=NSWindowAnimationBehaviorNone) {
        puts("FAIL: first order retains an independent AppKit appearance animation"); return 1;
    }
    if(regular.visible||regular.keyWindow||regular.mainWindow) return 2;
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,400,300)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:YES];
    panel.animationBehavior=NSWindowAnimationBehaviorDefault;will_order(panel);
    if(panel.animationBehavior!=NSWindowAnimationBehaviorDefault||panel.visible) return 3;
    puts("PASS: first-order tile animation belongs to the WM; panel policy and focus preserved");
    return 0;
} }
