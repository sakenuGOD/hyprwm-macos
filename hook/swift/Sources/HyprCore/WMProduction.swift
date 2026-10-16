import Foundation

struct ActivationMove {
    let pid: Int
    let birth: String
    let source: Int
    let destination: Int
    let frame: Rect
    let deadline: Double
}

struct ResizeCut {
    let node: Node
    let axis: Int
    let side: Int
    let ratio: Double
    let span: Double
    let manual: Bool
    let path: [Bool]
    let inner: (path: [Bool], coordinate: Double)?
}
struct DragSession {
    let wid: Int
    let pid: Int
    let space: Int
    let frame: Rect
    let birth: String
    let owners: [Int: (Int, String)]
    let point: (Double, Double)
    let cuts: [ResizeCut]
    let area: Rect
    var tree: JSON
    let nativeEpoch: UInt64?
    var resized = false
}

extension WM {
    /// Internal manager migration: quiesce without revealing/forgetting any owned source.
    public func prepareHandover() -> String {
        admission?.suspend()
        guard !engineRecoveryActive, !startupRecoveryPending else { return "handover pending: Engine recovery is active" }
        guard !sys.sessionLocked(),!sys.interactionOverlay(),overviewFrozen?() != true,
              eng.c.stats.nactive==0,eng.c.stats.holding==0,!eng.c.pending,snapshotLeases.isEmpty,liveBufferShrinks.isEmpty,
              !sys.closeBusy,silentSpaceMoves.isEmpty,restorePending.isEmpty,restoring.isEmpty else{return "handover pending: native work is active"}
        enabled=false;cancelFocusRecovery();workspaceCancel?();cfgSink?.cancelAll();cfgQ.removeAll()
        cancelLauncherTransfers()
        guard cfgSink?.idle != false,!sys.focusBusy,workspaceBusy?() != true else{return "handover pending: workers are draining"}
        dragSession=nil;activationIntent=nil;launcherIntent=nil
        activationMoves.removeAll();snapshotConfigures.removeAll();liveBufferShrinks.removeAll();later.removeAll()
        do { try armHiddenHandover() } catch { return "handover refused: \(error)" }
        save()
        guard recoveryStateSaved() else { hiddenHandover = nil; return "handover refused: state was not saved" }
        return "handover ready: state preserved; terminate this exact process with SIGHUP"
    }
    func hiddenRecordLive(_ record: Hidden) -> Bool {
        guard let pid = record.pid, !sys.protectedProcess(pid), sys.winPidLevel(record.wid).pid == pid,
              let current = sys.processBirth(pid), record.extra["native_visibility_pending"]?.truthy != true else { return false }
        if let expected = record.extra["swift_birth"]?.string { return current == expected }
        if let generation = record.extra["generation"]?.array, generation.count == 4,
           let owner = generation[0].int, let seconds = generation[2].int, let micros = generation[3].int {
            return owner == pid && current == "\(pid):\(seconds):\(micros)"
        }
        return false
    }

