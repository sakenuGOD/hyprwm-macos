import Darwin
import Foundation
import HyprCore

/// Cross-process kernel birth/path evidence; no AX or window mutations.
enum OrdinaryWorkspace {
    static let scope="native-layer0-application-windows"
    private static func object(_ path:String,maximum:Int=262144) -> [String:Any]? {
        var info=stat()
        guard lstat(path,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_size>0,info.st_size<=maximum,
              let bytes=try? Data(contentsOf:URL(fileURLWithPath:path)),bytes.count<=maximum else{return nil}
        if path.hasSuffix(".plist") {return (try? PropertyListSerialization.propertyList(from:bytes,format:nil)) as? [String:Any]}
        return (try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any]
    }
    private static func argv(_ pid:Int) -> [String]? {
        guard pid>0,pid<=Int(Int32.max) else{return nil}
        var mib:[Int32]=[CTL_KERN,KERN_PROCARGS2,Int32(pid)]
        var bytes=[UInt8](repeating:0,count:262144),size=bytes.count
        let code=mib.withUnsafeMutableBufferPointer { keys in
            bytes.withUnsafeMutableBytes { buffer in sysctl(keys.baseAddress,3,buffer.baseAddress,&size,nil,0) }
        }
        guard code==0,size>=5,size<=bytes.count else{return nil}
        let argc=Int(UInt32(bytes[0])|UInt32(bytes[1])<<8|UInt32(bytes[2])<<16|UInt32(bytes[3])<<24)
        guard argc>0,argc<=16 else{return nil}
        var offset=4
        while offset<size && bytes[offset] != 0 {offset+=1}
        guard offset<size else{return nil};offset+=1
        while offset<size && bytes[offset]==0 {offset+=1}
        var result:[String]=[]
        for _ in 0..<argc {
            let start=offset
            while offset<size && bytes[offset] != 0 {offset+=1}
            guard offset<size,let text=String(bytes:bytes[start..<offset],encoding:.utf8) else{return nil}
            result.append(text);offset+=1
        }
        return result
    }
    private static func ownMenu(_ path:String,pid:Int,hook:String) -> Bool {
        let root=URL(fileURLWithPath:hook).resolvingSymlinksInPath().deletingLastPathComponent().path
        guard path==root+"/dist/HyprWM.app/Contents/MacOS/hyprwm-swift",let arguments=argv(pid),
              let first=arguments.first,URL(fileURLWithPath:first).resolvingSymlinksInPath().path==path else{return false}
        let extra=Array(arguments.dropFirst())
        guard extra.isEmpty || extra==["--menu-only"] || extra==["--menu-only","--show-settings"] else{return false}
        let contents=URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent().path
        guard let info=object(contents+"/Info.plist",maximum:65536),
              info["CFBundleIdentifier"] as? String=="dev.hyprwm.HyprWM",info["CFBundleExecutable"] as? String=="hyprwm-swift",
              info["HyprWMLaunchRole"] as? String=="menu-only",(info["LSUIElement"] as? NSNumber)?.boolValue==true,
              let manifest=object(contents+"/Resources/BuildManifest.json"),
              manifest["bundle_id"] as? String=="dev.hyprwm.HyprWM",manifest["launch_role"] as? String=="menu-only",
              manifest["source_root"] as? String==root,argv(pid)==arguments else{return false}
        return true
    }
    static func describe(snapshot:Snapshot,hook:String) -> JSON {
        var ordinary:[JSON]=[],excluded:[JSON]=[],complete=snapshot.stable && !snapshot.locked && snapshot.spaceType==0
        var actors:[Int:JSON]=[:],seen=Set<Int>(),all=0
        for window in snapshot.windows where window.space==snapshot.space {
            all+=1
            guard window.wid>0,window.wid<Int(UInt32.max),window.pid>0,!seen.contains(window.wid) else{complete=false;continue}
            seen.insert(window.wid)
            let actor:JSON?
            if let cached=actors[window.pid] {actor=cached}
            else {actor=try? VerifiedPublicWorkspace.identity(window.pid);if let actor{actors[window.pid]=actor}}
            let components=actor?.array ?? []
            let birth:JSON=components.count==5 ? .array(Array(components.prefix(4))) : .null
            let path=components.last?.string
            var row=JSON.object([("wid",.int(window.wid)),("pid",.int(window.pid)),("birth",birth),
                ("executable",path.map(JSON.string) ?? .null),("space",.int(snapshot.space)),("layer",.int(window.layer)),
                ("on",.bool(window.on)),("alpha",.double(window.alpha))])
            guard let actor,let path else{complete=false;if window.layer==0{ordinary.append(row)}else{excluded.append(row.setting("reason",.string("nonzero-native-layer")))};continue}
            if window.layer != 0 {row=row.setting("reason",.string("nonzero-native-layer"));excluded.append(row)}
            else {
                let bundlePath=URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent().path+"/Info.plist"
                let bundle=object(bundlePath,maximum:65536)?["CFBundleIdentifier"] as? String
                if SystemUI.protected(executable:path,bundle:bundle) {
                    row=row.setting("reason",.string("immutable-platform-shell")).setting("bundle_id",.string(bundle!));excluded.append(row)
                } else if ownMenu(path,pid:window.pid,hook:hook) {
                    row=row.setting("reason",.string("verified-own-menu-ui")).setting("bundle_id",.string("dev.hyprwm.HyprWM")).setting("role",.string("menu-only"));excluded.append(row)
                } else {ordinary.append(row)}
            }
            if (try? VerifiedPublicWorkspace.identity(window.pid)) != actor {complete=false}
        }
        let descriptor=JSON.object([("schema",.int(1)),("scope",.string(scope)),("space",.int(snapshot.space)),
            ("complete",.bool(complete)),("all_window_count",.int(all)),("ordinary",.array(ordinary)),("excluded",.array(excluded)),
            ("titles_read",.bool(false)),("owner_labels_used",.bool(false))])
        return .object([("ordinary_window_count",.int(ordinary.count)),("ordinary_descriptor",descriptor)])
    }
}
