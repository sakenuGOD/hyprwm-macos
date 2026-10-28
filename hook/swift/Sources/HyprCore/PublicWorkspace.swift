import Foundation

public enum PublicWorkspacePermission {
    public static func validate(_ proof:JSON,manager:JSON,imageHash:String,generation:JSON) throws {
        let v2=proof["schema"] == .int(2)
        let flags=["acknowledged","independent_ack","manager_ack","returned_original"]
        let empty=v2 ? proof["manager_empty_ordinary_space_ack"] == .bool(true) && proof["ordinary_scope"] == .string("native-layer0-application-windows") && proof["shell_exclusions_complete"] == .bool(true) && proof["manager_runtime"] == .string("swift") && proof["manager_image"]?["sha256"] == .string(imageHash) : proof["manager_empty_space_ack"] == .bool(true)
        guard proof["backend"] == .string("public-Mission-Control-AX"),flags.allSatisfy({proof[$0] == .bool(true)}),
              empty,
              PublicWorkspaceCatalog.identity(proof["manager_identity"]),proof["manager_identity"]==manager,
              proof["manager_image_sha"] == .string(imageHash),proof["generation"]==generation,
              let parts=proof["generation"]?.array,parts.count==4,
              parts[0].string != nil,parts[1].string != nil,
              PublicWorkspaceCatalog.identity(parts[2]),PublicWorkspaceCatalog.identity(parts[3]) else {
            throw CmdError("separate reviewed Swift manager/image/session/empty-Space/return permission required")
        }
    }
}

