import Foundation
import HyprCore

/// Main-queue recovery scheduler. App messaging stays on independent AX workers;
/// an unresponsive client cannot block control replies or the recovery deadline.
final class LiteRestorePump {
    let sys: LiteSys
    private let recovered: (Int) -> Void
    private var inFlight = Set<Int>()
    private var inFlightPIDs = Set<Int>()
    private var retryAfter: [Int: Double] = [:]
    private var cursor = 0
    init(sys: LiteSys, recovered: @escaping (Int) -> Void = { _ in }) {
        self.sys = sys; self.recovered = recovered
    }
    /// A rotating 16-record/8ms batch prevents one unresolved lifetime from
    /// starving others. At most two writes can be outstanding across all apps.
    @discardableResult func step() -> Int {
        if sys.recovery.loadError != nil { return max(1, sys.recovery.records.count) }
        guard (try? sys.snapshot()) != nil else { return sys.recovery.records.count }
        let rows = sys.recovery.records.values.sorted { $0.wid < $1.wid }
        guard !rows.isEmpty else { return 0 }
        let began = sys.now()
        var scanned = 0
        while scanned < min(16, rows.count), sys.now()-began < 0.008 {
            let record = rows[(cursor+scanned)%rows.count]; scanned += 1
            if inFlight.contains(record.wid) { continue }
            let owner = sys.winPidLevel(record.wid).pid
            if sys.processExited(record.pid) || sys.processBirth(record.pid).map({ $0 != record.birth }) == true ||
                owner.map({ $0 != record.pid }) == true ||
                sys.ax.confirmedClosed(record.pid, record.wid) && (!sys.applicationHidden(record.pid) || owner == nil) {
                sys.recovery.remove(record.wid); retryAfter[record.wid] = nil
                recovered(record.wid); continue
            }
            guard inFlight.count < 2, !inFlightPIDs.contains(record.pid), sys.now() >= (retryAfter[record.wid] ?? 0),
                  sys.processBirth(record.pid) == record.birth, owner == record.pid,
                  let frame = Rect(record.frame), sys.ax.window(record.pid, record.wid) != nil else { continue }
            inFlight.insert(record.wid); inFlightPIDs.insert(record.pid); retryAfter[record.wid] = sys.now()+0.15
            sys.ax.setFrameAsync(record.pid, record.wid, frame, deadline: sys.now()+0.5) { [weak self] code, actual in
                guard let self else { return }; self.inFlight.remove(record.wid); self.inFlightPIDs.remove(record.pid)
                guard let current = self.sys.recovery.records[record.wid],
                      current.pid == record.pid, current.birth == record.birth, current.frame == record.frame,
                      self.sys.processBirth(record.pid) == record.birth,
                      self.sys.winPidLevel(record.wid).pid == record.pid,
                      code == 0, actual.map({ $0.maxDiff(frame) <= 8 }) == true else { return }
                self.sys.recovery.remove(record.wid); self.retryAfter[record.wid] = nil
                self.sys.concealed.remove(record.wid); self.sys.presentation[record.wid] = nil
                self.recovered(record.wid)
            }
        }
        cursor = (cursor+scanned)%rows.count
        return sys.recovery.records.count
    }
}
