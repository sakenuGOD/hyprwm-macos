// App rules release global Carbon registrations so the application receives them.
static NSArray *gHotkeyAppRules;
static NSSet *gDisabledHotkeyModifiers;
static NSArray *gHotkeyAppObservers;
static BOOL hotkeyModifiersDisabled(unsigned mods) {
    return [gDisabledHotkeyModifiers containsObject:@(mods)];
}
static BOOL hotkeyBindingDisabled(unsigned key,unsigned mods) {
    return hotkeyModifiersDisabled(mods) || [gDisabledHotkeyModifiers containsObject:@[@(mods),@(key)]];
}
static void addDisabledHotkeyRule(NSMutableSet *disabled,NSDictionary *rule) {
    NSArray *keys=rule[@"keycodes"];
    if(!keys){[disabled addObject:rule[@"modifiers"]];return;}
    for(NSNumber *key in keys)[disabled addObject:@[rule[@"modifiers"],key]];
}
static NSSet *disabledHotkeyModifiers(void) {
    NSMutableSet *disabled=[NSMutableSet set];
    for(NSDictionary *rule in gHotkeyAppRules) {
        NSArray *frontmost=rule[@"while_frontmost"];
        if(frontmost) {
            NSRunningApplication *app=NSWorkspace.sharedWorkspace.frontmostApplication;
            if(app && !app.terminated && app.bundleIdentifier && [frontmost containsObject:app.bundleIdentifier])
                addDisabledHotkeyRule(disabled,rule);
            continue;
        }
        for(NSString *bundle in rule[@"while_running"]) {
            BOOL running=NO;
            for(NSRunningApplication *app in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundle])
                if(!app.terminated) {running=YES;break;}
            if(running) {addDisabledHotkeyRule(disabled,rule);break;}
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
    publishKeyboardStatus();
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
        id keys=rule[@"keycodes"];
        if(keys) {
            if(![keys isKindOfClass:NSArray.class] || ![keys count] || [keys count]>128)return NO;
            NSMutableSet *seen=[NSMutableSet set];
            for(id value in keys) {
                NSInteger key;
                if(!repeatInteger(value,-1,127,&key) || key<0 || [seen containsObject:@(key)])return NO;
                [seen addObject:@(key)];
            }
        }
        if((rule[@"while_running"]!=nil)==(rule[@"while_frontmost"]!=nil))return NO;
        id bundles=rule[@"while_frontmost"]?:rule[@"while_running"];
        if(![bundles isKindOfClass:NSArray.class] || ![bundles count] || [bundles count]>16)return NO;
        for(id bundle in bundles)if(![bundle isKindOfClass:NSString.class] || ![bundle length] || [bundle length]>255)return NO;
    }
    gHotkeyAppRules=rules;gDisabledHotkeyModifiers=disabledHotkeyModifiers();
    NSMutableArray *observers=[NSMutableArray array];
    for(NSString *name in @[NSWorkspaceDidLaunchApplicationNotification,NSWorkspaceDidTerminateApplicationNotification,
                            NSWorkspaceDidActivateApplicationNotification]) {
        id observer=[NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:name object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){(void)note;refreshHotkeyApplications();}];
        if(observer)[observers addObject:observer];
    }
    gHotkeyAppObservers=observers;return YES;
}