    /// Pause keeps the current presentation until the client accepts that frame.
    public func setEnabled(_ on: Bool) {
        if !on { engineRecoveryResume = false }
        guard enabled != on else { return }
        if on {
            guard !engineRecoveryActive else { return }
            guard disarmHiddenHandover() else { log("resume: handover state was not saved"); return }
        }
        pauseEpoch+=1
        enabled=on
        if !on {
            admission?.suspend()
            cancelFocusRecovery()
            workspaceCancel?()
            snapshotConfigures.removeAll()
            clearSnapshotLeases()
            cfgSink?.cancelAll()
            dragSession = nil
            activationIntent = nil; activationMoves.removeAll(); silentSpaceMoves.removeAll(); restorePending.removeAll()
            cancelLauncherTransfers()
            pauseLandingWitnesses.removeAll()
            let c = eng.c
            let hiddenIDs=Set(hidden.map(\.wid)),slots=Dictionary(c.wins().map{($0.wid,$0)},uniquingKeysWith:{first,_ in first})
            var jobs:[CfgJob]=[]
            for wid in Set(target.keys).union(optimistic.keys).union(newbies.keys) where !hiddenIDs.contains(wid) {
                guard options.production,let slot=slots[wid],let pid=pids[wid],
                      sys.winPidLevel(wid).pid==pid,!sys.protectedProcess(pid),let birth=sys.processBirth(pid) else {
                    c.alpha(wid,1,0,0);c.forget(wid);continue
                }
                let frame=slot.visible
                let native=sys.nativeResize(pid)
                let nativeEpoch=native.flatMap{$0.wid==wid && $0.birth==birth ? $0.epoch:nil}
                pauseLandingWitnesses[wid] = PauseLandingWitness(pid:pid,birth:birth,frame:frame,nativeEpoch:nativeEpoch)
                c.geom(wid,frame,16,16,dpos:0,dsize:0,frm:frame,move:true,warp:true,stretch:false)
                c.alpha(wid,1,16,0)
                if slot.real.maxDiff(frame)<=1 {c.forget(wid);continue}
                var job=CfgJob(wid:wid,pid:pid,owner:owner[wid] ?? "",to:frame)
                job.birth=birth;job.requireOwnership=true;jobs.append(job)
                releasePausedWindow(wid,pid:pid,birth:birth,frame:frame,epoch:pauseEpoch,deadline:sys.now()+1)
            }
            c.commit()
            cfgQ.removeAll();liveBufferShrinks.removeAll(); target.removeAll(); newbies.removeAll(); optimistic.removeAll()
            restoring.removeAll(); dimSince.removeAll()
            cfgSink?.submit(jobs)
            save()
        } else {
            pauseLandingWitnesses.removeAll()
            cfgSink?.cancelAll()
            lastSnap = 0; rescued = false
        }
    }

    private func releasePausedWindow(_ wid:Int,pid:Int,birth:String,frame:Rect,epoch:Int,deadline:Double) {
        DispatchQueue.main.asyncAfter(deadline:.now()+0.016) { [weak self] in
            guard let self,!self.enabled,self.pauseEpoch==epoch,!self.sys.sessionLocked(),
                  self.sys.processBirth(pid)==birth,self.sys.winPidLevel(wid).pid==pid else{return}
            guard self.engineRecoveryActive else{return} // Ordinary pause is polled with current ACK/manual authority.
            let actual=self.sys.winBounds(wid)
            if self.engineRecoveryActive && actual.map({$0.maxDiff(frame)<=TOL}) != true && self.sys.now()>=deadline {
                return // Recovery retains B until physical A ACK; never timeout-forget.
            }
            if actual.map({$0.maxDiff(frame)<=TOL})==true || self.sys.now()>=deadline {
                self.cfgSink?.cancel(wid)
                self.eng.c.forget(wid);self.eng.c.commit()
            } else {
                self.releasePausedWindow(wid,pid:pid,birth:birth,frame:frame,epoch:epoch,deadline:deadline)
            }
        }
    }

