import Foundation

/// Existing Root-issued allowlist. This loader never grants permission or installs a client module.
public final class ClientPolicy {
    let path: String
    public init(path: String) { self.path=path }
    public func admitted(_ window: WinInfo, _ sys: SysAPI) -> Bool {
        var before=stat(),after=stat()
        guard lstat(path,&before) == 0, before.st_mode&S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_size > 0, before.st_size <= 65536, let data=FileManager.default.contents(atPath:path),
              lstat(path,&after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              let document=try? JSON.parse(data), document["schema"] == .int(1), let generation=document["generation"]?.string,
              !generation.isEmpty, generation.count <= 128, let targets=document["targets"]?.array, !targets.isEmpty, targets.count <= 64 else { return false }
        var seen=Set<Int>(), found: (String,String)?
        for target in targets {
            guard let pid=OverviewBinding.integer(target["pid"]), pid > 0, seen.insert(pid).inserted,
                  let birth=OverviewBinding.integers(target["birth"]), birth.count == 4, birth[0] == pid, birth[1] == Int(getuid()),
                  birth[2] > 0, birth[3] >= 0, birth[3] < 1_000_000, let app=target["app"]?.string,
                  app.hasPrefix("/"), app.hasSuffix(".app") else { return false }
            if pid == window.pid { found=("\(pid):\(birth[2]):\(birth[3])",app) }
        }
        guard let expected=found, sys.processBirth(window.pid) == expected.0, sys.appPath(window.pid) == expected.1,
              sys.processBirth(window.pid) == expected.0, !sys.protectedProcess(window.pid) else { return false }
        return true
    }
}
