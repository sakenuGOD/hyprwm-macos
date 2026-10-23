import CAX
import Foundation
import HyprCore
import CoreGraphics

/// Independent of Dock's waiting main-thread service. AppKit presentation remains
/// transparent until Native13 validates the exact prepared frame and changes alpha.
final class OverviewEntryBarrier {
    private let sys:LiveSys
    private weak var overview:OverviewBridge?
    private weak var wm:WM?
    private let worker:OrdinaryOverviewScene
    private var acknowledged:UInt64=0
    private var nonce=""
    private let lock=NSLock()
    private var busyValue=false
    private var phase="idle",error=""
    private var scene:([OrdinaryOverviewPose],UInt64,OverviewBinding)?
    private var prepared=false,failed=false,restoring=false
    private var preparationPending=false,geometryBusy=false
    private var restoreAttempts=0
    private var retryAfter=0.0
    // One bounded, sticky receipt survives timeout/cancel and successful rollback.
    private var lastEntry=JSON.object([])
    private var receiptChallenge:UInt64=0,receiptNonce=""
    private var receiptStarted=0.0
    init(sys:LiveSys,overview:OverviewBridge,wm:WM){self.sys=sys;self.overview=overview;self.wm=wm;worker=OrdinaryOverviewScene(sys:sys)
        overview.ordinarySceneBusy={ [weak self] in self?.busy ?? false }
        overview.ordinarySceneStatus={ [weak self] in self?.status ?? .object([]) }
    }
    var busy:Bool {lock.lock();defer{lock.unlock()};return busyValue}
    var status:JSON {lock.lock();defer{lock.unlock()};return .object([("busy",.bool(busyValue)),("phase",.string(phase)),("error",.string(error)),("last_entry",lastEntry)])}
    private func decision(_ reason:String,challenge:UInt64,binding:OverviewBinding,raw:UInt64,ready:Bool,worker:String?=nil) {
        let now=sys.now()
        if receiptChallenge != challenge || receiptNonce != binding.nonce {receiptChallenge=challenge;receiptNonce=binding.nonce;receiptStarted=now}
        let records=overview?.entryRecords ?? []
        var value=JSON.object([("challenge_hex",.string(String(challenge,radix:16))),("nonce",.string(binding.nonce)),("decision",.string(reason)),("raw_mode",.string(String(raw))),("ready",.bool(ready)),("ordinary_capability",.bool(binding.supportsOrdinaryPreentry)),("grant_count",.int(records.count)),("elapsed_ms",.double(max(0,now-receiptStarted)*1000))])
        if !ready,let refusal=wm?.overviewOwnershipRefusal {value=value.setting("ownership_refusal",.string(refusal))}
        if let worker {value=value.setting("worker",.string(worker))}
        lock.lock();lastEntry=value;lock.unlock()
    }
    private func setBusy(_ value:Bool,phase:String="idle",error:String=""){lock.lock();busyValue=value;self.phase=phase;self.error=error;lock.unlock()}
    private func restoreScene() {
        guard let scene,!restoring,!preparationPending,!geometryBusy,sys.now()>=retryAfter else{return}
        restoring=true;restoreAttempts+=1
        setBusy(true,phase:"restoring")
        let current=scene.0.filter{wm?.ordinaryOverviewIntentLive($0.source)==true}
        if current.isEmpty {
            self.scene=nil;prepared=false;failed=false;restoring=false;setBusy(false);return
        }
        if let wm,wm.ordinaryDockDeparted(pid:scene.2.pid,birth:scene.2.processBirth),
           !wm.ordinaryRollbackConcealed(current,dockPID:scene.2.pid,dockBirth:scene.2.processBirth) {
            restoring=false;setBusy(true,phase:"concealing-departed-dock");return
        }
        worker.restore(current,reconcile:reconcileGeometry){ [weak self] accepted,reason in
            guard let self else{return};self.restoring=false
            if !accepted {
                if self.restoreAttempts>=3 {self.retryAfter=self.sys.now()+0.25;self.setBusy(true,phase:"restore-refused",error:reason)}
                return
            }
            self.scene=nil;self.prepared=false;self.failed=false;self.setBusy(false)
        }
    }
    /// All channel publication and consume checks stay on the WM main queue.
    /// The background AX worker never touches the shared engine command ring.
    private func reconcileGeometry(_ poses:[OrdinaryOverviewPose],parked:Bool,completion:@escaping(Bool)->Void) {
        guard !geometryBusy,let wm,let scene,parked || scene.1 != acknowledged else{completion(false);return}
        geometryBusy=true
        let end=sys.now()+0.08,challenge=scene.1,binding=scene.2
        var started=false,released=false
        func step() {
            var current:UInt64=0
            let authority=parked || (hs_notify_state("hyprwm.overview11.request."+binding.nonce,&current)==0 && current==challenge && hs_overview10_mode()==1)
            let dockCurrent = !parked && self.sys.processBirth(binding.pid)==binding.processBirth
            let sourceCurrent=started || wm.ordinaryGeometryAuthority(poses,parked:parked,dockCurrent:dockCurrent)
            guard self.scene?.1==challenge,self.sys.now()<end,authority,(parked || dockCurrent),sourceCurrent else{self.geometryBusy=false;completion(false);return}
            if !started {started=wm.ordinaryGeometryStart(poses,parked:parked)}
            else if !released {released=wm.ordinaryGeometryRelease(poses,parked:parked)}
            else if wm.ordinaryGeometryConsumed(poses,parked:parked) {self.geometryBusy=false;completion(true);return}
            DispatchQueue.main.asyncAfter(deadline:.now()+0.002,execute:step)
        }
        step()
    }
    func acknowledge(ready:Bool) {
        let raw=hs_overview10_mode()
        if let scene {
            var current:UInt64=0
            let live=hs_notify_state("hyprwm.overview11.request."+scene.2.nonce,&current)==0 && current==scene.1 && sys.processBirth(scene.2.pid)==scene.2.processBirth
            if raw != 1 || failed || wm?.ordinaryDockDeparted(pid:scene.2.pid,birth:scene.2.processBirth)==true || (!live && acknowledged != scene.1){restoreScene();return}
            if prepared,ready,live,acknowledged != scene.1,
               wm?.ordinaryOverviewPoses(scene.0.map(\.source),display:display()) != nil,
               hs_notify_publish_state("hyprwm.overview11.ack."+scene.2.nonce,scene.1)==0 {acknowledged=scene.1;decision("acknowledged",challenge:scene.1,binding:scene.2,raw:raw,ready:ready)}
            else if !ready {decision("ownership-not-consumed",challenge:scene.1,binding:scene.2,raw:raw,ready:ready)}
            return
        }
        guard let binding=overview?.entryBinding,binding.supportsEntryBarrier else{
            if OverviewNativeMode.active(raw) {
                lock.lock();lastEntry = .object([("decision",.string("entry-binding-unavailable")),("raw_mode",.string(String(raw))),("ready",.bool(ready)),("challenge_observed",.bool(false))]);lock.unlock()
            }
            nonce="";acknowledged=0;return
        }
        if nonce != binding.nonce {nonce=binding.nonce;acknowledged=0}
        let request="hyprwm.overview11.request."+nonce,ack="hyprwm.overview11.ack."+nonce
        var challenge:UInt64=0
        guard hs_notify_state(request,&challenge)==0 else{return}
        if challenge==0 {acknowledged=0;return}
        guard challenge != acknowledged else{return}
        guard ready else{decision("ownership-not-consumed",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
        guard OverviewNativeMode.active(raw) else{decision("raw-mode-inactive",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
        guard sys.processBirth(binding.pid)==binding.processBirth else{decision("dock-birth-changed",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
        if wm?.options.overviewHiddenWindows != true {
            guard overview?.canAcknowledgeEmpty==true else {
                decision("empty-configured-pool-not-ready",challenge:challenge,binding:binding,raw:raw,ready:ready);return
            }
        } else if raw==1,binding.supportsOrdinaryPreentry {
            guard let wm else{decision("wm-unavailable",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
            let grants=overview?.entryRecords ?? [],screen=display()
            guard let poses=wm.ordinaryOverviewPoses(grants,display:screen) else{decision(wm.ordinaryOverviewRefusal(grants,display:screen) ?? "pose-recheck-refused",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
            if !poses.isEmpty {
                scene=(poses,challenge,binding);prepared=false;failed=false;restoreAttempts=0;retryAfter=0;setBusy(true,phase:"preparing")
                decision("worker-started",challenge:challenge,binding:binding,raw:raw,ready:ready)
                preparationPending=true
                worker.prepare(poses,binding:binding,challenge:challenge,reconcile:reconcileGeometry){ [weak self] accepted,reason in
                    guard let self,self.scene?.1==challenge else{return}
                    self.preparationPending=false
                    self.prepared=accepted;self.failed = !accepted
                    self.setBusy(true,phase:accepted ? "presented":"preflight-refused")
                    self.decision(accepted ? "worker-prepared":"worker-refused",challenge:challenge,binding:binding,raw:hs_overview10_mode(),ready:ready,worker:reason)
                }
                return
            }
        }
        var current:UInt64=0
        guard hs_notify_state(request,&current)==0,current==challenge,sys.processBirth(binding.pid)==binding.processBirth else{decision("request-expired-before-ack",challenge:challenge,binding:binding,raw:raw,ready:ready);return}
        if hs_notify_publish_state(ack,challenge)==0 {acknowledged=challenge;decision("acknowledged",challenge:challenge,binding:binding,raw:raw,ready:ready)}
        else{decision("ack-publish-failed",challenge:challenge,binding:binding,raw:raw,ready:ready)}
    }
    private func display() -> Rect {
        let d=CGDisplayBounds(CGMainDisplayID());return Rect(d.origin.x,d.origin.y,d.size.width,d.size.height)
    }
}