    /// Exact AX focus evidence authorizes a transfer; dialogs and menus retain focus ownership.
    func activateOnCurrentSpace(_ area: Rect, _ space: Int, _ wins: [WinInfo], _ pid: Int) {
        guard enabled,silentSpaceMoves.isEmpty, !sys.sessionLocked(), !sys.interactionOverlay(), !nativeSuspendedSpaces.contains(String(space)), !sys.protectedProcess(pid) else { return }
        let context = sys.focusContext(pid)
        if context.flags & 4 != 0 {
            if activationIntent == nil { activationIntent = (pid, space, sys.now()) }; return
        }
        activationIntent = nil
        guard context.flags & (1 | 2 | 4 | 8 | 16) == 0 else { return }
        let launcher=launcherIntent.flatMap { $0.space > 0 && $0.kind>0 ? $0 : nil }
        let destination=launcher?.space ?? space
        let crossed=destination != space
        if let launcher,let focused=context.wid,let pending=restorePending[focused],
           pending.launcherSequence==launcher.sequence,pending.record.pid==pid,
           pending.space==destination,hiddenRecordLive(pending.record) {return}
        // Membership can become current before transfer focus/placement ACK.
        // Keep its captured launcher alive; the visible-window fast path below
        // must not reclassify this existing source as a new local selection.
        if let launcher,let focused=context.wid,let transfer=launcherTransfers[focused],
           transfer.request.sequence==launcher.sequence,transfer.request.pid==pid,
           transfer.request.origin==destination,sys.winPidLevel(focused).pid==pid,
           sys.processBirth(pid)==transfer.request.birth {return}
        if let launcher,options.transferOnActivation,let focused=context.wid,
           let window=wins.first(where:{$0.wid==focused && $0.pid==pid && $0.space>0 && $0.layer==0 && !$0.nativeFullscreen}),
           crossed || window.space != destination,
           !ignored(window),sys.winPidLevel(focused).pid==pid,
           tileable(window) || hidden.contains(where:{$0.wid==focused && hiddenRecordLive($0)}) {
            if !launcherTransfers.isEmpty {return}
            let record=hidden.first{$0.wid==focused}
            let frame=record.flatMap{Rect($0.rect)} ?? sys.winBounds(focused) ?? window.rect
            if beginLauncherTransfer(launcher,window,space,frame,record != nil) {return}
        }
        // An origin intent alone cannot switch the user's view. Require the same
        // preflight/commit provider fence as an explicit workspace dispatcher.
        let hid = Set(hidden.map(\.wid))
        if let focused = context.wid, hid.contains(focused) {
            guard let launcher else{return} // OS close/focus fallback has no user restoration intent.
            if crossed, workspaceFocus?(destination,true) != true { return }
            if crossed, workspaceFocus?(destination,false) != true { return }
            _ = unhide(launcherAreas[destination] ?? area, destination, wins, which: .wids([focused]))
            if var pending=restorePending[focused] {
                pending.launcherSequence=launcher.sequence;restorePending[focused]=pending
                launcherDisposition="awaiting-local-placement"
            } else {
                consumeLauncher(hidden.contains(where:{$0.wid==focused}) ? "local-restore-refused":"restored-local-window")
            }
            return
        }
        let visible = wins.filter { $0.pid == pid && $0.space == destination && $0.on && !hid.contains($0.wid) && tileable($0) }
        if !visible.isEmpty {
            if let launcher,!crossed {
                // The origin app remains frontmost while Spotlight opens and
                // while an app switcher is cycling. Its existing key window is
                // not selection evidence. Exact hidden/cross-Space selections
                // above still restore even when they belong to the same PID.
                if pid != launcher.frontPID {consumeLauncher("selected-visible-window")}
                else {launcherDisposition="awaiting-selection"}
            }
            return
        }
        guard launcher != nil,options.transferOnActivation, let focused = context.wid,
              let window = wins.first(where: { $0.wid == focused && $0.pid == pid }),
              window.space != destination, window.space > 0, tileable(window),
              sys.winPidLevel(focused).pid == pid else { return }
        guard activationMoves[focused] == nil, activationMoves.count < 32,
              let birth = sys.processBirth(pid) else { return }
        if crossed, workspaceFocus?(destination,true) != true { return }
        activationMoves[focused] = ActivationMove(pid: pid, birth: birth, source: window.space,
                                                  destination: destination, frame: sys.winBounds(focused) ?? window.rect,
                                                  deadline: sys.now()+(crossed ? 8 : 2))
        cfgSink?.cancel(focused)
        eng.c.space(focused, destination)
        eng.c.commit()
        if crossed { _=workspaceFocus?(destination,false) }
        consumeLauncher()
    }

    func retryActivationIntent(_ area: Rect, _ space: Int, _ wins: [WinInfo]) {
        guard let intent = activationIntent else { return }
        guard intent.space == space, sys.now()-intent.started <= 0.6, sys.frontPid() == intent.pid else { activationIntent = nil; return }
        if sys.focusContext(intent.pid).flags & 4 == 0 { activateOnCurrentSpace(area, space, wins, intent.pid) }
    }

