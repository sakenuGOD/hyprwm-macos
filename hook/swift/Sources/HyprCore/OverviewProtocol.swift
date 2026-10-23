import CryptoKit
import Foundation

public enum OverviewNativeMode {
    /// UINT64_MAX means the read failed, rather than a native overview mode.
    public static func active(_ raw:UInt64) -> Bool {raw != 0 && raw != UInt64.max}
}

/// Authenticated controller state survives gaps between slower socket reads.
/// Missing/unknown service evidence expires; a fresh actual exit clears at once.
public struct OverviewActivityFence {
    private var authenticatedActive=false
    private var sampledAt:Double?
    public init() {}
    public mutating func observe(_ snapshot:JSON,time:Double) {
        guard time.isFinite,snapshot["controller_observed"] == .bool(true),
              case let .int(mode)?=snapshot["mode"],mode>=0,
              case let .int(raw)?=snapshot["raw_mode"],raw>=0,
              case let .bool(active)?=snapshot["overview_active"] else{return}
        authenticatedActive=mode != 0 || raw != 0 || active;sampledAt=time
    }
    public func active(raw:UInt64,time:Double) -> Bool {
        if OverviewNativeMode.active(raw) {return true}
        guard authenticatedActive,let sampledAt,time.isFinite,time>=sampledAt else{return false}
        return time-sampledAt<=0.3
    }
    public mutating func reset() {authenticatedActive=false;sampledAt=nil}
}

extension Hidden {
    /// Matches the sealed ledger verifier: sorted compact ASCII JSON of the FULL row.
    func intentFingerprint() throws -> String {
        func compact(_ value:JSON) throws -> String {
            switch value {
            case let .object(pairs):return "{" + (try pairs.sorted{$0.0<$1.0}.map{JSON.quote($0.0,ascii:true)+":"+(try compact($0.1))}).joined(separator:",") + "}"
            case let .array(values):return "[" + (try values.map(compact)).joined(separator:",") + "]"
            case let .double(number):guard number.isFinite else{throw CmdError("finite hidden ledger required")};return pyFloat(number)
            default:return value.dumps(ensureASCII:true)
            }
        }
        let bytes=Data(try compact(json).utf8)
        guard !bytes.isEmpty,bytes.count<=8192 else{throw CmdError("bounded hidden ledger authority required")}
        return SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
    }
}

