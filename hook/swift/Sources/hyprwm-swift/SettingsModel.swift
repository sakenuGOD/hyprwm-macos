import AppKit
import SwiftUI
import HyprCore
import CoreFoundation

// UI routes and settings are separate from window management. No preview creates managed windows.
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, layout, animations, appearance, focus, hotkeys, rules, advanced, about
    var id: String { rawValue }
    var title: String { switch self {
    case .general: return "General"; case .layout: return "Layout"; case .animations: return "Animations"
    case .appearance: return "Appearance"; case .focus: return "Focus & Mouse"; case .hotkeys: return "Keyboard Shortcuts"
    case .rules: return "App Rules"; case .advanced: return "Advanced"; case .about: return "About HyprWM" } }
    var symbol: String { switch self {
    case .general: return "gearshape"; case .layout: return "rectangle.split.2x2"; case .animations: return "waveform.path"
    case .appearance: return "paintpalette"; case .focus: return "cursorarrow.motionlines"; case .hotkeys: return "command"
    case .rules: return "app.badge"; case .advanced: return "slider.horizontal.3"; case .about: return "info.circle" } }
    var color: Color { switch self {
    case .general: return .gray; case .layout: return .blue; case .animations: return .blue; case .appearance: return .pink
    case .focus: return .orange; case .hotkeys: return .indigo; case .rules: return .green; case .advanced: return .gray; case .about: return .blue } }
    var subtitle: String { switch self {
    case .general: return "Windows and permissions."
    case .layout: return "Window layout."
    case .animations: return "Timing and curves."
    case .appearance: return "Borders, shadows, and spacing."
    case .focus: return "Focus and dragging."
    case .hotkeys: return "Keyboard shortcuts."
    case .rules: return "Per-app settings."
    case .advanced: return "Configuration and diagnostics."
    case .about: return "Version and support." } }
}
struct SettingSpec: Identifiable {
    enum Kind { case number(ClosedRange<Double>, Double, String), toggle, choice([(String,String)]), color }
    let path: String; let title: String; let page: SettingsPage; let group: String; let kind: Kind
    let fallback: Any; let source: String; let note: String
    var id: String { path }
    init(_ path: String, _ title: String, _ page: SettingsPage, _ group: String, _ kind: Kind, _ fallback: Any,
         source: String = "", note: String = "") {
        self.path=path; self.title=title; self.page=page; self.group=group; self.kind=kind; self.fallback=fallback; self.source=source; self.note=note
    }
}
let settingSpecs: [SettingSpec] = [
    .init("runtime.window_resize_mode","Resize Mode",.animations,"Motion",.choice([("native","Native"),("buffer","Scale Content")]),"native",note:"Native preserves the size of window content. Scale Content stretches the live window buffer during resizing."),
    .init("time_scale","Duration Scale",.animations,"Motion",.number(0.1...4,0.05,"×"),1.0),
    .init("animations.enabled","Window Animations",.animations,"Motion",.toggle,true,source:"config.animations.enabled"),
    .init("layout.gaps_in","Window Gap",.layout,"Spacing",.number(0...100,1,"pt"),3,source:"config.general.gaps_in",note:"Adjacent window margins combine to form the gap."),
    .init("layout.gaps_out.top","Top",.layout,"Screen Edges",.number(0...200,1,"pt"),8,source:"config.general.gaps_out.top"),
    .init("layout.gaps_out.right","Right",.layout,"Screen Edges",.number(0...200,1,"pt"),12,source:"config.general.gaps_out.right"),
    .init("layout.gaps_out.bottom","Bottom",.layout,"Screen Edges",.number(0...200,1,"pt"),12,source:"config.general.gaps_out.bottom"),
    .init("layout.gaps_out.left","Left",.layout,"Screen Edges",.number(0...200,1,"pt"),12,source:"config.general.gaps_out.left"),
    .init("layout.default_split_ratio","Split Ratio",.layout,"Splitting",.number(0.1...1.9,0.05,"×"),1,source:"config.dwindle.default_split_ratio"),
    .init("layout.split_width_multiplier","Prefer Wide Tiles",.layout,"Splitting",.number(0.1...10,0.05,"×"),1,source:"config.dwindle.split_width_multiplier"),
    .init("layout.minimum_policy","Minimum Size",.layout,"Splitting",.choice([("native","App Minimum"),("ratio","Layout Ratio")]),"native",source:"config.dwindle.minimum_policy"),
    .init("appearance.border.size","Border Width",.appearance,"Borders",.number(0...20,0.5,"pt"),2,source:"config.general.border_size"),
    .init("appearance.border.active.angle","Gradient Angle",.appearance,"Borders",.number(0...90,1,"°"),45,source:"config.general.col.active_border.angle"),
    .init("appearance.border.inactive","Inactive Border",.appearance,"Borders",.color,"rgba(53434155)",source:"config.general.col.inactive_border"),
    .init("appearance.rounding","Corner Radius",.appearance,"Window Shape",.number(0...100,1,"pt"),18,source:"config.decoration.rounding"),
    .init("appearance.rounding_power","Corner Shape",.appearance,"Window Shape",.number(1...10,0.1,""),2.6,source:"config.decoration.rounding_power"),
    .init("appearance.shadow.enabled","Shadow",.appearance,"Shadow",.toggle,true,source:"config.decoration.shadow.enabled"),
    .init("appearance.shadow.range","Shadow Size",.appearance,"Shadow",.number(1...200,1,"pt"),34,source:"config.decoration.shadow.range"),
    .init("appearance.shadow.render_power","Shadow Softness",.appearance,"Shadow",.number(1...4,1,""),3,source:"config.decoration.shadow.render_power"),
    .init("appearance.shadow.scale","Shadow Scale",.appearance,"Shadow",.number(0...1,0.01,"×"),1,source:"config.decoration.shadow.scale"),
    .init("appearance.shadow.offset.0","Horizontal Offset",.appearance,"Shadow",.number(-2000...2000,1,"pt"),0,source:"config.decoration.shadow.offset.0"),
    .init("appearance.shadow.offset.1","Vertical Offset",.appearance,"Shadow",.number(-2000...2000,1,"pt"),10,source:"config.decoration.shadow.offset.1"),
    .init("appearance.shadow.color","Active Shadow",.appearance,"Shadow",.color,"rgba(00000077)",source:"config.decoration.shadow.color"),
    .init("appearance.shadow.color_inactive","Inactive Shadow",.appearance,"Shadow",.color,"rgba(00000044)",source:"config.decoration.shadow.color_inactive"),
    .init("appearance.glow.enabled","Inner Glow",.appearance,"Glow",.toggle,true,source:"config.decoration.glow.enabled"),
    .init("appearance.glow.range","Glow Size",.appearance,"Glow",.number(0...200,1,"pt"),18,source:"config.decoration.glow.range"),
    .init("appearance.glow.render_power","Falloff",.appearance,"Glow",.number(1...10,0.1,""),3,source:"config.decoration.glow.render_power"),
    .init("appearance.glow.color","Active Glow",.appearance,"Glow",.color,"rgba(ffb4a433)",source:"config.decoration.glow.color"),
    .init("appearance.glow.color_inactive","Inactive Glow",.appearance,"Glow",.color,"rgba(ffb4a400)",source:"config.decoration.glow.color_inactive"),
    .init("focus.follow_mouse","Focus Follows Mouse",.focus,"Focus",.choice([("0","Off"),("1","On")]),1,source:"config.input.follow_mouse"),
    .init("focus.focus_on_close","After Closing a Window",.focus,"Focus",.choice([("0","Nearest Window"),("1","Window Under Pointer"),("2","Previous Window")]),0,source:"config.input.focus_on_close"),
    .init("focus.no_focus_fallback","Keep Focus Without a Neighbor",.focus,"Focus",.toggle,false,source:"config.general.no_focus_fallback"),
    .init("drag.mode","Tile Dragging",.focus,"Dragging",.choice([("swap","Swap"),("insert","Insert Beside")]),"swap",source:"config.input.drag_mode"),
    .init("drag.throw_distance_pt","Drag Threshold",.focus,"Dragging",.number(8...400,1,"pt"),32,source:"config.input.drag_throw_distance"),
    .init("drag.direction_ratio","Direction Bias",.focus,"Dragging",.number(1...4,0.05,"×"),1.25,source:"config.input.drag_direction_ratio"),
    .init("runtime.pointer_focus_pause_ms","Pointer Focus Delay",.focus,"Focus",.number(0...2000,10,"ms"),100),
    .init("runtime.overview_hidden_windows","Hidden Windows in Mission Control · Beta",.advanced,"Window Behavior",.toggle,false,note:"Experimental. Hidden windows may appear incorrectly in the overview. Off by default."),
    .init("runtime.prehide","Prepare New Windows",.advanced,"Window Behavior",.toggle,false),
    .init("runtime.hold_max_ms","First Frame Timeout",.advanced,"Window Behavior",.number(0...2000,10,"ms"),200),
    .init("runtime.capture_sampling","Sample Window Edge Color",.advanced,"Window Behavior",.toggle,false, note:"Use the window image to determine its edge color.")
]