    func completeActivationMoves(_ area: Rect, _ space: Int, _ wins: [WinInfo]) {
        for (wid, request) in activationMoves {
            guard sys.now() < request.deadline,
                  sys.processBirth(request.pid) == request.birth,
                  sys.winPidLevel(wid).pid == request.pid else {
                activationMoves[wid] = nil; continue
            }
            guard request.destination == space else { continue }
            guard let window = wins.first(where: { $0.wid == wid && $0.pid == request.pid && $0.space == space && $0.on }),
                  tileable(window) else { continue }
            activationMoves[wid] = nil
            let source = sp(request.source)
            source.tree = Dwindle.remove(source.tree, wid)
            if source.focus == wid { source.focus = nil }
            if source.full == wid { source.full = nil }
            target[wid] = nil
            restoring.insert(wid); restoreFrom[wid] = request.frame
            newbies[wid] = nil; optimistic[wid] = nil
            save()
        }
    }

    func beginInteraction(_ area: Rect, _ space: Int, _ wins: [WinInfo], native: NativeResizeContext? = nil) {
        dragSession = nil
        guard sp(space).full == nil else { return }
        let context = sys.frontPid().map(sys.focusContext)
        if let context, context.flags & (1 | 2 | 4 | 8 | 16) != 0 { return }
        let point = native?.point ?? sys.mouse(), rects = layout(area, sp(space))
        let actor:WinInfo?
        if let native {
            actor=wins.first{$0.space==space && $0.on && $0.wid==native.wid && $0.pid==native.pid}
        } else if options.production,let hint=sys.pointerHit() {
            actor=wins.first{$0.space==space && $0.on && $0.wid==hint.wid && (hint.pid==nil || $0.pid==hint.pid)}
        } else {
            actor=wins.first {w in w.space==space && w.on && (!options.production ? rects.contains(w.wid):true) &&
                point.0>=w.x && point.0<=w.x+w.w && point.1>=w.y && point.1<=w.y+w.h}
        }
        guard let window=actor,rects.contains(window.wid), !sys.protectedProcess(window.pid), tileable(window),
            sys.winPidLevel(window.wid).pid == window.pid,
            !eng.c.wins().contains(where: { slot in
                slot.wid == window.wid && (slot.posActive || slot.sizeActive || slot.held ||
                    (slot.settling && slot.visible.maxDiff(slot.real)>TOL))
            }),
            let birth = sys.processBirth(window.pid) else { return }
        if let native, native.birth != birth || native.phase > 2 || native.epoch == 0 { return }
        let frame = native?.frame ?? sys.winBounds(window.wid) ?? window.rect
        var path: [(Node, Rect, Bool, [Bool])] = []
        func walk(_ node: Node?, _ box: Rect, _ steps: [Bool] = []) -> Bool {
            guard let node else { return false }
            if node.isLeaf { return node.wid == window.wid }
            let (a, b) = tile.splitBox(box, node)
            path.append((node, box, true, steps))
            if walk(node.a, a, steps+[true]) { return true }
            path[path.count-1].2 = false
            if walk(node.b, b, steps+[false]) { return true }
            path.removeLast(); return false
        }
        _ = walk(sp(space).tree, area)
        var cuts: [ResizeCut] = []
        if options.sharedResize {
            for axis in 0...1 {
                for side in [-1, 1] {
                    let edge = frame.arr[axis] + (side == 1 ? frame.arr[axis+2] : 0)
                    let cursor = axis == 0 ? point.0 : point.1
                    guard abs(cursor-edge) <= 6 else { continue }
                    var inner: (path:[Bool],coordinate:Double)?
                    let leafBox=tile.boxes(sp(space).tree,area)[window.wid] ?? frame
                    for (node,box,first,steps) in path.reversed() where node.split == (axis == 0 ? "v" : "h") {
                        let (a,_)=tile.splitBox(box,node), boundary=a.arr[axis]+a.arr[axis+2]
                        if first != (side == 1) { if inner == nil { inner=(steps,boundary) }; continue }
                        let allocationEdge=leafBox.arr[axis]+(side == 1 ? leafBox.arr[axis+2] : 0)
                        guard abs(boundary-allocationEdge) <= 0.01 else { continue }
                        cuts.append(ResizeCut(node:node,axis:axis,side:side,ratio:(boundary-box.arr[axis])/box.arr[axis+2],
                            span:box.arr[axis+2],manual:node.manualRatio,path:steps,inner:inner)); break
                    }
                }
            }
        }
        var owners: [Int: (Int, String)] = [:]
        for peer in wins where rects.contains(peer.wid) {
            guard sys.winPidLevel(peer.wid).pid == peer.pid, let generation = sys.processBirth(peer.pid), !sys.protectedProcess(peer.pid) else { return }
            owners[peer.wid] = (peer.pid, generation)
        }
        dragSession = DragSession(wid: window.wid, pid: window.pid, space: space, frame:frame,birth:birth,owners:owners,point:point,cuts:cuts,area:area,tree:sp(space).tree?.json ?? .null,nativeEpoch:native?.epoch)
        if !cuts.isEmpty { cfgSink?.cancel(window.wid) }
    }