public struct OverviewBinding: Equatable {
    public let pid: Int
    public let birth: [Int]
    public let path, nonce, endpoint, imagePath, imageUUID: String
    public init(_ document: JSON) throws {
        guard document["schema"] == .int(1), let actor=document["actor"], let pid=Self.integer(actor["pid"]),
              let birth=Self.integers(actor["birth"]), birth.count == 4, birth[0] == pid, pid > 0,
              birth[1] == Int(getuid()), birth[2] > 0, birth[3] >= 0, birth[3] < 1_000_000,
              let path=actor["path"]?.string, path == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
              let nonce=document["nonce"]?.string, Self.hex(nonce,32), let endpoint=document["endpoint"]?.string,
              endpoint.hasPrefix("/private/tmp/re-tools-overview10-\(getuid())-\(nonce)/"), endpoint.utf8.count < 104,
              endpoint == URL(string:endpoint)?.standardized.path,
              URL(fileURLWithPath:endpoint).deletingLastPathComponent().path == "/private/tmp/re-tools-overview10-\(getuid())-\(nonce)",
              let image=document["image"], let imagePath=image["path"]?.string, imagePath.hasPrefix("/"),
              let imageUUID=image["uuid"]?.string, Self.hex(imageUUID,32) else { throw CmdError("overview10: invalid Root binding") }
        self.pid=pid;self.birth=birth;self.path=path;self.nonce=nonce;self.endpoint=endpoint;self.imagePath=imagePath;self.imageUUID=imageUUID
    }
    public static func integer(_ value: JSON?) -> Int? { if case let .int(number)?=value { return number }; return nil }
    static func integers(_ value: JSON?) -> [Int]? {
        guard let array=value?.array else { return nil }; let values=array.compactMap { integer($0) }; return values.count == array.count ? values : nil
    }
    static func hex(_ value: String, _ count: Int) -> Bool { value.count == count && value.allSatisfy { "0123456789abcdef".contains($0) } }
    public var generation: JSON { .array(birth.map(JSON.int)) }
    /// Selected only inside the already authenticated exact image binding.
    /// Source10's strict configure schema must retain its three-field payload.
    public var supportsEntryBarrier:Bool {
        ["libhypr-overview-pool10-v11.dylib","libhypr-overview-pool10-v12.dylib","libhypr-overview-pool10-v13.dylib","libhypr-overview-pool10-v14.dylib"].contains(URL(fileURLWithPath:imagePath).lastPathComponent)
    }
    public var supportsOrdinaryPreentry:Bool {["libhypr-overview-pool10-v13.dylib","libhypr-overview-pool10-v14.dylib"].contains(URL(fileURLWithPath:imagePath).lastPathComponent)}
    public var processBirth: String { "\(pid):\(birth[2]):\(birth[3])" }
    public func request(_ operation: String, sequence: Int, payload: JSON) throws -> JSON {
        guard ["hello","info","result","configure","snapshot","renew","ack-selection","disable"].contains(operation), sequence > 0, sequence <= 9_007_199_254_740_991, payload.object != nil else { throw CmdError("overview10: invalid request") }
        let result=JSON.object([("schema",.int(1)),("nonce",.string(nonce)),("generation",generation),
            ("seq",.int(sequence)),("issued_us",.int(Int(Date().timeIntervalSince1970*1_000_000))),
            ("operation",.string(operation)),("payload",payload)])
        guard result.dumps().utf8.count <= 65536 else { throw CmdError("overview10: request exceeds 64 KiB") }; return result
    }
    public func response(_ reply: JSON, sequence: Int, operation: String) throws -> JSON {
        guard reply["schema"] == .int(1), reply["nonce"]?.string == nonce, reply["generation"] == generation,
              reply["request_seq"] == .int(sequence), reply["operation"]?.string == operation,
              case let .bool(completed)?=reply["completed"], case let .bool(pending)?=reply["pending"],
              case let .bool(main)?=reply["main_evaluated"], !(completed && pending), reply["refused"]?.truthy != true else { throw CmdError("overview10: unauthenticated or refused response") }
        if operation == "hello" || operation == "info" {
            guard completed && !pending && !main, let info=reply["service_info"], info["state"] == .int(2),
                  info["endpoint"]?.string == endpoint, info["image_path"]?.string == imagePath,
                  info["image_uuid"]?.string == imageUUID, info["request_byte_limit"] == .int(65536),
                  info["response_byte_limit"] == .int(262144), info["native_completion_proven"] == .bool(false) else { throw CmdError("overview10: listening service attestation mismatch") }
            guard let latest=Self.integer(info["latest_request_seq"]), latest >= 0, latest <= 9_007_199_254_740_991,
                  let mutation=Self.integer(info["latest_mutation_seq"]), mutation >= 0, mutation <= latest else { throw CmdError("overview10: service lacks read sequence freshness fence") }
        } else if completed {
            guard main, reply["result"]?.object != nil, reply["result"]?["native_completion_proven"] == .bool(false) else { throw CmdError("overview10: completed transport lacks main result") }
        }
        return reply
    }
}

public struct OverviewHidden: Equatable {
    public let wid, pid: Int
    public let birth: [Int]
    public let intent: String
    public let parked: Rect
    public let spaces: [Int]
    public let savedVisible:Rect?
    public init(record: Hidden, parked: Rect, space: Int, birth: [Int]) throws {
        guard birth.count == 4, birth[0] == record.pid, record.wid > 0, space > 0,
              parked.arr.allSatisfy(\.isFinite), parked.w > 0, parked.h > 0 else { throw CmdError("overview10: invalid hidden source") }
        self.wid=record.wid;self.pid=record.pid!;self.birth=birth;self.parked=parked;self.spaces=[space]
        self.savedVisible=Rect(record.rect)
        intent=try record.intentFingerprint()
    }
    public var json: JSON { .object([("window",.object([("wid",.int(wid)),("pid",.int(pid)),("birth",.array(birth.map(JSON.int)))])),
        ("parked_bounds",parked.json),("spaces",.array(spaces.map(JSON.int))),("hidden_intent",.string(intent))]) }

