import Foundation

extension WM {
    /// A confirmed native fullscreen view leaves its ordinary peers behind.
    /// Configure those peers without focusing them or changing the user's view.
    func reflowBackgroundFullscreenSources(_ snapshot:Snapshot) {
        guard enabled,snapshot.stable,!snapshot.locked,snapshot.spaceType==4,cfgSink != nil,
              !sys.sessionLocked(),!sys.interactionOverlay(),overviewFrozen?() != true else{return}
        let byID=Dictionary(snapshot.windows.map{($0.wid,$0)},uniquingKeysWith:{$1})
        let excluded=Set(hidden.map(\.wid)).union(floating).union(closing).union(restoring)
            .union(restorePending.keys).union(launcherTransfers.keys).union(activationMoves.keys)
        var jobs:[CfgJob]=[]
        for key in nativeSourceSpaces.sorted() {
            guard let source=Int(key),source != snapshot.space,let area=launcherAreas[source] else{continue}
            let state=sp(source),leaves=Set(Dwindle.leaves(state.tree).compactMap(\.wid)).subtracting(excluded)
            let departed=leaves.filter{wid in byID[wid].map{$0.nativeFullscreen && $0.space>0 && $0.space != source} == true}
            guard !departed.isEmpty else{continue}
            let peers=leaves.subtracting(departed)
            guard !peers.isEmpty,peers.allSatisfy({wid in
                byID[wid].map{$0.space==source && !$0.nativeFullscreen && $0.layer==0 && $0.alpha>0.05} == true
            }) else{continue}
            let projected=SpaceState();projected.tree=Node.from(state.tree?.json)
            for wid in Set(Dwindle.leaves(projected.tree).compactMap(\.wid)).subtracting(peers).sorted() {
                projected.tree=tile.removeReorientingPromoted(projected.tree,wid,in:area)
            }
            for (wid,to) in layout(area,projected) where target[wid] != to {
                guard let window=byID[wid],pids[wid]==window.pid,!sys.protectedProcess(window.pid),tileable(window),
                      sys.winPidLevel(wid).pid==window.pid,let job=job(window.pid,wid,to) else{continue}
                var configureJob=job;configureJob.expectedSpace=source
                cfgSink?.cancel(wid);revokeSnapshotLease(wid);liveBufferShrinks[wid]=nil
                eng.c.geom(wid,to,16,16,frm:to,move:false,warp:true,stretch:false)
                target[wid]=to;jobs.append(configureJob)
            }
        }
        if !jobs.isEmpty {eng.c.commit();configure(jobs)}
    }
    /// Preserve native fullscreen ownership through AppKit's order-out/Space-zero gaps.
    /// Trees remain intact; stale configure and transforms are revoked for the whole departing source.
    @discardableResult func updateNativeFullscreen(_ windows: [WinInfo], _ space: Int) -> Bool {
        retireFirstMapArrivals(windows,space:space)
        var native=Set(windows.filter(\.nativeFullscreen).map(\.wid))
        let previous=nativeFullscreenWindows
        let previousSuspended=nativeSuspendedSpaces
        var source: [Int:String]=[:]
        for (key,state) in spaces { for leaf in Dwindle.leaves(state.tree) { if let wid=leaf.wid { source[wid]=key } } }
        let retained=Set(source.keys), hiddenIDs=Set(hidden.map(\.wid))
        let managed=retained.union(target.keys).union(newbies.keys).union(optimistic.keys).union(eng.c.wins().map(\.wid))
        var gaps: [Int:Double]=[:]
        for window in windows where retained.contains(window.wid) && window.space == 0 {
            if firstMapSourceCovered(window,space:space) {continue}
            // Ordered-out closed windows retain a Space-zero CG object for
            // hundreds of milliseconds. Exact prior primary focus plus NO_KEY
            // distinguishes this from an unconfirmed fullscreen entry gap.
            if !window.on,source[window.wid]==String(space),confirmedCloseDeparture(window.wid,space:space,windows:windows) {continue}
            let since=nativeGapSince[window.wid] ?? sys.now(); gaps[window.wid]=since
            let selectedTab=windows.contains { peer in peer.pid == window.pid && peer.on && String(peer.space) == source[window.wid] && !retained.contains(peer.wid) && !peer.nativeFullscreen && peer.layer == 0 && peer.w >= 120 && peer.h >= 120 }
            if window.on || (!selectedTab && sys.now()-since < 0.5) { native.insert(window.wid) }
        }
        nativeGapSince=gaps
        let context=(sys.frontPid() ?? frontPid).map(sys.focusContext)
        if let focused=context?.wid, context!.flags & 16 != 0 { native.insert(focused) }
        var nativePIDs=Set(windows.filter { native.contains($0.wid) }.map(\.pid))
        if let pid=sys.frontPid(), (context?.flags ?? 0) & 16 != 0 { nativePIDs.insert(pid) }
        var origins=nativeSourceSpaces
        for (key,state) in spaces where !Set(Dwindle.leaves(state.tree).compactMap(\.wid)).isDisjoint(with:native) { origins.insert(key) }
        if nativeSpaceType != 4 { origins.insert(String(space)) }
        let originWindows=Set(spaces.filter { origins.contains($0.0) }.flatMap { Dwindle.leaves($0.1.tree).compactMap(\.wid) })
        // An ordinary window on a background desktop is offscreen too. Only
        // Space-zero transition evidence can inherit its app's fullscreen gap.
        for window in windows where nativePIDs.contains(window.pid) && originWindows.contains(window.wid) && managed.contains(window.wid) && !window.on && window.space==0 { native.insert(window.wid) }
        let byID=Dictionary(windows.map { ($0.wid,$0) },uniquingKeysWith: { first,_ in first })
        var returning=Set<Int>(), returnTimes: [Int:Double]=[:]
        for wid in previous.intersection(retained).subtracting(hiddenIDs) {
            let window=byID[wid]
            if let window, window.nativeFullscreen || window.on { continue }
            if let window, window.space == 0 && !nativeConfirmed.contains(wid) { continue }
            if window == nil && sys.winBounds(wid) == nil { continue }
            let since=nativeReturnSince[wid] ?? sys.now(); returnTimes[wid]=since
            if sys.now()-since < 1 { native.insert(wid); returning.insert(wid) }
        }
        nativeReturnSince=returnTimes
        let entering=native.subtracting(previous).intersection(managed).subtracting(hiddenIDs)
        var sources: [String:Set<Int>]=[:], suspended=Set<String>()
        for (key,state) in spaces {
            let leaves=Set(Dwindle.leaves(state.tree).compactMap(\.wid)).subtracting(hiddenIDs), owners=leaves.intersection(native)
            guard !owners.isEmpty else { continue }
            sources[key]=leaves
            let peers=leaves.subtracting(owners)
            // Missing peers can be closed, and positive foreign membership is
            // a completed move. Let sync retire those leaves; suspending here
            // prevents the very reconciliation that could unfreeze the source.
            if nativeSpaceType == 4 || !owners.isDisjoint(with:returning) || owners.contains(where: { byID[$0]?.space == 0 || byID[$0].map { $0.on && String($0.space)==key } == true }) || peers.contains(where: { byID[$0]?.space == 0 }) { suspended.insert(key) }
        }
        let departing=Set(sources.keys).subtracting(nativeSourceSpaces).union(suspended.subtracting(nativeSuspendedSpaces))
        var revoked=entering
        for key in departing { revoked.formUnion(sources[key] ?? []) }
        nativeSourceSpaces=Set(sources.keys); nativeSuspendedSpaces=suspended
        nativeSuspendedWindows=Set(suspended.flatMap { Array(sources[$0] ?? []) })
        for wid in revoked {
            cfgSink?.cancel(wid); eng.c.forget(wid); deco.drop(wid)
            newbies[wid]=nil; optimistic[wid]=nil; cfgQ.removeAll { $0.wid == wid }
        }
        let changed=native.symmetricDifference(previous).intersection(managed).subtracting(hiddenIDs)
        for wid in revoked.union(changed) { target[wid]=nil }
        nativeConfirmed.formIntersection(native); nativeConfirmed.formUnion(windows.filter(\.nativeFullscreen).map(\.wid))
        if let focused=context?.wid, context!.flags & 16 != 0 { nativeConfirmed.insert(focused) }
        nativeFullscreenWindows=native
        if !revoked.isEmpty { eng.c.commit() }
        return !changed.isEmpty || !departing.isEmpty || suspended != previousSuspended
    }
}