public struct PublicWorkspaceSpace:Equatable {
    public let sid:Int,kind:Int
    public let uuid:String
    public var json:JSON { .object([("sid",.int(sid)),("uuid",.string(uuid)),("type",.int(kind))]) }
}
public struct PublicWorkspaceCatalog:Equatable {
    public let generation:JSON,observer:JSON
    public let display:String
    public let spaces:[PublicWorkspaceSpace]
    public let active:Int
    public let ordinaryWitness:JSON
    public static func identity(_ value:JSON?) -> Bool {
        guard let row=value?.array,row.count==5,let pid=OverviewBinding.integer(row[0]),pid>0,
              let uid=OverviewBinding.integer(row[1]),uid>=0,let sec=OverviewBinding.integer(row[2]),sec>0,
              let usec=OverviewBinding.integer(row[3]),(0..<1_000_000).contains(usec),
              let path=row[4].string,path.hasPrefix("/"),!path.contains("\0"),path.utf8.count<=4096 else { return false }
        return true
    }
    public init(_ raw:JSON) throws {
        guard raw["mode"] == .string("native-diagnostic"),raw["setter_called"] == .bool(false),
              raw["locked"] == .bool(false),raw["consistent"] == .bool(true),
              let generation=raw["generation"],let generations=generation.array,generations.count==4,
              generations[0].string != nil,generations[1].string != nil,
              Self.identity(generations[2]),Self.identity(generations[3]),Self.identity(raw["observer_identity"]),
              let displays=raw["displays"]?.array,displays.count==1,
              let identifier=displays[0]["display"]?.string,UUID(uuidString:identifier) != nil,
              let active=OverviewBinding.integer(raw["active_before"]),active>0,active<1<<53,
              OverviewBinding.integer(raw["active_after"])==active,
              OverviewBinding.integer(displays[0]["current_catalog"])==active,
              OverviewBinding.integer(displays[0]["current_getter"])==active,
              let rows=displays[0]["spaces"]?.array,!rows.isEmpty,rows.count<=64 else {
            throw CmdError("stable single-display native workspace identity required")
        }
        var spaces:[PublicWorkspaceSpace]=[],ids=Set<Int>()
        for row in rows {
            guard let sid=OverviewBinding.integer(row["sid"]),sid>0,sid<1<<53,ids.insert(sid).inserted,
                  let kind=OverviewBinding.integer(row["type"]),let uuid=row["uuid"]?.string,
                  uuid.utf8.count<=128,!uuid.contains("\0") else { throw CmdError("bounded unique native Space required") }
            spaces.append(PublicWorkspaceSpace(sid:sid,kind:kind,uuid:uuid))
        }
        guard spaces.contains(where:{$0.sid==active&&$0.kind==0}) else { throw CmdError("ordinary current Space required") }
        self.generation=generation;self.observer=raw["observer_identity"]!;self.display=identifier;self.spaces=spaces;self.active=active;self.ordinaryWitness=raw
    }
    public func sameSession(_ other:Self) -> Bool { generation==other.generation&&display==other.display&&spaces==other.spaces }
    /// A split native read during the already-dispatched transition is not an ACK.
    /// Only the unchanged, unlocked session/topology may be observed again.
    public static func duringTransition(_ raw:JSON,from before:Self) throws -> Self? {
        guard raw["consistent"] == .bool(false) else{return try Self(raw)}
        guard raw["mode"] == .string("native-diagnostic"),raw["setter_called"] == .bool(false),raw["locked"] == .bool(false),
              raw["generation"]==before.generation,Self.identity(raw["observer_identity"]),
              let displays=raw["displays"]?.array,displays.count==1,displays[0]["display"] == .string(before.display),
              displays[0]["spaces"] == .array(before.spaces.map(\.json)) else{throw CmdError("unstable workspace session/topology differs")}
        let readings=[raw["active_before"],raw["active_after"],displays[0]["current_catalog"],displays[0]["current_getter"]]
        let ordinary=Set(before.spaces.filter{$0.kind==0}.map(\.sid))
        let ids=readings.compactMap{OverviewBinding.integer($0)}
        // The independent observer also marks a composite read inconsistent
        // when its earlier census disagreed, even if the final getters converge.
        guard ids.count==readings.count,ids.allSatisfy({ordinary.contains($0)}) else{throw CmdError("bounded native transition readings required")}
        return nil
    }
    public func appendedOrdinary(_ after:Self) throws -> PublicWorkspaceSpace {
        guard generation==after.generation,display==after.display,active==after.active,
              after.spaces.count==spaces.count+1,Array(after.spaces.dropLast())==spaces,
              let added=after.spaces.last,added.kind==0,!added.uuid.isEmpty,
              !spaces.contains(where:{$0.sid==added.sid || $0.uuid==added.uuid}) else {
            throw CmdError("one unique appended ordinary Space with original identities/current preserved required")
        }
        _=try after.target(added.sid);return added
    }
    public func target(_ sid:Int) throws -> PublicWorkspaceSpace {
        let ordinary=spaces.filter{$0.kind==0}
        guard let index=ordinary.firstIndex(where:{$0.sid==sid}),index<10 else { throw CmdError("existing ordinary Space ordinal1..10 required") }
        return ordinary[index]
    }
    public func ordinal(_ sid:Int) throws -> Int { _=try target(sid);return spaces.filter{$0.kind==0}.firstIndex(where:{$0.sid==sid})!+1 }
    public var dock:JSON {
        let row=generation.array![3].array!
        return .object([("pid",row[0]),("uid",row[1]),("start_sec",row[2]),("start_usec",row[3]),("path",row[4])])
    }
    public var publicSnapshot:JSON {
        .object([("active",.int(active)),("displays",.array([.object([("display",.string(display)),("current",.int(active)),
            ("spaces",.array(spaces.map{.object([("id64",.int($0.sid)),("ManagedSpaceID",.int($0.sid)),("type",.int($0.kind)),("uuid",.string($0.uuid))])}))])]))])
    }
    public func request(_ sid:Int) throws -> JSON {
        let target=try target(sid)
        return .object([("dock",dock),("snapshot",publicSnapshot),("target",.object([("display",.string(display)),("sid",.int(sid)),("uuid",.string(target.uuid)),("type",.int(0))]))])
    }
    public func matchesPublicSnapshot(_ value:JSON?) -> Bool {
        guard let value,OverviewBinding.integer(value["active"])==active,
              let displays=value["displays"]?.array,displays.count==1,
              displays[0]["display"] == .string(display),OverviewBinding.integer(displays[0]["current"])==active,
              let rows=displays[0]["spaces"]?.array,rows.count==spaces.count else{return false}
        for (row,space) in zip(rows,spaces) {
            guard OverviewBinding.integer(row["id64"] ?? row["ManagedSpaceID"])==space.sid,
                  row["ManagedSpaceID"].map({OverviewBinding.integer($0)==space.sid}) ?? true,
                  row["uuid"] ?? row["UUID"] == .string(space.uuid),
                  row["UUID"].map({$0 == .string(space.uuid)}) ?? true,
                  OverviewBinding.integer(row["type"])==space.kind else{return false}
        }
        return true
    }
}

