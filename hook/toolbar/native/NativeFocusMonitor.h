// Public read-only native focus events. No polling, AX actions, controller or owner attachment.
@class NativeFocusMonitor;
// Same local AX window identity ABI used by the WM's existing AX bridge.
extern AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *window);
static void NativeFocusChanged(AXObserverRef observer,AXUIElementRef element,CFStringRef notification,void *context);
static NSString *privateFocusText(id value,NSUInteger limit) {
    if(![value isKindOfClass:NSString.class])return @"";
    NSString *clean=[[value componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    return clean.length>limit?[clean substringToIndex:limit]:clean;
}
@interface NativeFocusMonitor:NSObject
@property NSDictionary *focus;
@property NSDictionary *identity;
@property AXObserverRef observer;
@property AXUIElementRef application;
@property AXUIElementRef window;
@property BOOL focusWatching;
@property BOOL titleWatching;
@property(copy) void(^changed)(void);
- (void)refresh;
- (void)close;
@end
@implementation NativeFocusMonitor
- (instancetype)init {if((self=[super init]))self.focus=@{@"available":@NO,@"app":@"",@"title":@""};return self;}
- (void)close {
    if(self.observer){CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(self.observer),kCFRunLoopCommonModes);if(self.application){AXObserverRemoveNotification(self.observer,self.application,kAXFocusedWindowChangedNotification);AXObserverRemoveNotification(self.observer,self.application,kAXMenuOpenedNotification);AXObserverRemoveNotification(self.observer,self.application,kAXMenuClosedNotification);}if(self.window){AXObserverRemoveNotification(self.observer,self.window,kAXTitleChangedNotification);AXObserverRemoveNotification(self.observer,self.window,kAXUIElementDestroyedNotification);}CFRelease(self.observer);self.observer=NULL;}
    if(self.window){CFRelease(self.window);self.window=NULL;}if(self.application){CFRelease(self.application);self.application=NULL;}self.identity=nil;self.focusWatching=NO;self.titleWatching=NO;self.focus=@{@"available":@NO,@"app":@"",@"title":@""};
}
- (void)refresh {
    NSDictionary *identity=frontIdentity();if(!AXIsProcessTrusted()||!identity){[self close];return;}
    if(![identity isEqual:self.identity]){
        [self close];self.identity=identity;self.application=AXUIElementCreateApplication([identity[@"pid"] intValue]);
        if(AXUIElementSetMessagingTimeout(self.application,.05)!=kAXErrorSuccess){[self close];return;}
        AXObserverRef observer=NULL;if(AXObserverCreate([identity[@"pid"] intValue],NativeFocusChanged,&observer)!=kAXErrorSuccess){[self close];return;}self.observer=observer;
        self.focusWatching=AXObserverAddNotification(observer,self.application,kAXFocusedWindowChangedNotification,(__bridge void *)self)==kAXErrorSuccess;
        if(!self.focusWatching){[self close];return;}
        AXObserverAddNotification(observer,self.application,kAXMenuOpenedNotification,(__bridge void *)self);
        AXObserverAddNotification(observer,self.application,kAXMenuClosedNotification,(__bridge void *)self);
        CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),kCFRunLoopCommonModes);
    }
    CFTypeRef candidate=NULL;pid_t owner=-1;
    if(AXUIElementCopyAttributeValue(self.application,kAXFocusedWindowAttribute,&candidate)!=kAXErrorSuccess||!candidate||CFGetTypeID(candidate)!=AXUIElementGetTypeID()||AXUIElementGetPid((AXUIElementRef)candidate,&owner)!=kAXErrorSuccess||owner!=[identity[@"pid"] intValue]){if(candidate)CFRelease(candidate);self.focus=@{@"available":@NO,@"app":@"",@"title":@""};return;}
    if(!self.window||!CFEqual(self.window,candidate)){
        if(self.window){AXObserverRemoveNotification(self.observer,self.window,kAXTitleChangedNotification);AXObserverRemoveNotification(self.observer,self.window,kAXUIElementDestroyedNotification);CFRelease(self.window);}
        self.window=(AXUIElementRef)candidate;candidate=NULL;AXUIElementSetMessagingTimeout(self.window,.05);
        self.titleWatching=AXObserverAddNotification(self.observer,self.window,kAXTitleChangedNotification,(__bridge void *)self)==kAXErrorSuccess;
        AXObserverAddNotification(self.observer,self.window,kAXUIElementDestroyedNotification,(__bridge void *)self);
    }
    if(candidate)CFRelease(candidate);
    CFTypeRef title=NULL;if(self.titleWatching)AXUIElementCopyAttributeValue(self.window,kAXTitleAttribute,&title);
    NSString *name=privateFocusText([NSRunningApplication runningApplicationWithProcessIdentifier:owner].localizedName,256);NSString *text=privateFocusText((__bridge id)title,512);if(title)CFRelease(title);
    if(![identity isEqual:frontIdentity()]||!name.length){self.focus=@{@"available":@NO,@"app":@"",@"title":@""};return;}
    CGWindowID wid=0;
    if(_AXUIElementGetWindow(self.window,&wid)!=kAXErrorSuccess||!wid||![identity isEqual:frontIdentity()]){self.focus=@{@"available":@NO,@"app":@"",@"title":@""};return;}
    self.focus=@{@"available":@YES,@"app":name,@"title":text,@"wid":@(wid),@"pid":@(owner),
                 @"process_birth":@[identity[@"pid"],identity[@"uid"],identity[@"birth_sec"],identity[@"birth_usec"]]};
}
- (void)dealloc {[self close];}
@end
static void NativeFocusChanged(AXObserverRef observer,AXUIElementRef element,CFStringRef notification,void *context) {
    NativeFocusMonitor *monitor=(__bridge NativeFocusMonitor *)context;[monitor refresh];if(monitor.changed)monitor.changed();
}
