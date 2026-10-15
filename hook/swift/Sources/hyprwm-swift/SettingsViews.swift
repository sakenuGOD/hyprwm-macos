import AppKit
import SwiftUI

struct SettingsRootView: View {
    @ObservedObject var store: SettingsStore
    let replay: () -> Void
    var initialPage: SettingsPage = .general
    @State private var selection: SettingsPage? = .general
    @State private var search=""
    @State private var resetConfirmation=false
    @FocusState private var searchFocused:Bool
    var body: some View {
        NavigationSplitView {
            VStack(spacing:0) {
                HStack(spacing:8) { Image(systemName:"magnifyingglass").foregroundStyle(.secondary); TextField("Search Settings",text:$search).textFieldStyle(.plain).focused($searchFocused)
                    if !search.isEmpty { Button { search="" } label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(.plain).foregroundStyle(.secondary) }
                }.padding(9).background(.quaternary,in:RoundedRectangle(cornerRadius:8)).padding(12)
                List(selection:$selection) {
                    ForEach(SettingsPage.allCases.filter { page in search.isEmpty || page.title.localizedCaseInsensitiveContains(search) || settingSpecs.contains{$0.page==page && $0.title.localizedCaseInsensitiveContains(search)} }) { page in
                        HStack(spacing:11) { Image(systemName:page.symbol).font(.system(size:14,weight:.medium)).foregroundStyle(.white).frame(width:27,height:27).background(page.color,in:RoundedRectangle(cornerRadius:6)); Text(page.title) }.padding(.vertical,3).tag(page)
                    }
                }.listStyle(.sidebar)
                HStack(spacing:7) { Circle().fill(store.trusted && store.connected ? (store.enabled ? .green : .orange) : .red).frame(width:7,height:7)
                    Text(!store.trusted ? "Permission Required" : !store.connected ? "Disconnected" : store.enabled ? "HyprWM Running" : "Tiling Paused").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(16)
            }.navigationSplitViewColumnWidth(min:210,ideal:235,max:270)
        } detail: {
            let page=selection ?? .general
            VStack(spacing:0) {
                HStack(spacing:13) {
                    Image(systemName:page.symbol).font(.system(size:23,weight:.medium)).foregroundStyle(.white).frame(width:48,height:48).background(page.color,in:RoundedRectangle(cornerRadius:12))
                    Text(page.title).font(.title2.weight(.semibold))
                    Spacer()
                    if page != .general && page != .about && page != .hotkeys && sectionChanged(page) { Button {resetConfirmation=true} label:{ Image(systemName:"arrow.counterclockwise") }.help("Reset Section").buttonStyle(.borderless) }
                }.padding(.horizontal,UIStyle.spacious).padding(.vertical,UIStyle.large)
                Divider()
                if let error=store.error { HStack(alignment:.top) {Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(.orange); Text(error).font(.callout); Spacer(); Button {store.error=nil} label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.padding(14).background(.orange.opacity(0.08)) }
                ScrollViewReader { proxy in
                Form {
                    if page == .general { general }
                    if [.layout,.animations,.appearance].contains(page) { Section { TilingPreview(store:store,animated:page == .animations).frame(height:190).listRowInsets(EdgeInsets()) } }
                    let specs=settingSpecs.filter { $0.page==page && (search.isEmpty || page.title.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search)) }
                    ForEach(Array(Set(specs.map(\.group))).sorted(),id:\.self) { group in
                        Section(group) {
                            ForEach(specs.filter{$0.group==group}) { spec in SettingRow(store:store,spec:spec) }
                            if page == .appearance && group == "Borders" { gradientColors }
                        }
                    }
                    if page == .animations { AnimationSettings(store:store) }
                    if page == .rules { AppRulesSettings(store:store) }
                    if page == .hotkeys { HotkeySettings(store:store) }
                    if page == .advanced { Section("Configuration") {
                        Button {store.openConfig()} label:{Label("Open Configuration",systemImage:"doc.text")}
                        Button {store.importConfig()} label:{Label("Import HyprWM Configuration…",systemImage:"square.and.arrow.down")}
                        Button {store.importForeignConfig()} label:{Label("Import From Another Window Manager…",systemImage:"arrow.down.doc")}
                        Button {store.exportConfig()} label:{Label("Export…",systemImage:"square.and.arrow.up")}
                        Button {store.resetConfig()} label:{Label("Reset Configuration",systemImage:"arrow.counterclockwise")}
                        Button {NSWorkspace.shared.open(store.url.deletingLastPathComponent())} label:{Label("Show Configuration Folder",systemImage:"folder")}
                    } }
                    if page == .about { about }
                    if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW_SCROLL"] == "bottom" {Color.clear.frame(height:0).id("settings-bottom")}
                }.formStyle(.grouped).disabled(!store.loaded && ![.general,.about,.advanced].contains(page))
                    .onAppear { if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW_SCROLL"] == "bottom" {DispatchQueue.main.asyncAfter(deadline:.now()+0.5){proxy.scrollTo("settings-bottom",anchor:.bottom)}} }
                }
                HStack { Spacer(); if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW"] == "1" {Text("Preview").font(.caption).foregroundStyle(.tertiary)} else if store.saving {ProgressView().controlSize(.mini);Text("Saving…").font(.caption).foregroundStyle(.secondary)} else {Text("Changes apply automatically").font(.caption).foregroundStyle(.tertiary)} }.padding(.horizontal,24).padding(.vertical,9)
            }.background(Color(nsColor:.windowBackgroundColor))
            .confirmationDialog("Reset this section?",isPresented:$resetConfirmation,titleVisibility:.visible) {Button("Reset Settings",role:.destructive){store.resetPage(page)}} message:{Text("Other sections will stay unchanged.")}
        }.frame(minWidth:830,minHeight:640)
        .onAppear { selection=initialPage;searchFocused=true }

        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) {_ in store.trusted=AXIsProcessTrusted();store.reload()}
    }
    private func sectionChanged(_ page:SettingsPage)->Bool {
        if store.hasChanges(page) {return true}
        if page == .appearance {return !store.isDefault("appearance.border.active.colors",fallback:["rgba(ffb4a4ee)","rgba(7fd0f5ee)"])}
        if page == .animations {return !store.isDefault("animations",fallback:[:]) || !store.isDefault("curves",fallback:[:])}
        if page == .rules {return !store.isDefault("window_rules",fallback:[])}
        return false
    }
    private var general: some View {
        Group {
            Section {
                HStack { VStack(alignment:.leading,spacing:5) {Text("Tiling").font(.headline);Text("Arrange windows automatically.").foregroundStyle(.secondary)};Spacer();Toggle("",isOn:Binding(get:{store.enabled},set:{store.set("runtime.enabled",$0)})).labelsHidden().toggleStyle(.switch).disabled(!store.connected) }
                HStack {Label("Accessibility",systemImage:store.trusted ? "checkmark.shield.fill":"hand.raised.fill").foregroundStyle(store.trusted ? .green:.primary);Spacer();Text(store.trusted ? "Granted":"Permission Required").foregroundStyle(.secondary);if !store.trusted {Button("Grant Access"){store.requestAccess()}}}
            }
            Section("System") {
                LabeledContent("macOS Version",value:ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Reduce Motion",value:NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? "Enabled in macOS":"Off")
            }
            Section {TilingPreview(store:store,animated:false).frame(height:190).listRowInsets(EdgeInsets())}
        }
    }
    private var gradientColors: some View {
        let values=(store.value("appearance.border.active.colors",fallback:["rgba(ffb4a4ee)","rgba(7fd0f5ee)"]) as? [String]) ?? ["rgba(ffb4a4ee)"]
        return VStack(alignment:.leading,spacing:12) {
            HStack {Text("Active Border");Spacer();if settingChanged(store,"appearance.border.active.colors",fallback:["rgba(ffb4a4ee)","rgba(7fd0f5ee)"]) {Button {store.reset("appearance.border.active.colors")} label:{Image(systemName:"arrow.counterclockwise")}.buttonStyle(.borderless).help("Reset Colors")}}
            HStack {
                ForEach(values.indices,id:\.self) {index in ColorPicker("Color \(index+1)",selection:Binding(get:{nativeColor(values[index])},set:{ var colors=values;colors[index]=runtimeColor($0);store.set("appearance.border.active.colors",colors)})).labelsHidden()
                    if values.count>1 {Button {var colors=values;colors.remove(at:index);store.set("appearance.border.active.colors",colors)} label:{Image(systemName:"minus.circle")}.buttonStyle(.borderless)}
                }
                if values.count<8 {Button {store.set("appearance.border.active.colors",values+["rgba(7fd0f5ee)"])} label:{Image(systemName:"plus.circle")}.buttonStyle(.borderless).help("Add Color")};Spacer()
            }
        }.padding(.vertical,5)
    }
    private var about: some View {
        Group {
            Section {
                VStack(spacing:13) {AppMark().frame(width:84,height:84);Text("HyprWM").font(.system(size:28,weight:.semibold));Text(store.runtimeVersion.isEmpty ? appVersion : "Version "+store.runtimeVersion).font(.caption).foregroundStyle(.tertiary)}.frame(maxWidth:.infinity).padding(.vertical,24)
            }
            Section {
                Link(destination:URL(string:"https://github.com/sakenuGOD/hyprwm-macos")!){Label("HyprWM on GitHub",systemImage:"arrow.up.right.square")}
                Link(destination:URL(string:"https://github.com/sakenuGOD/hyprwm-macos/issues")!){Label("Report an Issue",systemImage:"bubble.left.and.bubble.right")}
                Button {store.copyDiagnosis()} label:{Label("Copy Diagnostics",systemImage:"doc.on.doc")}
                Text("Diagnostics include the version, connection, and permissions. Window contents and personal settings are excluded.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
var appVersion: String { let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String; let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String; return version.map { "Version "+$0+(build.map{" ("+$0+")"} ?? "") } ?? "Local Build · Swift" }
struct AppMark: View {
    var body: some View {GeometryReader{geometry in
        let width=min(geometry.size.width,geometry.size.height)
        ZStack {RoundedRectangle(cornerRadius:width*0.24).fill(Color.accentColor)
            HStack(spacing:width*0.06){RoundedRectangle(cornerRadius:width*0.06).fill(.white.opacity(0.95));VStack(spacing:width*0.06){RoundedRectangle(cornerRadius:width*0.06).fill(.white.opacity(0.95));RoundedRectangle(cornerRadius:width*0.06).fill(.white.opacity(0.6))}}.padding(width*0.21)
        }
    }.accessibilityLabel("HyprWM")}
}
struct SettingRow: View {
    @ObservedObject var store: SettingsStore; let spec: SettingSpec
    var body: some View {
        HStack(spacing:12) {
            VStack(alignment:.leading,spacing:3){Text(spec.title);if !spec.note.isEmpty{Text(spec.note).font(.caption).foregroundStyle(.secondary)}}
            Spacer(minLength:12)
            switch spec.kind {
            case let .number(range,step,unit):
                Slider(value:Binding(get:{store.number(spec.path,(spec.fallback as? NSNumber)?.doubleValue ?? 0)},set:{store.set(spec.path,min(range.upperBound,max(range.lowerBound,($0/step).rounded()*step)))}),in:range).frame(width:130)
                TextField("",value:Binding(get:{store.number(spec.path,(spec.fallback as? NSNumber)?.doubleValue ?? 0)},set:{if range.contains($0) && $0.isFinite {store.set(spec.path,$0)}}),format:.number.precision(.fractionLength(0...2))).multilineTextAlignment(.trailing).frame(width:68).textFieldStyle(.roundedBorder).lineLimit(1).fixedSize(horizontal:false,vertical:true)
                Stepper(spec.title,value:Binding(get:{store.number(spec.path,(spec.fallback as? NSNumber)?.doubleValue ?? 0)},set:{if range.contains($0) && $0.isFinite {store.set(spec.path,$0)}}),in:range,step:step).labelsHidden().fixedSize()
                Text(unit).lineLimit(1).font(.caption).foregroundStyle(.secondary).frame(width:21,alignment:.leading)
            case .toggle: Toggle(spec.title,isOn:Binding(get:{store.bool(spec.path,(spec.fallback as? Bool) ?? false)},set:{store.set(spec.path,$0)})).labelsHidden().toggleStyle(.switch)
            case let .choice(choices):
                Picker(spec.title,selection:Binding(get:{String(describing:store.value(spec.path,fallback:spec.fallback))},set:{value in store.set(spec.path,spec.fallback is Int ? (Int(value) ?? 0) as Any:value)})) {ForEach(choices,id:\.0){Text($0.1).tag($0.0)}}.labelsHidden().frame(maxWidth:220)
            case .color: ColorPicker(spec.title,selection:Binding(get:{nativeColor(store.string(spec.path,spec.fallback as? String ?? ""))},set:{store.set(spec.path,runtimeColor($0))})).labelsHidden()
            }
            if settingChanged(store,spec.path,fallback:spec.fallback) {Button {store.reset(spec.path)} label:{Image(systemName:"arrow.counterclockwise").font(.caption)}.buttonStyle(.borderless).foregroundStyle(.secondary).help("Reset: "+spec.title).accessibilityLabel("Reset "+spec.title).frame(width:16)} else {Color.clear.frame(width:16,height:16)}
        }.padding(.vertical,2)
    }
}

/// Compare effective values, so a redundant override does not show a reset control.
func settingChanged(_ store:SettingsStore,_ path:String,fallback:Any)->Bool {
    !store.isDefault(path,fallback:fallback)
}