/// Independent + actual fresh manager witnesses. Helper AX success is never an ACK.
public struct PublicWorkspaceACK {
    public let before:PublicWorkspaceCatalog,target:PublicWorkspaceSpace,managerIdentity:JSON
    private var managerSequence:Int?
    private var managerTimes:[Double]=[],independentTimes:[Double]=[]
    private var observers:[JSON]=[]
    private let ordinaryRequired:Bool
    public init(before:PublicWorkspaceCatalog,sid:Int,managerIdentity:JSON,ordinaryRequired:Bool=false) throws {
        self.before=before;self.target=try before.target(sid);self.managerIdentity=managerIdentity
        self.ordinaryRequired=ordinaryRequired
    }
    public mutating func observeManager(_ raw:JSON,time:Double) {
        guard time.isFinite,let sequence=OverviewBinding.integer(raw["sample_sequence"]),sequence>0 else { managerTimes=[];return }
        if sequence==managerSequence { return }
        if let old=managerSequence,sequence<old { managerTimes=[];return }
        managerSequence=sequence
        let rows=raw["workspace_native"]?.array ?? []
        guard raw["stable"] == .bool(true) || raw["stable"] == .int(1) else { managerTimes=[];return }
        guard OverviewBinding.integer(raw["space"])==target.sid,OverviewBinding.integer(raw["space_type"])==0,
              rows.count==1,rows[0]["display"] == .string(before.display),
              OverviewBinding.integer(rows[0]["sid"])==target.sid,rows[0]["uuid"] == .string(target.uuid),
              OverviewBinding.integer(rows[0]["type"])==0,
              let count=OverviewBinding.integer(raw["native_current_window_count"]),count>=0 else { managerTimes=[];return }
        if ordinaryRequired && !OrdinaryWorkspaceWitness.validate(raw,space:target.sid) {managerTimes=[];return}
        if let last=managerTimes.last,time<=last { managerTimes=[];return }
        managerTimes.append(time)
        // Retain the start of this uninterrupted valid run. A rolling suffix
        // can never span 150ms when fresh samples arrive faster than 100Hz.
        if managerTimes.count>16 {managerTimes.remove(at:1)}
    }
    public mutating func resetTransitionSamples(){managerTimes=[];independentTimes=[]}
    public mutating func observeIndependent(_ catalog:PublicWorkspaceCatalog,time:Double) throws {
        guard catalog.sameSession(before),catalog.observer != managerIdentity else { throw CmdError("independent native session/observer identity differs") }
        guard catalog.active==target.sid else { independentTimes=[];return }
        guard !ordinaryRequired || OrdinaryWorkspaceWitness.validate(catalog.ordinaryWitness,space:target.sid) else {throw CmdError("complete desktop window information required")}
        guard !observers.contains(catalog.observer),time.isFinite,
              independentTimes.last.map({time>$0}) ?? true else { throw CmdError("observer process identity or time was reused") }
        observers.append(catalog.observer);independentTimes.append(time)
        if independentTimes.count>16 {independentTimes.remove(at:1)}
    }
    public var acknowledged:Bool {
        managerTimes.count>=3 && independentTimes.count>=3 && managerTimes.last!-managerTimes.first!>=0.15 &&
            independentTimes.last!-independentTimes.first!>=0.15
    }
    public var status:JSON { .object([("acknowledged",.bool(acknowledged)),("manager_samples",.int(managerTimes.count)),("independent_samples",.int(independentTimes.count))]) }
}