    public func ordinaryVisibleBounds(display:Rect) -> Rect? {
        guard let original=savedVisible,original.arr.allSatisfy(\.isFinite),display.arr.allSatisfy(\.isFinite),
              parked.w>0,parked.h>0,parked.w<=display.w,parked.h<=display.h else{return nil}
        return Rect(floor(min(max(original.x,display.x),display.x+display.w-parked.w)),
                    floor(min(max(original.y,display.y),display.y+display.h-parked.h)),parked.w,parked.h)
    }
}

/// A transient desired pool is not authority for a retained native commit.
/// Replace accepted scope only after its exact configure response succeeds.
public struct OverviewConfiguredPool {
    public private(set) var records:[OverviewHidden]=[]
    public var pendingRecords:[OverviewHidden]?
    public init() {}
    public mutating func confirm(_ reply:JSON) throws {
        guard OverviewProtocol.succeeded(reply,operation:"configure"),let pendingRecords else {throw CmdError("overview10: configured pool authority unconfirmed")}
        records=pendingRecords;self.pendingRecords=nil
    }
    public func canAcknowledgeEmpty(hiddenWindowsEnabled:Bool,attested:Bool,pending:Bool,configured:Bool,desired:[OverviewHidden]) -> Bool {
        !hiddenWindowsEnabled && attested && !pending && configured && records.isEmpty && pendingRecords==nil && desired.isEmpty
    }
    public mutating func reset() {records=[];pendingRecords=nil}
}

public struct OverviewSelection: Equatable {
    public let wid, pid: Int
    public let birth: [Int]
    public let intent, token: String
    public var acknowledge: JSON { .object([("commit_token",.string(token)),("wid",.int(wid)),("birth",.array(birth.map(JSON.int))),("hidden_intent",.string(intent))]) }
}

public enum OverviewProtocol {
    /// The service cancels only a queued callback; a started or unknown request remains pending.
    /// Validate the original operation/sequence envelope even when recovering via `result`.
    public static func canceledBeforeMain(_ reply:JSON,binding:OverviewBinding,sequence:Int,operation:String) -> Bool {
        guard sequence>0,["snapshot","configure","renew","ack-selection","disable"].contains(operation),
              let value=try? binding.response(reply,sequence:sequence,operation:operation),
              value["completed"] == .bool(false),value["pending"] == .bool(false),
              value["main_evaluated"] == .bool(false),value["result"] == nil else{return false}
        switch value["canceled"] {
        case .bool(true)?,.int(1)?:return true // Objective-C atomic C-int boxing emits integer 1.
        default:return false
        }
    }

    /// Native pool handler returns 0 for a read, 1 for accepted mutations.
    /// Transport completion never substitutes for native handler success.
    public static func requiresEmptyBootstrap(_ reply:JSON,hasConfiguredScope:Bool,rawMode:UInt64,locked:Bool,pending:Bool) -> Bool {
        succeeded(reply,operation:"snapshot") && reply["result"]?["snapshot"] == .null &&
            !hasConfiguredScope && rawMode==0 && !locked && !pending
    }
    public static func succeeded(_ reply:JSON,operation:String) -> Bool {
        let code:Int
        switch operation {
        case "snapshot":code=0
        case "configure","renew","ack-selection","disable":code=1
        default:return false
        }
        guard case let .int(actual)?=reply["result"]?["code"],actual==code else{return false}
        return reply["operation"] == .string(operation) && reply["completed"] == .bool(true) &&
            reply["pending"] == .bool(false) && reply["main_evaluated"] == .bool(true) &&
            reply["result"]?["native_completion_proven"] == .bool(false)
    }

    /// Retained commits from a replaced pool have no authority in its successor.
    /// Preserve them without fabricating an ACK or blocking future configuration.
    public static func hasCurrentPoolCommits(_ snapshot:JSON) -> Bool {
        guard let pool=OverviewBinding.integer(snapshot["pool_generation"]),pool>0,
              let commits=snapshot["commits"]?.array,commits.count<=64 else{return true}
        for commit in commits {
            guard let generation=OverviewBinding.integer(commit["pool_generation"]),generation>0 else{return true}
            if generation==pool{return true}
            if generation>pool{return true} // An impossible future generation is not evidence of an empty current pool.
        }
        return false
    }