func valueAt(_ root: Any, _ path: String) -> Any? {
    var current: Any? = root
    for component in path.split(separator: ".").map(String.init) {
        if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current=array[index] }
        else if let dictionary = current as? [String:Any] { current=dictionary[component] }
        else { return nil }
    }
    return current
}
func settingValue(_ root: Any, _ components: [String], _ value: Any?) -> Any {
    guard let key=components.first else { return value ?? NSNull() }
    let tail=Array(components.dropFirst())
    if let index=Int(key) {
        var array=(root as? [Any]) ?? [0,0]
        while array.count <= index { array.append(0) }
        array[index]=settingValue(array[index],tail,value); return array
    }
    var dictionary=(root as? [String:Any]) ?? [:]
    if tail.isEmpty { dictionary[key]=value }
    else { dictionary[key]=settingValue(dictionary[key] ?? [:],tail,value) }
    return dictionary
}

func settingsFileData(_ url:URL) throws -> Data {
    guard FileManager.default.fileExists(atPath:url.path) else {return Data("{}".utf8)}
    let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
    let data=try file.read(upToCount:262145) ?? Data()
    guard data.count<=262144 else {throw NSError(domain:"HyprWM.Settings",code:1,userInfo:[NSLocalizedDescriptionKey:"Settings file exceeds 256 KB."])}
    return data
}

