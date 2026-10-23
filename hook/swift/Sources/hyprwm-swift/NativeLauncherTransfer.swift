import CAX
import Foundation
import HyprCore

/// Focus only the existing window moved by one captured launcher transaction.
/// Ordinary focus stays current-Space-only; this worker never sets a Space.
final class NativeLauncherTransferWorker {
    private let queue = DispatchQueue(label: "hyprwm.launcher.transfer.focus", qos: .userInteractive)
    private let lock = NSLock()
    private var serial = 0
    private var workers = 0

    var busy: Bool { lock.lock(); defer { lock.unlock() }; return workers > 0 }
    func cancel() { lock.lock(); serial += 1; lock.unlock() }
    private func current(_ token: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return serial == token }

    func submit(_ sys: LiveSys, _ request: LauncherTransferFocus, completion: @escaping (Bool) -> Void) {
        lock.lock(); serial += 1; let token = serial; workers += 1; lock.unlock()
        queue.async { [weak sys] in
            var accepted = false
            defer {
                let result = accepted && self.current(token)
                DispatchQueue.main.async {
                    self.lock.lock(); self.workers -= 1; self.lock.unlock()
                    completion(result)
                }
            }
            guard let sys else { return }
            func allowed() -> Bool {
                guard self.current(token), request.sequence > 0, sys.now() < request.deadline,
                      !sys.sessionLocked(), !sys.interactionOverlay(), !sys.mouseDown(),
                      !OverviewNativeMode.active(hs_overview10_mode()),
                      !sys.protectedProcess(request.pid), sys.processBirth(request.pid) == request.birth,
                      sys.winPidLevel(request.wid).pid == request.pid,
                      sys.frontPid() == request.pid,
                      let intent = sys.launcherIntent(after: request.sequence - 1),
                      intent.sequence == request.sequence, intent.space == request.origin, intent.kind > 0 else { return false }
                return true
            }
            func contextAllows(_ context: (wid: Int?, flags: Int)) -> Bool {
                guard context.flags & (NativeFocusFlags.positive | NativeFocusFlags.unknown) == 0 else { return false }
                return context.wid == request.wid || context.wid == nil && context.flags & NativeFocusFlags.noKey != 0
            }
            func census(_ snapshot: Snapshot, _ catalog: PublicWorkspaceCatalog) -> Bool {
                catalog.sameSession(request.catalog) && [request.source, request.origin].contains(catalog.active) &&
                    catalog.active == snapshot.space && request.member(in: snapshot) != nil
            }
            do {
                guard allowed(), let firstCatalog = sys.launcherCatalog(),
                      (try? firstCatalog.target(request.origin)) != nil,
                      (try? firstCatalog.target(request.source)) != nil else { return }
                let context = sys.nativeFocusContext(request.pid)
                guard contextAllows(context), sys.axTileable(request.pid, request.wid) == 1, allowed() else { return }
                let first = try sys.focusSnapshot()
                guard census(first, firstCatalog), let firstAfter = sys.launcherCatalog(),
                      firstAfter.sameSession(firstCatalog), firstAfter.active == firstCatalog.active, allowed() else { return }
                Thread.sleep(forTimeInterval: 0.016)
                guard allowed() else { return }
                let freshContext = sys.nativeFocusContext(request.pid)
                guard freshContext.wid == context.wid, freshContext.flags == context.flags,
                      contextAllows(freshContext), let secondCatalog = sys.launcherCatalog() else { return }
                let second = try sys.focusSnapshot()
                guard census(second, secondCatalog), secondCatalog.sameSession(firstCatalog),
                      secondCatalog.active == firstCatalog.active,
                      let secondAfter = sys.launcherCatalog(), secondAfter.sameSession(secondCatalog),
                      secondAfter.active == secondCatalog.active, allowed() else { return }
                // This exact-window activation can naturally reveal its Space.
                // The WM main loop must still observe real origin/view/key ACK.
                let commitContext=sys.nativeFocusContext(request.pid)
                guard commitContext.wid==context.wid,commitContext.flags==context.flags,
                      contextAllows(commitContext),allowed() else{return}
                accepted = sys.axFocus(request.pid, request.wid, raise: true) == 0
            } catch { return }
        }
    }
}

extension LiveSys {
    func launcherCatalog() -> PublicWorkspaceCatalog? {
        try? PublicWorkspaceCatalog(VerifiedPublicWorkspace.diagnostic())
    }
    func requestTransferFocus(_ request: LauncherTransferFocus, completion: @escaping (Bool) -> Void) {
        launcherTransferWorker.submit(self, request, completion: completion)
    }
    func cancelTransferFocus() { launcherTransferWorker.cancel() }
    var transferFocusBusy: Bool { launcherTransferWorker.busy }
}
