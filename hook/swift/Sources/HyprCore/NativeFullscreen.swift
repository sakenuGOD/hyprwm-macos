import Foundation

extension WM {
    /// Preserve native fullscreen ownership through AppKit's order-out/Space-zero gaps.
    /// Trees remain intact; stale configure and transforms are revoked for the whole departing source.
    @discardableResult func updateNativeFullscreen(_ windows: [WinInfo], _ space: Int) -> Bool {
        var native=Set(windows.filter(\.nativeFullscreen).map(\.wid))
        let previous=nativeFullscreenWindows
        let previousSuspended=nativeSuspendedSpaces
        var source: [Int:String]=[:]
        for (key,state) in spaces { for leaf in Dwindle.leaves(state.tree) { if let wid=leaf.wid { source[wid]=key } } }
        let retained=Set(source.keys), hiddenIDs=Set(hidden.map(\.wid))
        let managed=retained.union(target.keys).union(newbies.keys).union(optimistic.keys).union(eng.c.wins().map(\.wid))
        var gaps: [Int:Double]=[:]
        for window in windows where retained.contains(window.wid) && window.space == 0 {
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
            if nativeSpaceType == 4 || !owners.isDisjoint(with:returning) || owners.contains(where: { byID[$0]?.space == 0 || byID[$0].map { $0.on && String($0.space)==key } == true }) || peers.contains(where: { String(byID[$0]?.space ?? 0) != key }) { suspended.insert(key) }
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