    @discardableResult func updateSharedResize(_ area: Rect, _ space: Int, _ wins: [WinInfo]) -> Bool {
        guard var drag = dragSession, drag.space == space, !drag.cuts.isEmpty, drag.area == area, drag.tree == sp(space).tree?.json,
              sys.winPidLevel(drag.wid).pid == drag.pid, sys.processBirth(drag.pid) == drag.birth,
              drag.owners.allSatisfy({ sys.winPidLevel($0.key).pid == $0.value.0 && sys.processBirth($0.value.0) == $0.value.1 }),
              let actual = acceptedInteractionFrame(drag) else { return false }
        guard abs(actual.w-drag.frame.w) > 1 || abs(actual.h-drag.frame.h) > 1 else { return false }
        var proposals: [(ResizeCut, Double)] = []
        for cut in drag.cuts {
            let opposite = actual.arr[cut.axis] + (cut.side == -1 ? actual.arr[cut.axis+2] : 0)
            let original = drag.frame.arr[cut.axis] + (cut.side == -1 ? drag.frame.arr[cut.axis+2] : 0)
            guard abs(opposite-original) <= 3, cut.span > 0 else { dragSession = nil; return false }
            let edge = actual.arr[cut.axis] + (cut.side == 1 ? actual.arr[cut.axis+2] : 0)
            let start = drag.frame.arr[cut.axis] + (cut.side == 1 ? drag.frame.arr[cut.axis+2] : 0)
            let ratio = cut.ratio + (edge-start)/cut.span
            guard ratio >= 0.05 && ratio <= 0.95 else { dragSession = nil; return false }
            proposals.append((cut, ratio))
        }
        guard let candidate=Node.from(drag.tree) else { dragSession=nil; return false }
        func locate(_ steps: [Bool]) -> (Node,Rect)? {
            var node=candidate, box=area
            for step in steps {
                guard !node.isLeaf else { return nil }
                let (a,b)=tile.splitBox(box,node); node=step ? node.a : node.b; box=step ? a : b
            }
            return (node,box)
        }
        for (cut,ratio) in proposals {
            guard let (node,_)=locate(cut.path) else { dragSession=nil; return false }
            node.ratio=ratio; node.manualRatio=true
        }
        for cut in drag.cuts {
            guard let inner=cut.inner else { continue }
            guard let (node,box)=locate(inner.path), box.arr[cut.axis+2] > 0 else { dragSession=nil; return false }
            let ratio=(inner.coordinate-box.arr[cut.axis])/box.arr[cut.axis+2]
            guard ratio >= 0.05 && ratio <= 0.95 else { dragSession=nil; return false }
            node.ratio=ratio; node.manualRatio=true
        }
        let proposed=SpaceState(); proposed.tree=candidate
        let rects=layout(area,proposed)
        guard let accepted=rects[drag.wid], abs(accepted.w-actual.w) <= TOL, abs(accepted.h-actual.h) <= TOL,
              abs(accepted.x-actual.x) <= TOL, abs(accepted.y-actual.y) <= TOL else { dragSession=nil; return false }
        sp(space).tree=candidate; drag.tree=candidate.json
        target[drag.wid] = accepted
        drag.resized = true; dragSession = drag
        // Mirror AppKit's already accepted actor geometry into its visual slot;
        // F_MOVE remains off, so this does not write the actor's native frame.
        eng.c.geom(drag.wid,actual,0,0,dpos:0,dsize:0,move:false,warp:true,stretch:false)
        apply(area, space, wins.filter { $0.wid != drag.wid })
        return true
    }