enum SettingsPersistence {
    static func merge(base:[String:Any],disk:[String:Any],changes:[String:Any]) throws->[String:Any] {
        for key in changes.keys {
            let expected=valueAt(base,key),actual=valueAt(disk,key)
            let equal:Bool
            if expected==nil && actual==nil {equal=true}
            else if let expected,let actual {equal=NSDictionary(dictionary:["value":expected]).isEqual(to:["value":actual])}
            else {equal=false}
            guard equal else {throw NSError(domain:"HyprWM.Settings",code:2,userInfo:[NSLocalizedDescriptionKey:"These settings changed in another app. Try again."])}
        }
        var candidate=disk
        for (key,value) in changes.sorted(by:{$0.key.split(separator:".").count < $1.key.split(separator:".").count}) {candidate=settingValue(candidate,key.split(separator:".").map(String.init),value is NSNull ? nil:value) as! [String:Any]}
        return candidate
    }
}

final class SettingsStore: ObservableObject {
    @Published var document: [String:Any] = [:]
    @Published var base: [String:Any] = [:]
    @Published var error: String?
    @Published var saving=false
    @Published var loaded=false
    @Published var shuttingDown=false
    @Published var connected=false
    @Published var enabled=true
    @Published var trusted=AXIsProcessTrusted()
    @Published var runtimeName=""
    @Published var runtimeVersion=""
    let hook: String
    private let queue=DispatchQueue(label:"hyprwm.settings.persistence",qos:.userInitiated)
    private var pending: [String:Any] = [:]
    private var scheduled: DispatchWorkItem?
    private var editRevision=0
    private var savesInFlight=0
    private var persistenceBase:[String:Any]?
    private var watcher: ConfigFileWatcher?
    let send: MenuBarController.Send
    init(hook: String, send: @escaping MenuBarController.Send) {
        self.hook=hook; self.send=send
        reload()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        watcher = try? ConfigFileWatcher(url: url) { [weak self] in DispatchQueue.main.async { self?.reload() } }
    }
    var url: URL { TextConfig.url(configDir:hook+"/config") }
    func reload() {
        guard pending.isEmpty && savesInFlight==0 else {return}
        loaded=false
        let cache=hook+"/config/hypr_cfg.json"
        queue.async { [weak self] in
            do {
                let parsed = try TextConfig.read(configDir:self?.hook.appending("/config") ?? "")
                let data=Data(parsed.document.dumps(ensureASCII:false).utf8)
                let document=try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
                var base=(try? Data(contentsOf:URL(fileURLWithPath:cache))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
                if let data=try? JSONSerialization.data(withJSONObject:base),let native=try? HyprConfig(json:JSON.parse(data),timeScale:1) {
                    var curves=base["curves"] as? [String:[String:Any]] ?? [:]
                    for (name,curve) in native.sortedCurves() {
                        switch curve {
                        case let .bezier(p1,p2):curves[name]=["type":"bezier","points":[[p1.0,p1.1],[p2.0,p2.1]]]
                        case let .spring(mass,stiffness,damping):curves[name]=["type":"spring","mass":mass,"stiffness":stiffness,"damping":damping]
                        }
                    };base["curves"]=curves
                }
                self?.persistenceBase=document
                DispatchQueue.main.async { guard let self, self.pending.isEmpty else { return }; self.document=document; self.base=base;self.loaded=true;self.error=parsed.error
                    if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW"] == "1",ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW_RULES"] == "1" {
                        let apps=NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.localizedName != nil}.prefix(3)
                        self.document["window_rules"]=apps.enumerated().map{index,app in ["name":app.localizedName!,"match":["class":"^"+NSRegularExpression.escapedPattern(for:app.localizedName!)+"$"],"float":index==1,"ignore":index==2,"enabled":true] as [String:Any]}
                    } }
            } catch { DispatchQueue.main.async { self?.error=error.localizedDescription } }
        }
    }
    private func inheritedAnimationValue(_ path:String)->Any? {
        let components=path.split(separator:".").map(String.init)
        guard components.count==3,components[0]=="animations" else {return nil}
        var node:String?=components[1]
        while let current=node {if let value=valueAt(document,"animations."+current+"."+components[2]) {return value};node=HyprConfig.parent[current]}
        return nil
    }
    func value(_ path: String, fallback: Any) -> Any {
        if let n=valueAt(document,path) { return n }
        if let n=inheritedAnimationValue(path) {return n}
        if path.hasPrefix("layout.gaps_out."), let n=valueAt(document,"layout.gaps_out") as? NSNumber { return n }
        if path.hasPrefix("layout.gaps_out."), let n=valueAt(base,"config.general.gaps_out") as? NSNumber {return n}
        if let spec=settingSpecs.first(where:{$0.path==path}), !spec.source.isEmpty, let n=valueAt(base,spec.source) { return n }
        if path == "appearance.border.active.colors", let n=valueAt(base,"config.general.col.active_border.colors") {return n}
        if path.hasPrefix("runtime."), let n=valueAt(base,path) { return n }
        return fallback
    }
    func number(_ path: String, _ fallback: Double=0) -> Double { (value(path,fallback:fallback) as? NSNumber)?.doubleValue ?? fallback }
    func string(_ path: String, _ fallback: String="") -> String { value(path,fallback:fallback) as? String ?? fallback }
    func bool(_ path: String, _ fallback: Bool=true) -> Bool {
        if path.hasPrefix("animations."),path.hasSuffix(".enabled"),valueAt(document,path)==nil,inheritedAnimationValue(path)==nil {
            let event=path.split(separator:".").dropFirst().first.map(String.init) ?? ""
            if let record=(base["animations"] as? [[String:Any]])?.first(where:{$0["leaf"] as? String==event}),let enabled=record["enabled"] as? Bool {return enabled}
        }
        return (value(path,fallback:fallback) as? NSNumber)?.boolValue ?? fallback
    }
    func setTiling(_ value: Bool) {
        send(value ? "resume" : "pause") { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(response) where response == (value ? "enabled" : "paused"):
                self.enabled=value;self.set("runtime.enabled",value)
            case let .success(response): self.error=response
            case let .failure(error): self.error=error.localizedDescription
            }
        }
    }
    func set(_ path: String, _ value: Any) {
        guard loaded else {return}
        editRevision += 1
        if path.hasPrefix("appearance.shadow.offset."),valueAt(document,"appearance.shadow.offset")==nil {
            let offset=valueAt(base,"config.decoration.shadow.offset") as? [Any] ?? [0,10]
            document=settingValue(document,["appearance","shadow","offset"],offset) as! [String:Any]
            pending["appearance.shadow.offset"]=offset
        }
        // Normalize scalar outer gaps into all four sides before editing one side.
        if path.hasPrefix("layout.gaps_out."), let n=valueAt(document,"layout.gaps_out") as? NSNumber {
            let sides=Dictionary(uniqueKeysWithValues:["top","right","bottom","left"].map{($0,n)})
            document=settingValue(document,["layout","gaps_out"],sides) as! [String:Any]; pending["layout.gaps_out"]=sides
        }
        document=settingValue(document,path.split(separator:".").map(String.init),value) as! [String:Any]
        pending[path]=value; schedule()
    }
    private func defaultValue(_ path: String) -> Any? {
        guard let bytes=try? JSONSerialization.data(withJSONObject:base), let json=try? JSON.parse(bytes), let native=try? HyprConfig(json:json,timeScale:1),
              let object=try? JSONSerialization.jsonObject(with:Data(TextConfig.defaults(base:native).dumps(ensureASCII:false).utf8)) else { return nil }
        return valueAt(object,path)
    }
    func isDefault(_ path: String, fallback: Any) -> Bool {
        let expected=defaultValue(path) ?? fallback
        return NSDictionary(dictionary:["v":value(path,fallback:fallback)]).isEqual(to:["v":expected])
    }
    func hasChanges(_ page: SettingsPage) -> Bool {
        settingSpecs.contains { $0.page==page && !isDefault($0.path,fallback:$0.fallback) }
    }
    func reset(_ path: String) {
        if let value=defaultValue(path) { set(path,value); return }
        guard loaded else {return}
        editRevision += 1
        document=settingValue(document,path.split(separator:".").map(String.init),nil) as! [String:Any]
        pending[path]=NSNull(); schedule()
    }
    func resetPage(_ page: SettingsPage) {
        for spec in settingSpecs where spec.page==page { reset(spec.path) }
        if page == .appearance { reset("appearance.border.active.colors") }
        if page == .animations { reset("animations"); reset("curves"); reset("time_scale") }
        if page == .rules { reset("window_rules") }
    }
    func openConfig() { NSWorkspace.shared.open(url) }
    func importConfig() {
        let panel=NSOpenPanel(); panel.canChooseDirectories=false; panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let source=panel.url else {return}
        do {
            let bytes=try Data(contentsOf:source)
            guard bytes.count <= 262144, let text=String(data:bytes,encoding:.utf8) else {throw CmdError("Expected a UTF-8 file no larger than 256 KB.")}
            let result=try TextConfig.parse(text,configDir:hook+"/config")
            guard result.issues.isEmpty else {throw CmdError(result.error ?? "Invalid configuration")}
            try backupConfig(); try bytes.write(to:url,options:.atomic); reload()
        } catch {self.error=error.localizedDescription}
    }
    func importForeignConfig() {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.message="Import settings from another window manager. Unsupported entries are reported."
        guard panel.runModal() == .OK,let source=panel.url else{return}
        do {
            let result=try ForeignConfigImport.importFile(source,configDir:hook+"/config",apply:true)
            reload()
            error=result.issues.isEmpty ? nil:result.issues.map(\.description).joined(separator:"\n")
        } catch {self.error=error.localizedDescription}
    }
    func exportConfig() {
        let panel=NSSavePanel(); panel.nameFieldStringValue="hyprwm.conf"
        guard panel.runModal() == .OK, let target=panel.url else {return}
        do {try Data(contentsOf:url).write(to:target,options:.atomic)} catch {self.error=error.localizedDescription}
    }
    func resetConfig() {
        do {
            let native=try HyprConfig.load(configDir:hook+"/config",rebuild:false,timeScale:1)
            try backupConfig(); try TextConfig.write(TextConfig.defaults(base:native),configDir:hook+"/config"); reload()
        } catch {self.error=error.localizedDescription}
    }
    private func backupConfig() throws {
        guard FileManager.default.fileExists(atPath:url.path) else {return}
        let backup=url.appendingPathExtension("backup-"+String(Int(Date().timeIntervalSince1970))+"-"+String(UUID().uuidString.prefix(8)))
        try FileManager.default.copyItem(at:url,to:backup)
    }
    private func schedule() {
        scheduled?.cancel(); saving=true
        let task=DispatchWorkItem { [weak self] in self?.persist() }; scheduled=task
        DispatchQueue.main.asyncAfter(deadline:.now()+0.065,execute:task)
    }
    private func persist() {
        if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW"] == "1" {pending=[:];saving=false;return}
        let changes=pending; pending=[:]; let path=url, hook=self.hook;let revision=editRevision;savesInFlight += 1
        queue.async { [weak self] in
            do {
                let old=try settingsFileData(path)
                let diskJSON=try TextConfig.parse(String(decoding:old,as:UTF8.self),configDir:hook+"/config").document
                guard let disk=try JSONSerialization.jsonObject(with:Data(diskJSON.dumps(ensureASCII:false).utf8)) as? [String:Any] else {throw NSError(domain:"Settings",code:3,userInfo:[NSLocalizedDescriptionKey:"Could not read settings."])}
                let candidate=try SettingsPersistence.merge(base:self?.persistenceBase ?? disk,disk:disk,changes:changes)
                let bytes=try JSONSerialization.data(withJSONObject:candidate,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
                guard bytes.count <= 262144 else { throw NSError(domain:"Settings",code:1,userInfo:[NSLocalizedDescriptionKey:"Settings exceed the maximum size."]) }
                try SettingsValidation.validate(bytes, hook:hook)
                // Do not overwrite an external edit made during validation.
                let now=try settingsFileData(path)
                guard now==old else { throw NSError(domain:"Settings",code:2,userInfo:[NSLocalizedDescriptionKey:"The file changed in another app. Try again."]) }
                try TextConfig.write(try JSON.parse(bytes),configDir:hook+"/config",preserving:String(decoding:old,as:UTF8.self))
                self?.persistenceBase=candidate
                DispatchQueue.main.async {
                    guard let self else { return }; self.error=nil;self.savesInFlight -= 1; self.saving = !self.pending.isEmpty || self.savesInFlight>0
                    if self.pending.isEmpty && self.editRevision==revision { self.document=candidate }
                    // The shared file watcher applies this edit through the same diff as editor saves.
                }
            } catch { DispatchQueue.main.async { guard let self else {return}; self.error="Change not saved: "+error.localizedDescription;self.savesInFlight -= 1; self.saving = !self.pending.isEmpty || self.savesInFlight>0;if self.editRevision==revision {self.reload()} } }
        }
    }
    func requestAccess() { let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary; trusted=AXIsProcessTrustedWithOptions(options) }
    func copyDiagnosis() {
        send("status") { [weak self] result in
            var summary:[String:Any]=["app":"HyprWM","macOS":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":"arm64","accessibility":AXIsProcessTrusted()]
            if case let .success(text)=result, let object=text.data(using:.utf8).flatMap({try? JSONSerialization.jsonObject(with:$0)}) as? [String:Any] {
                // Explicit allowlist: no titles, app names, paths, PIDs, window IDs, or configuration contents.
                summary["enabled"]=object["enabled"]; summary["connected"]=true
                if let daemon=object["daemon"] as? [String:Any] { summary["runtime"]=daemon["runtime"]; summary["version"]=daemon["version"] }
            } else { summary["connected"]=false }
            summary["settings_valid"]=self?.error == nil
            if let data=try? JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]), let string=String(data:data,encoding:.utf8) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string,forType:.string)
            }
        }
    }
}

