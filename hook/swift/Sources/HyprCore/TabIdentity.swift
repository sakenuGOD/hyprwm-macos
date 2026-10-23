import Foundation

public struct TabProperty {
    public let connection: Int
    public let data: Data
    public init(connection: Int, data: Data) { self.connection = connection; self.data = data }
}
public struct TabFact: Equatable {
    public let pid: Int
    public let birth: String
    public let selected: Int
    public let members: [Int]
}

/// Full coherent passive tab protocol. No geometry or PID similarity can manufacture group membership.
struct TabSnapshot {
    let raw: JSON
    let pid: Int
    let launch: String
    let generation: Int
    let publication: Int
    let sequence: Int
    let revision: Int
    let ready: Bool
    let groups: [(selected: Int, members: [Int])]
    static func parse(_ data: Data) throws -> TabSnapshot {
        guard !data.isEmpty && data.count <= 65536 else { throw CmdError("tab identity byte ceiling") }
        let raw = try JSON.parse(data)
        func integer(_ value: JSON?, _ minimum: Int = 0) throws -> Int {
            guard case let .int(n)? = value, n >= minimum else { throw CmdError("tab identity integer") }; return n
        }
        func wid(_ value: JSON?) throws -> Int {
            guard case let .int(n)? = value, n >= Int(Int32.min), n <= Int(UInt32.max) else { throw CmdError("tab identity WID") }; return n
        }
        func boolean(_ value: JSON?) throws -> Bool {
            guard case let .bool(on)? = value else { throw CmdError("tab identity boolean") }; return on
        }
        guard raw.object != nil, try integer(raw["schema"]) == 1,
              raw["transport"]?.string == "ws-connection-v1", let launch = raw["launch"]?.string,
              !launch.isEmpty, launch.count <= 128 else { throw CmdError("tab identity envelope") }
        let pid = try integer(raw["pid"], 1), generation = try integer(raw["generation"], 1)
        let publication = try integer(raw["publication"], 1), sequence = try integer(raw["seq"])
        let revision = try integer(raw["revision"]), settled = try integer(raw["settled_revision"])
        guard settled <= revision else { throw CmdError("tab identity future revision") }
        let installed = try boolean(raw["installed"]), complete = try boolean(raw["complete"])
        let pending = try boolean(raw["reconcile_pending"])
        _ = try boolean(raw["gap"]); _ = try integer(raw["dropped_events"])
        guard let windows = raw["windows"]?.array, windows.count <= 128,
              let groups = raw["groups"]?.array, groups.count <= 128,
              let events = raw["events"]?.array, events.count <= 32 else { throw CmdError("tab identity array ceiling") }
        var objects: [Int: (wid: Int, group: Int?)] = [:], positive = Set<Int>()
        for window in windows {
            let object = try integer(window["object"], 1), number = try wid(window["wid"])
            guard objects[object] == nil, number <= 0 || positive.insert(number).inserted else { throw CmdError("duplicate tab identity window") }
            let group = window["group"]?.isNull == true ? nil : try integer(window["group"], 1)
            let known = try boolean(window["group_known"]), kvo = try boolean(window["group_kvo"])
            let hidden = window["hidden_tab"]?.isNull == true ? nil : try boolean(window["hidden_tab"])
            if installed && complete && (!known || !kvo || hidden == nil) { throw CmdError("unknown complete tab identity") }
            objects[object] = (number, group)
        }
        var observed: [Int: [(object: Int, wid: Int)]] = [:], facts: [(Int, [Int])] = []
        for group in groups {
            let identity = try integer(group["group"], 1)
            guard observed[identity] == nil, let members = group["members"]?.array, members.count <= 128 else { throw CmdError("tab group ceiling/duplicate") }
            var memberObjects = Set<Int>(), parsed: [(object: Int, wid: Int)] = []
            for member in members {
                let object = try integer(member["object"], 1), number = try wid(member["wid"])
                guard memberObjects.insert(object).inserted else { throw CmdError("duplicate tab group member") }
                if installed && complete {
                    guard let window = objects[object], window.group == identity, window.wid == number else { throw CmdError("incoherent tab group member") }
                }
                parsed.append((object, number))
            }
            let selected = group["selected"]?.isNull == true ? nil : try integer(group["selected"], 1)
            guard selected == nil || memberObjects.contains(selected!) else { throw CmdError("selected tab outside group") }
            let selectedWID = try wid(group["selected_wid"])
            guard selectedWID == (parsed.first(where: { $0.object == selected })?.wid ?? 0) else { throw CmdError("selected tab WID mismatch") }
            let membership = try boolean(group["membership_kvo"]), selection = try boolean(group["selection_kvo"])
            if installed && complete && (!membership || !selection) { throw CmdError("complete tab group lacks observation") }
            observed[identity] = parsed
            facts.append((selectedWID, parsed.map(\.wid).filter { $0 > 0 }))
        }
        if installed && complete {
            for (object, window) in objects {
                if let group = window.group {
                    guard observed[group]?.contains(where: { $0.object == object }) == true else { throw CmdError("missing tab group membership") }
                }
            }
        }
        var previous = 0
        for event in events {
            let seq = try integer(event["seq"], 1)
            guard seq > previous, seq <= sequence, try integer(event["generation"]) == generation else { throw CmdError("tab event replay/generation") }
            previous = seq
        }
        return TabSnapshot(raw: raw, pid: pid, launch: launch, generation: generation, publication: publication,
                           sequence: sequence, revision: revision, ready: installed && complete && !pending && settled == revision, groups: facts)
    }
}

final class TabIdentityReader {
    struct Store {
        let birth: String
        let connection: Int
        let snapshot: TabSnapshot
    }
    var stores: [Int: Store] = [:]
    func read(_ windows: [WinInfo], _ sys: SysAPI) -> [Int: TabFact] {
        var representatives: [Int: Int] = [:]
        for window in windows where window.wid > 0 && window.pid > 0 && !sys.protectedProcess(window.pid) {
            if representatives[window.pid] == nil { representatives[window.pid] = window.wid }
        }
        stores = stores.filter { representatives[$0.key] != nil }
        var facts: [Int: TabFact] = [:]
        for (pid, wid) in representatives {
            guard let birth = sys.processBirth(pid), let property = sys.tabProperty(wid, pid), property.connection > 0,
                  sys.processBirth(pid) == birth, sys.winPidLevel(wid).pid == pid,
                  let snapshot = try? TabSnapshot.parse(property.data), snapshot.pid == pid else { continue }
            if let old = stores[pid], old.birth == birth && old.connection == property.connection {
                let previous = old.snapshot
                guard snapshot.launch == previous.launch else { continue }
                let unchanged = snapshot.raw == previous.raw
                guard unchanged || (snapshot.generation >= previous.generation && snapshot.publication > previous.publication &&
                    (snapshot.generation != previous.generation || (snapshot.sequence >= previous.sequence && snapshot.revision >= previous.revision))) else { continue }
            }
            stores[pid] = Store(birth: birth, connection: property.connection, snapshot: snapshot)
            guard snapshot.ready else { continue }
            for group in snapshot.groups where group.selected > 0 && group.members.count >= 2 {
                for member in group.members {
                    facts[member] = TabFact(pid: pid, birth: birth, selected: group.selected, members: group.members)
                }
            }
        }
        return facts
    }
}
