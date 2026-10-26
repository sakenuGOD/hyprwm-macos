// Hide application menus while retaining the system/status bar and shortcuts.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <notify.h>

@interface HYMItemState2 : NSObject
@property BOOL hidden, keyEquivalent, root;
@end
@implementation HYMItemState2
@end

static NSMapTable<NSMenuItem *,HYMItemState2 *> *items;
static BOOL enabled, changing, queued;
static int requestToken, capabilityToken;

static HYMItemState2 *remember(NSMenuItem *item) {
    HYMItemState2 *state=[items objectForKey:item];
    if (!state) {
        state=[HYMItemState2 new];state.hidden=item.hidden;
        state.keyEquivalent=item.allowsKeyEquivalentWhenHidden;
        [items setObject:state forKey:item];
    }
    return state;
}

static void shortcuts(NSMenuItem *item, BOOL hiddenAncestor) {
    HYMItemState2 *state=remember(item);
    // Do not activate commands which the application had already hidden.
    BOOL appHidden=hiddenAncestor || (!state.root && item.hidden) || (state.root && state.hidden);
    if (appHidden) {
        if (item.allowsKeyEquivalentWhenHidden) item.allowsKeyEquivalentWhenHidden=state.keyEquivalent;
        for (NSMenuItem *child in item.submenu.itemArray) shortcuts(child,YES);
        return;
    }
    if (!item.allowsKeyEquivalentWhenHidden) item.allowsKeyEquivalentWhenHidden=YES;
    for (NSMenuItem *child in item.submenu.itemArray) shortcuts(child,NO);
}

static void restore(void) {
    for (NSMenuItem *item in items.keyEnumerator) {
        @try {
            HYMItemState2 *state=[items objectForKey:item];
            if (state.root && item.hidden) item.hidden=state.hidden;
            if (item.allowsKeyEquivalentWhenHidden) item.allowsKeyEquivalentWhenHidden=state.keyEquivalent;
        } @catch (NSException *exception) { /* Keep restoring the other owned entries. */ }
    }
    [items removeAllObjects];
}

static void update(void) {
    if (changing) return;changing=YES;
    @try {
        if (enabled) {
            for (NSMenuItem *item in NSApp.mainMenu.itemArray) {
                HYMItemState2 *state=remember(item);
                if (!state.root) {
                    state.hidden=item.hidden;
                    if (state.hidden) continue;
                    state.root=YES;
                }
                shortcuts(item,NO);
                if (!item.hidden) item.hidden=YES;
            }
        } else restore();
    } @catch (NSException *exception) {
        enabled=NO;restore();notify_set_state(capabilityToken,2);
    } @finally {changing=NO;}
}

static void schedule(void) {
    if (changing || queued) return;queued=YES;
    dispatch_async(dispatch_get_main_queue(), ^{queued=NO;update();});
}

__attribute__((constructor)) static void hyprmenus_init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!NSApp || objc_getAssociatedObject(NSApp,@selector(hyprmenus_v2))) return;
        objc_setAssociatedObject(NSApp,@selector(hyprmenus_v2),@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        items=[NSMapTable weakToStrongObjectsMapTable];
        char name[96];snprintf(name,sizeof(name),"hyprwm.menus.v2.request.%d",getpid());
        if (notify_register_dispatch(name,&requestToken,dispatch_get_main_queue(),^(int token){
            uint64_t state=0;notify_get_state(token,&state);enabled=state==1;update();
        }) != NOTIFY_STATUS_OK) return;
        uint64_t state=0;notify_get_state(requestToken,&state);enabled=state==1;
        NSNotificationCenter *center=NSNotificationCenter.defaultCenter;
        for (NSString *event in @[NSApplicationDidBecomeActiveNotification,NSMenuDidAddItemNotification,
                                  NSMenuDidRemoveItemNotification,NSMenuDidChangeItemNotification])
            [center addObserverForName:event object:nil queue:nil usingBlock:^(NSNotification *note){
                if (NSThread.isMainThread) update();else schedule();
            }];
        snprintf(name,sizeof(name),"hyprwm.menus.v2.cap.%d",getpid());
        if (notify_register_check(name,&capabilityToken)==NOTIFY_STATUS_OK) notify_set_state(capabilityToken,1);
        update();
    });
}
