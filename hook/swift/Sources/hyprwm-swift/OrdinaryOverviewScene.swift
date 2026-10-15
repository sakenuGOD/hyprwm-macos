import Foundation
import HyprCore
import CAX

/// Only ordinary native AppKit frame changes; alpha remains owned by Native13.
/// Every request carries the authenticated grant and exact producer challenge.
final class OrdinaryOverviewScene {
    private let queue=DispatchQueue(label:"hyprwm.overview.appkit",qos:.userInitiated)
    private let sys:LiveSys
    init(sys:LiveSys){self.sys=sys}
    private func exact(_ pose:OrdinaryOverviewPose) -> Bool {
        let source=pose.source
        guard !sys.sessionLocked(),!sys.protectedProcess(source.pid),
              sys.processBirth(source.pid)=="\(source.pid):\(source.birth[2]):\(source.birth[3])",
              sys.winPidLevel(source.wid).pid==source.pid,sys.winPidLevel(source.wid).level==0 else{return false}
        guard let census=try? sys.focusSnapshot(),census.stable,
              census.windows.contains(where:{$0.wid==source.wid && $0.pid==source.pid && source.spaces.contains($0.space) && $0.layer==0 && !$0.nativeFullscreen}) else{return false}
        return sys.processBirth(source.pid)=="\(source.pid):\(source.birth[2]):\(source.birth[3])"
    }
    typealias Reconcile=([OrdinaryOverviewPose],Bool,@escaping(Bool)->Void)->Void
    func prepare(_ poses:[OrdinaryOverviewPose],binding:OverviewBinding,challenge:UInt64,reconcile:@escaping Reconcile,completion:@escaping(Bool,String)->Void) {
        let end=sys.now()+0.235
        stage(poses,parked:false,reconcile:reconcile,authority:{ [self] in
            var actual:UInt64=0
            return sys.now()<end && hs_notify_state("hyprwm.overview11.request."+binding.nonce,&actual)==0 && actual==challenge &&
                sys.processBirth(binding.pid)==binding.processBirth && hs_overview10_mode()==1
        },completion:completion)
    }
    func restore(_ poses:[OrdinaryOverviewPose],reconcile:@escaping Reconcile,completion:@escaping(Bool,String)->Void) {
        stage(poses,parked:true,reconcile:reconcile,authority:{true},completion:completion)
    }
    private func stage(_ poses:[OrdinaryOverviewPose],parked:Bool,reconcile:@escaping Reconcile,authority:@escaping()->Bool,completion:@escaping(Bool,String)->Void) {
        queue.async { [self] in
            func finish(_ accepted:Bool,_ reason:String) {DispatchQueue.main.async{completion(accepted,reason)}}
            for pose in poses {
                let goal=parked ? pose.source.parked:pose.visible,wid=pose.source.wid
                guard authority() else{finish(false,"authority-before-frame");return}
                guard exact(pose) else{finish(false,"native-identity-or-census:\(wid)");return}
                guard sys.axTileable(pose.source.pid,wid)==1 else{finish(false,"appkit-role:\(wid)");return}
                guard (sys.winAlpha(wid) ?? 1)<=0.001 else{finish(false,"alpha-before-frame:\(wid)");return}
                let result=sys.axFrame(pose.source.pid,wid,goal)
                guard result==0 else{finish(false,"appkit-frame-result:\(wid):\(result)");return}
                guard let app=sys.axGetFrame(pose.source.pid,wid),
                      OrdinaryOverviewFrameReadback.acceptsAppKit(app,pose:pose,parked:parked,sourceCurrent:exact(pose),alpha:sys.winAlpha(wid)) else {
                    finish(false,"appkit-frame-not-accepted:\(wid):parked=\(parked):goal=\(goal.arr):app=\(sys.axGetFrame(pose.source.pid,wid)?.arr ?? [])");return
                }
            }
            guard authority() else{finish(false,"authority-before-native-align");return}
            DispatchQueue.main.async {
                reconcile(poses,parked) {aligned in
                    self.queue.async {
                        guard aligned else{finish(false,"native-align-not-consumed");return}
                        for sample in 0..<2 {
                            for pose in poses {
                                let goal=parked ? pose.source.parked:pose.visible,wid=pose.source.wid
                                guard authority(),self.exact(pose) else{finish(false,"authority-or-identity-during-readback:\(wid)");return}
                                guard let native=self.sys.winBounds(wid),native.maxDiff(goal)<0.01,(self.sys.winAlpha(wid) ?? 1)<=0.001 else{finish(false,"native-frame-or-alpha-readback:\(wid)");return}
                                if sample==1 {
                                    guard let app=self.sys.axGetFrame(pose.source.pid,wid),
                                          OrdinaryOverviewFrameReadback.acceptsAppKit(app,pose:pose,parked:parked,sourceCurrent:self.exact(pose),alpha:self.sys.winAlpha(wid)) else {
                                        finish(false,"appkit-frame-after-align:\(wid):parked=\(parked):goal=\(goal.arr):app=\(self.sys.axGetFrame(pose.source.pid,wid)?.arr ?? [])");return
                                    }
                                }
                            }
                            if sample==0 {self.sys.sleep(0.008)}
                        }
                        finish(authority(),"aligned-and-verified")
                    }
                }
            }
        }
    }
}
