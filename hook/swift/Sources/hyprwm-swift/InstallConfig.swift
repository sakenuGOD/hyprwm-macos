import Darwin
import Foundation
import HyprCore

/// Explicit installation entry point, separate from the legacy user-override migration.
func initDefaultConfig(hook: String) throws {
    let directory = hook+"/config", destination = TextConfig.url(configDir:directory)
    guard !FileManager.default.fileExists(atPath:destination.path) else {
        print("Preserved existing configuration: \(destination.path)"); return
    }
    let base = try HyprConfig.load(configDir:directory,rebuild:false,timeScale:1)
    let contents = TextConfig.render(TextConfig.defaults(base:base),configDir:directory)
    try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(".hyprwm-init-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:temporary) }
    try Data(contents.utf8).write(to:temporary,options:.withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
    // link publishes the complete file without replacing a user's concurrent edit.
    guard link(temporary.path,destination.path) == 0 else {
        if errno == EEXIST { print("Preserved existing configuration: \(destination.path)"); return }
        throw CmdError("Could not create configuration: \(String(cString:strerror(errno)))")
    }
    print("Created commented defaults: \(destination.path)")
}
