import AppKit
import Darwin
import SwiftUI

struct AppRulesSettings: View {
    @ObservedObject var store:SettingsStore
    @State private var adding=false
    @State private var expanded:Int?
    var rules:[[String:Any]] {store.document["window_rules"] as? [[String:Any]] ?? []}
    var apps:[NSRunningApplication] {NSWorkspace.shared.runningApplications.filter{$0.activationPolicy == .regular && $0.localizedName != nil}.sorted{($0.localizedName ?? "")<($1.localizedName ?? "")}}
    var body:some View {
        Section("App Rules") {
            if rules.isEmpty { VStack(spacing:9){Image(systemName:"app.badge").font(.system(size:30)).foregroundStyle(.secondary);Text("No App Rules").font(.headline);Text("Add a rule to change how an app is managed.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity).padding(.vertical,20) }
            ForEach(rules.indices,id:\.self){index in
                VStack(alignment:.leading,spacing:12){
                    HStack(spacing:12){Image(nsImage:icon(rules[index])).resizable().frame(width:32,height:32);VStack(alignment:.leading,spacing:3){Text(rules[index]["name"] as? String ?? "Rule \(index+1)").font(.body.weight(.medium));Text((rules[index]["match"] as? [String:Any])?["class"] as? String ?? "Window Title Match").font(.caption).foregroundStyle(.secondary)};Spacer()
                        Picker("Mode",selection:Binding(get:{rules[index]["ignore"] as? Bool == true ? "ignore" : rules[index]["float"] as? Bool == true ? "float":"tile"},set:{mode in var rule=rules[index];rule["float"]=mode=="float";rule["ignore"]=mode=="ignore";replace(index,rule)})){Text("Tile").tag("tile");Text("Float").tag("float");Text("Ignore").tag("ignore")}.labelsHidden().frame(width:135)
                        Button{expanded=expanded==index ? nil:index}label:{Image(systemName:"slider.horizontal.3")}.buttonStyle(.borderless).help("Rule Options")
                        Button{var next=rules;next.remove(at:index);store.set("window_rules",next);expanded=nil}label:{Image(systemName:"minus.circle")}.buttonStyle(.borderless).foregroundStyle(.secondary).help("Delete Rule")
                    }
                    if expanded==index {
                        TextField("Rule Name",text:Binding(get:{rules[index]["name"] as? String ?? ""},set:{var rule=rules[index];rule["name"]=$0;replace(index,rule)}))
                        TextField("App (Regular Expression)",text:matchBinding(index,"class"))
                        TextField("Window Title (Optional)",text:matchBinding(index,"title"))
                        ForEach([("enabled","Enable Rule",true),("no_anim","Disable Animation",false),("no_follow_mouse","Disable Pointer Focus",false)],id:\.0){key,title,fallback in Toggle(title,isOn:Binding(get:{rules[index][key] as? Bool ?? fallback},set:{var rule=rules[index];rule[key]=$0;replace(index,rule)}))}
                        HStack{Text("Opacity");Spacer();Slider(value:Binding(get:{(rules[index]["opacity"] as? Double) ?? 1},set:{var rule=rules[index];rule["opacity"]=$0;replace(index,rule)}),in:0...1).frame(width:180);Text(((rules[index]["opacity"] as? Double) ?? 1).formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()}
                    }
                }.padding(.vertical,5)
            }
            Menu {ForEach(apps,id:\.processIdentifier){app in Button{add(app)}label:{Text(app.localizedName ?? "App")}}} label:{Label("Add Running App",systemImage:"plus")}.disabled(rules.count>=128)
        }
        Section {Text("Rules apply in order and supplement the default app rules.").font(.caption).foregroundStyle(.secondary)}
    }
    private func replace(_ index:Int,_ rule:[String:Any]) {var next=rules;next[index]=rule;store.set("window_rules",next)}
    private func matchBinding(_ index:Int,_ key:String)->Binding<String> {Binding(get:{(rules[index]["match"] as? [String:Any])?[key] as? String ?? ""},set:{var rule=rules[index];var match=rule["match"] as? [String:Any] ?? [:];if $0.isEmpty {match.removeValue(forKey:key)}else{match[key]=$0};rule["match"]=match;replace(index,rule)})}
    private func add(_ app:NSRunningApplication){let name=app.localizedName ?? "App";store.set("window_rules",rules+[["name":name,"match":["class":"^"+NSRegularExpression.escapedPattern(for:name)+"$"],"float":false,"ignore":false,"enabled":true]]);expanded=rules.count}
    private func icon(_ rule:[String:Any])->NSImage {let name=rule["name"] as? String;return apps.first{$0.localizedName==name}?.icon ?? NSImage(systemSymbolName:"app",accessibilityDescription:nil)!}
}
struct HotkeySettings:View {
    @ObservedObject var store:SettingsStore
    @State private var bindings:[[String:Any]]=[]
    @State private var recording:Int?
    @State private var conflict:String?
    @State private var helperSummary="Checking keyboard service…"
    @State private var helperReady=false
    @State private var inputMonitoring=CGPreflightListenEventAccess()
    var overrides:[[String:Any]] {store.document["hotkeys"] as? [[String:Any]] ?? []}
    var body:some View {
        Section("Keyboard Shortcuts") {
            HStack {
                Label(helperSummary,systemImage:helperReady ? "checkmark.circle.fill":"keyboard")
                    .foregroundStyle(helperReady ? Color.green:Color.secondary)
                Spacer()
                Button("Refresh"){load();refreshKeyboardStatus()}.buttonStyle(.borderless)
            }
            Text("Global shortcuts use Carbon and require no keyboard monitoring permission.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Accessibility");Spacer()
                if store.trusted {Text("Allowed").foregroundStyle(.secondary)}
                else {Button("Allow…"){store.requestAccess()}}
            }
            HStack {Text("Input Monitoring");Spacer();Text(inputMonitoring ? "Allowed":"Not granted").foregroundStyle(.secondary)}
            Text("HyprWM needs Accessibility to manage windows. Shortcut recording may need keyboard access in System Settings.").font(.caption).foregroundStyle(.secondary)
            if bindings.isEmpty {Text("Connect to HyprWM to edit its active mode’s shortcuts.").foregroundStyle(.secondary)}
            ForEach(bindings.indices.filter{bindings[$0]["event"] as? String != "wheel"},id:\.self){index in
                let record=effective(index)
                HStack{Text(displayTitle(bindings[index]));Spacer()
                    Toggle("Enable Shortcut",isOn:Binding(get:{isEnabled(index)},set:{enabled in
                        saveOverride(index,key:record["keycode"] as? Int ?? 0,modifiers:record["modifiers"] as? Int ?? 0,enabled:enabled)
                    })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    HotkeyRecorder(label:shortcut(record),recording:recording==index,onBegin:{recording=index},onCancel:{recording=nil},onRecord:{key,mods in
                        if bindings.indices.contains(where:{$0 != index && isEnabled($0) && effective($0)["keycode"] as? Int == key && effective($0)["modifiers"] as? Int == mods}) {conflict="This shortcut is already in use. Choose another.";recording=nil;return}
                        saveOverride(index,key:key,modifiers:mods,enabled:true);recording=nil;conflict=nil
                    },onUnavailable:{message in conflict=message;recording=nil}).frame(width:145,height:26)
                    if shortcutChanged(index) {Button{store.set("hotkeys",overrides.filter{!matches($0,index)})}label:{Image(systemName:"arrow.counterclockwise")}.buttonStyle(.borderless).help("Reset Shortcut")}
                }
            }
            if let conflict {Text(conflict).foregroundStyle(.orange).font(.caption)}
        }
        Section {Text("Click a shortcut to record it. Press Escape to cancel. Include ⌘, ⌥, or ⌃.").font(.caption).foregroundStyle(.secondary)}
            .onAppear{load();refreshKeyboardStatus()}
            .onReceive(Timer.publish(every:2,on:.main,in:.common).autoconnect()){_ in refreshKeyboardStatus()}
    }
    private func refreshKeyboardStatus() {
        inputMonitoring=CGPreflightListenEventAccess()
        let directory=ProcessInfo.processInfo.environment["HYPRWM_KEYBOARD_STATE"] ??
            NSHomeDirectory()+"/Library/Application Support/HyprWM/keyboard"
        DispatchQueue.global(qos:.utility).async {
            let path=directory+"/status.json",fd=Darwin.open(path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK)
            var record:[String:Any]?
            if fd>=0 {
                var info=stat()
                if fstat(fd,&info)==0,info.st_uid==getuid(),info.st_mode&S_IFMT==S_IFREG,
                   info.st_mode&0o022==0,info.st_size>=0,info.st_size<=65536 {
                    let file=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
                    let data=(try?file.read(upToCount:65537)) ?? Data()
                    if data.count<=65536 {record=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any]}
                    try?file.close()
                } else {Darwin.close(fd)}
            }
            var message="Keyboard service status unavailable",ready=false
            if let value=record,let updated=value["updated"] as? Double,
               value["backend"] as? String=="carbon",value["schema"] as? Int==1,
               let registered=value["registered"] as? Int,let expected=value["expected"] as? Int,
               registered>=0,expected>=registered {
                let age=Date().timeIntervalSince1970-updated
                if age<0 || age>6 {message="Keyboard service is not reporting"}
                else if value["reload_rejected"] as? Bool==true {message="Shortcut update rejected; previous shortcuts retained"}
                else if registered<expected {message="\(registered) of \(expected) shortcuts registered; check keyboard.log"}
                else if expected==0 {message="No shortcuts active"}
                else {message="Keyboard service running · \(registered) shortcuts registered";ready=true}
            }
            let summary=message,isReady=ready
            DispatchQueue.main.async {helperSummary=summary;helperReady=isReady}
        }
    }
    private func load() {
        store.send("status") { result in
            guard case let .success(text)=result,let bytes=text.data(using:.utf8),
                  let status=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any] else {
                bindings=[];return
            }
            let mode=status["mode"] as? String ?? (status["daemon"] as? [String:Any])?["mode"] as? String ?? (status["engine"] as? [String:Any])?["mode"] as? String
            if mode == "lite" {
                bindings=status["hotkey_bindings"] as? [[String:Any]] ?? []
                if bindings.isEmpty { conflict="Lite shortcut metadata is unavailable. Edit bind lines in the configuration." }
                return
            }
            let url=URL(fileURLWithPath:"/tmp/hyprkeys.json")
            DispatchQueue.global(qos:.utility).async {
                let records=(try?settingsFileData(url)).flatMap{try?JSONSerialization.jsonObject(with:$0) as? [[String:Any]]} ?? []
                DispatchQueue.main.async { bindings=records }
            }
        }
    }
    private func matches(_ entry:[String:Any],_ index:Int)->Bool {
        if let command=entry["command"] as? [String] {return command==bindings[index]["cmd"] as? [String]}
        return entry["id"] as? Int==index
    }
    private func saveOverride(_ index:Int,key:Int,modifiers:Int,enabled:Bool) {
        var next=overrides.filter{!matches($0,index)}
        for item in next.indices {
            if let command=next[item]["command"] as? [String],let current=bindings.indices.first(where:{bindings[$0]["cmd"] as? [String]==command}) {next[item]["id"]=current}
        }
        next.append(["id":index,"keycode":key,"modifiers":modifiers,"enabled":enabled,"command":bindings[index]["cmd"] as? [String] ?? []])
        let ids=next.compactMap{$0["id"] as? Int}
        guard Set(ids).count==ids.count else {conflict="The default actions changed. Reset the outdated shortcut.";return}
        store.set("hotkeys",next)
    }
    private func shortcutChanged(_ index:Int)->Bool {
        let base=bindings[index],current=effective(index)
        return current["keycode"] as? Int != (base["keycode"] as? Int ?? base["key"] as? Int ?? 0) || current["modifiers"] as? Int != (base["modifiers"] as? Int ?? base["mods"] as? Int ?? 0) || isEnabled(index) != (base["enabled"] as? Bool ?? true)
    }
    private func isEnabled(_ index:Int)->Bool {overrides.first{matches($0,index)}?["enabled"] as? Bool ?? bindings[index]["enabled"] as? Bool ?? true}
    private func effective(_ index:Int)->[String:Any]{let b=bindings[index];let o=overrides.first{matches($0,index)} ?? [:];return ["keycode":o["keycode"] ?? b["keycode"] ?? b["key"] ?? 0,"modifiers":o["modifiers"] ?? b["modifiers"] ?? b["mods"] ?? 0]}
    private func shortcut(_ record:[String:Any])->String {let mods=record["modifiers"] as? Int ?? 0,key=record["keycode"] as? Int ?? 0;return (mods&0x1000 != 0 ? "⌃":"")+(mods&0x0800 != 0 ? "⌥":"")+(mods&0x0200 != 0 ? "⇧":"")+(mods&0x0100 != 0 ? "⌘":"")+(keyNames[key] ?? "Key \(key)")}
    private func displayTitle(_ record:[String:Any])->String {
        let title=(record["desc"] as? String ?? "").replacingOccurrences(of:#"^\[[^\]]+\]\s*"#,with:"",options:.regularExpression)
        return title.isEmpty ? commandName(record):title
    }
    private func commandName(_ record:[String:Any])->String {(record["argv"] as? [String])?.joined(separator:" ") ?? (record["cmd"] as? [String])?.joined(separator:" ") ?? record["cmd"] as? String ?? "Action"}
}
let keyNames:[Int:String]=[0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"+",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"Space",50:"`",51:"⌫",53:"⎋",123:"←",124:"→",125:"↓",126:"↑"]
struct HotkeyRecorder:NSViewRepresentable {
    let label:String;let recording:Bool;let onBegin:()->Void;let onCancel:()->Void;let onRecord:(Int,Int)->Void;let onUnavailable:(String)->Void
    func makeNSView(context:Context)->RecorderButton{let v=RecorderButton();v.bezelStyle = .rounded;return v}
    func updateNSView(_ view:RecorderButton,context:Context){
        view.onBegin=onBegin;view.onCancel=onCancel;view.onRecord=onRecord;view.onUnavailable=onUnavailable
        view.title=recording ? "Type Shortcut…":label;view.setAccessibilityLabel("Keyboard Shortcut: "+label)
        if recording {view.window?.makeFirstResponder(view)};view.recording=recording
    }
    static func dismantleNSView(_ view:RecorderButton,coordinator:()){let wasRecording=view.recording;view.recording=false;view.stopCapture();if wasRecording {DispatchQueue.main.async{view.onCancel?()}}}
}
final class RecorderButton:NSButton {
    var recording=false {didSet{guard recording != oldValue else{return};if recording{startCapture()}else{stopCapture()}}}
    var onBegin:(()->Void)?;var onCancel:(()->Void)?;var onRecord:((Int,Int)->Void)?;var onUnavailable:((String)->Void)?
    private var tap:CFMachPort?
    private var source:CFRunLoopSource?
    private var observers:[NSObjectProtocol]=[]
    private var timeout:Task<Void,Never>?
    override init(frame:NSRect){super.init(frame:frame);target=self;action=#selector(beginRecording)}
    required init?(coder:NSCoder){super.init(coder:coder);target=self;action=#selector(beginRecording)}
    override var acceptsFirstResponder:Bool {true}
    @objc private func beginRecording(){onBegin?();window?.makeFirstResponder(self)}
    private func startCapture(){
        let callback:CGEventTapCallBack={_,type,event,userInfo in
            guard let userInfo else{return Unmanaged.passUnretained(event)}
            let button=Unmanaged<RecorderButton>.fromOpaque(userInfo).takeUnretainedValue()
            guard button.recording else{return Unmanaged.passUnretained(event)}
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {button.failCapture("Recording stopped. Click the shortcut to try again.");return Unmanaged.passUnretained(event)}
            guard NSApp.isActive,button.window?.isKeyWindow==true,button.window?.firstResponder === button else {button.cancelCapture();return Unmanaged.passUnretained(event)}
            guard type == .keyDown else{return Unmanaged.passUnretained(event)}
            let key=Int(event.getIntegerValueField(.keyboardEventKeycode))
            if key==53{button.cancelCapture();return nil}
            let flags=event.flags
            let mods=(flags.contains(.maskCommand) ? 0x100:0)|(flags.contains(.maskAlternate) ? 0x800:0)|(flags.contains(.maskShift) ? 0x200:0)|(flags.contains(.maskControl) ? 0x1000:0)
            guard mods&0x1900 != 0 else {NSSound.beep();return nil}
            button.recording=false;button.onRecord?(key,mods);return nil
        }
        let mask=CGEventMask(1)<<CGEventType.keyDown.rawValue
        guard let port=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mask,callback:callback,userInfo:Unmanaged.passUnretained(self).toOpaque()),let runLoopSource=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,port,0) else {
            failCapture("Shortcut recording requires keyboard access. Check Accessibility and Input Monitoring in System Settings.");return
        }
        tap=port;source=runLoopSource;CFRunLoopAddSource(CFRunLoopGetMain(),runLoopSource,.commonModes);CGEvent.tapEnable(tap:port,enable:true)
        let center=NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification,NSApplication.didHideNotification] {observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self]_ in self?.cancelCapture()})}
        if let window {for name in [NSWindow.didResignKeyNotification,NSWindow.willCloseNotification] {observers.append(center.addObserver(forName:name,object:window,queue:.main){[weak self]_ in self?.cancelCapture()})}}
        timeout=Task{[weak self] in try?await Task.sleep(nanoseconds:30_000_000_000);if !Task.isCancelled{self?.cancelCapture()}}
    }
    func stopCapture(){
        timeout?.cancel();timeout=nil
        if let tap{CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)}
        if let source{CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)}
        tap=nil;source=nil;for token in observers{NotificationCenter.default.removeObserver(token)};observers=[]
    }
    private func cancelCapture(){recording=false;onCancel?()}
    private func failCapture(_ message:String){recording=false;DispatchQueue.main.async{[weak self]in self?.onUnavailable?(message)}}
    override func keyDown(with event:NSEvent){
        guard recording else {if event.keyCode==49 || event.keyCode==36{beginRecording()};return}
        if event.keyCode==53{cancelCapture();return}
        let f=event.modifierFlags;guard !f.intersection([.command,.option,.control]).isEmpty else{NSSound.beep();return}
        let mods=(f.contains(.command) ? 0x100:0)|(f.contains(.option) ? 0x800:0)|(f.contains(.shift) ? 0x200:0)|(f.contains(.control) ? 0x1000:0)
        recording=false;onRecord?(Int(event.keyCode),mods)
    }
    override func performKeyEquivalent(with event:NSEvent)->Bool {if recording{keyDown(with:event);return true};return false}
    override func resignFirstResponder()->Bool {if recording{cancelCapture()};return super.resignFirstResponder()}
    deinit{stopCapture()}
}
