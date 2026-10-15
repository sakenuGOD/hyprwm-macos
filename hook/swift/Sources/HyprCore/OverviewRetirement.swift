import Foundation

public enum OverviewRetirement {
    /// Geometry-ready grants can temporarily be empty. Only the independent,
    /// complete hidden-intent ledger can withdraw an outstanding commit.
    public static func permitted(_ snapshot:JSON,nonce:String,liveIntents:Set<String>?) -> Bool {
        guard let liveIntents,snapshot["nonce"] == .string(nonce),
              snapshot["controller_observed"] == .bool(true),snapshot["mode"] == .int(0),
              snapshot["raw_mode"] == .int(0),snapshot["overview_active"] == .bool(false),
              let pool=OverviewBinding.integer(snapshot["pool_generation"]),pool>0,
              let commits=snapshot["commits"]?.array,commits.count<=64 else{return false}
        var withdrawn=false
        for commit in commits {
            guard let generation=OverviewBinding.integer(commit["pool_generation"]),generation>0,generation<=pool else{return false}
            if generation != pool {continue}
            guard commit["nonce"] == .string(nonce),let intent=commit["hidden_intent"]?.string,
                  OverviewBinding.hex(intent,64),!liveIntents.contains(intent) else{return false}
            withdrawn=true
        }
        return withdrawn
    }
}
extension WM {
    public func overviewHiddenIntents() -> Set<String>? {
        guard enabled,!sys.sessionLocked(),nativeSpaceType==0 else{return nil}
        var result=Set<String>()
        for record in hidden {
            guard let value=try? record.intentFingerprint() else{return nil}
            result.insert(value)
        }
        return result
    }
}
