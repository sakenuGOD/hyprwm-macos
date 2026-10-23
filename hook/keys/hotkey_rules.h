// App rules release global Carbon registrations so the application receives them.
static NSArray *gHotkeyAppRules;
static NSSet *gDisabledHotkeyModifiers;
static NSArray *gHotkeyAppObservers;
static BOOL hotkeyModifiersDisabled(unsigned mods) {
    return [gDisabledHotkeyModifiers containsObject:@(mods)];
}
static NSSet *disabledHotkeyModifiers(void) {
    NSMutableSet *disabled=[NSMutableSet set];
    for(NSDictionary *rule in gHotkeyAppRules) {
        for(NSString *bundle in rule[@"while_running"]) {
            BOOL running=NO;
            for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle])
                if(!app.terminated) {running=YES;break;}
            if(running) {[disabled addObject:rule[@"modifiers"]];break;}
        }
    }
    return disabled;
}
static void refreshHotkeyApplications(void) {
    NSSet *disabled=disabledHotkeyModifiers();
    if([disabled isEqual:gDisabledHotkeyModifiers])return;
    gDisabledHotkeyModifiers=disabled;
    if(gRepeat){dispatch_source_cancel(gRepeat);gRepeat=nil;}
    unregisterBindings();registerBindings(gBinds,NO);
    NSLog(@"[hyprkeys] application rules: suspended modifiers %@; %lu keyboard shortcuts registered",
          gDisabledHotkeyModifiers,(unsigned long)gHotKeyRefs.count);
}
static BOOL installHotkeyApplicationRules(void) {
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/HyprWM/hotkey-rules.json"];
    NSFileHandle *file=[NSFileHandle fileHandleForReadingAtPath:path];
    if(!file)return ![NSFileManager.defaultManager fileExistsAtPath:path];
    NSData *data=[file readDataUpToLength:65537 error:nil];[file closeFile];
    if(!data || data.length>65536)return NO;
    id rules=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![rules isKindOfClass:NSArray.class] || [rules count]>64)return NO;
    for(id rule in rules) {
        if(![rule isKindOfClass:NSDictionary.class])return NO;
        NSInteger mods;
        if(!repeatInteger(rule[@"modifiers"],-1,65535,&mods) || mods<0 || (mods&~0x1b00))return NO;
        id bundles=rule[@"while_running"];
        if(![bundles isKindOfClass:NSArray.class] || ![bundles count] || [bundles count]>16)return NO;
        for(id bundle in bundles)if(![bundle isKindOfClass:NSString.class] || ![bundle length] || [bundle length]>255)return NO;
    }
    gHotkeyAppRules=rules;gDisabledHotkeyModifiers=disabledHotkeyModifiers();
    NSMutableArray *observers=[NSMutableArray array];
    for(NSString *name in @[NSWorkspaceDidLaunchApplicationNotification,NSWorkspaceDidTerminateApplicationNotification]) {
        id observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){(void)note;refreshHotkeyApplications();}];
        if(observer)[observers addObject:observer];
    }
    gHotkeyAppObservers=observers;return YES;
}
