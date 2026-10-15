import Foundation

struct PauseLandingWitness {
    let pid:Int, birth:String, frame:Rect
    var released = false
}

struct EngineRecoveryWork {
    let record: Hidden, frame: Rect, birth: String
    var accepted: Rect?
    var samples = 0
    var sampledAt = 0.0
    var released = false
}

extension WM {
    private func hiddenIntents() throws -> JSON {
        .array(try hidden.map { try $0.intentFingerprint() }.sorted().map(JSON.string))
    }

    /// Only an authenticated handover command arms preservation. No environment bypass.
    func armHiddenHandover() throws {
        let pid = Int(getpid())
        guard let birth = sys.processBirth(pid) else { throw CmdError("handover: daemon birth unavailable") }
        hiddenHandover = .object([("version", .int(1)), ("owner_pid", .int(pid)),
            ("owner_birth", .string(birth)), ("hidden_intents", try hiddenIntents())])
    }

    func recoveryStateSaved() -> Bool {
        guard saveEnabled, let data = FileManager.default.contents(atPath: statePath), data.count <= 4 * 1024 * 1024,
              let state = try? JSON.parse(data) else { return false }
        return state["handover"] == hiddenHandover && state["hidden"] == .array(hidden.map(\.json))
    }

    func disarmHiddenHandover() -> Bool {
        guard let marker = hiddenHandover else { return true }
        hiddenHandover = nil; save()
        if recoveryStateSaved() { return true }
        hiddenHandover = marker
        return false
    }

    /// Call once after options load, before serving commands. A malformed handover is a refusal.
    public func prepareStartupRecovery() throws {
        guard hidden.count <= 1024 else { throw CmdError("recovery: hidden ledger exceeds 1024 records") }
        guard let marker = hiddenHandover else { return }
        guard marker["version"] == .int(1), let pid = marker["owner_pid"]?.int, pid > 1,
              let birth = marker["owner_birth"]?.string, !birth.isEmpty,
              marker["hidden_intents"] == (try hiddenIntents()),
              sys.processExited(pid) || sys.processBirth(pid).map({ $0 != birth }) == true else {
            throw CmdError("recovery: handover identity or hidden ledger changed; state preserved")
        }
        startupKeepHidden = true
    }

    /// Explicit restore-all leaves tiling paused. Startup may resume its configured state after ACK.
    public func requestEngineRecovery(resumeAfter: Bool = false) {
        guard options.production else { return }
        if !resumeAfter { engineRecoveryResume = false }
        pruneCompletedPauseWitnesses()
        guard disarmHiddenHandover() else {
            setEnabled(false); engineRecoveryActive = true; engineRecoveryDeadline = 0
            log("recovery: cannot durably disarm handover; state retained")
            return
        }
        if !engineRecoveryActive {
            setEnabled(false)
            engineRecoveryActive = true
            engineRecoveryResume = resumeAfter
            engineRecoveryDeadline = sys.now() + 8
        } else if sys.now() >= engineRecoveryDeadline {
            for wid in engineRecoveryWork.keys { cfgSink?.cancel(wid) }
            engineRecoveryWork.removeAll()
            engineRecoveryDeadline = sys.now() + 8
            for (wid,witness) in pauseLandingWitnesses where cfgSink?.busy(wid) != true {
                guard sys.processBirth(witness.pid)==witness.birth,sys.winPidLevel(wid).pid==witness.pid,!sys.protectedProcess(witness.pid) else{continue}
                var job=CfgJob(wid:wid,pid:witness.pid,owner:owner[wid] ?? "",to:witness.frame)
                job.birth=witness.birth;job.requireOwnership=true;cfgSink?.submit([job])
            }
        }
        hiddenHandover = nil
        save()
    }

    public func engineRestoreAll() throws -> String {
        requestEngineRecovery()
        pollEngineRecovery()
        if engineRecoveryActive { throw CmdError("Engine restoration pending: \(hidden.count + pauseLandingWitnesses.count); retry restore-all") }
        return "restored all windows"
    }

