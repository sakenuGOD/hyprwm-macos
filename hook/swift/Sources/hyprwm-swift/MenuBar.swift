import AppKit
import SwiftUI
import HyprCore

/// Native companion and in-process daemon share one UI and command surface.
final class MenuBarController:NSObject,NSMenuDelegate,NSWindowDelegate {
    typealias Send=(String,@escaping(Result<String,Error>)->Void)->Void
    private let send:Send
    private let hook:String
    private let companion:Bool
    private let item:NSStatusItem
    private let stateItem=NSMenuItem(title:"Connecting…",action:nil,keyEquivalent:"")
    private let configErrorItem=NSMenuItem(title:"",action:nil,keyEquivalent:"")
    private var enabled=true,connected=false,refreshing=false,unverified=false
    private var runtimeMode=""
    private var window:NSWindow?
    private var onboardingWindow:NSWindow?
    private var poll:Timer?
    private let store:SettingsStore
    var onQuit:((@escaping(Bool)->Void)->Void)?
    init(hook:String,companion:Bool,startupAnimation:Bool,send:@escaping Send) {
        self.hook=hook;self.companion=companion;self.send=send;store=SettingsStore(hook:hook,send:send)
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.autosaveName="HyprWMControls"
        super.init()
        if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW"] == "1",let mode=ProcessInfo.processInfo.environment["HYPRWM_UI_APPEARANCE"] {
            NSApp.appearance=NSAppearance(named:mode=="light" ? .aqua:.darkAqua)
        }
        item.menu = makeMenu()
        item.button?.image=Self.brandStatusImage()
        item.button?.toolTip="HyprWM — Window Management";item.button?.setAccessibilityLabel("HyprWM, Tiling Controls")
        poll=Timer.scheduledTimer(withTimeInterval:3,repeats:true){[weak self]_ in self?.refresh()};poll?.tolerance=1;refresh()

    }
    private static func brandStatusImage()->NSImage {
        let image=NSImage(size:NSSize(width:20,height:20),flipped:false){_ in
            NSColor.labelColor.setFill()
            for rect in [NSRect(x:2,y:3,width:7,height:14),NSRect(x:11,y:11,width:7,height:6),NSRect(x:11,y:3,width:7,height:6)] {NSBezierPath(roundedRect:rect,xRadius:1.6,yRadius:1.6).fill()}
            return true
        };image.isTemplate=true;image.accessibilityDescription="HyprWM";return image
    }
    deinit{poll?.invalidate();NSStatusBar.system.removeStatusItem(item)}
    private func add(_ title:String,_ action:Selector,_ menu:NSMenu,symbol:String,key:String=""){let entry=NSMenuItem(title:title,action:action,keyEquivalent:key);entry.target=self;entry.image=NSImage(systemSymbolName:symbol,accessibilityDescription:nil);menu.addItem(entry)}
    func menuWillOpen(_ menu:NSMenu){refresh();updateMenu(menu)}
    private func refresh(){guard !refreshing else{return};refreshing=true;store.trusted=AXIsProcessTrusted();send("status"){[weak self]result in
        guard let self else{return};self.refreshing=false
        switch result {
        case let .success(text):self.connected=true;if let json=try?JSON.parse(text){self.unverified=json["compatibility"]?["verified"] == .bool(false);self.enabled=json["enabled"]?.truthy ?? true;self.runtimeMode=json["mode"]?.string ?? json["daemon"]?["mode"]?.string ?? json["engine"]?["mode"]?.string ?? "engine";self.store.runtimeName=self.runtimeMode.capitalized+" · "+(json["daemon"]?["runtime"]?.string ?? "Swift");self.store.runtimeVersion=json["daemon"]?["version"]?.string ?? ""}
        case .failure:self.connected=false
        }
        self.store.connected=self.connected;self.store.enabled=self.enabled
        self.stateItem.title = self.unverified ? "Unverified on this macOS build" : !self.store.trusted ? "Accessibility Access Required" : !self.connected ? "HyprWM Disconnected" : (self.enabled ? "HyprWM Running":"Tiling Paused")+" · "+self.runtimeMode.capitalized
        let color:NSColor = !self.store.trusted || !self.connected ? .systemRed:self.enabled ? .systemGreen:.systemOrange
        self.stateItem.attributedTitle=NSAttributedString(string:self.stateItem.title,attributes:[.foregroundColor:color])

        self.item.button?.appearsDisabled = !self.connected || !self.enabled
        if let menu=self.item.menu {self.updateMenu(menu)}
    }}
    private func command(_ value:String){send(value){[weak self]result in if case let .failure(error)=result{self?.store.error=error.localizedDescription};self?.refresh()}}
    @objc private func toggle(){command(enabled ? "pause" : "resume")}
    @objc private func returnHidden(){command("restore-all")}
    @objc private func retile(){command("retile")}
    @objc private func balance(){command("balance")}
    @objc private func checkConnection(){refresh()}
    @objc private func copyDiagnostics(){store.copyDiagnosis()}
    func showSettings(){showSettings(page:.general)}
    func showSettings(page:SettingsPage){ settings(page:page) }
    private func makeMenu()->NSMenu {
        let menu=NSMenu();menu.delegate=self;menu.autoenablesItems=false
        stateItem.isEnabled=false;menu.addItem(stateItem);configErrorItem.isEnabled=false;configErrorItem.isHidden=true;menu.addItem(configErrorItem);menu.addItem(.separator())
        add("Pause Tiling",#selector(toggle),menu,symbol:"pause.circle",key:"p")
        add("Borders",#selector(toggleBorders),menu,symbol:"rectangle",key:"")
        add("Animations",#selector(toggleAnimations),menu,symbol:"waveform.path",key:"")
        add("Focus Follows Mouse",#selector(togglePointerFocus),menu,symbol:"cursorarrow",key:"")
        menu.addItem(.separator())
        add("Retile Windows",#selector(retile),menu,symbol:"rectangle.split.2x2",key:"r")
        add("Restore Hidden Windows",#selector(returnHidden),menu,symbol:"rectangle.on.rectangle",key:"w")
        add("Balance Layout",#selector(balance),menu,symbol:"equal.square",key:"=")
        menu.addItem(.separator())
        add("Settings…",#selector(openSettings),menu,symbol:"gearshape",key:",")
        add("Application Rules…",#selector(showRules),menu,symbol:"app.badge")
        add("Open Configuration",#selector(openConfig),menu,symbol:"doc.text")
        let diagnostics=NSMenu();diagnostics.autoenablesItems=false
        add("Check Connection",#selector(checkConnection),diagnostics,symbol:"arrow.clockwise")
        add("Copy Diagnostics",#selector(copyDiagnostics),diagnostics,symbol:"doc.on.doc")
        add("Accessibility…",#selector(openAccess),diagnostics,symbol:"hand.raised")
        let diagnosticsItem=NSMenuItem(title:"Diagnostics",action:nil,keyEquivalent:"");diagnosticsItem.submenu=diagnostics;menu.addItem(diagnosticsItem)
        add("About HyprWM…",#selector(showAbout),menu,symbol:"info.circle")
        add("Report an Issue…",#selector(reportIssue),menu,symbol:"bubble.left")
        menu.addItem(.separator());add("Quit HyprWM",#selector(quit),menu,symbol:"power",key:"q")
        for entry in menu.items where !entry.keyEquivalent.isEmpty {entry.keyEquivalentModifierMask = [.command,.option]}
        menu.items.first(where:{$0.action == #selector(openSettings)})?.keyEquivalentModifierMask = .command
        menu.items.first(where:{$0.action == #selector(toggle)})?.keyEquivalentModifierMask = [.control,.option]
        return menu
    }
    private func updateMenu(_ menu:NSMenu) {
        configErrorItem.isHidden = store.error == nil
        configErrorItem.title = String((store.error ?? "").split(separator:"\n").first.map(String.init)?.prefix(120) ?? "".prefix(120))
        configErrorItem.toolTip=store.error
        for entry in menu.items {
            if entry.action == #selector(toggle) {entry.title=enabled ? "Pause Tiling":"Resume Tiling";entry.state = .off;entry.isEnabled=connected && !unverified}
            if let action=entry.action,[#selector(retile),#selector(balance),#selector(returnHidden)].contains(action) {entry.isEnabled=connected && !unverified}
            if entry.action == #selector(toggleBorders) {entry.state=store.number("appearance.border.size",2)>0 ? .on:.off;entry.isEnabled=store.loaded}
            if entry.action == #selector(toggleAnimations) {entry.state=store.bool("animations.enabled") ? .on:.off;entry.isEnabled=store.loaded}
            if entry.action == #selector(togglePointerFocus) {entry.state=store.number("focus.follow_mouse",1)>0 ? .on:.off;entry.isEnabled=store.loaded}
        }
    }
    @objc private func toggleBorders(){store.set("appearance.border.size",store.number("appearance.border.size",2)>0 ? 0:2)}
    @objc private func toggleAnimations(){store.set("animations.enabled",!store.bool("animations.enabled"))}
    @objc private func togglePointerFocus(){store.set("focus.follow_mouse",store.number("focus.follow_mouse",1)>0 ? 0:1)}
    @objc private func showRules(){settings(page:.rules)}
    @objc private func showAbout(){settings(page:.about)}
    @objc private func openConfig(){store.openConfig()}
    @objc private func openAccess(){store.requestAccess()}
    @objc private func reportIssue(){NSWorkspace.shared.open(URL(string:"https://github.com/sakenuGOD/hyprwm-macos/issues")!)}
    @objc private func showPanel(){guard let menu=item.menu else{return};updateMenu(menu);item.button?.performClick(nil)}
    private func closePanel(){}
    func showPreview(section:String?,onboardingStep:Int?){
        if section=="menu" {showPanel()}

        else {showSettings(page:SettingsPage(rawValue:section ?? "general") ?? .general)}
    }
    @objc private func openSettings(){settings(page:.general)}
    private func settings(page:SettingsPage){
        if let window{window.contentView=NSHostingView(rootView:SettingsRootView(store:store,replay:{[weak self]in self?.replayOnboarding()},initialPage:page));presentOnCurrentSpace(window);return}
        let created=NSWindow(contentRect:NSRect(x:0,y:0,width:960,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        created.setAccessibilitySubrole(.dialog)
        created.title="HyprWM";created.titlebarAppearsTransparent=true;created.toolbar=NSToolbar(identifier:"hyprwm.settings.toolbar");created.toolbarStyle = .unified
        created.minSize=NSSize(width:850,height:680);created.isReleasedWhenClosed=false;created.delegate=self
        created.contentView=NSHostingView(rootView:SettingsRootView(store:store,replay:{[weak self] in self?.replayOnboarding()},initialPage:page))
        window=created;presentOnCurrentSpace(created)
    }
    private func presentOnCurrentSpace(_ window:NSWindow){
        // Select the display before activation can change the active application or Space.
        let pointer=NSEvent.mouseLocation
        let screen=NSScreen.screens.first(where:{$0.frame.contains(pointer)}) ?? NSScreen.main ?? NSScreen.screens.first
        window.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary]
        window.level = .normal
        if window.isMiniaturized {window.deminiaturize(nil)}
        if let screen {
            let visible=screen.visibleFrame
            let size=NSSize(width:min(window.frame.width,visible.width),height:min(window.frame.height,visible.height))
            let frame=NSRect(x:visible.midX-size.width/2,y:visible.midY-size.height/2,width:size.width,height:size.height)
            window.setFrame(frame,display:true,animate:false)
        }
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func replayOnboarding(){replayOnboarding(step:0,preview:false)}
    private func replayOnboarding(step:Int,preview:Bool){
        if let onboardingWindow{onboardingWindow.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);return}
        let created=NSWindow(contentRect:NSRect(x:0,y:0,width:580,height:570),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false)
        created.title="Welcome to HyprWM";created.titlebarAppearsTransparent=true;created.isReleasedWhenClosed=false;created.delegate=self
        created.contentView=NSHostingView(rootView:OnboardingView(store:store,completion:{[weak self] in self?.onboardingWindow?.close();self?.onboardingWindow=nil;self?.openSettings()},initialStep:step,preview:preview));onboardingWindow=created;created.center();created.makeKeyAndOrderFront(nil);created.makeFirstResponder(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func windowWillClose(_ notification:Notification){if (notification.object as? NSWindow) === onboardingWindow {onboardingWindow=nil}}
    @objc private func quit(){
        if ProcessInfo.processInfo.environment["HYPRWM_UI_PREVIEW"] == "1" {NSApp.terminate(nil);return}
        guard !store.shuttingDown else {return};store.shuttingDown=true
        if !companion {
            guard let onQuit else {store.shuttingDown=false;store.error="Safe shutdown is currently unavailable.";return}
            onQuit{[weak self]confirmed in if confirmed{NSApp.terminate(nil)}else{self?.store.shuttingDown=false;self?.store.error="Window restoration is incomplete. HyprWM is still running.";self?.showSettings(page:.general)}};return
        }
        // Existing lifecycle authority restores hidden windows, waits for drain, and checks exact process identities.
        // Run it off the UI queue; a timeout terminates only this helper, never a WM process.
        let hook=self.hook
        DispatchQueue.global(qos:.userInitiated).async{[weak self] in
            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["python3",hook+"/lifecycle.py","stop"]
            let output=Pipe();process.standardOutput=output;process.standardError=output
            do {
                try process.run()
                let deadline=Date().addingTimeInterval(30)
                while process.isRunning && Date()<deadline {Thread.sleep(forTimeInterval:0.05)}
                if process.isRunning {process.terminate();throw NSError(domain:"HyprWM",code:1,userInfo:[NSLocalizedDescriptionKey:"Shutdown was not confirmed. HyprWM is still running."])}
                let data=output.fileHandleForReading.readDataToEndOfFile()
                guard process.terminationStatus==0,let report=(try?JSONSerialization.jsonObject(with:data)) as? [String:Any],report["ok"] as? Bool==true else {throw NSError(domain:"HyprWM",code:2,userInfo:[NSLocalizedDescriptionKey:"HyprWM could not shut down safely. Check Diagnostics for details."])}
                DispatchQueue.main.async{NSApp.terminate(nil)}
            } catch {DispatchQueue.main.async{self?.store.shuttingDown=false;self?.store.error=error.localizedDescription;self?.showSettings(page:.general)}}
        }
    }
}

/// Pure AppKit-coordinate geometry, shared by the popover and detached fallback.
enum MenuPlacement {
    static func validAnchor(_ anchor:NSRect,on screen:NSRect)->Bool {
        guard [anchor.minX,anchor.minY,anchor.width,anchor.height].allSatisfy(\.isFinite),anchor.width>0,anchor.height>0 else{return false}
        return anchor.intersects(screen) && anchor.maxY >= screen.maxY-UIStyle.spacious*2
    }
    static func contentSize(in visible:NSRect)->NSSize {
        NSSize(width:min(350,max(1,visible.width-UIStyle.large*2)),height:min(720,max(1,visible.height-UIStyle.large*2-UIStyle.spacious)))
    }
    static func clamp(_ frame:NSRect,to visible:NSRect)->NSRect {
        let safe=visible.insetBy(dx:min(UIStyle.small,visible.width/4),dy:min(UIStyle.small,visible.height/4))
        let size=NSSize(width:min(frame.width,safe.width),height:min(frame.height,safe.height))
        return NSRect(x:min(max(frame.minX,safe.minX),safe.maxX-size.width),y:min(max(frame.minY,safe.minY),safe.maxY-size.height),width:size.width,height:size.height)
    }
    static func fallbackFrame(size:NSSize,in visible:NSRect)->NSRect {
        clamp(NSRect(x:visible.maxX-size.width-UIStyle.large,y:visible.maxY-size.height-UIStyle.large,width:size.width,height:size.height),to:visible)
    }
}

private final class AnchoredMenuPanel:NSPanel {
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {false}
}
