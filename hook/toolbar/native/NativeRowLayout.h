// Geometry only; native caller obtains fresh CG rows. No window/process actions.
static CGFloat nativeRightBoundary(NSArray *rows,NSRect screen,CGFloat menuHeight,pid_t ownPID) {
    CGFloat fallback=NSMinX(screen)+NSWidth(screen)*.48;
    if(![rows isKindOfClass:NSArray.class]||rows.count>8192)return fallback;
    CGFloat edge=NSMaxX(screen);BOOL found=NO;
    for(id value in rows){if(![value isKindOfClass:NSDictionary.class])continue;NSDictionary *row=value;
        if([row[(id)kCGWindowOwnerPID] intValue]==ownPID)continue;
        NSInteger level=[row[(id)kCGWindowLayer] integerValue];if(level<NSMainMenuWindowLevel||level>NSMainMenuWindowLevel+2)continue;
        if(![row[(id)kCGWindowBounds] isKindOfClass:NSDictionary.class])continue;
        CGRect rect;if(!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)row[(id)kCGWindowBounds],&rect))continue;
        if(!isfinite(rect.origin.x)||!isfinite(rect.origin.y)||!isfinite(rect.size.width)||!isfinite(rect.size.height)||rect.size.width<=0||rect.size.width>NSWidth(screen)*.5||rect.size.height<14||rect.size.height>menuHeight+2)continue;
        // Primary-screen CG and AppKit horizontal coordinates coincide. Only the top native right region qualifies.
        if(rect.origin.x<NSMidX(screen)||rect.origin.y<0||rect.origin.y+rect.size.height>menuHeight+2)continue;
        edge=MIN(edge,rect.origin.x);found=YES;
    }
    return found?edge:fallback;
}

// Preserve native SF image proportions inside the existing optical slot.
static NSRect nativeGlyphAspectFit(NSSize source,NSRect slot) {
    if(!isfinite(source.width)||!isfinite(source.height)||source.width<=0||source.height<=0||!isfinite(slot.size.width)||!isfinite(slot.size.height)||slot.size.width<=0||slot.size.height<=0)return NSZeroRect;
    CGFloat scale=MIN(NSWidth(slot)/source.width,NSHeight(slot)/source.height);NSSize size=NSMakeSize(source.width*scale,source.height*scale);
    return NSMakeRect(NSMidX(slot)-size.width/2.0,NSMidY(slot)-size.height/2.0,size.width,size.height);
}
