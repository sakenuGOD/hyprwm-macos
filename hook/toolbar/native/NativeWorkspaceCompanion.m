#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <math.h>
#import "OwnedSpaceWindow.h"
#import "SuppressionQualification.h"
#import "NativeRowLayout.h"
#import "NativeFocusMonitor.h"
#import "NativePanelRecovery.h"
#import "AppGlyphs.h"

static NSString *const CompanionID = @"dev.hyprwm.style.native-bar";
static BOOL boolean(id value) { return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID(); }
static BOOL positiveInteger(id value) { return [value isKindOfClass:NSNumber.class] && !boolean(value) && isfinite([value doubleValue]) && [value doubleValue]>0 && floor([value doubleValue])==[value doubleValue]; }
static BOOL boundedString(id value, NSUInteger limit) { return [value isKindOfClass:NSString.class] && [value length]<=limit && [value rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location==NSNotFound; }
#import "AppMenuClient.h"
static BOOL validWindowBirth(id birth,id pid) {
    return [birth isKindOfClass:NSArray.class]&&[birth count]==4&&panelInteger(birth[0],YES)&&[birth[0] isEqual:pid]&&panelInteger(birth[1],NO)&&[birth[1] unsignedLongLongValue]==getuid()&&panelInteger(birth[2],YES)&&panelInteger(birth[3],NO)&&[birth[3] unsignedLongLongValue]<1000000;
}
static BOOL validState(id value) {
    if (![value isKindOfClass:NSDictionary.class] || ![value[@"schema"] isEqual:@1] || ![value[@"kind"] isEqual:@"state"] || ![value[@"revision"] isKindOfClass:NSNumber.class] || boolean(value[@"revision"]) || !isfinite([value[@"revision"] doubleValue]) || [value[@"revision"] doubleValue]<0 || floor([value[@"revision"] doubleValue])!=[value[@"revision"] doubleValue]) return NO;
    if (!boolean(value[@"available"]) || !boolean(value[@"retained"]) || !boolean(value[@"click_enabled"]) || ![value[@"spaces"] isKindOfClass:NSArray.class] || [value[@"spaces"] count]>64) return NO;
    if([value[@"click_enabled"] boolValue] && (![value[@"available"] boolValue] || [value[@"retained"] boolValue]))return NO;
    if (![ @[@"available",@"retained",@"unavailable"] containsObject:value[@"status"]] || !boundedString(value[@"reason"],256)) return NO;
    if ([value[@"available"] boolValue] != [value[@"status"] isEqual:@"available"] || [value[@"retained"] boolValue] != [value[@"status"] isEqual:@"retained"]) return NO;
    if(value[@"focus"]){id focus=value[@"focus"];if(![focus isKindOfClass:NSDictionary.class]||!boolean(focus[@"available"])||!boundedString(focus[@"app"],256)||!boundedString(focus[@"title"],512)||([focus[@"available"] boolValue]&&![focus[@"app"] length]))return NO;}
    NSMutableSet *ids=[NSMutableSet set]; NSUInteger active=0;
    for (id row in value[@"spaces"]) {
        if (![row isKindOfClass:NSDictionary.class] || !positiveInteger(row[@"sid"]) || [ids containsObject:row[@"sid"]] || !boolean(row[@"active"]) || !boolean(row[@"apps_verified"]) || ![row[@"apps"] isKindOfClass:NSArray.class] || [row[@"apps"] count]>512) return NO;
        if(row[@"window_count"] && (!panelInteger(row[@"window_count"],NO) || [row[@"window_count"] unsignedLongLongValue]<[row[@"apps"] count] || [row[@"window_count"] unsignedLongLongValue]>8192))return NO;
        if (!panelInteger(row[@"type"],NO) || ([row[@"type"] isEqual:@0] ? !positiveInteger(row[@"ordinal"]) : row[@"ordinal"]!=NSNull.null)) return NO;
        [ids addObject:row[@"sid"]]; active += [row[@"active"] boolValue];
        NSMutableSet *keys=[NSMutableSet set];
        for (id app in row[@"apps"]) {
            if (![app isKindOfClass:NSDictionary.class] || !boundedString(app[@"bundle"],256) || !boundedString(app[@"name"],256) || !boundedString(app[@"key"],256) || ![app[@"key"] length] || [keys containsObject:app[@"key"]] || !panelInteger(app[@"wid"],YES) || [app[@"wid"] unsignedLongLongValue]>UINT32_MAX || !panelInteger(app[@"pid"],YES) || [app[@"pid"] unsignedLongLongValue]>INT_MAX || ![app[@"key"] isEqual:[@"wid:" stringByAppendingString:[app[@"wid"] stringValue]]]) return NO;
            [keys addObject:app[@"key"]];
            if(app[@"process_birth"]&&!validWindowBirth(app[@"process_birth"],app[@"pid"]))return NO;
        }
        id selected=row[@"selected_window"];
        if(selected){
            if(![selected isKindOfClass:NSDictionary.class]||!boolean(selected[@"available"])||!boundedString(selected[@"app"],256)||!boundedString(selected[@"title"],512))return NO;
            if([selected[@"available"] boolValue]){
                if(![selected[@"app"] length]||!panelInteger(selected[@"wid"],YES)||!panelInteger(selected[@"pid"],YES)||!validWindowBirth(selected[@"process_birth"],selected[@"pid"])||![@[@"native-focus-history",@"wm-space-selection"] containsObject:selected[@"source"]])return NO;
                BOOL member=NO;for(NSDictionary *app in row[@"apps"])if([app[@"wid"] isEqual:selected[@"wid"]]&&[app[@"pid"] isEqual:selected[@"pid"]]&&[app[@"process_birth"] isEqual:selected[@"process_birth"]])member=YES;
                if(!member)return NO;
            }
        }
        if (![row[@"apps_verified"] boolValue] && [row[@"apps"] count]) return NO;
    }
    return active<=1 && (![value[@"available"] boolValue] || ![ids count] || active==1);
}
static NSDictionary *viewportSelector(NSDictionary *window) {
    return @{@"wid":window[@"wid"],@"pid":window[@"pid"],@"birth":window[@"birth"],@"space":window[@"space"]};
}
static BOOL viewportMatchesFocus(id window,NSDictionary *focus,NSNumber *sid) {
    if(![window isKindOfClass:NSDictionary.class]||!leaseTrue(focus[@"available"])||
       !panelInteger(window[@"wid"],YES)||[window[@"wid"] unsignedLongLongValue]>UINT32_MAX||
       !panelInteger(window[@"pid"],YES)||[window[@"pid"] unsignedLongLongValue]>INT_MAX||
       !panelInteger(window[@"space"],YES)||![window[@"space"] isEqual:sid]||
       ![window[@"wid"] isEqual:focus[@"wid"]]||![window[@"pid"] isEqual:focus[@"pid"]]||
       !validWindowBirth(focus[@"process_birth"],focus[@"pid"])||!boolean(window[@"pending"]))return NO;
    NSArray *birth=focus[@"process_birth"];
    NSString *stamp=[NSString stringWithFormat:@"%@:%@:%@",birth[0],birth[2],birth[3]];
    if(![window[@"birth"] isEqual:stamp])return NO;
    for(NSString *key in @[@"x",@"y",@"max_x",@"max_y"]){id v=window[key];if(![v isKindOfClass:NSNumber.class]||boolean(v)||!isfinite([v doubleValue])||[v doubleValue]<0||[v doubleValue]>65536)return NO;}
    return [window[@"x"] doubleValue]<=[window[@"max_x"] doubleValue]&&[window[@"y"] doubleValue]<=[window[@"max_y"] doubleValue];
}
static NSArray *viewportDirections(NSDictionary *window) {
    NSMutableArray *result=[NSMutableArray new];
    if([window[@"max_x"] doubleValue]>1)[result addObjectsFromArray:@[@"left",@"right"]];
    if([window[@"max_y"] doubleValue]>1)[result addObjectsFromArray:@[@"up",@"down"]];
    if(result.count)[result addObject:@"reset"];return result;
}
static BOOL viewportCanMove(NSDictionary *window,NSString *direction) {
    double x=[window[@"x"] doubleValue],y=[window[@"y"] doubleValue];
    if([direction isEqual:@"left"])return x>.01;
    if([direction isEqual:@"right"])return x+.01<[window[@"max_x"] doubleValue];
    if([direction isEqual:@"up"])return y>.01;
    if([direction isEqual:@"down"])return y+.01<[window[@"max_y"] doubleValue];
    return x>.01||y>.01;
}
static CGFloat ordinalSlotWidth(NSString *ordinal) { return MAX(9.0,ordinal.length*9.0); }
static NSString *nativeWindowOverflow(NSDictionary *row) {
    NSUInteger total=row[@"window_count"]?[row[@"window_count"] unsignedIntegerValue]:[row[@"apps"] count];
    NSUInteger shown=[row[@"apps"] count];
    return total>shown?[NSString stringWithFormat:@"+%lu",(unsigned long)(total-shown)]:@"";
}
static CGFloat capsuleWidth(NSDictionary *row, CGFloat height, BOOL compact) {
    CGFloat glyph=MIN(16.0,MAX(10.0,height-6.0));
    NSUInteger count=[row[@"apps_verified"] boolValue] ? [row[@"apps"] count] : 1;
    NSString *ordinal=row[@"ordinal"]==NSNull.null ? @"•" : [row[@"ordinal"] stringValue];
    NSString *overflow=nativeWindowOverflow(row);
    CGFloat badge=overflow.length?(count?(compact?2:4):(compact?4:5))+overflow.length*6+4:0;
    return (compact?8.0:14.0) + ordinalSlotWidth(ordinal) + (count ? (compact?4.0:5.0)+count*glyph+(count-1)*(compact?2.0:4.0) : 0.0)+badge;
}
static NSDictionary *nativeVisibleWindowRow(NSDictionary *row,NSUInteger count) {
    NSMutableDictionary *visible=[row mutableCopy];NSArray *apps=row[@"apps"];
    visible[@"window_count"]=row[@"window_count"]?:@(apps.count);
    visible[@"apps"]=[apps subarrayWithRange:NSMakeRange(0,MIN(count,apps.count))];
    return visible;
}
static CGFloat nativeRowsWidth(NSArray *rows,CGFloat height,BOOL compact) {
    CGFloat width=0;for(NSDictionary *row in rows)width+=capsuleWidth(row,height,compact);
    return width+(rows.count?rows.count-1:0)*(compact?4:5);
}
static NSArray *nativeFitWindowRows(NSArray *rows,CGFloat height,BOOL compact,CGFloat budget) {
    if(nativeRowsWidth(rows,height,compact)<=budget)return rows;
    // Keep every ordinal and an explicit +N before sharing remaining glyph slots.
    NSMutableArray *visible=[NSMutableArray array];
    for(NSDictionary *row in rows)[visible addObject:nativeVisibleWindowRow(row,0)];
    CGFloat width=nativeRowsWidth(visible,height,compact);BOOL changed=YES;
    while(changed){
        changed=NO;
        for(NSUInteger i=0;i<rows.count;i++){
            NSUInteger count=[visible[i][@"apps"] count];if(count>=[rows[i][@"apps"] count])continue;
            NSDictionary *next=nativeVisibleWindowRow(rows[i],count+1);
            CGFloat nextWidth=width-capsuleWidth(visible[i],height,compact)+capsuleWidth(next,height,compact);
            if(nextWidth>budget && count+1<[rows[i][@"apps"] count]){
                next=nativeVisibleWindowRow(rows[i],[rows[i][@"apps"] count]);
                nextWidth=width-capsuleWidth(visible[i],height,compact)+capsuleWidth(next,height,compact);
            }
            if(nextWidth<=budget){visible[i]=next;width=nextWidth;changed=YES;}
        }
    }
    return visible;
}
static CGFloat nativeMenuBarHeight(CGFloat thickness, CGFloat safeTop, CGFloat visibleTopInset) {
    if(!isfinite(thickness)||thickness<14||thickness>64||!isfinite(safeTop)||safeTop<0||safeTop>64||!isfinite(visibleTopInset)||visibleTopInset<0||visibleTopInset>64)return NAN;
    // Public physical screen geometry; no guessed notch/menu-height constant.
    return MAX(thickness,MAX(safeTop,visibleTopInset));
}
static BOOL validAnchor(CGFloat x, CGFloat width, NSRect screen, CGFloat appleRight) {
    return isfinite(x)&&isfinite(width)&&width>0&&x>=NSMinX(screen)+4&&x>=appleRight+2&&x+width<=NSMinX(screen)+NSWidth(screen)*0.48;
}
static BOOL replacementFits(CGFloat appleEdge,CGFloat menuEdge,CGFloat contentWidth,NSRect screen) {
    return isfinite(appleEdge)&&isfinite(menuEdge)&&isfinite(contentWidth)&&contentWidth>0&&menuEdge-appleEdge>=contentWidth&&appleEdge>=NSMinX(screen)+8&&menuEdge<=NSMinX(screen)+NSWidth(screen)*.48;
}
typedef struct {BOOL available,native;CGFloat edge;} B15AnchorChoice;
static BOOL b15AnchorPending(BOOL enabled,BOOL waiting,NSDictionary *watchFront,NSDictionary *currentFront,NSDictionary *snapshot) {
    if(!enabled)return NO;
    if(waiting||!B15SameBirth(watchFront,currentFront))return YES;
    // A healthy owner can reply before AppKit activation converges. This does
    // not qualify its menu; keep existing geometry until its activation event.
    if(!B15SameBirth(snapshot[@"identity"],currentFront)||!boolean(snapshot[@"active"])||leaseTrue(snapshot[@"active"]))return NO;
    for(NSString *key in @[@"enabled",@"current_menu_matches",@"hook_owned",@"original_items_unchanged",@"apple_preserved"])if(!leaseTrue(snapshot[key]))return NO;
    return boolean(snapshot[@"failsafe"])&&!leaseTrue(snapshot[@"failsafe"])&&[snapshot[@"error"] isEqual:@""];
}
static B15AnchorChoice b15AnchorChoice(BOOL witness,CGFloat nativeEdge,BOOL legacy,CGFloat legacyEdge,NSRect screen,BOOL pending) {
    if(witness&&isfinite(nativeEdge)&&nativeEdge>=NSMinX(screen)+8&&nativeEdge<NSMaxX(screen))return (B15AnchorChoice){YES,YES,nativeEdge};
    if(!pending&&legacy&&isfinite(legacyEdge)&&legacyEdge>=NSMinX(screen)+8&&legacyEdge<NSMaxX(screen))return (B15AnchorChoice){YES,NO,legacyEdge};
    return (B15AnchorChoice){NO,NO,0};
}
// Transient native status/enabled/title changes do not replace controls being tracked.
static NSDictionary *b15HeadingModel(NSDictionary *snapshot,CGFloat height) {
    NSMutableArray *ids=[NSMutableArray new];for(NSDictionary *row in snapshot[@"headings"])[ids addObject:row[@"id"]];
    return @{@"identity":snapshot[@"identity"],@"epoch":snapshot[@"epoch"],@"ids":ids,@"height":@(height)};
}
static NSDictionary *spaceDisplayFocus(NSDictionary *space,NSDictionary *native,BOOL fresh) {
    NSDictionary *unknown=@{@"available":@NO,@"app":@"",@"title":@""};
    if(![space[@"apps_verified"] boolValue])return unknown;
    if(fresh&&[space[@"apps"] count]==0)return @{@"available":@YES,@"app":@"Нет окон",@"title":@""};
    for(NSDictionary *app in space[@"apps"])
        if([native[@"available"] boolValue]&&app[@"process_birth"]&&[native[@"wid"] isEqual:app[@"wid"]]&&[native[@"pid"] isEqual:app[@"pid"]]&&[native[@"process_birth"] isEqual:app[@"process_birth"]])return native;
    NSDictionary *selected=space[@"selected_window"];
    if(![selected[@"available"] boolValue])return unknown;
    NSMutableDictionary *focus=[selected mutableCopy];focus[@"app"]=privateFocusText(selected[@"app"],256);focus[@"title"]=privateFocusText(selected[@"title"],512);return focus;
}
static BOOL b15MenuSelectionMatches(NSDictionary *drawn,NSDictionary *native,NSDictionary *front,NSNumber *sid,NSNumber *catalogSID,uint64_t activeSID) {
    if(!positiveInteger(sid)||![sid isEqual:catalogSID]||sid.unsignedLongLongValue!=activeSID||!leaseTrue(drawn[@"available"])||!leaseTrue(native[@"available"]))return NO;
    if(!positiveInteger(drawn[@"wid"])||![drawn[@"wid"] isEqual:native[@"wid"]]||![drawn[@"pid"] isEqual:native[@"pid"]]||![drawn[@"process_birth"] isEqual:native[@"process_birth"]])return NO;
    NSArray *birth=drawn[@"process_birth"];
    return [birth isKindOfClass:NSArray.class]&&birth.count==4&&[birth isEqual:@[front[@"pid"]?:NSNull.null,front[@"uid"]?:NSNull.null,front[@"birth_sec"]?:NSNull.null,front[@"birth_usec"]?:NSNull.null]];
}
// Opt-in diagnostics preserve normal AppKit event routing.
@interface CompanionApplication : NSApplication @end
@implementation CompanionApplication
- (void)sendEvent:(NSEvent *)event {
    if(event.type==NSEventTypeLeftMouseDown||event.type==NSEventTypeLeftMouseUp)B15BarTrace(@"own-application-mouse type=%ld wid=%ld active=%d window_class=%@",(long)event.type,(long)event.windowNumber,self.active,NSStringFromClass(event.window.class));
    [super sendEvent:event];
}
@end
@interface QuietPanel : NSPanel
@property NSDictionary *menuSelection;
@property NSNumber *menuSID;
@property NSDictionary *viewportWindow;
@end
@implementation QuietPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)sendEvent:(NSEvent *)event {
    if(event.type==NSEventTypeLeftMouseDown||event.type==NSEventTypeLeftMouseUp)B15BarTrace(@"own-panel-mouse type=%ld wid=%ld x=%.1f y=%.1f",(long)event.type,(long)self.windowNumber,event.locationInWindow.x,event.locationInWindow.y);
    [super sendEvent:event];
}
@end
// Keep release-to-activate semantics without NSCell's nested tracking loop.
@interface WorkspaceButton : NSButton
@property BOOL pressArmed;
@end
@implementation WorkspaceButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event;return self.enabled; }
- (void)mouseDown:(NSEvent *)event {
    self.pressArmed=self.enabled&&event.window==self.window&&NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds);
}
- (void)mouseUp:(NSEvent *)event {
    BOOL armed=self.pressArmed;self.pressArmed=NO;
    if(armed&&self.enabled&&event.window==self.window&&NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],self.bounds))[self sendAction:self.action to:self.target];
}
@end
#import "WorkspaceRowView.h"
@interface Companion : NSObject <NSApplicationDelegate>
@property NSDictionary *settings;
@property NSString *settingsPath;
@property NSDictionary *state;
@property NSString *localReason;
@property NSString *sourceFailure;
@property NSTask *bridge;
@property NSPipe *bridgeOutput;
@property NSPipe *bridgeInput;
@property NSStatusItem *item;
@property QuietPanel *panel;
@property NSImageView *strip;
@property NSButton *panelButton;
@property dispatch_queue_t parserQueue;
@property NSMutableData *pending;
@property CGFloat nativeHeight;
@property CGFloat nativeStatusThickness;
@property CGFloat rightBoundary;
@property BOOL compactSpacing;
@property NSDictionary *pendingState;
@property NativeFocusMonitor *nativeFocus;
@property BOOL stateApplyScheduled;
@property CGFloat menuBarHeight;
@property CGFloat safeTop;
@property CGFloat visibleTopInset;
@property CGFloat measuredAppleEdge;
@property CGFloat measuredAppMenuEdge;
@property CGFloat panelWidth;
@property NSArray *renderedRows;
@property NSDictionary *lastWorkspaceAction;
@property BOOL anchorReadInFlight;
@property BOOL anchorReadPending;
@property NSUInteger anchorGeneration;
@property NSDictionary *menuAnchorState;
@property NSDictionary *anchorIdentity;
@property NSRect anchorScreen;
@property NSTimeInterval suppressionLeaseExpiry;
@property CGFloat actualWidth;
@property NSString *anchorSource;
@property BOOL terminating;
@property B15AppMenuClient *appMenuClient;
@property QuietPanel *appHeadingsPanel;
@property NSScrollView *appHeadingsScroll;
@property NSArray<NSButton *> *appHeadingButtons;
@property NSDictionary *appHeadingsModel;
@property BOOL appHeadingsExpanded;
@property NSNumber *appHeadingsSID;
@property CGFloat focusWidth;
@property QuietPanel *appMenuAnchorPanel;
@property NSMutableDictionary<NSNumber *,QuietPanel *> *spacePanels;
@property NSMutableDictionary *placementReports;
@property NSMutableSet *failedPlacements;
@property NSNumber *drawingSID;
@property NSDictionary *drawingFocus;
@property NSDictionary *drawingViewport;
@property CGFloat viewportWidth;
@property NSString *panRequestID;
@property NSDictionary *panSubmittedViewport;
@property NSDictionary *lastPanAction;
@end
@implementation Companion
- (BOOL)representationAnchor:(CGFloat*)edge screen:(NSScreen*)screen {
    if(!screen)return NO;
    NSDictionary *snapshot=self.appMenuClient.snapshot;
    if(!leaseTrue(snapshot[@"suppressed"])||!B15SameBirth(frontIdentity(),snapshot[@"identity"]))return NO;
    NSArray *a=snapshot[@"apple_frame"];if(![a isKindOfClass:NSArray.class]||a.count!=4)return NO;
    NSRect frame=NSMakeRect([a[0] doubleValue],[a[1] doubleValue],[a[2] doubleValue],[a[3] doubleValue]);
    if(!NSContainsRect(screen.frame,frame)||fabs(NSMaxY(frame)-NSMaxY(screen.frame))>3||frame.size.width<8||frame.size.width>100||frame.size.height<14||frame.size.height>64)return NO;
    *edge=NSMaxX(frame);return YES;
}
- (void)refreshMenuOwnerForFront:(NSDictionary*)front {
    if(front&&!B15SameBirth(self.appMenuClient.front,front))[self.appMenuClient refresh:front];
}
- (BOOL)menuOwnerContextForPanel:(QuietPanel*)panel {
    if(!panel)return NO;
    BOOL owned=panel==self.panel||[self.spacePanels.allValues containsObject:panel];
    if(!owned||!b15MenuSelectionMatches(panel.menuSelection,panel.menuSelection,frontIdentity(),panel.menuSID,panelActiveSID(self.state),ownCurrentActiveSpace()))return NO;
    CGFloat edge=0;return [self representationAnchor:&edge screen:panel.screen];
}
- (BOOL)menuOwnerQualifiedForPanel:(QuietPanel*)panel {
    if(![self.state[@"available"] boolValue]||self.sourceFailure||self.localReason||![self menuOwnerContextForPanel:panel])return NO;
    // Application menus keep the same owner across dialogs and cold AX reads.
    // Context already binds the panel, front process birth, Space and snapshot.
    return YES;
}
- (BOOL)applicationAnchor:(CGFloat*)edge native:(BOOL*)native screen:(NSScreen*)screen {
    NSDictionary *front=frontIdentity();[self refreshMenuOwnerForFront:front];
    CGFloat nativeEdge=NAN,legacyEdge=NAN;BOOL witness=[self representationAnchor:&nativeEdge screen:screen];
    BOOL legacy=!witness&&[self appleRight:&legacyEdge screen:screen];
    BOOL pending=b15AnchorPending([self.settings[@"b15_menu_enabled"] isEqual:@YES],self.appMenuClient.waitingForSnapshot,self.appMenuClient.front,frontIdentity(),self.appMenuClient.snapshot);
    B15AnchorChoice choice=b15AnchorChoice(witness,nativeEdge,legacy,legacyEdge,screen.frame,pending);
    if(choice.available){*edge=choice.edge;*native=choice.native;}return choice.available;
}
- (void)toggleApplicationMenu:(id)sender {
    [self.nativeFocus refresh];if(![self menuOwnerQualifiedForPanel:(QuietPanel*)[sender window]]){[self layout];return;}
    self.appMenuAnchorPanel=(QuietPanel*)[sender window];self.appHeadingsExpanded=!self.appHeadingsExpanded;B15BarTrace(@"headings-toggle expanded=%d epoch=%@",self.appHeadingsExpanded,B15TraceEpoch(self.appMenuClient.snapshot[@"epoch"]));[self layoutApplicationHeadings];
}
- (void)openOriginalHeading:(NSButton*)sender {
    [self.nativeFocus refresh];NSDictionary *snapshot=self.appMenuClient.snapshot;B15BarTrace(@"heading-action id=%@ epoch=%@ expanded=%d",B15TraceID(sender.identifier),B15TraceEpoch(snapshot[@"epoch"]),self.appHeadingsExpanded);if(!self.appHeadingsExpanded||![self menuOwnerQualifiedForPanel:self.appMenuAnchorPanel]){B15BarTrace(@"heading-refused predicate=collapsed_or_unqualified");return;}
    BOOL found=NO;for(NSDictionary *row in snapshot[@"headings"])if([row[@"id"] isEqual:sender.identifier]&&[row[@"enabled"] boolValue])found=YES;if(!found){B15BarTrace(@"heading-refused predicate=missing_or_disabled id=%@",B15TraceID(sender.identifier));return;}
    NSPoint anchor=[sender.window convertPointToScreen:[sender convertPoint:NSZeroPoint toView:nil]];
    [self.appMenuClient popup:sender.identifier epoch:snapshot[@"epoch"] anchor:anchor];
}
- (void)layoutApplicationHeadings {
    NSDictionary *snapshot=self.appMenuClient.snapshot;
    BOOL expanded=self.appHeadingsExpanded,visible=NO,qualified=NO;
    // An already-open authenticated popup may temporarily lack AX focus. Keep
    // its row while the same owner and Space remain; new commands stay strict.
    BOOL pending=leaseTrue(snapshot[@"popup_pending"])&&self.appHeadingsPanel.visible;
    if(!expanded||!(visible=self.appMenuAnchorPanel.visible)||!(qualified=pending?[self menuOwnerContextForPanel:self.appMenuAnchorPanel]:[self menuOwnerQualifiedForPanel:self.appMenuAnchorPanel])){
        B15BarTrace(@"headings-close predicate=%@ expanded=%d visibility_checked=%d visible=%d qualification_checked=%d qualified=%d epoch=%@ reason=%@",!expanded?@"already_collapsed":!visible?@"anchor_panel_invisible":@"representation_anchor_refused",expanded,expanded,visible,expanded&&visible,qualified,B15TraceEpoch(snapshot[@"epoch"]),self.appMenuClient.reason);
        self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];return;}
    if(leaseTrue(snapshot[@"popup_pending"])&&self.appHeadingsPanel.visible){B15BarTrace(@"headings-layout held=popup_pending epoch=%@",B15TraceEpoch(snapshot[@"epoch"]));return;}
    NSScreen *screen=self.appMenuAnchorPanel.screen;if(!screen){B15BarTrace(@"headings-orderout predicate=no_screen");[self.appHeadingsPanel orderOut:nil];return;}CGFloat x=NSMinX(self.appMenuAnchorPanel.frame),budget=MIN(NSMaxX(screen.frame)-x-8,self.rightBoundary-x);
    if(!screen||budget<40){B15BarTrace(@"headings-orderout predicate=screen_or_budget");[self.appHeadingsPanel orderOut:nil];return;}
    if(!self.appHeadingsPanel){self.appHeadingsPanel=[self newOwnedPanel];self.appHeadingsPanel.ignoresMouseEvents=NO;
        self.appHeadingsPanel.collectionBehavior=NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *material=[[NSVisualEffectView alloc] initWithFrame:NSZeroRect];material.material=NSVisualEffectMaterialMenu;material.blendingMode=NSVisualEffectBlendingModeBehindWindow;material.state=NSVisualEffectStateActive;self.appHeadingsPanel.contentView=material;}
    if(!self.appHeadingsScroll){
        NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];scroll.drawsBackground=NO;scroll.hasHorizontalScroller=YES;scroll.autohidesScrollers=YES;
        scroll.documentView=[[NSView alloc] initWithFrame:NSZeroRect];self.appHeadingsScroll=scroll;[self.appHeadingsPanel.contentView addSubview:scroll];
    }
    NSDictionary *model=b15HeadingModel(snapshot,self.nativeHeight);NSView *document=self.appHeadingsScroll.documentView;
    if(![model isEqual:self.appHeadingsModel]){
        B15BarTrace(@"headings-rebuild epoch=%@ pending=%d",B15TraceEpoch(snapshot[@"epoch"]),leaseTrue(snapshot[@"popup_pending"]));
        for(NSView *view in [document.subviews copy])[view removeFromSuperview];NSMutableArray *buttons=[NSMutableArray new];
        for(NSDictionary *row in snapshot[@"headings"]){NSButton *button=[NSButton buttonWithTitle:row[@"title"] target:self action:@selector(openOriginalHeading:)];button.identifier=row[@"id"];button.font=[NSFont menuBarFontOfSize:0];button.bordered=NO;button.bezelStyle=NSBezelStyleInline;button.focusRingType=NSFocusRingTypeNone;[document addSubview:button];[buttons addObject:button];}
        self.appHeadingButtons=buttons;self.appHeadingsModel=model;
    }
    CGFloat width=0,height=self.nativeHeight;NSUInteger index=0;
    for(NSDictionary *row in snapshot[@"headings"]){NSButton *button=self.appHeadingButtons[index++];
        if(![button.title isEqual:row[@"title"]])button.title=row[@"title"];BOOL enabled=[row[@"enabled"] boolValue];if(button.enabled!=enabled)button.enabled=enabled;
        CGFloat size=MAX(24,[button.cell cellSize].width+14);NSRect frame=NSMakeRect(width,0,size,height);if(!NSEqualRects(button.frame,frame))button.frame=frame;width+=size;}
    if(!width){B15BarTrace(@"headings-orderout predicate=no_heading_width");[self.appHeadingsPanel orderOut:nil];return;}
    NSRect documentFrame=NSMakeRect(0,0,width,height),scrollFrame=NSMakeRect(0,0,MIN(width,budget),height);
    if(!NSEqualRects(document.frame,documentFrame))document.frame=documentFrame;
    if(!NSEqualRects(self.appHeadingsScroll.frame,scrollFrame))self.appHeadingsScroll.frame=scrollFrame;
    NSRect panelFrame=NSMakeRect(x,NSMinY(self.appMenuAnchorPanel.frame)-height,MIN(width,budget),height);
    if(!NSEqualRects(self.appHeadingsPanel.frame,panelFrame))[self.appHeadingsPanel setFrame:panelFrame display:YES];
    NSNumber *sid=self.appMenuAnchorPanel.menuSID;
    uint64_t active=ownCurrentActiveSpace();
    if(!sid||sid.unsignedLongLongValue!=active){self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];return;}
    BOOL ordered=!self.appHeadingsPanel.visible;
    if(![self.appHeadingsSID isEqual:sid]||!self.appHeadingsPanel.isOnActiveSpace){
        NSMutableSet *catalog=[NSMutableSet set];
        for(NSDictionary *row in self.state[@"spaces"])if([row[@"type"] isEqual:@0]&&positiveInteger(row[@"ordinal"]))[catalog addObject:row[@"sid"]];
        NSDictionary *placement=placeOwnPanelWithScope(self.appHeadingsPanel,active,catalog,YES,YES);
        if(![placement[@"ok"] boolValue]){self.appHeadingsSID=nil;self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];return;}
        self.appHeadingsSID=sid;ordered=YES;
    }
    if(ordered){
        [self.appHeadingsPanel orderFrontRegardless];
        if(![verifyOwnPanelAfterOrder(self.appHeadingsPanel,active,active)[@"ok"] boolValue]){self.appHeadingsSID=nil;self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];}
    }
}
- (BOOL)transparentRow { return [@[@"left-transparent",@"left-inline"] containsObject:self.settings[@"presentation"]]; }
- (BOOL)qualifiedTransparentOwner {
    CGFloat nativeEdge=0;if([self.settings[@"b15_menu_enabled"] isEqual:@YES])return YES; // Final placement still requires native witness or AX-after-menu geometry.
    if([self representationAnchor:&nativeEdge screen:NSScreen.screens.firstObject])return YES;
    if(![self.settings[@"presentation"] isEqual:@"left-transparent"])return YES;
    NSDictionary *lease=readPrivateSuppressionLease(self.settings[@"menu_suppression_qualification"]);
    NSTimeInterval now=NSDate.date.timeIntervalSince1970;
    if(!suppressionLeaseValid(lease,frontIdentity(),self.settings[@"menu_suppression_module_sha256"],now))return NO;
    NSTimeInterval expiry=[lease[@"valid_until"] doubleValue];
    if(self.suppressionLeaseExpiry!=expiry){self.suppressionLeaseExpiry=expiry;dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)((expiry-now)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{if(self.suppressionLeaseExpiry==expiry)[self layout];});}
    return YES;
}
- (BOOL)perSpaceMode { return [self.settings[@"presentation"] isEqual:@"left-per-space-panels"] || ([self transparentRow] && [self.settings[@"own_space_panels_enabled"] isEqual:@YES]); }
- (NSDictionary *)contentViewportForFocus:(NSDictionary *)focus sid:(NSNumber *)sid {
    if(!leaseTrue(self.state[@"available"])||leaseTrue(self.state[@"retained"])||self.sourceFailure||self.localReason||![sid isEqual:panelActiveSID(self.state)])return nil;
    id viewport=self.state[@"viewport"];
    NSDictionary *window=[viewport isKindOfClass:NSDictionary.class]&&leaseTrue(viewport[@"supported"])?viewport[@"window"]:nil;
    if(viewportMatchesFocus(window,focus,sid))return window;
    // Preserve only the disabled controls while their own command is in flight.
    if(self.panRequestID&&viewportMatchesFocus(self.panSubmittedViewport,focus,sid))return self.panSubmittedViewport;
    return nil;
}
- (BOOL)contentContextForPanel:(QuietPanel *)panel window:(NSDictionary *)window {
    if(!window||self.terminating||!self.bridge.running||!leaseTrue(self.state[@"available"])||self.sourceFailure||self.localReason||leaseTrue(self.appMenuClient.snapshot[@"popup_pending"]))return NO;
    if(panel!=self.panel&&![self.spacePanels.allValues containsObject:panel])return NO;
    if(!viewportMatchesFocus(window,panel.menuSelection,panel.menuSID)||![panel.menuSID isEqual:panelActiveSID(self.state)]||panel.menuSID.unsignedLongLongValue!=ownCurrentActiveSpace())return NO;
    NSDictionary *front=frontIdentity();NSArray *birth=panel.menuSelection[@"process_birth"];
    return [birth isEqual:@[front[@"pid"]?:NSNull.null,front[@"uid"]?:NSNull.null,front[@"birth_sec"]?:NSNull.null,front[@"birth_usec"]?:NSNull.null]];
}
- (void)panContent:(NSButton *)sender {
    QuietPanel *panel=(QuietPanel *)sender.window;NSString *direction=[sender.identifier substringFromIndex:[@"viewport-pan:" length]];
    NSDictionary *window=[self contentViewportForFocus:panel.menuSelection sid:panel.menuSID];
    if(self.panRequestID||![@[@"left",@"right",@"up",@"down",@"reset"] containsObject:direction]||![self contentContextForPanel:panel window:window]||leaseTrue(window[@"pending"])||!viewportCanMove(window,direction))return;
    NSDictionary *selector=viewportSelector(window);NSString *request=NSUUID.UUID.UUIDString;
    self.panRequestID=request;self.panSubmittedViewport=window;self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];[self layout];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,50*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if(![self.panRequestID isEqual:request])return;
        [self.nativeFocus refresh];id viewport=self.state[@"viewport"];
        NSDictionary *current=[viewport isKindOfClass:NSDictionary.class]&&leaseTrue(viewport[@"supported"])?viewport[@"window"]:nil;
        if(!b15MenuSelectionMatches(panel.menuSelection,self.nativeFocus.focus,frontIdentity(),panel.menuSID,panelActiveSID(self.state),ownCurrentActiveSpace())||
           !viewportMatchesFocus(current,panel.menuSelection,panel.menuSID)||![self contentContextForPanel:panel window:current]||![viewportSelector(current) isEqual:selector]||leaseTrue(current[@"pending"])){
            self.panRequestID=nil;self.panSubmittedViewport=nil;[self layout];return;
        }
        NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"action":@"pan",@"direction":direction,@"window":selector,@"request_id":request} options:0 error:nil];
        NSMutableData *line=[data mutableCopy];[line appendBytes:"\n" length:1];
        @try{[self.bridgeInput.fileHandleForWriting writeData:line];}
        @catch(NSException *exception){(void)exception;self.panRequestID=nil;self.panSubmittedViewport=nil;[self layout];}
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(![self.panRequestID isEqual:request])return;
        self.lastPanAction=@{@"action":@"pan",@"request_id":request,@"ok":@NO,@"acknowledged":@NO,@"queued":NSNull.null,@"retry_allowed":@NO,@"reason":@"pan-confirmation-timeout"};
        self.panRequestID=nil;self.panSubmittedViewport=nil;[self layout];
    });
}
- (void)updatePanel:(QuietPanel *)panel segments:(NSArray *)segments image:(NSImage *)image width:(CGFloat)width {
    if(!image&&!segments) {
        // A retained packet changes input eligibility, not the last drawn row.
        BOOL enabled=[self.state[@"click_enabled"] boolValue]&&!self.localReason&&!self.sourceFailure;
        for(NSView *child in panel.contentView.subviews)if([child isKindOfClass:NSButton.class]) {
            NSButton *button=(NSButton*)child;
            if([child.identifier isEqual:@"workspace-hit"])button.enabled=enabled;
            if([child.identifier isEqual:@"app-title-hit"])button.enabled=NO;
            if([child.identifier hasPrefix:@"viewport-pan:"])button.enabled=NO;
        }
        if([self transparentRow])panel.ignoresMouseEvents=!enabled;
        return;
    }
    NSView *view=panel.contentView.subviews.firstObject;
    if(segments) {
        if(![view isKindOfClass:WorkspaceRowView.class]){[view removeFromSuperview];view=[[WorkspaceRowView alloc] initWithFrame:NSZeroRect];[panel.contentView addSubview:view positioned:NSWindowBelow relativeTo:nil];}
        NSRect frame=NSMakeRect(0,(self.menuBarHeight-self.nativeHeight)/2.0,width,self.nativeHeight);if(!NSEqualRects(view.frame,frame))view.frame=frame;[(WorkspaceRowView*)view applySegments:segments];
    } else if([view isKindOfClass:NSImageView.class]) {
        NSImageView *row=(NSImageView *)view;row.frame=NSMakeRect(0,(self.menuBarHeight-self.nativeHeight)/2.0,width,self.nativeHeight);row.image=image;
    } else {
        NSButton *button=(NSButton *)view;button.frame=NSMakeRect(0,0,width,self.menuBarHeight);button.image=image;
    }
    NSMutableDictionary<NSNumber *,NSButton *> *workspaceHits=[NSMutableDictionary new];
    for(NSView *child in panel.contentView.subviews)if([child.identifier isEqual:@"workspace-hit"]&&[child isKindOfClass:NSButton.class])workspaceHits[@([(NSButton *)child tag])]=(NSButton *)child;
    BOOL enabled=[self.state[@"click_enabled"] boolValue]&&!self.localReason&&!self.sourceFailure;
    NSButton *titleHit=nil;for(NSView *child in panel.contentView.subviews)if([child.identifier isEqual:@"app-title-hit"]&&[child isKindOfClass:NSButton.class]){titleHit=(NSButton*)child;break;}
    panel.menuSelection=self.drawingFocus;panel.menuSID=self.drawingSID?:panelActiveSID(self.state);panel.viewportWindow=self.drawingViewport;
    // Focus notifications may precede AX readiness. A click refreshes exact
    // native focus before dispatch; an unavailable cached read must not make
    // that recovery click inaccessible forever.
    BOOL titleEnabled=self.focusWidth>0&&[self.state[@"available"] boolValue]&&!self.sourceFailure&&!self.localReason&&[self menuOwnerContextForPanel:panel];
    if([self transparentRow])panel.ignoresMouseEvents=!(enabled||titleEnabled);
    if(titleEnabled&&!titleHit){titleHit=[WorkspaceButton buttonWithTitle:@"" target:self action:@selector(toggleApplicationMenu:)];titleHit.identifier=@"app-title-hit";titleHit.bordered=NO;titleHit.focusRingType=NSFocusRingTypeNone;[titleHit setAccessibilityLabel:@"Меню активного приложения"];[panel.contentView addSubview:titleHit];}
    if(titleHit){if(titleHit.hidden!=!titleEnabled)titleHit.hidden=!titleEnabled;if(titleHit.enabled!=titleEnabled)titleHit.enabled=titleEnabled;if(titleEnabled){NSRect frame=NSMakeRect(width-self.focusWidth-self.viewportWidth,0,self.focusWidth,self.menuBarHeight);if(!NSEqualRects(titleHit.frame,frame))titleHit.frame=frame;}}
    NSArray *panDirections=self.viewportWidth>0?viewportDirections(panel.viewportWindow):@[];
    NSMutableDictionary *panHits=[NSMutableDictionary new];
    for(NSView *child in panel.contentView.subviews)if([child.identifier hasPrefix:@"viewport-pan:"]&&[child isKindOfClass:NSButton.class])panHits[child.identifier]=(NSButton*)child;
    NSDictionary *symbols=@{@"left":@"arrow.left",@"right":@"arrow.right",@"up":@"arrow.up",@"down":@"arrow.down",@"reset":@"arrow.uturn.backward"};
    NSDictionary *labels=@{@"left":@"Содержимое левее",@"right":@"Содержимое правее",@"up":@"Содержимое выше",@"down":@"Содержимое ниже",@"reset":@"Сбросить положение содержимого"};
    NSMutableSet *panShown=[NSMutableSet new];NSUInteger index=0;
    BOOL panContext=[self contentContextForPanel:panel window:panel.viewportWindow]&&!self.panRequestID&&!leaseTrue(panel.viewportWindow[@"pending"]);
    for(NSString *direction in panDirections){
        NSString *identifier=[@"viewport-pan:" stringByAppendingString:direction];NSButton *button=panHits[identifier];
        if(!button){button=[WorkspaceButton buttonWithTitle:@"" target:self action:@selector(panContent:)];button.identifier=identifier;button.bordered=NO;button.focusRingType=NSFocusRingTypeNone;button.image=[NSImage imageWithSystemSymbolName:symbols[direction] accessibilityDescription:labels[direction]];button.imagePosition=NSImageOnly;button.toolTip=labels[direction];[button setAccessibilityLabel:labels[direction]];[panel.contentView addSubview:button];}
        button.frame=NSMakeRect(width-self.viewportWidth+6+22*index++,0,22,self.menuBarHeight);button.enabled=panContext&&viewportCanMove(panel.viewportWindow,direction);[panShown addObject:identifier];
    }
    for(NSString *identifier in panHits)if(![panShown containsObject:identifier])[panHits[identifier] removeFromSuperview];
    if([self transparentRow]&&panDirections.count)panel.ignoresMouseEvents=NO;
    NSMutableSet *shown=[NSMutableSet new];CGFloat x=0;for(NSDictionary *row in self.renderedRows){
        CGFloat size=capsuleWidth(row,self.nativeHeight,self.compactSpacing);
        if([row[@"type"] isEqual:@0]&&positiveInteger(row[@"ordinal"])){
            NSNumber *sid=row[@"sid"];NSButton *hit=workspaceHits[sid];
            if(!hit){hit=[WorkspaceButton buttonWithTitle:@"" target:self action:@selector(selectWorkspace:)];hit.identifier=@"workspace-hit";hit.bordered=NO;hit.focusRingType=NSFocusRingTypeNone;hit.tag=sid.integerValue;[panel.contentView addSubview:hit];}
            NSRect frame=NSMakeRect(x,0,size,self.menuBarHeight);if(!NSEqualRects(hit.frame,frame))hit.frame=frame;
            if(hit.enabled!=enabled)hit.enabled=enabled;
            [hit setAccessibilityLabel:[NSString stringWithFormat:@"Рабочий стол %@",row[@"ordinal"]]];[shown addObject:sid];
        }x+=size+(self.compactSpacing?4:5);
    }
    for(NSNumber *sid in workspaceHits)if(![shown containsObject:sid])[workspaceHits[sid] removeFromSuperview];
}
- (void)selectWorkspace:(id)sender {
    B15BarTrace(@"workspace-action sid=%ld wid=%ld",(long)[sender tag],(long)[[sender window] windowNumber]);
    BOOL pendingAnchor=[self.localReason isEqual:@"left-anchor-unavailable-no-fallback"];
    if(![self.state[@"click_enabled"] boolValue]||self.sourceFailure||(self.localReason&&!pendingAnchor)||!self.bridge.running)return;
    NSArray *ownedPanels=self.spacePanels.allValues;
    if(![ownedPanels containsObject:[sender window]]&&[sender window]!=self.panel)return;
    NSNumber *sid=@([sender tag]);BOOL found=NO;
    for(NSDictionary *row in self.state[@"spaces"])if([row[@"sid"] isEqual:sid]&&[row[@"type"] isEqual:@0])found=YES;
    if(!found)return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"action":@"workspace",@"sid":sid} options:0 error:nil];
    NSMutableData *line=[data mutableCopy];[line appendBytes:"\n" length:1];
    @try{[self.bridgeInput.fileHandleForWriting writeData:line];}@catch(NSException *exception){self.sourceFailure=@"bridge-input-unavailable";[self layout];}
}
- (NSMenu *)menu {
    NSMenu *menu=[[NSMenu alloc] initWithTitle:@"Spaces"];
    BOOL available=[self.state[@"available"] boolValue] && !self.localReason && !self.sourceFailure;
    NSString *heading=available ? @"Spaces · только просмотр" : @"Spaces · данные сохранены / недоступны";
    [menu addItem:[[NSMenuItem alloc] initWithTitle:heading action:nil keyEquivalent:@""]];
    for (NSDictionary *row in self.state[@"spaces"] ?: @[]) {
        NSString *ordinal=row[@"ordinal"]==NSNull.null ? @"Полноэкранное Space" : [NSString stringWithFormat:@"Space %@",row[@"ordinal"]];
        NSMutableArray *names=[NSMutableArray array]; for (NSDictionary *app in row[@"apps"]) if ([app[@"name"] length]) [names addObject:app[@"name"]];
        NSString *detail=![row[@"apps_verified"] boolValue] ? @"состав не проверен" : names.count ? [names componentsJoinedByString:@", "] : @"нет проверенных приложений";
        NSMenuItem *item=[[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@ — %@",ordinal,detail] action:nil keyEquivalent:@""];
        item.state=[row[@"active"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff; [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Переключение Spaces: backend не квалифицирован" action:nil keyEquivalent:@""]];
    if (self.sourceFailure.length || self.localReason.length || [self.state[@"reason"] length]) [menu addItem:[[NSMenuItem alloc] initWithTitle:self.sourceFailure ?: self.localReason ?: self.state[@"reason"] action:nil keyEquivalent:@""]];
    return menu;
}
- (void)showMenu:(id)sender { [NSMenu popUpContextMenu:[self menu] withEvent:NSApp.currentEvent forView:sender]; }
- (NSArray *)prepareRowWithWidth:(CGFloat *)resultWidth maxWidth:(CGFloat)maxWidth {
    CGFloat height=self.nativeHeight;
    NSNumber *panelSID=self.drawingSID?:panelActiveSID(self.state);NSDictionary *ownSpace=nil;
    for(NSDictionary *row in self.state[@"spaces"])if([row[@"sid"] isEqual:panelSID]){ownSpace=row;break;}
    NSDictionary *focus=spaceDisplayFocus(ownSpace,self.nativeFocus.focus,[self.state[@"available"] boolValue]&&!self.sourceFailure);self.drawingFocus=focus;
    NSDictionary *viewport=[self contentViewportForFocus:focus sid:panelSID];NSArray *directions=viewportDirections(viewport);
    CGFloat panWidth=directions.count?6+22*directions.count:0;
    NSMutableArray *minimumRows=[NSMutableArray new];for(NSDictionary *row in self.state[@"spaces"])[minimumRows addObject:nativeVisibleWindowRow(row,0)];
    if(maxWidth<nativeRowsWidth(minimumRows,height,self.compactSpacing)+82+panWidth)panWidth=0;
    CGFloat rowBudget=panWidth?maxWidth-panWidth-82:maxWidth;
    NSArray *rows=nativeFitWindowRows(self.state[@"spaces"]?:@[],height,self.compactSpacing,rowBudget);NSMutableArray *shown=[NSMutableArray new];CGFloat width=0;
    for(NSDictionary *row in rows){CGFloat next=capsuleWidth(row,height,self.compactSpacing)+(shown.count?(self.compactSpacing?4:5):0);if(width+next+(shown.count+1<rows.count?26:0)>rowBudget)break;[shown addObject:row];width+=next;}
    NSUInteger overflow=rows.count-shown.count;self.renderedRows=shown;
    CGFloat focusWidth=0;if(!overflow&&[focus[@"available"] boolValue]&&!self.sourceFailure&&(!self.compactSpacing||panWidth)){CGFloat room=maxWidth-width-10-panWidth;if(room>=72)focusWidth=MIN(220,room);}
    if(!focusWidth)panWidth=0;
    if(overflow)width+=26;if(!rows.count)width=32;
    width=MAX(24,MIN(width+(focusWidth?10+focusWidth:0)+panWidth,maxWidth));*resultWidth=width;self.focusWidth=focusWidth;self.viewportWidth=panWidth;self.drawingViewport=panWidth?viewport:nil;
    BOOL available=[self.state[@"available"] boolValue]&&!self.localReason&&!self.sourceFailure;
    NSColor *ink=[(available?NSColor.labelColor:NSColor.secondaryLabelColor) colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
    NSMutableArray *segments=[NSMutableArray new];CGFloat x=0,glyph=MIN(16.0,MAX(10.0,height-6));
    for(NSDictionary *row in shown){
        CGFloat cw=capsuleWidth(row,height,self.compactSpacing);BOOL active=self.drawingSID?[self.drawingSID isEqual:row[@"sid"]]:[row[@"active"] boolValue];
        NSString *ordinal=row[@"ordinal"]==NSNull.null?@"•":[row[@"ordinal"] stringValue],*badge=nativeWindowOverflow(row);BOOL compact=self.compactSpacing;
        NSDictionary *model=@{@"kind":@"capsule",@"ordinal":ordinal,@"badge":badge,@"active":@(active),@"compact":@(compact),@"width":@(cw),@"height":@(height),@"ink":ink.description};
        NSImage *background=nativeCachedSegment(model,NSMakeSize(cw,height),^{
            [[ink colorWithAlphaComponent:active?.14:.05] setFill];[[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0,2,cw,height-4) xRadius:5 yRadius:5] fill];
            NSFont *font=[NSFont monospacedDigitSystemFontOfSize:13 weight:active?NSFontWeightSemibold:NSFontWeightRegular];NSDictionary *attrs=@{NSFontAttributeName:font,NSForegroundColorAttributeName:ink};NSSize text=[ordinal sizeWithAttributes:attrs];
            [ordinal drawAtPoint:NSMakePoint(compact?4:7,round((height-text.height)/2)) withAttributes:attrs];
            if(badge.length)[badge drawAtPoint:NSMakePoint(cw-badge.length*6-(compact?4:7),round((height-12)/2)) withAttributes:@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],NSForegroundColorAttributeName:ink}];
        });
        [segments addObject:nativeRowSegment([@"capsule:" stringByAppendingString:[row[@"sid"] stringValue]],background,NSMakeRect(x,0,cw,height))];
        CGFloat ix=x+(compact?4:7)+ordinalSlotWidth(ordinal)+(compact?4:5);
        NSArray *apps=[row[@"apps_verified"] boolValue]?row[@"apps"]:@[@{@"bundle":@"?"}];
        for(NSDictionary *app in apps){
            NSString *identity=appGlyphIdentity(app);NSImage *image=appGlyphImage(identity,glyph,available?ink:[ink colorWithAlphaComponent:.6]);
            NSString *key=[NSString stringWithFormat:@"glyph:%@:%@:%@",row[@"sid"],app[@"key"]?:@"unknown",app[@"process_birth"]?:@[]];
            [segments addObject:nativeRowSegment(key,image,NSMakeRect(ix,(height-glyph)/2,glyph,glyph))];ix+=glyph+(compact?2:4);
        }
        x+=cw+(compact?4:5);
    }
    if(overflow){NSString *text=[NSString stringWithFormat:@"+%lu",(unsigned long)overflow];NSDictionary *key=@{@"kind":@"overflow",@"text":text,@"height":@(height),@"ink":ink.description};NSImage *image=nativeCachedSegment(key,NSMakeSize(26,height),^{[text drawAtPoint:NSMakePoint(2,round((height-12)/2)) withAttributes:@{NSFontAttributeName:[NSFont systemFontOfSize:10],NSForegroundColorAttributeName:ink}];});[segments addObject:nativeRowSegment(@"overflow",image,NSMakeRect(x,0,26,height))];}
    if(!rows.count)[segments addObject:nativeRowSegment(@"unavailable",appGlyphImage(@":default:",16,ink),NSMakeRect(8,(height-16)/2,16,16))];
    if(focusWidth>0){
        NSString *text=nativeFocusText(focus[@"app"],focus[@"title"]);NSDictionary *key=@{@"kind":@"title",@"text":text,@"width":@(focusWidth),@"height":@(height),@"ink":ink.description};
        NSImage *image=nativeCachedSegment(key,NSMakeSize(focusWidth,height),^{NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];paragraph.lineBreakMode=NSLineBreakByTruncatingTail;[text drawWithRect:NSMakeRect(0,round((height-17)/2),focusWidth,17) options:NSStringDrawingUsesLineFragmentOrigin attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:13],NSForegroundColorAttributeName:ink,NSParagraphStyleAttributeName:paragraph}];});
        [segments addObject:nativeRowSegment(@"focus-title",image,NSMakeRect(width-focusWidth-panWidth,0,focusWidth,height))];
    }
    return segments;
}
- (NSImage *)imageWithWidth:(CGFloat *)resultWidth maxWidth:(CGFloat)maxWidth {
    NSArray *segments=[self prepareRowWithWidth:resultWidth maxWidth:maxWidth];NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(*resultWidth,self.nativeHeight)];[image lockFocus];
    for(NSDictionary *segment in segments)[segment[@"image"] drawInRect:[segment[@"frame"] rectValue] fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
    [image unlockFocus];return image;
}
- (NSDictionary *)readMenuEdges:(NSDictionary *)identity display:(CGRect)display afterMenus:(BOOL)afterMenus {
    if (!AXIsProcessTrusted()) return nil;
    pid_t pid=[identity[@"pid"] intValue]; if (pid<=0) return nil;
    AXUIElementRef app=AXUIElementCreateApplication(pid);CFTypeRef menu=NULL,children=NULL;BOOL found=NO;
    CGFloat apple=0, menuEdge=0;
    AXUIElementSetMessagingTimeout(app,.05);
    if(AXUIElementCopyAttributeValue(app,kAXMenuBarAttribute,&menu)==kAXErrorSuccess&&menu&&CFGetTypeID(menu)==AXUIElementGetTypeID()&&AXUIElementCopyAttributeValue((AXUIElementRef)menu,kAXChildrenAttribute,&children)==kAXErrorSuccess&&children&&CFGetTypeID(children)==CFArrayGetTypeID()) {
        CFIndex count=CFArrayGetCount(children);CGFloat last=0;BOOL valid=count>0&&count<=64;
        for(CFIndex i=0;valid&&i<count;i++) {
            CFTypeRef child=CFArrayGetValueAtIndex(children,i);CFTypeRef pos=NULL,size=NULL,role=NULL;CGPoint point={0};CGSize extent={0};
            BOOL item=CFGetTypeID(child)==AXUIElementGetTypeID()&&AXUIElementCopyAttributeValue((AXUIElementRef)child,kAXRoleAttribute,&role)==kAXErrorSuccess&&role&&CFEqual(role,kAXMenuBarItemRole)&&AXUIElementCopyAttributeValue((AXUIElementRef)child,kAXPositionAttribute,&pos)==kAXErrorSuccess&&AXUIElementCopyAttributeValue((AXUIElementRef)child,kAXSizeAttribute,&size)==kAXErrorSuccess&&pos&&size&&CFGetTypeID(pos)==AXValueGetTypeID()&&CFGetTypeID(size)==AXValueGetTypeID()&&AXValueGetType((AXValueRef)pos)==kAXValueCGPointType&&AXValueGetType((AXValueRef)size)==kAXValueCGSizeType&&AXValueGetValue((AXValueRef)pos,kAXValueCGPointType,&point)&&AXValueGetValue((AXValueRef)size,kAXValueCGSizeType,&extent);
            valid=item&&isfinite(point.x)&&isfinite(point.y)&&isfinite(extent.width)&&isfinite(extent.height)&&extent.width>0&&extent.height>0&&fabs(point.y-display.origin.y)<3&&point.x>=display.origin.x&&point.x+extent.width<=CGRectGetMaxX(display);
            if(i==0)valid=valid&&extent.width>8&&extent.width<80&&point.x<display.origin.x+40;
            if(valid){last=MAX(last,point.x+extent.width);if(i==0)apple=last;}
            if(pos)CFRelease(pos);if(size)CFRelease(size);if(role)CFRelease(role);
            if(!afterMenus)break;
        }
        if(valid&&last>0){menuEdge=last;found=YES;}
    }
    if(children)CFRelease(children);if(menu)CFRelease(menu);CFRelease(app);return found?@{@"apple":@(apple),@"menu":@(menuEdge)}:nil;
}
- (BOOL)appleRight:(CGFloat *)edge screen:(NSScreen *)screen {
    if(![self.anchorIdentity isEqual:frontIdentity()] || !NSEqualRects(self.anchorScreen,screen.frame))return NO;
    *edge=self.measuredAppMenuEdge;return self.measuredAppleEdge>0 && *edge>0;
}
- (void)refreshAnchor {
    if(self.anchorReadInFlight){self.anchorReadPending=YES;return;}
    NSScreen *screen=NSScreen.screens.firstObject;NSDictionary *identity=frontIdentity();
    if(!screen || !identity)return;
    NSRect frame=screen.frame;CGRect display=CGDisplayBounds((CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue]);
    BOOL afterMenus=[self.settings[@"b15_menu_enabled"] isEqual:@YES] || [self.settings[@"presentation"] isEqual:@"left-inline"] || (![self transparentRow] && (![self.settings[@"anchor_after_app_menus"] isEqual:@NO] || [self.settings[@"presentation"] isEqual:@"left-replacement"]));
    NSUInteger generation=self.anchorGeneration;self.anchorReadInFlight=YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSDictionary *edges=[self readMenuEdges:identity display:display afterMenus:afterMenus];
        dispatch_async(dispatch_get_main_queue(),^{
            self.anchorReadInFlight=NO;if(self.terminating)return;
            if(edges && generation==self.anchorGeneration && [identity isEqual:frontIdentity()] && NSEqualRects(frame,NSScreen.screens.firstObject.frame)) {
                self.anchorIdentity=identity;self.anchorScreen=frame;
                self.measuredAppleEdge=[edges[@"apple"] doubleValue];self.measuredAppMenuEdge=[edges[@"menu"] doubleValue];[self layout];
            }
            if(self.anchorReadPending){self.anchorReadPending=NO;[self refreshAnchor];}
        });
    });
}
- (void)applicationMenuStateChanged {
    NSDictionary *snapshot=self.appMenuClient.snapshot;
    B15BarTrace(@"application-menu-state reason=%@ epoch=%@ suppressed=%d pending=%d expanded=%d",self.appMenuClient.reason,B15TraceEpoch(snapshot[@"epoch"]),leaseTrue(snapshot[@"suppressed"]),leaseTrue(snapshot[@"popup_pending"]),self.appHeadingsExpanded);
    NSDictionary *marker=@{@"identity":snapshot[@"identity"]?:@{},@"epoch":snapshot[@"epoch"]?:@0,@"suppressed":@([snapshot[@"suppressed"] boolValue])};
    if(![marker isEqual:self.menuAnchorState]){
        self.menuAnchorState=marker;self.anchorGeneration++;self.anchorIdentity=nil;[self refreshAnchor];
    }
    [self layout];[self layoutApplicationHeadings];
}
- (void)layout {
    self.nativeStatusThickness=NSStatusBar.systemStatusBar.thickness; NSScreen *screen=NSScreen.screens.firstObject;
    self.safeTop=screen?screen.safeAreaInsets.top:NAN;self.visibleTopInset=screen?NSMaxY(screen.frame)-NSMaxY(screen.visibleFrame):NAN;
    self.menuBarHeight=nativeMenuBarHeight(self.nativeStatusThickness,self.safeTop,self.visibleTopInset);
    self.nativeHeight=MIN(self.menuBarHeight,MAX(self.nativeStatusThickness,24));
    if (!screen || !isfinite(self.menuBarHeight) || !isfinite(self.nativeHeight) || self.nativeHeight<14 || self.nativeHeight>64) { self.localReason=@"native-menubar-geometry-unavailable"; [self.panel orderOut:nil]; for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil]; [self writeStatus]; return; }
    if([self transparentRow]&&![self qualifiedTransparentOwner]){self.localReason=@"application-menu-suppression-unqualified";[self.panel orderOut:nil];for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil];[self writeStatus];return;}
    if([self.localReason isEqual:@"native-menubar-geometry-unavailable"]||[self.localReason isEqual:@"application-menu-suppression-unqualified"])self.localReason=nil;
    NSArray *nativeRows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly,kCGNullWindowID));self.rightBoundary=nativeRightBoundary(nativeRows,screen.frame,self.menuBarHeight,getpid())-8;
    CGFloat maxWidth=MIN(480,NSWidth(screen.frame)*.48);
    if ([self.settings[@"maximum_left_width"] isKindOfClass:NSNumber.class]) maxWidth=MIN(maxWidth,MAX(24,[self.settings[@"maximum_left_width"] doubleValue]));
    if ([self perSpaceMode]) { [self layoutOwnSpacePanels:screen maximum:maxWidth]; [self layoutApplicationHeadings]; [self writeStatus]; return; }
    self.compactSpacing=NO;CGFloat width=0;NSImage *image=nil;
    if ([self.settings[@"presentation"] isEqual:@"native-extras"]) {
        image=[self imageWithWidth:&width maxWidth:maxWidth];self.actualWidth=width;self.anchorSource=@"public-NSStatusItem-right-extras"; self.item.length=width; self.item.button.image=image; self.item.button.imagePosition=NSImageOnly;self.item.button.imageScaling=NSImageScaleNone; self.item.button.toolTip=@"Spaces · только просмотр"; self.item.menu=[self menu];
    } else {
        CGFloat apple=0,x=0;BOOL nativeRepresentation=NO;
        BOOL verified=[self applicationAnchor:&apple native:&nativeRepresentation screen:screen];
        if (verified) { x=nativeRepresentation?apple+4:![self.settings[@"b15_menu_enabled"] isEqual:@YES]&&[self.settings[@"presentation"] isEqual:@"left-transparent"]?self.measuredAppleEdge+4:apple+8; self.anchorSource=![self.settings[@"b15_menu_enabled"] isEqual:@YES]&&[self.settings[@"presentation"] isEqual:@"left-transparent"]?@"public-AX-Apple-edge-transparent-row":@"public-AX-after-last-application-menu-item"; }
        if(nativeRepresentation)self.anchorSource=@"qualified-owner-native-representation-Apple-edge";
        else if (!verified && ![self.settings[@"b15_menu_enabled"] isEqual:@YES] && ![self transparentRow] && [self.settings[@"anchor_after_app_menus"] isEqual:@NO] && [self.settings[@"left_anchor_x"] isKindOfClass:NSNumber.class] && !boolean(self.settings[@"left_anchor_x"])) { x=[self.settings[@"left_anchor_x"] doubleValue]; apple=NSMinX(screen.frame)+20; self.anchorSource=@"explicit-root-reviewed-anchor"; }
        else if(!verified) { self.localReason=@"left-anchor-unavailable-no-fallback"; self.anchorSource=@"pending-native-menu-event";[self.panel orderOut:nil];[self writeStatus];return; }
        maxWidth=MIN(maxWidth,self.rightBoundary-x);if(maxWidth<24){self.localReason=@"left-native-free-slot-unavailable";[self.panel orderOut:nil];[self writeStatus];return;}
        if([self.localReason hasPrefix:@"left-anchor"]||[self.localReason isEqual:@"left-native-free-slot-unavailable"])self.localReason=nil;
        CGFloat expanded=0;for(NSDictionary *row in self.state[@"spaces"])expanded+=capsuleWidth(row,self.nativeHeight,NO)+(expanded?5:0);self.compactSpacing=expanded>maxWidth;
        image=[self imageWithWidth:&width maxWidth:maxWidth];self.actualWidth=width;
        CGFloat panelWidth=width;BOOL replacing=[self.settings[@"presentation"] isEqual:@"left-replacement"]&&![self.settings[@"b15_menu_enabled"] isEqual:@YES];
        if(replacing&&verified){x=self.measuredAppleEdge;panelWidth=self.measuredAppMenuEdge-x;self.anchorSource=@"public-AX-Apple-to-application-menu-end-visual-mask";}
        BOOL fits=replacing ? (verified&&replacementFits(x,self.measuredAppMenuEdge,width,screen.frame)) : (isfinite(x)&&isfinite(width)&&width>0&&x>=(nativeRepresentation?apple:[self.settings[@"presentation"] isEqual:@"left-transparent"]?self.measuredAppleEdge:apple)+2&&x+width<=self.rightBoundary);
        if (!fits) { self.localReason=@"left-anchor-outside-reviewed-left-region"; [self.panel orderOut:nil]; [self writeStatus]; return; }
        if ([self.localReason hasPrefix:@"left-anchor"]) self.localReason=nil;
        self.panelWidth=panelWidth;[self.panel setFrame:NSMakeRect(x,NSMaxY(screen.frame)-self.menuBarHeight,panelWidth,self.menuBarHeight) display:YES]; [self updatePanel:self.panel segments:nil image:image width:width]; [self.panel orderFrontRegardless];
    }
    [self layoutApplicationHeadings];[self writeStatus];
}
- (QuietPanel *)newOwnedPanel {
    QuietPanel *panel=[[QuietPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed=NO;panel.opaque=NO;panel.backgroundColor=NSColor.clearColor;panel.hasShadow=NO;panel.level=NSMainMenuWindowLevel+1;panel.hidesOnDeactivate=NO;
    // Direct placement owns one Space; Stationary keeps the toolbar out of Exposé.
    // No CanJoinAllSpaces, MoveToActiveSpace or fullscreen auxiliary copy.
    panel.collectionBehavior=NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
    if([self transparentRow]) {
        panel.contentView=[[NSView alloc] initWithFrame:NSZeroRect];panel.ignoresMouseEvents=YES;
        NSImageView *row=[[NSImageView alloc] initWithFrame:NSZeroRect];row.imageScaling=NSImageScaleNone;row.contentTintColor=NSColor.whiteColor;row.imageAlignment=NSImageAlignCenter;[row setAccessibilityLabel:@"Spaces"];[row setAccessibilityHelp:@"Переключение Spaces недоступно"];[panel.contentView addSubview:row];
    } else {
        NSVisualEffectView *material=[[NSVisualEffectView alloc] initWithFrame:NSZeroRect];material.material=NSVisualEffectMaterialMenu;material.blendingMode=NSVisualEffectBlendingModeBehindWindow;material.state=NSVisualEffectStateActive;material.wantsLayer=YES;material.layer.cornerRadius=5;material.layer.masksToBounds=YES;panel.contentView=material;
        NSButton *button=[NSButton buttonWithTitle:@"" target:self action:@selector(showMenu:)];button.bordered=NO;button.imagePosition=NSImageOnly;button.imageScaling=NSImageScaleNone;button.focusRingType=NSFocusRingTypeNone;[material addSubview:button];
    }
    return panel;
}
- (void)layoutOwnSpacePanels:(NSScreen *)screen maximum:(CGFloat)maxWidth {
    if (![self.settings[@"own_space_panels_enabled"] isEqual:@YES]) {self.localReason=@"own-space-panels-not-explicitly-enabled";return;}
    CGFloat apple=0,x=0;BOOL nativeRepresentation=NO;BOOL verified=[self applicationAnchor:&apple native:&nativeRepresentation screen:screen];
    if (verified) {x=nativeRepresentation?apple+4:![self.settings[@"b15_menu_enabled"] isEqual:@YES]&&[self.settings[@"presentation"] isEqual:@"left-transparent"]?self.measuredAppleEdge+4:apple+8;self.anchorSource=nativeRepresentation?@"qualified-owner-native-representation-Apple-edge-per-space":![self.settings[@"b15_menu_enabled"] isEqual:@YES]&&[self.settings[@"presentation"] isEqual:@"left-transparent"]?@"public-AX-Apple-edge-transparent-row":@"public-AX-after-last-application-menu-item";apple=![self.settings[@"b15_menu_enabled"] isEqual:@YES]&&[self.settings[@"presentation"] isEqual:@"left-transparent"]?self.measuredAppleEdge:apple;}
    else if (![self.settings[@"b15_menu_enabled"] isEqual:@YES] && ![self transparentRow] && [self.settings[@"anchor_after_app_menus"] isEqual:@NO] && [self.settings[@"left_anchor_x"] isKindOfClass:NSNumber.class]&&!boolean(self.settings[@"left_anchor_x"])) {x=[self.settings[@"left_anchor_x"] doubleValue];apple=NSMinX(screen.frame)+20;self.anchorSource=@"explicit-root-reviewed-anchor";}
    else {self.localReason=@"left-anchor-unavailable-no-fallback";self.anchorSource=@"pending-native-menu-event";for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil];return;}
    if ([self.localReason hasPrefix:@"left-anchor"])self.localReason=nil;
    maxWidth=MIN(maxWidth,self.rightBoundary-x);if(maxWidth<24){self.localReason=@"left-native-free-slot-unavailable";for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil];return;}
    if([self.localReason isEqual:@"left-native-free-slot-unavailable"])self.localReason=nil;
    CGFloat expanded=0;for(NSDictionary *row in self.state[@"spaces"])expanded+=capsuleWidth(row,self.nativeHeight,NO)+(expanded?5:0);self.compactSpacing=expanded>maxWidth;
    if (![self.state[@"available"] boolValue] || self.sourceFailure) {
        // Revalidate geometry even for retained data; never create/assign/order a window here.
        for (NSNumber *sid in self.spacePanels) {
            QuietPanel *panel=self.spacePanels[sid];CGFloat width=NSWidth(panel.frame);self.actualWidth=width;
            if(!(isfinite(x)&&isfinite(width)&&width>0&&x>=apple+2&&x+width<=self.rightBoundary)){self.localReason=@"left-anchor-outside-reviewed-left-region";for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil];break;}
            NSRect frame=NSMakeRect(x,NSMaxY(screen.frame)-self.menuBarHeight,width,self.menuBarHeight);if(!NSEqualRects(panel.frame,frame))[panel setFrame:frame display:YES];[self updatePanel:panel segments:nil image:nil width:width];
        }
        self.drawingSID=nil;return;
    }
    NSMutableSet *catalog=[NSMutableSet set];
    for(NSDictionary *row in self.state[@"spaces"]) if([row[@"type"] isKindOfClass:NSNumber.class]&&!boolean(row[@"type"])&&[row[@"type"] isEqual:@0]&&positiveInteger(row[@"ordinal"]))[catalog addObject:row[@"sid"]];
    for (NSNumber *sid in catalog) {
        if([self.failedPlacements containsObject:sid])continue;
        self.drawingSID=sid;CGFloat width=0;NSArray *segments=[self prepareRowWithWidth:&width maxWidth:maxWidth];self.actualWidth=width;
        if(!(isfinite(x)&&isfinite(width)&&width>0&&x>=apple+2&&x+width<=self.rightBoundary)){self.localReason=@"left-anchor-outside-reviewed-left-region";for(NSWindow *panel in self.spacePanels.allValues)[panel orderOut:nil];break;}
        QuietPanel *panel=self.spacePanels[sid];BOOL created=panel==nil;if(created)panel=[self newOwnedPanel];
        NSRect frame=NSMakeRect(x,NSMaxY(screen.frame)-self.menuBarHeight,width,self.menuBarHeight);if(!NSEqualRects(panel.frame,frame))[panel setFrame:frame display:NO];[self updatePanel:panel segments:segments image:nil width:width];
        if(created) {
            NSDictionary *report=placeOwnPanel(panel,sid.unsignedLongLongValue,catalog,YES);self.placementReports[sid.stringValue]=report;
            if(![report[@"ok"] boolValue]){[self.failedPlacements addObject:sid];[panel close];continue;}
            self.spacePanels[sid]=panel;
        }
        if(created || !panel.isVisible) {
            uint64_t activeBeforeOrder=ownCurrentActiveSpace();
            if(!activeBeforeOrder){[self.failedPlacements addObject:sid];[panel close];[self.spacePanels removeObjectForKey:sid];continue;}
            [panel orderFrontRegardless];
            NSDictionary *ordered=verifyOwnPanelAfterOrder(panel,sid.unsignedLongLongValue,activeBeforeOrder);self.placementReports[sid.stringValue]=ordered;
            if(![ordered[@"ok"] boolValue]){[self.failedPlacements addObject:sid];[panel close];[self.spacePanels removeObjectForKey:sid];}
        }
    }
    self.drawingSID=nil;
    // Complete new panels are assigned and ordered before retired own panels close.
    for(NSNumber *sid in self.spacePanels.allKeys)if(![catalog containsObject:sid]){[self.spacePanels[sid] close];[self.spacePanels removeObjectForKey:sid];}
}
- (void)writeStatus {
    NSString *path=self.settings[@"native_ui_status_path"]; if (!path) return;
    NSDictionary *panelStates=panelStatusBySID(self.state,self.spacePanels,self.placementReports,self.failedPlacements);NSNumber *activeSID=panelActiveSID(self.state);
    NSMutableDictionary *collectionFlags=[NSMutableDictionary new];for(NSNumber *sid in self.spacePanels)collectionFlags[sid.stringValue]=@(self.spacePanels[sid].collectionBehavior);
    NSDictionary *status=@{@"schema":@1,@"pid":@(getpid()),@"presentation":self.settings[@"presentation"],@"native_height":@(self.nativeHeight),@"status_bar_thickness":@(self.nativeStatusThickness),@"native_right_boundary":@(self.rightBoundary),@"compact_spacing":@(self.compactSpacing),@"focus_available":@([self.nativeFocus.focus[@"available"] boolValue]),@"native_focus_observing":@(self.nativeFocus.focusWatching),@"ax_trusted":@(AXIsProcessTrusted()),@"native_title_observing":@(self.nativeFocus.titleWatching),@"native_menu_bar_height":@(self.menuBarHeight),@"safe_area_top":@(self.safeTop),@"visible_top_inset":@(self.visibleTopInset),@"content_vertical_offset":@((self.menuBarHeight-self.nativeHeight)/2.0),@"menu_height_source":@"max(public-status-thickness,public-screen-safe-area,public-visible-top-inset)",@"width":@(self.actualWidth),@"panel_width":@(self.panelWidth),@"apple_edge":@(self.measuredAppleEdge),@"application_menu_edge":@(self.measuredAppMenuEdge),@"application_menus_visually_covered":@([self.settings[@"presentation"] isEqual:@"left-replacement"]),@"native_menu_semantic_suppression":@(leaseTrue(self.appMenuClient.snapshot[@"suppressed"])&&B15SameBirth(frontIdentity(),self.appMenuClient.snapshot[@"identity"])),@"b15_menu_headings":@([self.appMenuClient.snapshot[@"headings"] count]),@"b15_menu_reason":self.appMenuClient.reason?:@"disabled",@"b15_headings_expanded":@(self.appHeadingsExpanded),@"suppression_qualification_expires":@(self.suppressionLeaseExpiry),@"transparent_row":@([self transparentRow]),@"anchor_source":self.anchorSource?:@"pending",@"total_spaces":@([self.state[@"spaces"] count]),@"source_available":@([self.state[@"available"] boolValue]&&!self.sourceFailure),@"display_available":@([self.state[@"available"] boolValue]&&!self.sourceFailure&&!self.localReason&&(![self perSpaceMode]||panelActiveReady(self.state,panelStates))),@"retained":@([self.state[@"spaces"] count]>0&&(![self.state[@"available"] boolValue]||self.sourceFailure!=nil)),@"reason":self.sourceFailure?:self.localReason?:self.state[@"reason"]?:@"bootstrap-pending",@"workspace_clicks_enabled":@([self.state[@"click_enabled"] boolValue]),@"last_workspace_action":self.lastWorkspaceAction?:@{},@"wm_state_polling":@NO,@"own_space_placements":self.placementReports?:@{},@"own_panel_count":@(self.spacePanels.count),@"active_catalog_sid":activeSID?:NSNull.null,@"active_panel_ready":@(panelActiveReady(self.state,panelStates)),@"own_panels_by_sid":panelStates,@"own_panel_collection_flags":collectionFlags,@"display_evidence":@"owned-placement+public-NSWindow-flags;not-pixel-proof",@"native_gesture_motion_qualified":@NO};
    NSMutableDictionary *reported=[status mutableCopy],*selections=[NSMutableDictionary new];
    for(NSDictionary *row in self.state[@"spaces"]){NSDictionary *focus=spaceDisplayFocus(row,self.nativeFocus.focus,[self.state[@"available"] boolValue]&&!self.sourceFailure);selections[[row[@"sid"] stringValue]]=@{@"available":@([focus[@"available"] boolValue]),@"wid":focus[@"wid"]?:NSNull.null,@"pid":focus[@"pid"]?:NSNull.null,@"source":focus[@"source"]?:@"native-focus-or-empty"};}
    reported[@"selected_windows_by_sid"]=selections;
    QuietPanel *activePanel=activeSID?self.spacePanels[activeSID]:self.panel;
    reported[@"viewport"]=activePanel.viewportWindow?:@{};reported[@"pan_pending"]=@(self.panRequestID!=nil);reported[@"last_pan_action"]=self.lastPanAction?:@{};
    NSMutableDictionary *glyphs=[NSMutableDictionary new],*updates=[NSMutableDictionary new];
    for(NSDictionary *row in self.state[@"spaces"]){NSMutableArray *items=[NSMutableArray new];for(NSDictionary *app in row[@"apps"])[items addObject:@{@"wid":app[@"wid"],@"pid":app[@"pid"],@"glyph":appGlyphIdentity(app)}];glyphs[[row[@"sid"] stringValue]]=items;}
    for(NSNumber *sid in self.spacePanels){NSView *row=self.spacePanels[sid].contentView.subviews.firstObject;if([row isKindOfClass:WorkspaceRowView.class])updates[sid.stringValue]=@{ @"changed_elements":@([(WorkspaceRowView*)row changedElements]),@"retained_elements":@([[(WorkspaceRowView*)row elements] count]),@"changed_glyphs":@([(WorkspaceRowView*)row changedGlyphs])};}
    reported[@"app_glyphs_by_sid"]=glyphs;reported[@"incremental_rows_by_sid"]=updates;reported[@"app_glyph_source"]=@"sketchybar-app-font-3.0.11+custom-svg";
    NSData *data=[NSJSONSerialization dataWithJSONObject:reported options:NSJSONWritingPrettyPrinted error:nil]; [data writeToFile:path options:NSDataWritingAtomic error:nil];
}
- (void)queueState:(NSDictionary *)state {
    @synchronized(self){if(!self.pendingState||[state[@"revision"] unsignedLongLongValue]>[self.pendingState[@"revision"] unsignedLongLongValue])self.pendingState=state;if(self.stateApplyScheduled)return;self.stateApplyScheduled=YES;}
    dispatch_async(dispatch_get_main_queue(),^{NSDictionary *latest=nil;@synchronized(self){latest=self.pendingState;self.pendingState=nil;self.stateApplyScheduled=NO;}
        if(latest&&(!self.state||[latest[@"revision"] unsignedLongLongValue]>[self.state[@"revision"] unsignedLongLongValue])){panelRetryTransientFailures(self.failedPlacements,self.placementReports,self.state,latest);self.state=latest;self.sourceFailure=self.bridge&&!self.bridge.running?@"bridge-not-running":nil;self.localReason=nil;[self refreshAnchor];[self layout];}
    });
}
- (void)acceptData:(NSData *)data {
    if (!data.length) { dispatch_async(dispatch_get_main_queue(),^{ if (!self.terminating) {self.sourceFailure=@"bridge-output-eof";[self layout];} }); return; }
    [self.pending appendData:data]; if (self.pending.length>2*1024*1024) { [self.pending setLength:0]; dispatch_async(dispatch_get_main_queue(),^{self.sourceFailure=@"bridge-output-overflow";[self layout];}); return; }
    while (YES) { const unsigned char *bytes=self.pending.bytes; NSUInteger length=self.pending.length,index=0; while(index<length&&bytes[index]!='\n')index++; if(index==length)break;
        NSData *line=[self.pending subdataWithRange:NSMakeRange(0,index)]; [self.pending replaceBytesInRange:NSMakeRange(0,index+1) withBytes:NULL length:0];
        id state=[NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if([state isKindOfClass:NSDictionary.class]&&[state[@"kind"] isEqual:@"action"]){dispatch_async(dispatch_get_main_queue(),^{
            if([state[@"action"] isEqual:@"pan"]){
                if(![state[@"request_id"] isEqual:self.panRequestID])return;
                self.lastPanAction=state;
                if(!(leaseTrue(state[@"queued"])&&!leaseTrue(state[@"acknowledged"])&&[state[@"reason"] isEqual:@"queued"])) {self.panRequestID=nil;self.panSubmittedViewport=nil;[self layout];}
            }else self.lastWorkspaceAction=state;
            [self writeStatus];
        });continue;}
        if(!validState(state)) {dispatch_async(dispatch_get_main_queue(),^{self.sourceFailure=@"invalid-bridge-state";[self layout];});continue;}
        [self queueState:state];
    }
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; self.parserQueue=dispatch_queue_create("dev.hyprwm.style.native-bar.parser",DISPATCH_QUEUE_SERIAL); self.pending=[NSMutableData data];self.spacePanels=[NSMutableDictionary dictionary];self.placementReports=[NSMutableDictionary dictionary];self.failedPlacements=[NSMutableSet set];
    if ([self.settings[@"presentation"] isEqual:@"native-extras"]) { self.item=[NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength]; self.item.autosaveName=CompanionID; }
    else if ([self transparentRow] && ![self perSpaceMode]) { self.panel=[self newOwnedPanel];self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle; }
    else if ([@[@"left-panel",@"left-replacement"] containsObject:self.settings[@"presentation"]]) { self.panel=[[QuietPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO]; self.panel.opaque=NO;self.panel.backgroundColor=NSColor.clearColor;self.panel.hasShadow=NO;self.panel.level=NSMainMenuWindowLevel+1;self.panel.hidesOnDeactivate=NO;self.panel.collectionBehavior=NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorIgnoresCycle;
        NSVisualEffectView *material=[[NSVisualEffectView alloc] initWithFrame:NSZeroRect];material.material=NSVisualEffectMaterialMenu;material.blendingMode=NSVisualEffectBlendingModeBehindWindow;material.state=NSVisualEffectStateActive;material.wantsLayer=YES;material.layer.cornerRadius=5;material.layer.masksToBounds=YES; self.panel.contentView=material;
        self.panelButton=[NSButton buttonWithTitle:@"" target:self action:@selector(showMenu:)];self.panelButton.bordered=NO;self.panelButton.imagePosition=NSImageOnly;self.panelButton.imageScaling=NSImageScaleNone;self.panelButton.focusRingType=NSFocusRingTypeNone;[material addSubview:self.panelButton];
    }
    self.appMenuClient=[B15AppMenuClient new];self.appMenuClient.settings=self.settings;__weak Companion *menuOwner=self;self.appMenuClient.changed=^{[menuOwner applicationMenuStateChanged];};[self.appMenuClient refresh:frontIdentity()];
    self.nativeFocus=[NativeFocusMonitor new];__weak Companion *focusOwner=self;self.nativeFocus.changed=^{[focusOwner.appMenuClient refresh:frontIdentity()];[focusOwner refreshAnchor];[focusOwner layout];};[self.nativeFocus refresh];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(environmentChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(environmentChanged:) name:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(environmentChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil]; [self refreshAnchor];[self layout];
    self.bridge=[NSTask new];self.bridge.executableURL=[NSURL fileURLWithPath:self.settings[@"python_executable"]];self.bridge.arguments=@[self.settings[@"bridge_script"],@"--settings",self.settingsPath];self.bridgeOutput=[NSPipe pipe];self.bridgeInput=[NSPipe pipe];self.bridge.standardOutput=self.bridgeOutput;self.bridge.standardInput=self.bridgeInput;self.bridge.standardError=NSFileHandle.fileHandleWithStandardError;
    __weak Companion *weakSelf=self;
    self.bridgeOutput.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle){ NSData *data=handle.availableData;if(!data.length)handle.readabilityHandler=nil;dispatch_async(weakSelf.parserQueue,^{[weakSelf acceptData:data];});};
    self.bridge.terminationHandler=^(NSTask *task){dispatch_async(dispatch_get_main_queue(),^{Companion *strong=weakSelf;if(strong&&!strong.terminating){strong.sourceFailure=@"bridge-exited";[strong layout];}});};
    NSError *error=nil;if(![self.bridge launchAndReturnError:&error]){self.sourceFailure=@"bridge-launch-failed";[self layout];}
}
- (void)environmentChanged:(NSNotification *)note {
    B15BarTrace(@"environment-changed note=%@ front_pid=%d close_predicate=environment_notification expanded=%d epoch=%@",note.name,NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier,self.appHeadingsExpanded,B15TraceEpoch(self.appMenuClient.snapshot[@"epoch"]));
    self.appHeadingsExpanded=NO;[self.appHeadingsPanel orderOut:nil];[self.appMenuClient refresh:frontIdentity()];
    [self refreshAnchor];[self.nativeFocus refresh];[self layout];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender { self.terminating=YES;[self.appMenuClient close];[self.appHeadingsPanel close];[self.nativeFocus close];self.bridgeOutput.fileHandleForReading.readabilityHandler=nil;[self.bridgeInput.fileHandleForWriting closeFile];if(self.bridge.running)[self.bridge terminate];return NSTerminateNow; }
@end
static NSDictionary *fixture(void) { return @{@"schema":@1,@"kind":@"state",@"revision":@1,@"available":@YES,@"retained":@NO,@"status":@"available",@"reason":@"",@"click_enabled":@NO,@"spaces":@[@{@"sid":@91,@"ordinal":@1,@"type":@0,@"active":@YES,@"apps_verified":@YES,@"apps":@[@{@"bundle":@"com.mitchellh.ghostty",@"name":@"Ghostty",@"key":@"wid:101",@"wid":@101,@"pid":@201}]}]}; }
static int selfTest(void) {
    NSUInteger passed=0;
#define CHECK(x) do { if(!(x)){fprintf(stderr,"self-test failure line %d\n",__LINE__);return 1;}passed++;}while(0)
    CHECK([appGlyphBaseName(@"  GHOSTTY Helper (Renderer) Beta  ") isEqual:@"ghostty"]);
    CHECK([appGlyphNormalize(@"App\u00a0Store") isEqual:@"app store"]);
    CHECK([nativeFocusText(@"Telegram",@"Telegram @ kyle butler") isEqual:@"Telegram @ kyle butler"]);
    CHECK([nativeFocusText(@"Zen",@"Article") isEqual:@"Zen  Article"]);
    CHECK(appGlyphNeedsParent(@"com.apple.WebKit.WebContent",@"WebContent"));
    CHECK(validState(fixture())); NSMutableDictionary *bad=[fixture() mutableCopy];bad[@"click_enabled"]=@YES;CHECK(validState(bad));bad[@"available"]=@NO;CHECK(!validState(bad));bad=[fixture() mutableCopy];bad[@"spaces"]=@[[fixture()[@"spaces"] firstObject],[fixture()[@"spaces"] firstObject]];CHECK(!validState(bad));
    bad=[fixture() mutableCopy];NSMutableDictionary *row=[bad[@"spaces"][0] mutableCopy];row[@"apps_verified"]=@NO;bad[@"spaces"]=@[row];CHECK(!validState(bad));
    bad=[fixture() mutableCopy];bad[@"revision"]=@(-1);CHECK(!validState(bad));
    NSDictionary *menuIdentity=@{@"pid":@42,@"uid":@501,@"birth_sec":@100,@"birth_usec":@1,@"executable":@"/own/fixture",@"main_uuid":@"owned-main"};
    NSDictionary *menuBinding=@{@"identity":menuIdentity,@"module_uuid":@"AB-CD"};
    NSDictionary *nativeMenu=@{@"schema":@1,@"version":@7,@"ok":@YES,@"identity":menuIdentity,@"module_uuid":@"abcd",@"epoch":@1,@"headings":@[@{@"id":[@"a" stringByPaddingToLength:64 withString:@"a" startingAtIndex:0],@"title":@"Original File",@"enabled":@YES}],@"suppressed":@YES,@"enabled":@YES,@"current_menu_matches":@YES,@"active":@YES,@"hook_owned":@YES,@"original_items_unchanged":@YES,@"apple_preserved":@YES,@"apple_frame":@[@10,@923,@34,@33]};
    NSDictionary *headingModel=b15HeadingModel(nativeMenu,24);NSMutableDictionary *menuRefresh=[nativeMenu mutableCopy];
    NSMutableDictionary *headingRefresh=[nativeMenu[@"headings"][0] mutableCopy];headingRefresh[@"title"]=@"Renamed original";headingRefresh[@"enabled"]=@NO;menuRefresh[@"headings"]=@[headingRefresh];menuRefresh[@"popup_pending"]=@YES;menuRefresh[@"callbacks"]=@100;
    CHECK([headingModel isEqual:b15HeadingModel(menuRefresh,24)]); // Status and validation changes preserve control identity.
    CHECK(![headingModel isEqual:b15HeadingModel(nativeMenu,25)]);
    menuRefresh[@"epoch"]=@2;CHECK(![headingModel isEqual:b15HeadingModel(menuRefresh,24)]);menuRefresh[@"epoch"]=@1;
    NSMutableDictionary *newBirth=[menuIdentity mutableCopy];newBirth[@"birth_usec"]=@2;menuRefresh[@"identity"]=newBirth;CHECK(![headingModel isEqual:b15HeadingModel(menuRefresh,24)]);menuRefresh[@"identity"]=menuIdentity;
    headingRefresh[@"id"]=[@"b" stringByPaddingToLength:64 withString:@"b" startingAtIndex:0];CHECK(![headingModel isEqual:b15HeadingModel(menuRefresh,24)]);
    menuRefresh[@"headings"]=@[nativeMenu[@"headings"][0],headingRefresh];NSDictionary *twoHeadingModel=b15HeadingModel(menuRefresh,24);CHECK(![headingModel isEqual:twoHeadingModel]);menuRefresh[@"headings"]=@[headingRefresh,nativeMenu[@"headings"][0]];CHECK(![twoHeadingModel isEqual:b15HeadingModel(menuRefresh,24)]);
    B15AnchorChoice absent=b15AnchorChoice(NO,44,YES,343,NSMakeRect(0,0,1470,956),NO);CHECK(absent.available&&!absent.native&&absent.edge==343);
    B15AnchorChoice present=b15AnchorChoice(YES,44,YES,343,NSMakeRect(0,0,1470,956),NO);CHECK(present.available&&present.native&&present.edge==44);
    B15AnchorChoice malformed=b15AnchorChoice(YES,NAN,YES,343,NSMakeRect(0,0,1470,956),NO);CHECK(malformed.available&&!malformed.native&&malformed.edge==343);
    CHECK(!b15AnchorChoice(NO,44,NO,343,NSMakeRect(0,0,1470,956),NO).available);
    CHECK(!b15AnchorChoice(NO,44,YES,612,NSMakeRect(0,0,1470,956),YES).available);
    CHECK(b15AnchorChoice(YES,44,YES,612,NSMakeRect(0,0,1470,956),YES).native);
    NSMutableDictionary *inactiveOwner=[nativeMenu mutableCopy];inactiveOwner[@"active"]=@NO;inactiveOwner[@"suppressed"]=@NO;inactiveOwner[@"failsafe"]=@NO;inactiveOwner[@"error"]=@"";
    CHECK(b15AnchorPending(YES,NO,menuIdentity,newBirth,nativeMenu));
    CHECK(b15AnchorPending(YES,YES,menuIdentity,menuIdentity,nil));
    CHECK(b15AnchorPending(YES,NO,menuIdentity,menuIdentity,inactiveOwner));
    CHECK(!b15AnchorPending(NO,YES,menuIdentity,newBirth,inactiveOwner));
    CHECK(!b15AnchorPending(YES,NO,menuIdentity,menuIdentity,nativeMenu));
    inactiveOwner[@"enabled"]=@NO;CHECK(!b15AnchorPending(YES,NO,menuIdentity,menuIdentity,inactiveOwner));inactiveOwner[@"enabled"]=@YES;
    inactiveOwner[@"failsafe"]=@YES;CHECK(!b15AnchorPending(YES,NO,menuIdentity,menuIdentity,inactiveOwner));inactiveOwner[@"failsafe"]=@NO;
    inactiveOwner[@"error"]=@"native-refusal";CHECK(!b15AnchorPending(YES,NO,menuIdentity,menuIdentity,inactiveOwner));
    uint64_t pacHandle=(1ULL<<54)+17;
    NSData *handleJSON=[NSJSONSerialization dataWithJSONObject:@{@"handle":@(pacHandle),@"maximum":@(UINT64_MAX)} options:0 error:NULL];
    NSDictionary *handleRoundTrip=handleJSON?[NSJSONSerialization JSONObjectWithData:handleJSON options:0 error:NULL]:nil;
    CHECK(B15RetainedHandle(handleRoundTrip[@"handle"]));CHECK([handleRoundTrip[@"handle"] unsignedLongLongValue]==pacHandle);CHECK(!panelInteger(handleRoundTrip[@"handle"],YES));
    CHECK(B15RetainedHandle(handleRoundTrip[@"maximum"]));CHECK([handleRoundTrip[@"maximum"] unsignedLongLongValue]==UINT64_MAX);CHECK(B15RetainedHandle(@1));
    CHECK(!B15RetainedHandle(nil));CHECK(!B15RetainedHandle(NSNull.null));CHECK(!B15RetainedHandle(@YES));CHECK(!B15RetainedHandle(@NO));CHECK(!B15RetainedHandle(@0));CHECK(!B15RetainedHandle(@(-1)));
    CHECK(!B15RetainedHandle(@1.0));CHECK(!B15RetainedHandle(@1.5));CHECK(!B15RetainedHandle(@(NAN)));CHECK(!B15RetainedHandle(@(INFINITY)));CHECK(!B15RetainedHandle(@"18014398509482001"));
    CHECK(B15SnapshotValid(nativeMenu,menuBinding));NSMutableDictionary *badMenu=[nativeMenu mutableCopy];badMenu[@"module_uuid"]=@"foreign";CHECK(!B15SnapshotValid(badMenu,menuBinding));badMenu=[nativeMenu mutableCopy];badMenu[@"hook_owned"]=@NO;CHECK(!B15SnapshotValid(badMenu,menuBinding));badMenu=[nativeMenu mutableCopy];badMenu[@"epoch"]=@0;CHECK(!B15SnapshotValid(badMenu,menuBinding));badMenu=[nativeMenu mutableCopy];badMenu[@"headings"]=@[nativeMenu[@"headings"][0],nativeMenu[@"headings"][0]];CHECK(!B15SnapshotValid(badMenu,menuBinding));badMenu=[nativeMenu mutableCopy];badMenu[@"identity"]=@{@"pid":@42};CHECK(!B15SnapshotValid(badMenu,menuBinding));CHECK(!B15SameBirth(menuIdentity,@{@"pid":@42}));
    NSDictionary *row0=fixture()[@"spaces"][0];CHECK(capsuleWidth(row0,24,NO)==44);CHECK(capsuleWidth(row0,24,YES)==37);CHECK(ordinalSlotWidth(@"12")==18);CHECK(validAnchor(30,120,NSMakeRect(0,0,1470,956),26));CHECK(!validAnchor(20,120,NSMakeRect(0,0,1470,956),26));CHECK(!validAnchor(30,900,NSMakeRect(0,0,1470,956),26));CHECK(!validAnchor(NAN,120,NSMakeRect(0,0,1470,956),26));
    CHECK(ownPlacementPreflight(getpid(),12,12,91,[NSSet setWithObject:@91],YES,YES));CHECK(!ownPlacementPreflight(getpid()+1,12,12,91,[NSSet setWithObject:@91],YES,YES));CHECK(!ownPlacementPreflight(getpid(),12,13,91,[NSSet setWithObject:@91],YES,YES));CHECK(!ownPlacementPreflight(getpid(),12,12,92,[NSSet setWithObject:@91],YES,YES));CHECK(!ownPlacementPreflight(getpid(),12,12,91,[NSSet setWithObject:@91],NO,YES));CHECK(!ownPlacementPreflight(getpid(),12,12,91,[NSSet setWithObject:@91],YES,NO));
    CHECK(!ownActiveWitnessMatches(0,0));CHECK(!ownActiveWitnessMatches(91,0));CHECK(!ownActiveWitnessMatches(91,92));CHECK(ownActiveWitnessMatches(91,91));CHECK(validAnchor(640,60,NSMakeRect(0,0,1470,956),632));CHECK(!validAnchor(650,87,NSMakeRect(0,0,1470,956),642));
    CHECK(nativeMenuBarHeight(22,33,33)==33);CHECK(nativeMenuBarHeight(22,0,33)==33);CHECK(nativeMenuBarHeight(22,0,22)==22);CHECK(isnan(nativeMenuBarHeight(22,NAN,33)));CHECK((nativeMenuBarHeight(22,33,33)-22)/2.0==5.5);
    CHECK(replacementFits(28,430,87,NSMakeRect(0,0,1470,956)));CHECK(!replacementFits(28,70,87,NSMakeRect(0,0,1470,956)));CHECK(!replacementFits(28,900,87,NSMakeRect(0,0,1470,956)));CHECK(!replacementFits(NAN,430,87,NSMakeRect(0,0,1470,956)));CHECK(!replacementFits(28,430,0,NSMakeRect(0,0,1470,956)));
    NSDictionary *identity=@{@"pid":@123,@"uid":@501,@"birth_sec":@10,@"birth_usec":@20,@"executable":@"/fixture/app"};
    NSString *module=@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    NSMutableDictionary *lease=[@{@"schema":@1,@"kind":@"native-menu-suppression-qualification",@"module_sha256":module,@"identity":identity,@"enabled":@YES,@"current_menu_matches":@YES,@"apple_preserved":@YES,@"right_preserved":@YES,@"headings_hidden":@YES,@"detached":@YES,@"not_stopped_after_detach":@YES,@"qualified_at":@100,@"valid_until":@200} mutableCopy];
    CHECK(suppressionLeaseValid(lease,identity,module,150));CHECK(!suppressionLeaseValid(lease,identity,module,201));CHECK(!suppressionLeaseValid(lease,identity,@"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",150));
    lease[@"headings_hidden"]=@NO;CHECK(!suppressionLeaseValid(lease,identity,module,150));lease[@"headings_hidden"]=@YES;
    NSMutableDictionary *other=[identity mutableCopy];other[@"pid"]=@124;CHECK(!suppressionLeaseValid(lease,other,module,150));other=[identity mutableCopy];other[@"birth_usec"]=@21;CHECK(!suppressionLeaseValid(lease,other,module,150));
    lease[@"valid_until"]=@500;CHECK(!suppressionLeaseValid(lease,identity,module,150));lease[@"valid_until"]=@200;lease[@"current_menu_matches"]=@NO;CHECK(!suppressionLeaseValid(lease,identity,module,150));
    NSDictionary *own=@{(id)kCGWindowNumber:@27263,(id)kCGWindowOwnerPID:@(getpid())};NSDictionary *foreign=@{(id)kCGWindowNumber:@27263,(id)kCGWindowOwnerPID:@(getpid()+1)};
    CHECK(ownUniqueCGOwnerInRows(@[own],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[foreign],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[own,foreign],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[own,own],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[own],27264,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[own],0,getpid()));
    NSMutableArray *tooMany=[NSMutableArray array];for(NSUInteger i=0;i<8193;i++)[tooMany addObject:own];CHECK(!ownUniqueCGOwnerInRows(tooMany,27263,getpid()));
    CHECK(!ownUniqueCGOwnerInRows(@[@{(id)kCGWindowNumber:@27263.5,(id)kCGWindowOwnerPID:@(getpid())}],27263,getpid()));CHECK(!ownUniqueCGOwnerInRows(@[@{(id)kCGWindowNumber:@27263,(id)kCGWindowOwnerPID:@((double)getpid()+.5)}],27263,getpid()));
    CHECK(nativeRightBoundary(@[],NSMakeRect(0,0,1470,956),33,getpid())==705.6);
    NSDictionary *right=@{(id)kCGWindowOwnerPID:@(getpid()+1),(id)kCGWindowLayer:@25,(id)kCGWindowBounds:CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(1100,0,32,33)))};
    CHECK(nativeRightBoundary(@[right],NSMakeRect(0,0,1470,956),33,getpid())==1100);CHECK(nativeRightBoundary(@[right],NSMakeRect(0,0,1470,956),33,getpid()+1)==705.6);
    CHECK([privateFocusText(@"Private\nTitle",512) isEqual:@"Private Title"]);CHECK([privateFocusText(@"abcdef",3) isEqual:@"abc"]);
    CHECK(NSEqualRects(nativeGlyphAspectFit(NSMakeSize(24,12),NSMakeRect(10,5,16,16)),NSMakeRect(10,9,16,8)));CHECK(NSEqualRects(nativeGlyphAspectFit(NSMakeSize(12,24),NSMakeRect(10,5,16,16)),NSMakeRect(14,5,8,16)));CHECK(NSEqualRects(nativeGlyphAspectFit(NSMakeSize(16,16),NSMakeRect(10,5,16,16)),NSMakeRect(10,5,16,16)));CHECK(NSEqualRects(nativeGlyphAspectFit(NSMakeSize(0,12),NSMakeRect(10,5,16,16)),NSZeroRect));CHECK(NSEqualRects(nativeGlyphAspectFit(NSMakeSize(NAN,12),NSMakeRect(10,5,16,16)),NSZeroRect));
    NSMutableDictionary *twice=[fixture() mutableCopy];NSMutableDictionary *space=[twice[@"spaces"][0] mutableCopy];NSMutableDictionary *second=[space[@"apps"][0] mutableCopy];second[@"key"]=@"wid:102";second[@"wid"]=@102;space[@"apps"]=@[space[@"apps"][0],second];twice[@"spaces"]=@[space];CHECK(validState(twice));CHECK(capsuleWidth(space,24,NO)==64);second[@"wid"]=@101;CHECK(!validState(twice));

    NSMutableArray *many=[NSMutableArray array];
    for(NSUInteger i=0;i<7;i++){NSMutableDictionary *app=[row0[@"apps"][0] mutableCopy];app[@"wid"]=@(300+i);app[@"key"]=[NSString stringWithFormat:@"wid:%lu",300+i];[many addObject:app];}
    NSMutableDictionary *seven=[row0 mutableCopy];seven[@"apps"]=many;seven[@"window_count"]=@7;seven[@"windows_truncated"]=@NO;
    NSMutableDictionary *manyState=[fixture() mutableCopy];manyState[@"spaces"]=@[seven];CHECK(validState(manyState));
    NSArray *wide=nativeFitWindowRows(@[seven],24,NO,200);CHECK([wide[0][@"apps"] count]==7);CHECK(nativeWindowOverflow(wide[0]).length==0);
    NSArray *narrow=nativeFitWindowRows(@[seven],24,NO,70);CHECK(nativeRowsWidth(narrow,24,NO)<=70);CHECK([narrow[0][@"apps"] count]<7);CHECK(nativeWindowOverflow(narrow[0]).length>0);CHECK([seven[@"apps"] count]==7);
    NSDictionary *two=nativeVisibleWindowRow(seven,2);NSMutableDictionary *completeTwo=[two mutableCopy];completeTwo[@"window_count"]=@2;
    NSArray *tight=nativeFitWindowRows(@[completeTwo,completeTwo],24,NO,117);CHECK(nativeRowsWidth(tight,24,NO)<=117);CHECK([tight[0][@"apps"] count]+[tight[1][@"apps"] count]>=2);
    NSMutableDictionary *falseCount=[seven mutableCopy];falseCount[@"window_count"]=@3;manyState[@"spaces"]=@[falseCount];CHECK(!validState(manyState));
    NSMutableDictionary *placementRace=[@{@"ok":@NO,@"reason":@"active-space-changed-refused",@"native_call_completed":@YES,@"requested_sid":@91,@"own_pid":@(getpid()),@"own_wid":@12,@"active_before":@91,@"active_after":@92,@"foreign_window_acted_on":@NO,@"space_activation_api_called":@NO,@"after_membership":@[@91]} mutableCopy];
    CHECK(panelFailureWasOnlyActiveRace(placementRace,@91));
    [placementRace removeObjectForKey:@"native_call_completed"];CHECK(!panelFailureWasOnlyActiveRace(placementRace,@91));
    placementRace[@"native_call_completed"]=@1;CHECK(!panelFailureWasOnlyActiveRace(placementRace,@91));
    placementRace[@"native_call_completed"]=@NO;CHECK(!panelFailureWasOnlyActiveRace(placementRace,@91));
    placementRace[@"native_call_completed"]=@YES;placementRace[@"after_membership"]=@[@92];CHECK(!panelFailureWasOnlyActiveRace(placementRace,@91));
    placementRace[@"after_membership"]=@[@91];placementRace[@"active_after"]=@91;CHECK(!panelFailureWasOnlyActiveRace(placementRace,@91));
    NSArray *focusBirth=@[@201,@(getuid()),@1700000000,@1];
    NSMutableDictionary *focusApp=[fixture()[@"spaces"][0][@"apps"][0] mutableCopy];focusApp[@"process_birth"]=focusBirth;
    NSDictionary *spaceSelection=@{@"available":@YES,@"wid":@101,@"pid":@201,@"process_birth":focusBirth,@"app":@"Selected app",@"title":@"Selected title",@"source":@"wm-space-selection"};
    NSMutableDictionary *focusedSpace=[fixture()[@"spaces"][0] mutableCopy];focusedSpace[@"apps"]=@[focusApp];focusedSpace[@"selected_window"]=spaceSelection;
    NSMutableDictionary *focusedState=[fixture() mutableCopy];focusedState[@"spaces"]=@[focusedSpace];CHECK(validState(focusedState));
    NSDictionary *otherFocus=@{@"available":@YES,@"wid":@102,@"pid":@202,@"process_birth":@[@202,@(getuid()),@1700000000,@1],@"app":@"Other space",@"title":@"Other title"};
    CHECK([spaceDisplayFocus(focusedSpace,otherFocus,YES)[@"title"] isEqual:@"Selected title"]);
    CHECK([spaceDisplayFocus(focusedSpace,otherFocus,NO)[@"title"] isEqual:@"Selected title"]);
    NSMutableDictionary *actualFocus=[spaceSelection mutableCopy];actualFocus[@"title"]=@"Current native title";
    NSDictionary *selectionFront=@{@"pid":@201,@"uid":@(getuid()),@"birth_sec":@1700000000,@"birth_usec":@1};
    CHECK(b15MenuSelectionMatches(spaceSelection,actualFocus,selectionFront,@91,@91,91));
    CHECK(!b15MenuSelectionMatches(spaceSelection,otherFocus,selectionFront,@91,@91,91));
    CHECK(!b15MenuSelectionMatches(spaceSelection,actualFocus,selectionFront,@91,@92,91));
    CHECK(!b15MenuSelectionMatches(spaceSelection,actualFocus,selectionFront,@91,@91,92));
    CHECK(!b15MenuSelectionMatches(spaceSelection,actualFocus,selectionFront,nil,@91,91));
    CHECK(!b15MenuSelectionMatches(spaceSelection,actualFocus,@{},@91,@91,91));
    NSMutableDictionary *staleSelection=[spaceSelection mutableCopy];staleSelection[@"available"]=@NO;
    CHECK(!b15MenuSelectionMatches(staleSelection,actualFocus,selectionFront,@91,@91,91));
    CHECK(!b15MenuSelectionMatches(spaceSelection,@{@"available":@NO},selectionFront,@91,@91,91));
    CHECK(b15MenuSelectionMatches(spaceSelection,spaceSelection,selectionFront,@91,@91,91));
    staleSelection=[spaceSelection mutableCopy];staleSelection[@"wid"]=@102;
    CHECK(!b15MenuSelectionMatches(staleSelection,actualFocus,selectionFront,@91,@91,91));
    staleSelection=[spaceSelection mutableCopy];staleSelection[@"process_birth"]=@[@201,@(getuid()),@1700000001,@1];
    CHECK(!b15MenuSelectionMatches(staleSelection,actualFocus,selectionFront,@91,@91,91));
    CHECK([spaceDisplayFocus(focusedSpace,actualFocus,YES)[@"title"] isEqual:@"Current native title"]);
    actualFocus[@"process_birth"]=@[@201,@(getuid()),@1700000001,@1];CHECK([spaceDisplayFocus(focusedSpace,actualFocus,YES)[@"title"] isEqual:@"Selected title"]);
    NSMutableDictionary *invalidSelection=[spaceSelection mutableCopy];invalidSelection[@"wid"]=@102;focusedSpace[@"selected_window"]=invalidSelection;CHECK(!validState(focusedState));
    focusedSpace[@"selected_window"]=spaceSelection;focusApp[@"process_birth"]=@[@201,@(getuid()),@YES,@1];CHECK(!validState(focusedState));focusApp[@"process_birth"]=focusBirth;
    focusedSpace[@"apps"]=@[];focusedSpace[@"selected_window"]=@{@"available":@NO,@"app":@"",@"title":@""};
    CHECK([spaceDisplayFocus(focusedSpace,otherFocus,YES)[@"app"] isEqual:@"Нет окон"]);
    CHECK(![spaceDisplayFocus(focusedSpace,otherFocus,NO)[@"available"] boolValue]);
    fprintf(stdout,"native pure fixtures: %lu PASS (no NSApplication/AX/GUI)\n",(unsigned long)passed);return 0;
}
static int rowViewTest(void) {
    NSUInteger passed=0;
    WorkspaceRowView *retainedRow=[[WorkspaceRowView alloc] initWithFrame:NSMakeRect(0,0,80,24)];
    NSImage *glyphA=[[NSImage alloc] initWithSize:NSMakeSize(16,16)],*titleA=[[NSImage alloc] initWithSize:NSMakeSize(20,16)],*titleB=[[NSImage alloc] initWithSize:NSMakeSize(20,16)];
    NSDictionary *glyphSegment=nativeRowSegment(@"glyph:1:101",glyphA,NSMakeRect(0,0,16,16));
    [retainedRow applySegments:@[glyphSegment,nativeRowSegment(@"title",titleA,NSMakeRect(20,0,20,16))]];
    NSImageView *retainedGlyph=retainedRow.elements[@"glyph:1:101"];NSUInteger beforeChanges=retainedRow.changedElements;
    [retainedRow applySegments:@[glyphSegment,nativeRowSegment(@"title",titleB,NSMakeRect(20,0,20,16))]];
    CHECK(retainedRow.elements[@"glyph:1:101"]==retainedGlyph&&retainedGlyph.image==glyphA);
    CHECK(retainedRow.changedElements==beforeChanges+1);
    beforeChanges=retainedRow.changedElements;[retainedRow applySegments:@[glyphSegment,nativeRowSegment(@"title",titleB,NSMakeRect(20,0,20,16))]];
    CHECK(retainedRow.changedElements==beforeChanges);CHECK(NSApp.windows.count==0);
    printf("retained row elements: %lu PASS, native windows=%lu\n",(unsigned long)passed,(unsigned long)NSApp.windows.count);return 0;
}
static int ownedWindowProbe(const char *rawSID) {
    char *end=NULL;uint64_t sid=strtoull(rawSID,&end,10);if(!rawSID[0]||!end||*end||sid==0||sid>=(1ULL<<53))return 2;
    void *image=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL);OwnMainConnection connection=image?(OwnMainConnection)dlsym(image,"SLSMainConnectionID"):NULL;OwnActiveSpace active=image?(OwnActiveSpace)dlsym(image,"SLSGetActiveSpace"):NULL;
    if(!connection||!active||active(connection())!=sid){if(image)dlclose(image);fprintf(stderr,"probe refuses target other than exact current active SID\n");return 2;}dlclose(image);
    NSApplication *app=NSApplication.sharedApplication;[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    QuietPanel *panel=[[QuietPanel alloc] initWithContentRect:NSMakeRect(0,0,1,1) styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];panel.releasedWhenClosed=NO;panel.collectionBehavior=NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
    if(ownCurrentActiveSpace()!=sid){[panel close];fprintf(stderr,"probe active SID changed before own placement\n");return 2;}
    // Never ordered, activated or made key. Only this new own window reaches the typed API.
    NSDictionary *result=placeOwnPanelWithScope(panel,sid,[NSSet setWithObject:@(sid)],YES,YES);NSData *data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);[panel close];return [result[@"ok"] boolValue]?0:1;
}
int main(int argc,const char **argv) { @autoreleasepool {
    if(argc==2&&!strcmp(argv[1],"--self-test"))return selfTest();
    if(argc==2&&!strcmp(argv[1],"--row-view-test"))return rowViewTest();
    if(argc==3&&!strcmp(argv[1],"--glyph-test")){
        if(!appGlyphLoad(@(argv[2])))return 4;
        for(NSString *key in appGlyphPoints){CGPathRef path=CTFontCreatePathForGlyph(appGlyphFont,[appGlyphPoints[key] unsignedShortValue],NULL);if(!path||CGPathIsEmpty(path))return 5;CGPathRelease(path);}
        if(![appGlyphMatch(@"APP.ZEN-BROWSER.ZEN",@"ignored") isEqual:@":zen_browser:"]||![appGlyphMatch(@"",@"Ghostty Helper (Renderer) Beta") isEqual:@":ghostty:"]||![appGlyphMatch(@"",@"App\u00a0Store") isEqual:@":app_store:"]||![appGlyphIdentity(@{@"bundle":@"unknown.vendor.app",@"name":@"Completely Unknown"}) isEqual:@":default:"])return 6;
        for(NSString *key in appGlyphCustom){NSImage *image=appGlyphImage(key,24,NSColor.whiteColor);if(![image CGImageForProposedRect:NULL context:nil hints:nil])return 7;}
        printf("glyphs: %lu outlines + %lu SVG + normalized identities PASS; NSApp=%s\n",(unsigned long)appGlyphPoints.count,(unsigned long)appGlyphCustom.count,NSApp?"created":"nil");return 0;
    }
    if(argc==3&&!strcmp(argv[1],"--owned-window-probe"))return ownedWindowProbe(argv[2]);
    if(argc!=3||strcmp(argv[1],"--settings")){fprintf(stderr,"usage: NativeWorkspaceCompanion --settings /absolute/settings.json\n");return 2;}
    NSString *path=[NSString stringWithUTF8String:argv[2]];NSData *data=[NSData dataWithContentsOfFile:path];if(!path.isAbsolutePath||!data||data.length>65536)return 2;
    NSDictionary *settings=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];if(![settings isKindOfClass:NSDictionary.class]||![settings[@"schema"] isEqual:@1]||![@[@"native-extras",@"left-panel",@"left-replacement",@"left-transparent",@"left-inline",@"left-per-space-panels"] containsObject:settings[@"presentation"]])return 2;
    for(NSString *key in @[@"python_executable",@"bridge_script"]){if(![settings[key] isKindOfClass:NSString.class]||![settings[key] isAbsolutePath])return 2;}
    NSString *status=settings[@"native_ui_status_path"];if(status&&(![status isKindOfClass:NSString.class]||!status.isAbsolutePath||![status.lastPathComponent isEqual:@"ui-status.json"]||![status.stringByDeletingLastPathComponent.lastPathComponent isEqual:@"hyprwm-native-companion"]))return 2;
    if(!appGlyphLoad([NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"app-glyphs"])) {fprintf(stderr,"app glyph resources unavailable\n");return 4;}
    Companion *delegate=[Companion new];delegate.settings=settings;delegate.settingsPath=path;NSApplication *app=CompanionApplication.sharedApplication;app.delegate=delegate;[app run];return 0;
} }