enum SettingsValidation {
    static func validate(_ bytes: Data, hook: String) throws {
        let json=try JSON.parse(bytes)
        let base=try HyprConfig.load(configDir:hook+"/config",rebuild:false,timeScale:1)
        // Schema is interpreted natively. This checks every numeric/color/rule field before the shared consumer resolves inheritance.
        var schema=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:hook+"/config/runtime.schema.json"))) as! [String:Any]
        for key in ["enabled","menu_bar","startup_animation"] {
            schema=settingValue(schema,["properties","runtime","properties",key],["type":"boolean"]) as! [String:Any]
        }
        let object=try JSONSerialization.jsonObject(with:bytes)
        try check(object,schema:schema,root:schema,path:"Settings")
        if let object=object as? [String:Any] {
            let curves=(base.raw["curves"]?.object ?? []).reduce(into:[String:JSON]()){$0[$1.0]=$1.1}
            let local=object["curves"] as? [String:[String:Any]] ?? [:]
            for (name,curve) in local {
                if curve["damping"] != nil && curve["dampening"] != nil {throw failure("curves."+name)}
            }
            let animations=object["animations"] as? [String:[String:Any]] ?? [:]
            for event in ["border","fadeShadow"] {
                if let name=animations[event]?["curve"] as? String,
                   (local[name]?["type"] as? String ?? curves[name]?["type"]?.string) == "spring" {throw failure("animations."+event+".curve")}
            }
        }
        _=try NativeRuntimeConfig.build(base:base,document:json,environment:[:])
    }
    private static func failure(_ path: String) -> NSError { NSError(domain:"HyprWM.Settings",code:1,userInfo:[NSLocalizedDescriptionKey:"Invalid value: "+path]) }
    private static func check(_ value: Any, schema: [String:Any], root:[String:Any],path:String) throws {
        if let ref=schema["$ref"] as? String, let target=valueAt(root,String(ref.dropFirst(2)).replacingOccurrences(of:"/",with:".")) as? [String:Any] { try check(value,schema:target,root:root,path:path); return }
        if let alternatives=schema["oneOf"] as? [[String:Any]] {
            var valid=0
            for alt in alternatives { if (try? check(value,schema:alt,root:root,path:path)) != nil { valid += 1 } }
            guard valid==1 else {throw failure(path)}; return
        }
        if let choices=schema["enum"] as? [Any], !choices.contains(where:{ NSDictionary(dictionary:["v":$0]).isEqual(to:["v":value]) }) {throw failure(path)}
        if let constant=schema["const"], !NSDictionary(dictionary:["v":constant]).isEqual(to:["v":value]) {throw failure(path)}
        switch schema["type"] as? String {
        case "object":
            guard let object=value as? [String:Any] else {throw failure(path)}
            let properties=schema["properties"] as? [String:[String:Any]] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key]==nil {throw failure(path+"."+key)}
            for (key,v) in object {
                if let spec=properties[key] {try check(v,schema:spec,root:root,path:path+"."+key)}
                else if let spec=schema["additionalProperties"] as? [String:Any] {try check(v,schema:spec,root:root,path:path+"."+key)}
                else if schema["additionalProperties"] as? Bool == false {throw failure(path+"."+key)}
            }
        case "array":
            guard let array=value as? [Any], array.count >= (schema["minItems"] as? Int ?? 0), array.count <= (schema["maxItems"] as? Int ?? Int.max) else {throw failure(path)}
            let prefix=schema["prefixItems"] as? [[String:Any]] ?? []
            for (i,v) in array.enumerated() { if i < prefix.count {try check(v,schema:prefix[i],root:root,path:path+".\(i)")} else if let item=schema["items"] as? [String:Any] {try check(v,schema:item,root:root,path:path+".\(i)")} }
        case "number", "integer":
            guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                  n.doubleValue >= (schema["minimum"] as? Double ?? -Double.infinity), n.doubleValue <= (schema["maximum"] as? Double ?? Double.infinity),
                  schema["type"] as? String != "integer" || n.doubleValue.rounded()==n.doubleValue else {throw failure(path)}
        case "boolean": guard let n=value as? NSNumber, CFGetTypeID(n)==CFBooleanGetTypeID() else {throw failure(path)}
        case "string":
            guard let s=value as? String, s.count >= (schema["minLength"] as? Int ?? 0), s.count <= (schema["maxLength"] as? Int ?? Int.max) else {throw failure(path)}
            if let pattern=schema["pattern"] as? String, s.range(of:pattern,options:.regularExpression)==nil {throw failure(path)}
        default: break
        }
    }
}
func nativeColor(_ text: String) -> Color {
    var hex=text.replacingOccurrences(of:"rgba(",with:"").replacingOccurrences(of:"rgb(",with:"").replacingOccurrences(of:")",with:"")
    if hex.hasPrefix("0x") {let raw=String(hex.dropFirst(2)); hex=String(raw.dropFirst(2))+String(raw.prefix(2))}
    if hex.count==6 {hex += "ff"}
    guard let n=UInt64(hex,radix:16) else {return .accentColor}
    return Color(.sRGB,red:Double((n>>24)&255)/255,green:Double((n>>16)&255)/255,blue:Double((n>>8)&255)/255,opacity:Double(n&255)/255)
}
func runtimeColor(_ color: Color) -> String {
    guard let n=NSColor(color).usingColorSpace(.sRGB) else {return "rgba(ffffffff)"}
    return String(format:"rgba(%02x%02x%02x%02x)",Int((n.redComponent*255).rounded()),Int((n.greenComponent*255).rounded()),Int((n.blueComponent*255).rounded()),Int((n.alphaComponent*255).rounded()))
}
