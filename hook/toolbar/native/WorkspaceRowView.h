// Stable keyed drawing elements. A title update cannot invalidate glyph views.
@interface WorkspaceRowView : NSView
@property NSMutableDictionary<NSString *,NSImageView *> *elements;
@property NSUInteger changedElements;
@property NSUInteger changedGlyphs;
- (void)applySegments:(NSArray *)segments;
@end
@implementation WorkspaceRowView
- (NSView *)hitTest:(NSPoint)point {return nil;}
- (void)applySegments:(NSArray *)segments {
    if(!self.elements)self.elements=[NSMutableDictionary new];
    NSMutableSet *present=[NSMutableSet new];
    for(NSDictionary *segment in segments){
        NSString *key=segment[@"key"];[present addObject:key];NSImageView *view=self.elements[key];
        if(!view){view=[[NSImageView alloc] initWithFrame:NSZeroRect];view.imageScaling=NSImageScaleNone;view.wantsLayer=YES;self.elements[key]=view;
            [self addSubview:view positioned:[key hasPrefix:@"capsule:"]?NSWindowBelow:NSWindowAbove relativeTo:nil];}
        NSRect frame=[segment[@"frame"] rectValue];BOOL changed=NO;
        if(!NSEqualRects(view.frame,frame)){view.frame=frame;changed=YES;}
        if(view.image!=segment[@"image"]){view.image=segment[@"image"];changed=YES;}
        if(changed){self.changedElements++;if([key hasPrefix:@"glyph:"])self.changedGlyphs++;}
    }
    for(NSString *key in self.elements.allKeys)if(![present containsObject:key]){[self.elements[key] removeFromSuperview];[self.elements removeObjectForKey:key];self.changedElements++;if([key hasPrefix:@"glyph:"])self.changedGlyphs++;}
}
@end

static NSImage *nativeCachedSegment(NSDictionary *key,NSSize size,void (^draw)(void)) {
    static NSCache *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=512;});
    NSImage *image=[cache objectForKey:key];if(image)return image;
    image=[[NSImage alloc] initWithSize:size];[image lockFocus];draw();[image unlockFocus];image.template=NO;[cache setObject:image forKey:key];return image;
}
static NSDictionary *nativeRowSegment(NSString *key,NSImage *image,NSRect frame) {
    return @{@"key":key,@"image":image,@"frame":[NSValue valueWithRect:frame]};
}