    func acceptedInteractionFrame(_ drag: DragSession) -> Rect? {
        if let epoch=drag.nativeEpoch, let native=sys.nativeResize(drag.pid) {
            guard native.wid==drag.wid, native.birth==drag.birth, native.epoch==epoch,
                  native.phase<=3 else { return nil }
            if native.sample>0 {
                guard let frame=native.acceptedFrame, let time=native.acceptedTime,
                      (0...0.25).contains(sys.now()-time) else { return nil }
                return frame
            }
        }
        return sys.winBounds(drag.wid)
    }

    @discardableResult func endInteraction(_ area: Rect, _ space: Int, _ wins: [WinInfo]) -> Bool {
        guard let drag = dragSession else { return false }
        defer { dragSession = nil }
        guard drag.space == space, sys.winPidLevel(drag.wid).pid == drag.pid, sys.processBirth(drag.pid) == drag.birth else { return false }
        if !drag.cuts.isEmpty {
            guard acceptedInteractionFrame(drag) != nil else { return false }
            let changed=updateSharedResize(area,space,wins)
            guard dragSession != nil else { return false }
            if changed || drag.resized { save();return true }
            return false
        }
        guard let actual = acceptedInteractionFrame(drag), abs(actual.w-drag.frame.w) <= TOL,
              abs(actual.h-drag.frame.h) <= TOL else { return false }
        let dx = actual.x-drag.frame.x, dy = actual.y-drag.frame.y
        let horizontal = abs(dx) >= abs(dy)*options.directionRatio
        let vertical = abs(dy) >= abs(dx)*options.directionRatio
        guard max(abs(dx), abs(dy)) >= options.throwDistance, horizontal || vertical else { return false }
        let direction = horizontal ? (dx < 0 ? "left" : "right") : (dy < 0 ? "up" : "down")
        let state = sp(space), rects = layout(area, state)
        let cursor = sys.mouse()
        let detached=nativeFullscreenWindows.subtracting(nativeSuspendedWindows)
        let projected=options.production && Dwindle.leaves(state.tree).contains{detached.contains($0.wid!)}
        let originalBox = projected ? rects[drag.wid] ?? drag.frame : tile.boxes(state.tree, area)[drag.wid] ?? drag.frame
        let shortThrow = cursor.0 >= originalBox.x && cursor.0 <= originalBox.x+originalBox.w &&
            cursor.1 >= originalBox.y && cursor.1 <= originalBox.y+originalBox.h
        if !shortThrow || options.dragMode == "insert" {
            let dropped = rects.first { wid, rect in wid != drag.wid && cursor.0 >= rect.x && cursor.0 <= rect.x+rect.w && cursor.1 >= rect.y && cursor.1 <= rect.y+rect.h }?.0
            if let peer = dropped {
                state.tree = Dwindle.remove(state.tree, drag.wid)
                state.tree = insert(state, drag.wid, peer, area, point: cursor)
            } else if options.dragMode == "insert" {
                moveDir(state, area, drag.wid, direction, rects)
            } else { return false }
            state.focus = drag.wid; target[drag.wid] = nil
            return true
        }
        guard let peer = Dwindle.neighbour(rects, drag.wid, direction), peer > 0 else { return false }
        for leaf in Dwindle.leaves(state.tree) {
            if leaf.wid == drag.wid { leaf.wid = peer } else if leaf.wid == peer { leaf.wid = drag.wid }
        }
        state.focus = drag.wid
        target[drag.wid] = nil; target[peer] = nil
        return true
    }
}
