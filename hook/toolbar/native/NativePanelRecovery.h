// Pure recovery/status decisions. The caller has already validated bridge state.
// No GUI, Space getter/setter, process attachment or window ordering occurs here.
static BOOL panelInteger(id value,BOOL positive) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()&&isfinite([value doubleValue])&&[value doubleValue]>=(positive?1:0)&&[value doubleValue]<(1ULL<<53)&&floor([value doubleValue])==[value doubleValue];
}
static BOOL panelBoolean(id value,BOOL expected) {
    return [value isKindOfClass:NSNumber.class]&&CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()&&[value boolValue]==expected;
}
static NSNumber *panelActiveSID(NSDictionary *state) {
    NSNumber *active=nil;
    for(NSDictionary *row in state[@"spaces"]){if(panelBoolean(row[@"active"],YES)){if(active||!panelInteger(row[@"sid"],YES))return nil;active=row[@"sid"];}}
    return active;
}
static BOOL panelFailureWasOnlyActiveRace(NSDictionary *report,NSNumber *sid) {
    if(![report isKindOfClass:NSDictionary.class]||!panelBoolean(report[@"ok"],NO)||!panelInteger(sid,YES)||!panelInteger(report[@"requested_sid"],YES)||![report[@"requested_sid"] isEqual:sid]||!panelInteger(report[@"own_pid"],YES)||[report[@"own_pid"] longLongValue]!=getpid()||!panelInteger(report[@"own_wid"],YES)||[report[@"own_wid"] unsignedLongLongValue]>UINT32_MAX)return NO;
    if(!panelInteger(report[@"active_before"],YES)||!panelInteger(report[@"active_after"],YES)||[report[@"active_before"] isEqual:report[@"active_after"]]||!panelBoolean(report[@"foreign_window_acted_on"],NO)||!panelBoolean(report[@"space_activation_api_called"],NO))return NO;
    NSArray *members=report[@"after_membership"];
    if(![members isKindOfClass:NSArray.class]||members.count!=1||!panelInteger(members[0],YES)||![members[0] isEqual:sid])return NO;
    if([report[@"reason"] isEqual:@"active-space-changed-refused"])return panelBoolean(report[@"native_call_completed"],YES);
    return [report[@"reason"] isEqual:@"own-membership-or-active-changed-after-order"]&&[report[@"stage"] isEqual:@"after-order"];
}
static void panelRetryTransientFailures(NSMutableSet *failed,NSDictionary *reports,NSDictionary *previous,NSDictionary *next) {
    if(![previous isKindOfClass:NSDictionary.class]||!panelInteger(previous[@"revision"],NO)||!panelInteger(next[@"revision"],NO)||[next[@"revision"] unsignedLongLongValue]<=[previous[@"revision"] unsignedLongLongValue]||!panelBoolean(next[@"available"],YES)||!panelBoolean(next[@"retained"],NO)||![next[@"status"] isEqual:@"available"]||![next[@"reason"] isEqual:@""])return;
    NSMutableSet *ordinary=[NSMutableSet set];
    for(NSDictionary *row in next[@"spaces"])if(panelInteger(row[@"sid"],YES)&&panelInteger(row[@"type"],NO)&&[row[@"type"] isEqual:@0]&&panelInteger(row[@"ordinal"],YES))[ordinary addObject:row[@"sid"]];
    for(NSNumber *sid in failed.allObjects)if([ordinary containsObject:sid]&&panelFailureWasOnlyActiveRace(reports[sid.stringValue],sid))[failed removeObject:sid];
}
static NSDictionary *panelStatusBySID(NSDictionary *state,NSDictionary *panels,NSDictionary *reports,NSSet *failed) {
    NSMutableSet *sids=[NSMutableSet setWithArray:panels.allKeys?:@[]];
    for(NSDictionary *row in state[@"spaces"])if(panelInteger(row[@"sid"],YES))[sids addObject:row[@"sid"]];
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSNumber *sid in sids){id panel=panels[sid];NSInteger number=panel?[panel windowNumber]:0;NSDictionary *report=reports[sid.stringValue];
        BOOL verified=panel&&number>0&&number<=UINT32_MAX&&panelBoolean(report[@"ok"],YES)&&panelInteger(report[@"own_pid"],YES)&&[report[@"own_pid"] longLongValue]==getpid()&&panelInteger(report[@"own_wid"],YES)&&[report[@"own_wid"] longLongValue]==number&&panelInteger(report[@"requested_sid"],YES)&&[report[@"requested_sid"] isEqual:sid];
        result[sid.stringValue]=@{@"present":@((BOOL)(panel!=nil)),@"own_wid":number>0?@(number):NSNull.null,@"placement_verified":@(verified),@"nswindow_is_visible":@((BOOL)(panel&&[panel isVisible])),@"nswindow_is_on_active_space":@((BOOL)(panel&&[panel isOnActiveSpace])),@"failed_placement":@([failed containsObject:sid])};
    }
    return result;
}
static BOOL panelActiveReady(NSDictionary *state,NSDictionary *bySID) {
    NSNumber *sid=panelActiveSID(state);NSDictionary *row=bySID[sid.stringValue?:@""];
    return sid&&panelBoolean(row[@"present"],YES)&&panelBoolean(row[@"placement_verified"],YES)&&panelBoolean(row[@"nswindow_is_visible"],YES)&&panelBoolean(row[@"nswindow_is_on_active_space"],YES)&&panelBoolean(row[@"failed_placement"],NO);
}
