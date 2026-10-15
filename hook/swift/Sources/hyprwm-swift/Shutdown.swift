import AppKit
import Foundation
import HyprCore

/// Native shutdown keeps the daemon alive until exact owned sources are visible
/// and both the WindowServer command ring and application AX workers are drained.
final class ShutdownCoordinator {
    let wm:WM, overview:OverviewBridge, sys:LiveSys
    private var timer:DispatchSourceTimer?
    private var pending=false, overviewReady=false, started=0.0
    private var witnesses:[(Int,Int,String)]=[]
    private var completions:[(Bool)->Void]=[]
    private var epoch=0
    init(wm:WM,overview:OverviewBridge,sys:LiveSys) { self.wm=wm;self.overview=overview;self.sys=sys }
    func request(_ completion:@escaping(Bool)->Void) {
        completions.append(completion)
        guard timer == nil else { return }
        epoch+=1
        started=sys.now();overviewReady=false
        let timer=DispatchSource.makeTimerSource(queue:.main)
        timer.schedule(deadline:.now(),repeating:.milliseconds(40),leeway:.milliseconds(4))
        timer.setEventHandler { [weak self] in self?.poll() };timer.resume();self.timer=timer
    }
    private func finish(_ success:Bool) {
        timer?.cancel();timer=nil;pending=false
        if !success { overview.cancelShutdown() }
        let callbacks=completions;completions=[];for callback in callbacks { callback(success) }
    }
    private func poll() {
        if sys.now()-started > 8 { log("shutdown: native restoration is pending; daemon remains alive");finish(false);return }
        guard !sys.sessionLocked(), !overview.active else { return }
        if !overviewReady {
            guard !pending else { return };pending=true
            let expectedEpoch=epoch
            overview.prepareShutdown { [weak self] ready in
                guard let self else { return };self.pending=false
                guard self.timer != nil, self.epoch == expectedEpoch else { return }
                guard ready else { return };self.overviewReady=true
                self.witnesses=self.wm.shutdownWitnesses()
                self.wm.setEnabled(false);self.wm.save()
            }
            return
        }
        guard wm.shutdownDrained else { return }
        for (wid,pid,birth) in witnesses {
            guard sys.processBirth(pid) == birth, sys.winPidLevel(wid).pid == pid else { continue } // departed lifetime has no restoration authority
            guard let alpha=sys.winAlpha(wid), alpha >= 0.999 else { return }
        }
        finish(true)
    }
}
