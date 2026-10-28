import Darwin
import Foundation
import HyprCore

/// Installation location only. Native attachment and startup qualification remain separate.
struct EngineStateLocation {
    let path, source: String

    static func resolve(hook: String) throws -> EngineStateLocation {
        let environment=ProcessInfo.processInfo.environment
        if let path=environment["HYPRWM_ENGINE_STATE"] {
            return try location(path,source:"environment")
        }
        if Bundle.main.bundleIdentifier=="dev.hyprwm.HyprWM",
           let receipt=Bundle.main.resourceURL?.appendingPathComponent("InstallReceipt.json") {
            var info=stat()
            if lstat(receipt.path,&info)==0 {
                let text=try readText(receipt.path,limit:262144)
                guard let data=text.data(using:.utf8),
                      let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],
                      object["installer"] as? String=="hyprwm-user-install-v1" else {
                    throw CmdError("Unrecognized application installation state file")
                }
                if let value=object["engine_state_path"] {
                    guard let path=value as? String else {throw CmdError("Invalid engine_state_path in installation state file")}
                    return try location(path,source:"installation")
                }
            } else if errno != ENOENT {
                throw CmdError("Application installation state file unavailable")
            }
        }
        return try location(URL(fileURLWithPath:hook).appendingPathComponent("anim4.state").path,source:"hook")
    }

    private static func location(_ path:String,source:String) throws -> EngineStateLocation {
        guard path.hasPrefix("/"),path.utf8.count<=4096,!path.utf8.contains(0) else {
            throw CmdError("Engine state path must be absolute; use HYPRWM_ENGINE_STATE or install --engine-state FILE")
        }
        return EngineStateLocation(path:path,source:source)
    }

    func read() throws -> String {try Self.readText(path,limit:4096)}

    private static func readText(_ path:String,limit:Int) throws -> String {
        let fd=open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw CmdError("Engine state file unavailable: \(path); select an existing engine state file with --engine-state FILE")}
        defer{close(fd)}
        var before=stat()
        guard fstat(fd,&before)==0,before.st_mode&S_IFMT==S_IFREG,
              before.st_uid==getuid() || before.st_uid==0,
              before.st_mode&0o022==0,before.st_nlink==1,before.st_size>0,before.st_size<=off_t(limit) else {
            throw CmdError("Engine state must be a small regular file owned by you or root, with no shared write access")
        }
        var bytes=[UInt8](repeating:0,count:Int(before.st_size)),used=0
        while used<bytes.count {
            let count=bytes.withUnsafeMutableBytes{Darwin.read(fd,$0.baseAddress!.advanced(by:used),$0.count-used)}
            if count<0 && errno==EINTR {continue}
            guard count>0 else {throw CmdError("Engine state file changed while reading")}
            used+=count
        }
        var after=stat()
        guard fstat(fd,&after)==0,before.st_dev==after.st_dev,before.st_ino==after.st_ino,
              before.st_size==after.st_size,before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec,
              let text=String(bytes:bytes,encoding:.utf8),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw CmdError("Engine state file changed or is not valid UTF-8")
        }
        return text
    }
}
