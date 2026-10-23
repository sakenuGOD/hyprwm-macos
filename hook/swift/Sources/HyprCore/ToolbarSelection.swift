import Foundation

struct ToolbarWindowSelection: Equatable {
    let wid: Int, pid: Int, birth: String, source: String
    var json: JSON { .object([("wid", .int(wid)), ("pid", .int(pid)), ("birth", .string(birth)), ("source", .string(source))]) }
    static func from(_ value: JSON?) -> ToolbarWindowSelection? {
        guard case let .int(wid)? = value?["wid"], wid > 0, wid <= Int(UInt32.max),
              case let .int(pid)? = value?["pid"], pid > 0, pid <= Int(Int32.max),
              let birth = value?["birth"]?.string, !birth.isEmpty, birth.utf8.count <= 128,
              let source = value?["source"]?.string, ["native-focus-history", "wm-space-selection"].contains(source) else { return nil }
        return ToolbarWindowSelection(wid: wid, pid: pid, birth: birth, source: source)
    }
}

extension WM {
    /// Rank only: the bar still proves membership from its native census.
    /// A vertical split visits left first; a horizontal split visits top first.
    func toolbarTilingOrder(_ windows: [WinInfo]) -> JSON {
        guard !sys.sessionLocked() else { return .object([]) }
        let native = Dictionary(windows.map { ($0.wid, $0) }, uniquingKeysWith: { first, _ in first })
        let excluded = Set(hidden.map(\.wid)).union(closing).union(floating)
        var result: [(String, JSON)] = []
        for key in spaces.keys.sorted().prefix(256) {
            guard let sid = Int(key), sid > 0, String(sid) == key, let state = spaces[key] else { continue }
            var rows: [JSON] = []
            for leaf in Dwindle.leaves(state.tree).prefix(512) {
                guard let wid = leaf.wid, !excluded.contains(wid), let window = native[wid],
                      pids[wid].map({ $0 == window.pid }) != false, window.layer == 0,
                      let birth = sys.processBirth(window.pid),
                      sys.winPidLevel(wid).pid == window.pid else { continue }
                if let prior = verifiedMinima[wid], prior.pid != window.pid || prior.birth != birth { continue }
                guard sys.processBirth(window.pid) == birth else { continue }
                rows.append(.object([("wid", .int(wid)), ("pid", .int(window.pid)), ("birth", .string(birth))]))
            }
            if !rows.isEmpty { result.append((key, .array(rows))) }
        }
        return .object(result)
    }

    // Display projection only. An inactive Space need not be activated to resolve
    // its last native focus, or its persisted WM selection when no history exists.
    func toolbarSelectedWindows(_ windows: [WinInfo]) -> JSON {
        guard !sys.sessionLocked() else { return .object([]) }
        let excluded = Set(hidden.map(\.wid)).union(closing)
        var result: [(String, JSON)] = []
        for (key, state) in spaces {
            guard let sid = Int(key), sid > 0 else { continue }
            func candidate(_ wid: Int) -> (WinInfo, String)? {
                guard !excluded.contains(wid),
                      let window = windows.first(where: { $0.wid == wid && $0.space == sid && $0.layer == 0 && !$0.nativeFullscreen && $0.alpha >= 0.05 }),
                      let birth = sys.processBirth(window.pid),
                      sys.winPidLevel(wid).pid == window.pid else { return nil }
                if let prior = nativeFocusedIdentities[wid], prior.pid != window.pid || prior.birth != birth || prior.space != sid { return nil }
                guard sys.processBirth(window.pid) == birth else { return nil }
                return (window, birth)
            }
            var selected: (WinInfo, String)?
            var source = "native-focus-history"
            for wid in focusHistory.reversed() where nativeFocusedIdentities[wid]?.space == sid {
                if let current = candidate(wid) { selected = current; break }
            }
            if selected == nil, let prior = state.toolbarSelection,
               let current = candidate(prior.wid), current.0.pid == prior.pid, current.1 == prior.birth {
                selected = current; source = prior.source
            }
            // Legacy bare WIDs alone do not bind a selection to a process.
            // A current applied frame/minimum witness can bind the WM's tile.
            if selected == nil, let wid = state.focus, state.tree?.contains(wid) == true,
               let current = candidate(wid), pids[wid] == current.0.pid,
               let admitted = verifiedMinima[wid], admitted.pid == current.0.pid, admitted.birth == current.1 {
                selected = current; source = "wm-space-selection"
            }
            guard let (window, birth) = selected else { continue }
            result.append((key, ToolbarWindowSelection(wid: window.wid, pid: window.pid, birth: birth, source: source).json))
        }
        return .object(result)
    }
}
