import Foundation

public struct LauncherIntent: Equatable {
    public let sequence:UInt64
    public let space, frontPID, kind:Int
    public let started:Double
    public init(sequence:UInt64,space:Int,frontPID:Int,kind:Int,started:Double) {
        self.sequence=sequence;self.space=space;self.frontPID=frontPID;self.kind=kind;self.started=started
    }
}
extension WM {
    func observeLauncher(_ area:Rect,_ space:Int,_ windows:[WinInfo]) {
        launcherAreas[space]=area
        if let value=sys.launcherIntent(after:launcherSequence) {
            launcherSequence=value.sequence
            launcherObserved=value
            launcherIntent=value.kind > 0 && value.space > 0 && launcherAreas[value.space] != nil ? value : nil
            launcherDisposition=launcherIntent != nil ? "awaiting-selection" : "cancelled-or-invalid-origin"
        }
        if let value=launcherIntent, sys.now()-value.started > (value.kind == 1 ? 15 : 3),!launcherTransfers.values.contains(where:{$0.request.sequence==value.sequence && sys.now()<$0.request.deadline}) { consumeLauncher("expired") }
        sys.cacheLauncher(space:space,frontPID:sys.frontPid() ?? 0,windows:windows)
    }
    func consumeLauncher(_ reason:String="completed") {
        if launcherIntent != nil {launcherDisposition=reason}
        if let value=launcherIntent { sys.consumeLauncher(value.sequence) };launcherIntent=nil
    }
    var launcherStatus:JSON {
        .object([("available",.int(sys.launcherAvailable())),
            ("pending_origin",launcherIntent.map{.int($0.space)} ?? .null),
            ("pending_kind",launcherIntent.map{.int($0.kind)} ?? .null),
            ("observed_sequence",.int(Int(launcherSequence))),
            ("observed",launcherObserved.map{.object([("sequence",.int(Int($0.sequence))),
                ("origin",.int($0.space)),("front_pid",.int($0.frontPID)),("kind",.int($0.kind))])} ?? .null),
            ("disposition",.string(launcherDisposition)),
            ("workspace_provider",.bool(workspaceFocus != nil))])
    }
}