    public static func selections(snapshot: JSON, binding: OverviewBinding, hidden: [OverviewHidden]) throws -> [OverviewSelection] {
        guard snapshot["controller_observed"] == .bool(true), snapshot["mode"] == .int(0), snapshot["raw_mode"] == .int(0), snapshot["overview_active"] == .bool(false),
              let pool=OverviewBinding.integer(snapshot["pool_generation"]), pool > 0,
              let commits=snapshot["commits"]?.array, commits.count <= 64 else { return [] }
        var output: [OverviewSelection]=[], seen=Set<String>()
        for commit in commits {
            guard commit["nonce"]?.string == binding.nonce, commit["pool_generation"] == .int(pool),
                  commit["setup_observed"] == .bool(true), commit["end_order_observed"] == .bool(true),
                  commit["root_cancel_requested"] == .bool(false), commit["inverse_park_observed"] == .bool(true),
                  let token=commit["commit_token"]?.string, OverviewBinding.hex(token,32), seen.insert(token).inserted,
                  let wid=OverviewBinding.integer(commit["wid"]), let pid=OverviewBinding.integer(commit["pid"]), let birth=OverviewBinding.integers(commit["birth"]),
                  let intent=commit["hidden_intent"]?.string,
                  let epoch=OverviewBinding.integer(commit["epoch"]), epoch > 0,
                  hidden.contains(where: { $0.wid == wid && $0.pid == pid && $0.birth == birth && $0.intent == intent }) else { continue }
            output.append(OverviewSelection(wid:wid,pid:pid,birth:birth,intent:intent,token:token))
        }
        return output
    }
}


extension WM {
    public func overviewDesiredPool() -> [OverviewHidden]? {
        let expected=hidden.filter{hiddenRecordLive($0) && restorePending[$0.wid]==nil}.count
        let records=overviewRecords()
        return records.count==expected ? records:nil
    }
    public func overviewRecords() -> [OverviewHidden] {
        guard let last, !sys.sessionLocked(), nativeSpaceType == 0 else { return [] }
        let slots=Dictionary(eng.c.wins().map{($0.wid,$0)},uniquingKeysWith:{first,_ in first})
        var released=false,geometryPending=false
        let records:[OverviewHidden]=hidden.compactMap { record in
            guard hiddenRecordLive(record),restorePending[record.wid]==nil else{return nil}
            if slots[record.wid]?.geo != 0,slots[record.wid] != nil {geometryPending=true}
            cfgSink?.cancel(record.wid)
            guard let pid=record.pid,let current=sys.processBirth(pid),let bounds=sys.winBounds(record.wid),
                  hiddenParkSettled(record,bounds) else{return nil}
            if let slot=slots[record.wid],slot.geo != 0 {
                guard !eng.c.pending,!slot.posActive,!slot.sizeActive,!slot.alphaActive,!slot.held,hiddenRecordLive(record) else{return nil}
                // The app may clamp after retained native geometry is released.
                // Only new samples after consumption can authorize the pool.
                hiddenParkSamples[record.wid]=nil
                eng.c.forget(record.wid);eng.c.alpha(record.wid,0,16,0,frm:0);released=true
                return nil
            }
            let pieces=current.split(separator:":").compactMap { Int($0) }
            guard pieces.count == 3, pieces[0] == pid else { return nil }
            let birth=[pid,Int(getuid()),pieces[1],pieces[2]]
            let source=last.wins.first(where: { $0.wid == record.wid })?.space ?? record.space ?? 0
            return try? OverviewHidden(record:record,parked:bounds,space:source,birth:birth)
        }
        if released {eng.c.commit()}
        if geometryPending {return []} // Whole pool waits until every exact hidden geometry ownership is drained.
        return records
    }
    public func restoreOverviewSelection(_ selection: OverviewSelection) {
        guard let last, let record=hidden.first(where: { $0.wid == selection.wid && $0.pid == selection.pid }),
              hiddenRecordLive(record), sys.processBirth(selection.pid) == "\(selection.pid):\(selection.birth[2]):\(selection.birth[3])" else { return }
        guard let digest=try? record.intentFingerprint(),digest == selection.intent, !sys.sessionLocked(), nativeSpaceType == 0 else { return }
        _=unhide(last.area,last.space,last.wins,which:.wids([selection.wid]))
    }
}
