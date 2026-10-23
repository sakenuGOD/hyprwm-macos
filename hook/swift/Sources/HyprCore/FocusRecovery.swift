import Foundation

public enum NativeFocusFlags {
    public static let menu=1,modal=2,unknown=4,child=8,fullscreen=16,noKey=32
    public static let positive=menu|modal|child|fullscreen
}
public enum FocusReason:String {case keyboard,pointer,close,space}
public struct FocusCoverStamp:Equatable {
    public let wid,pid,epoch,space:Int
    public let birth:String
    public let deadline:Double
    public init(wid:Int,pid:Int,epoch:Int,space:Int,birth:String,deadline:Double) {self.wid=wid;self.pid=pid;self.epoch=epoch;self.space=space;self.birth=birth;self.deadline=deadline}
}
public struct FocusRequest {
    public let pid,wid,space:Int
    public let birth:String
    public let sourcePID:Int?
    public let reason:FocusReason
    public let deadline:Double
    public let pointer:(Double,Double)?
    public init(pid:Int,wid:Int,space:Int,birth:String,sourcePID:Int?,reason:FocusReason,deadline:Double,pointer:(Double,Double)?=nil) {
        self.pid=pid;self.wid=wid;self.space=space;self.birth=birth;self.sourcePID=sourcePID;self.reason=reason;self.deadline=deadline;self.pointer=pointer
    }
    /// A queued focus request must not replace a newer foreground choice,
    /// including a transition from no front application to a real one.
    public func sourceMatches(_ foregroundPID:Int?) -> Bool {sourcePID==foregroundPID}
    /// A background target app can own a modal even while another app is front.
    /// Focusing its primary must not bypass that app's current dialog/menu.
    public func targetAllows(_ context:(wid:Int?,flags:Int)) -> Bool {
        context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0
    }
    public func target(in snapshot:Snapshot,covered:Bool=false) -> WinInfo? {
        guard snapshot.stable,!snapshot.locked,snapshot.spaceType==0,snapshot.space==space else{return nil}
        return snapshot.windows.first{$0.wid==wid && $0.pid==pid && ($0.on || covered) && $0.space==space && $0.layer==0 && !$0.nativeFullscreen && ($0.alpha>=0.05 || covered)}
    }
    /// Pointer coordinates may change throughout a queued focus operation.
    /// The current native receiver, rather than its first pixel, owns intent.
    public func pointerAllows(_ point:(Double,Double),hint:(wid:Int,pid:Int?)?,snapshot:Snapshot,nativeBounds:Rect?) -> Bool {
        guard reason == .pointer else{return true}
        guard pointer != nil,point.0.isFinite,point.1.isFinite,let target=target(in:snapshot) else{return false}
        if let hint {return hint.wid==wid && hint.pid==pid}
        func contains(_ rect:Rect)->Bool {rect.arr.allSatisfy(\.isFinite) && rect.w>0 && rect.h>0 && point.0>=rect.x && point.0<rect.x+rect.w && point.1>=rect.y && point.1<rect.y+rect.h}
        // A real popup/notification is a barrier; never fall through it to a
        // tiled target. Unknown native hit data is accepted only with both
        // current bounds and the first visible census receiver in agreement.
        guard let nativeBounds,contains(nativeBounds),contains(target.rect),
              let front=snapshot.windows.first(where:{$0.on && $0.space==space && $0.alpha>=0.05 && contains($0.rect)}) else{return false}
        return front.wid==wid && front.pid==pid
    }
    public func sourceAllows(_ context:(wid:Int?,flags:Int),snapshot:Snapshot,sourcePrimary:Bool) -> Bool {
        guard context.flags&NativeFocusFlags.positive==0 else{return false}
        if context.wid==wid{return true}
        if let key=context.wid {
            guard context.flags&NativeFocusFlags.unknown==0,sourcePrimary else{return false}
            if reason == .keyboard{return true}
            // An explicit pointer intent can replace a still-visible primary
            // key. Absence is required only for automatic close/Space fallback.
            if reason == .pointer{return pointer != nil}
            return !snapshot.windows.contains{$0.wid==key&&$0.on&&$0.space==space&&$0.alpha>=0.05}
        }
        // Explicit NO_KEY32 is absence; UNKNOWN4 is not. A genuinely nil front
        // PID may still accept an explicit keyboard intent with two native censuses.
        if sourcePID==nil && reason == .keyboard{return true}
        return context.flags&NativeFocusFlags.unknown==0
    }
}
struct SpaceFocusRetry {
    let space:Int,started:Double,deadline:Double
    var fresh=0,queued=false,retryAt=0.0
}
extension WM {
    @discardableResult func queueFocus(_ window:WinInfo,space:Int,reason:FocusReason,pointer:(Double,Double)?=nil) -> Bool {
        guard enabled,!sys.sessionLocked(),!sys.interactionOverlay(),overviewFrozen?() != true,
              !nativeSuspendedSpaces.contains(String(space)),!sys.protectedProcess(window.pid),
              !hidden.contains(where:{$0.wid==window.wid}),!ignored(window),
              reason != .pointer || !windowPolicy(window).noPointerFocus,
              let birth=sys.processBirth(window.pid),sys.winPidLevel(window.wid).pid==window.pid else{return false}
        if reason == .pointer {
            let context=sys.focusContext(window.pid)
            // Known target modals stop here. A cold/unknown cache is resolved
            // by the worker's fresh target-app read, never treated as permission.
            guard context.flags&NativeFocusFlags.positive==0 else{return false}
        }
        if reason != .close {closeFocusRetry=nil} // Explicit newer intent supersedes automatic fallback.
        if reason != .pointer {pointerFocusRetryPoint=nil}
        if let pending=focusPending,pending.wid==window.wid,pending.pid==window.pid,pending.birth==birth,pending.space==space {
            if reason != .pointer || pending.reason == .pointer{return true}
            // One pointer ticket follows this native receiver across pixels.
            // Explicit pointer intent may replace an automatic fallback ticket.
        }
        focusSerial+=1;let sequence=focusSerial
        let deadline=reason == .close ? min(sys.now()+1,closeFocusRetry?.deadline ?? sys.now()+1):sys.now()+1
        let request=FocusRequest(pid:window.pid,wid:window.wid,space:space,birth:birth,sourcePID:sys.frontPid(),reason:reason,deadline:deadline,pointer:pointer)
        let sourceContext=reason == .pointer ? request.sourcePID.map(sys.focusContext):nil
        focusPending=request
        sys.requestFocus(request) {[weak self] accepted in
            guard let self,self.focusSerial==sequence else{return}
            self.focusPending=nil
            if var retry=self.spaceFocusRetry,retry.space==space {retry.queued=false;retry.retryAt=self.sys.now()+0.15;self.spaceFocusRetry=retry}
            if reason == .close,var retry=self.closeFocusRetry,retry.space==space {
                if accepted {self.closeFocusRetry=nil}
                else {retry.queued=false;retry.retryAt=self.sys.now()+0.1;self.closeFocusRetry=retry}
            }
            if reason == .pointer {
                self.pointerFocusRetryPoint=nil
                let point=self.sys.mouse()
                let snapshot=Snapshot(space:self.last?.space ?? space,stable:true,area:self.last?.area ?? window.rect,windows:self.last?.wins ?? [window])
                if !accepted,self.enabled,!self.windowPolicy(window).noPointerFocus,
                   request.pointerAllows(point,hint:self.sys.pointerHit(),snapshot:snapshot,nativeBounds:self.sys.winBounds(window.wid)),
                   self.sys.frontPid()==request.sourcePID,self.last?.space==nil || self.last?.space==space,
                   let source=request.sourcePID,let original=sourceContext {
                    let current=self.sys.focusContext(source)
                    if current.wid==original.wid,current.flags==original.flags {
                        self.pointerFocusRetryPoint=point;self.pointerFocusRetryAt=self.sys.now()+0.1
                    }
                }
            }
            guard accepted,self.enabled,(self.last==nil || self.last?.space==space),self.sys.processBirth(window.pid)==birth,
                  self.sys.winPidLevel(window.wid).pid==window.pid,self.overviewFrozen?() != true else{return}
            self.sp(space).focus=window.wid;self.fwant=window.wid;self.ft=self.sys.now();self.ownFocus=(window.pid,self.sys.now())
            self.refreshWindowOpacity(space,self.last?.wins ?? [window])
        }
        return true
    }
    public func cancelFocusRecovery() {focusSerial+=1;focusPending=nil;spaceFocusRetry=nil;closeFocusRetry=nil;pointerFocusRetryPoint=nil;pointerOverlayWasActive=false;pointerOverlayDismissPoint=nil;sys.cancelFocus()}
    func restoreSpaceFocus(_ snapshot:Snapshot) {
        guard var retry=spaceFocusRetry,retry.space==snapshot.space else{return}
        guard sys.now()<retry.deadline,launcherIntent==nil else{spaceFocusRetry=nil;return}
        retry.fresh+=1;spaceFocusRetry=retry
        guard retry.fresh>=2,sys.now()-retry.started>=0.08,!retry.queued,sys.now()>=retry.retryAt,
              !sys.mouseDown(),!sys.interactionOverlay(),!sys.sessionLocked(),snapshot.spaceType==0,
              cfg.raw["config"]?["general"]?["no_focus_fallback"]?.truthy != true else{return}
        let context:(wid:Int?,flags:Int)=sys.frontPid().map(sys.focusContext) ?? (nil,NativeFocusFlags.noKey)
        guard context.flags&(NativeFocusFlags.positive|NativeFocusFlags.unknown)==0 else{return}
        let hiddenIDs=Set(hidden.map(\.wid)),state=sp(snapshot.space)
        let here=snapshot.windows.filter{$0.space==snapshot.space && $0.on && $0.layer==0 && !$0.nativeFullscreen && $0.alpha>=0.05 && !hiddenIDs.contains($0.wid)}
        if let key=context.wid,here.contains(where:{$0.wid==key}) {spaceFocusRetry=nil;return}
        let candidates=here.filter{state.tree?.contains($0.wid)==true && tileable($0) && !ignored($0)}
        let target=candidates.first{$0.wid==state.focus} ?? focusHistory.reversed().compactMap{wid in candidates.first{$0.wid==wid}}.first ?? candidates.sorted{$0.wid<$1.wid}.first
        guard let target else{return}
        if queueFocus(target,space:snapshot.space,reason:.space){retry.queued=true;spaceFocusRetry=retry}
    }
}