    /// Runs before the paused return; no delayed hide/re-park closures execute during recovery.
    func pollEngineRecovery() {
        if startupRecoveryPending {
            startupRecoveryPending = false
            let marker = hiddenHandover
            hiddenHandover = nil; save() // one-use handover; never survives a subsequent crash
            if marker != nil && !recoveryStateSaved() {
                hiddenHandover = marker
                engineRecoveryActive = true; engineRecoveryDeadline = 0
                setEnabled(false)
                log("startup recovery: cannot durably consume handover; state retained")
                return
            }
            if !startupKeepHidden { requestEngineRecovery(resumeAfter: enabled) }
        }
        if !enabled {
            let hiddenIDs=Set(hidden.map(\.wid))
            cfgQ.removeAll { !hiddenIDs.contains($0.wid) } // late visible pause ACKs also drain after completion
            pruneCompletedPauseWitnesses()
        }
        guard engineRecoveryActive, !sys.sessionLocked(), !sys.interactionOverlay(),
              overviewFrozen?() != true else { return }
        engineRecoveryWork = engineRecoveryWork.filter { wid, work in hidden.contains(work.record) }
        if hidden.isEmpty && pauseLandingWitnesses.isEmpty && cfgSink?.idle != false && !eng.c.pending && eng.c.stats.holding==0 {
            let resume = engineRecoveryResume
            engineRecoveryActive = false; engineRecoveryWork.removeAll(); cfgQ.removeAll()
            if resume { setEnabled(true) }
            save(); return
        }
        guard sys.now() < engineRecoveryDeadline else { return } // retain rows and paused daemon on timeout
        pollRecoveryPauseLandings()
        guard !hidden.isEmpty else{return}
        let records = hidden, count = records.count, start = engineRecoveryCursor % count
        for offset in 0..<min(8, count) {
            let record = records[(start + offset) % count], wid = record.wid
            guard hiddenRecordLive(record), let pid = record.pid, let birth = sys.processBirth(pid),
                  let frame = Rect(record.rect), Self.recoveryFrame(frame) else { continue }
            if var work = engineRecoveryWork[wid] {
                guard work.record == record, work.birth == birth else {
                    cfgSink?.cancel(wid); engineRecoveryWork[wid] = nil; continue
                }
                if work.accepted == nil {
                    if let reply = cfgQ.first(where: { $0.wid == wid && $0.pid == pid && $0.birth == birth && $0.to == work.frame && $0.isCurrent?() == true }),
                       let actual = PlacementFrameAcceptance.accepted(reply, wid: wid, pid: pid,
                           birth: birth, target: work.frame), Self.recoveryFrame(actual) {
                        work.accepted = actual
                        eng.c.geom(wid, actual, 16, 16, move: true, warp: true)
                        eng.c.alpha(wid, 1, 16, 0); eng.c.commit()
                    }
                } else if let accepted = work.accepted, !eng.c.pending, cfgSink?.busy(wid) != true,
                          let actual = sys.winBounds(wid), actual.maxDiff(accepted) <= TOL,
                          let alpha = sys.winAlpha(wid), alpha >= 0.999,
                          eng.c.wins().first(where: { $0.wid == wid }).map({ !$0.held && !$0.moving }) ?? true {
                    if work.released {
                        hidden.removeAll { $0 == record }
                        cfgSink?.cancel(wid); cfgQ.removeAll { $0.wid == wid }
                        engineRecoveryWork[wid] = nil; save(); continue
                    }
                    if sys.now() - work.sampledAt >= 0.008 { work.samples += 1; work.sampledAt = sys.now() }
                    if work.samples >= 2 { eng.c.forget(wid); eng.c.commit(); work.released = true }
                } else { work.samples = 0 }
                engineRecoveryWork[wid] = work
            } else if engineRecoveryWork.values.filter({ $0.accepted == nil }).count < 2, cfgSink != nil {
                var job = CfgJob(wid: wid, pid: pid, owner: record.owner, to: frame)
                job.birth = birth; job.requireOwnership = true
                engineRecoveryWork[wid] = EngineRecoveryWork(record: record, frame: frame, birth: birth)
                eng.c.geom(wid, frame, 16, 16, move: true, warp: true)
                eng.c.alpha(wid, 1, 16, 0); eng.c.commit()
                cfgSink?.submit([job])
            }
        }
        engineRecoveryCursor = (start + min(8, count)) % count
    }

    private func pruneCompletedPauseWitnesses() {
        guard !enabled,!engineRecoveryActive,!eng.c.pending else{return}
        for (wid,witness) in pauseLandingWitnesses {
            let owner=sys.winPidLevel(wid).pid,current=sys.processBirth(witness.pid)
            if sys.processExited(witness.pid) || current.map({$0 != witness.birth}) == true || owner.map({$0 != witness.pid}) == true {
                pauseLandingWitnesses[wid]=nil;continue
            }
            guard current==witness.birth,owner==witness.pid,!sys.protectedProcess(witness.pid),cfgSink?.busy(wid) != true,
                  let frame=sys.winBounds(wid),Self.recoveryFrame(frame),let alpha=sys.winAlpha(wid),alpha>=0.999 else{continue}
            let slot=eng.c.wins().first{$0.wid==wid}
            // Once ownership is consumed, subsequent manual movement while paused is authoritative.
            if slot==nil || slot.map({$0.geo==0 && !$0.held && !$0.moving}) == true {pauseLandingWitnesses[wid]=nil}
        }
    }

    private func pollRecoveryPauseLandings() {
        for (wid,var witness) in pauseLandingWitnesses {
            let owner=sys.winPidLevel(wid).pid,current=sys.processBirth(witness.pid)
            if sys.processExited(witness.pid) || current.map({$0 != witness.birth}) == true || owner.map({$0 != witness.pid}) == true {
                pauseLandingWitnesses[wid]=nil;continue // positive departure grants no native authority
            }
            guard current==witness.birth,owner==witness.pid,!sys.protectedProcess(witness.pid),!eng.c.pending,cfgSink?.busy(wid) != true,
                  let actual=sys.winBounds(wid),actual.maxDiff(witness.frame)<=TOL,
                  let alpha=sys.winAlpha(wid),alpha>=0.999 else{continue}
            let slot=eng.c.wins().first{$0.wid==wid}
            guard slot.map({!$0.held && !$0.moving}) ?? true else{continue}
            if witness.released || slot==nil {pauseLandingWitnesses[wid]=nil;continue}
            eng.c.forget(wid);eng.c.commit();witness.released=true;pauseLandingWitnesses[wid]=witness
        }
    }

    private static func recoveryFrame(_ frame: Rect) -> Bool {
        frame.arr.allSatisfy(\.isFinite) && frame.w > 0 && frame.h > 0 && frame.w <= 32768 && frame.h <= 32768 &&
            abs(frame.x) <= 1_048_576 && abs(frame.y) <= 1_048_576
    }
}
