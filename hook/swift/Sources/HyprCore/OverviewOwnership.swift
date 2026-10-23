import Foundation

extension WM {
    /// Dock owns the visible originals' transform and clipping during overview.
    /// Freezing the daemon alone does not stop frame_win in WindowServer.
    func updateOverviewOwnership(active:Bool) {
        guard options.production else {return}
        guard active else {
            if overviewOwnershipEntered || !overviewReleased.isEmpty {
                overviewRetilePending = overviewRetilePending || !overviewReleased.isEmpty
                overviewOwnershipEntered=false;overviewReleased.removeAll();overviewReleasedIdentity.removeAll()
            }
            return
        }
        guard !overviewOwnershipEntered,!sys.sessionLocked(),
              let snapshot=try? sys.snapshot(),snapshot.stable,!snapshot.locked,snapshot.spaceType==0 else {return}
        let excluded=Set(hidden.map(\.wid)).union(restoring).union(restorePending.keys)
            .union(overviewGrantedWindows?() ?? []).union(closing).union(nativeSuspendedWindows)
        for window in snapshot.windows {
            let wid=window.wid,pid=window.pid
            guard window.space==snapshot.space,window.on,window.layer==0,window.alpha.isFinite,window.alpha>0.05,
                  !window.nativeFullscreen,!excluded.contains(wid),!floating.contains(wid),
                  sp(snapshot.space).tree?.contains(wid)==true,pids[wid]==pid,!sys.protectedProcess(pid),
                  let birth=sys.processBirth(pid),sys.winPidLevel(wid).pid==pid,sys.winPidLevel(wid).level==0,
                  let alpha=sys.winAlpha(wid),alpha.isFinite,alpha>0.05,sys.processBirth(pid)==birth else {continue}
            // cancel() invalidates worker generations before any reply can be
            // admitted. Native10 hidden sources are explicitly excluded above.
            cfgSink?.cancel(wid);cfgQ.removeAll{$0.wid==wid}
            liveBufferShrinks[wid]=nil;snapshotConfigures[wid]=nil;revokeSnapshotLease(wid)
            target[wid]=nil;eng.c.forget(wid);overviewReleased.insert(wid);overviewReleasedIdentity[wid]=(pid,birth)
        }
        if !overviewReleased.isEmpty {eng.c.commit()}
        overviewOwnershipEntered=true
    }

    /// Positive native pre-entry ACK: submission alone is insufficient.
    public var overviewOwnershipConsumed:Bool {overviewOwnershipRefusal==nil}
    /// Same ordered guards as consumption; diagnostics carry no additional authority.
    public var overviewOwnershipRefusal:String? {
        guard enabled else{return "manager-disabled"}
        guard options.production else{return "non-production"}
        guard overviewOwnershipEntered else{return "native-census-not-admitted"}
        guard overviewFrozen?() == true else{return "overview-not-frozen"}
        guard !sys.sessionLocked() else{return "session-locked"}
        guard !eng.c.pending else{return "engine-publication-pending"}
        guard eng.c.stats.nactive==0 else{return "engine-animation-active"}
        guard eng.c.stats.holding==0 else{return "engine-buffer-held"}
        guard cfgSink?.idle != false else{return "configure-worker-not-idle"}
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{$1})
        for wid in overviewReleased {
            guard let identity=overviewReleasedIdentity[wid],sys.winPidLevel(wid).pid==identity.pid,
                  sys.processBirth(identity.pid)==identity.birth else{return "released-owner-or-birth-changed:\(wid)"}
            if let slot=slots[wid],slot.geo != 0 || slot.posActive || slot.sizeActive || slot.alphaActive || slot.held || slot.settling {return "released-geometry-retained:\(wid)"}
        }
        return nil
    }
}
