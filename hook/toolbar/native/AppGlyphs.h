#import <CoreText/CoreText.h>
#include <libproc.h>
#include <sys/proc_info.h>

// The font carries its own APPM mapping. Registration is local to this process.
static CTFontRef appGlyphFont;
static NSDictionary *appGlyphPoints, *appGlyphNames, *appGlyphBundles, *appGlyphCustom;
static NSArray *appGlyphPrefixes;
static NSString *appGlyphDirectory;
static NSString *appGlyphNormalize(NSString *text) {
    if(![text isKindOfClass:NSString.class])return @"";
    text=[[text precomposedStringWithCompatibilityMapping] lowercaseString];
    NSArray *words=[text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}
static NSString *appGlyphBaseName(NSString *name) {
    NSString *value=appGlyphNormalize(name);
    static NSRegularExpression *suffix;static dispatch_once_t once;dispatch_once(&once,^{suffix=[NSRegularExpression regularExpressionWithPattern:@"(?:\\.app|[ ._-]+(?:helper(?: \\(.*\\))?|beta|nightly|canary|dev|debug)| ?[\\[(](?:beta|nightly|canary|dev|debug)[\\])])$" options:0 error:NULL];});
    for(NSUInteger n=0;n<5;n++){NSTextCheckingResult *match=[suffix firstMatchInString:value options:0 range:NSMakeRange(0,value.length)];if(!match)break;value=[value substringToIndex:match.range.location];}
    return value;
}
static uint32_t appGlyphBE32(const unsigned char *p) {return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];}
static BOOL appGlyphLoad(NSString *directory) {
    if(appGlyphFont)return YES;
    NSURL *url=[NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"sketchybar-app-font.ttf"]];
    CFArrayRef descriptors=CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
    if(!descriptors||CFArrayGetCount(descriptors)!=1){if(descriptors)CFRelease(descriptors);return NO;}
    CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,kCTFontManagerScopeProcess,NULL);
    CTFontRef font=CTFontCreateWithFontDescriptor(CFArrayGetValueAtIndex(descriptors,0),1000,NULL);CFRelease(descriptors);
    CFDataRef table=font?CTFontCopyTable(font,kCTFontTableMeta,kCTFontTableOptionNoOptions):NULL;
    NSDictionary *mapping=nil;
    if(table){const unsigned char *bytes=CFDataGetBytePtr(table);NSUInteger size=CFDataGetLength(table);
        if(size>=16&&appGlyphBE32(bytes)==1){uint32_t count=appGlyphBE32(bytes+12);if(count<=32&&16+count*12<=size)for(uint32_t i=0;i<count;i++){
            const unsigned char *row=bytes+16+i*12;NSUInteger offset=appGlyphBE32(row+4),length=appGlyphBE32(row+8);
            if(appGlyphBE32(row)==0x4150504d&&length<=2*1024*1024&&offset<=size&&length<=size-offset)mapping=[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes+offset length:length] options:0 error:NULL];
        }}CFRelease(table);}
    NSData *aliasData=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"aliases.json"]];
    NSDictionary *aliases=aliasData?[NSJSONSerialization JSONObjectWithData:aliasData options:0 error:NULL]:nil;
    NSMutableDictionary *points=[NSMutableDictionary new],*names=[NSMutableDictionary new];NSMutableArray *prefixes=[NSMutableArray new];
    if([mapping[@"version"] isEqual:@1]&&[mapping[@"icons"] isKindOfClass:NSArray.class]&&[mapping[@"icons"] count]<=2048)for(NSArray *row in mapping[@"icons"]){
        if(![row isKindOfClass:NSArray.class]||row.count!=3||![row[0] isKindOfClass:NSString.class]||![row[1] isKindOfClass:NSNumber.class])continue;
        unsigned code=[row[1] unsignedIntValue];if(code<0xe000||code>0xf8ff)continue;UniChar character=code;CGGlyph glyph=0;
        if(!CTFontGetGlyphsForCharacters(font,&character,&glyph,1)||!glyph)continue;
        points[row[0]]=@(glyph);
        if([row[2] isKindOfClass:NSArray.class])for(NSString *name in row[2])if([name isKindOfClass:NSString.class]){
            if([name hasSuffix:@"*"])[prefixes addObject:@[appGlyphNormalize([name substringToIndex:name.length-1]),row[0]]];else names[appGlyphNormalize(name)]=row[0];
        }
    }
    if(!points[@":default:"]||![aliases[@"schema"] isEqual:@1]){if(font)CFRelease(font);return NO;}
    [prefixes sortUsingComparator:^NSComparisonResult(NSArray *a,NSArray *b){return [a[0] length]>[b[0] length]?NSOrderedAscending:[a[0] length]<[b[0] length]?NSOrderedDescending:[a[0] compare:b[0]];}];
    for(NSString *key in aliases[@"custom"])for(NSString *name in aliases[@"custom"][key][@"names"])names[appGlyphNormalize(name)]=key;
    appGlyphFont=font;appGlyphPoints=points;appGlyphNames=names;appGlyphPrefixes=prefixes;appGlyphBundles=aliases[@"bundles"];appGlyphCustom=aliases[@"custom"];appGlyphDirectory=[directory copy];return YES;
}
static NSString *appGlyphMatch(NSString *bundle,NSString *name) {
    NSString *exact=appGlyphBundles[[bundle lowercaseString]];if(exact)return exact;
    NSString *normalized=appGlyphNormalize(name),*base=appGlyphBaseName(name);
    exact=appGlyphNames[normalized]?:appGlyphNames[base];if(exact)return exact;
    for(NSArray *row in appGlyphPrefixes)if([base hasPrefix:row[0]])return row[1];
    return nil;
}
static BOOL appGlyphNeedsParent(NSString *bundle,NSString *name) {
    NSString *normal=appGlyphNormalize(name),*lower=[bundle lowercaseString];
    return !bundle.length||[bundle isEqual:@"?"]||[lower containsString:@"helper"]||[lower hasSuffix:@".renderer"]||[lower hasSuffix:@".gpu"]||[lower hasSuffix:@".webcontent"]||[lower hasSuffix:@".plugincontainer"]||[lower hasPrefix:@"com.apple.safari.webapp."]||[lower hasPrefix:@"com.google.chrome.app."]||[normal containsString:@"helper"]||[@[@"electron",@"webcontent",@"plugin-container"] containsObject:normal];
}
static NSString *appGlyphIdentity(NSDictionary *app) {
    NSString *bundle=app[@"bundle"],*name=app[@"name"],*found=appGlyphMatch(bundle,name);
    if(!appGlyphNeedsParent(bundle,name))return found?:@":default:";
    pid_t pid=[app[@"pid"] intValue];NSMutableSet *seen=[NSMutableSet new];
    // The CG owner PID is the starting identity; titles never participate.
    for(unsigned depth=0;pid>1&&depth<8;depth++){
        if([seen containsObject:@(pid)])break;[seen addObject:@(pid)];struct proc_bsdinfo before={0},after={0};
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&before,sizeof before)!=sizeof before||before.pbi_uid!=getuid())break;
        if(depth==0&&[app[@"process_birth"] isKindOfClass:NSArray.class]){NSArray *birth=app[@"process_birth"];if(birth.count!=4||[birth[0] intValue]!=pid||[birth[2] unsignedLongLongValue]!=before.pbi_start_tvsec||[birth[3] unsignedLongLongValue]!=before.pbi_start_tvusec)break;}
        NSRunningApplication *owner=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *match=appGlyphMatch(owner.bundleIdentifier,owner.localizedName);
        if(proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&after,sizeof after)!=sizeof after||before.pbi_start_tvsec!=after.pbi_start_tvsec||before.pbi_start_tvusec!=after.pbi_start_tvusec)break;
        if(match&&!appGlyphNeedsParent(owner.bundleIdentifier,owner.localizedName))return match;
        // Nested Electron/helpers belong to the outer application bundle.
        NSString *path=owner.executableURL.path;NSString *prefix=@"";
        for(NSString *part in path.pathComponents){prefix=[prefix stringByAppendingPathComponent:part];if([part.pathExtension isEqual:@"app"]){NSBundle *outer=[NSBundle bundleWithPath:prefix];match=appGlyphMatch(outer.bundleIdentifier,outer.infoDictionary[@"CFBundleDisplayName"]?:outer.infoDictionary[@"CFBundleName"]);if(match)return match;break;}}
        pid=before.pbi_ppid;
    }
    return found?:@":default:";
}
static NSImage *appGlyphImage(NSString *identity,CGFloat size,NSColor *ink) {
    if(!appGlyphPoints[identity]&&!appGlyphCustom[identity])identity=@":default:";
    NSColor *color=[ink colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    NSString *key=[NSString stringWithFormat:@"%@:%g:%@",identity,size,color.description];static NSCache *cache;static dispatch_once_t once;dispatch_once(&once,^{cache=[NSCache new];cache.countLimit=512;});
    NSImage *image=[cache objectForKey:key];if(image)return image;
    NSImage *custom=nil;
    if(appGlyphCustom[identity]){
        custom=[[NSImage alloc] initWithContentsOfFile:[appGlyphDirectory stringByAppendingPathComponent:appGlyphCustom[identity][@"file"]]];
        if(!custom||![custom CGImageForProposedRect:NULL context:nil hints:nil])return appGlyphImage(@":default:",size,ink);
    }
    image=[[NSImage alloc] initWithSize:NSMakeSize(size,size)];[image lockFocus];[color setFill];
    if(custom){
        [custom drawInRect:NSMakeRect(0,0,size,size) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        NSRectFillUsingOperation(NSMakeRect(0,0,size,size),NSCompositingOperationSourceIn);
    }else{
        CGPathRef path=CTFontCreatePathForGlyph(appGlyphFont,[appGlyphPoints[identity] unsignedShortValue],NULL);
        if(path){CGRect box=CGPathGetBoundingBox(path);CGFloat scale=MIN(size/box.size.width,size/box.size.height);CGContextRef context=NSGraphicsContext.currentContext.CGContext;
            CGContextSaveGState(context);CGContextTranslateCTM(context,(size-box.size.width*scale)/2-box.origin.x*scale,(size-box.size.height*scale)/2-box.origin.y*scale);CGContextScaleCTM(context,scale,scale);CGContextAddPath(context,path);CGContextFillPath(context);CGContextRestoreGState(context);CGPathRelease(path);}
    }
    [image unlockFocus];image.template=NO;[cache setObject:image forKey:key];return image;
}

static NSString *nativeFocusText(NSString *app,NSString *title) {
    if(!title.length)return app?:@"";
    NSString *normalApp=appGlyphNormalize(app),*normalTitle=appGlyphNormalize(title);
    if([normalTitle isEqual:normalApp]||([normalTitle hasPrefix:normalApp]&&normalTitle.length>normalApp.length&&[[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[normalTitle characterAtIndex:normalApp.length]]))return title;
    return app.length?[NSString stringWithFormat:@"%@  %@",app,title]:title;
}
