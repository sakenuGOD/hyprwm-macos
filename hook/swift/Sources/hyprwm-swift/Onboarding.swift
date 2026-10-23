import AppKit
import SwiftUI

struct OnboardingView:View {
    @ObservedObject var store:SettingsStore
    let completion:()->Void
    var initialStep:Int=0
    var preview:Bool=false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step=0
    @State private var appeared=false
    var body:some View {
        VStack(spacing:0) {
            HStack{Text("HyprWM").font(.headline).foregroundStyle(.secondary);Spacer();Button("Skip"){finish()}.buttonStyle(.plain).foregroundStyle(.secondary)}.padding(24)
            Spacer(minLength:8)
            Group {
                if step==0 {
                    VStack(spacing:20){StartupMarkView().frame(width:88,height:88).scaleEffect(appeared ? 1:0.8).opacity(appeared ? 1:0);Text("Window Tiling").font(.system(size:30,weight:.semibold));Text("Arrange windows automatically.").foregroundStyle(.secondary);TilingPreview(store:store,animated:true).frame(width:430,height:180)}
                } else if step==1 {
                    VStack(spacing:20){Image(systemName:store.trusted ? "checkmark.shield.fill":"hand.raised.fill").font(.system(size:56)).foregroundStyle(store.trusted ? .green:.accentColor);Text("Allow Window Management").font(.title.weight(.semibold));Text("HyprWM needs Accessibility permission to arrange windows and change focus.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:410);Button(store.trusted ? "Access Granted":"Open Accessibility Settings"){store.requestAccess();NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)}.buttonStyle(.borderedProminent).controlSize(.large);Text("Continues automatically when access is granted.").font(.caption).foregroundStyle(.secondary)}
                        .task {guard !preview else {return};while !Task.isCancelled && step==1 {store.trusted=AXIsProcessTrusted();if store.trusted {try? await Task.sleep(nanoseconds:500_000_000);if !Task.isCancelled {advance()};break};try? await Task.sleep(nanoseconds:800_000_000)}}
                } else if step==2 {
                    VStack(spacing:22){Image(systemName:"command").font(.system(size:52)).foregroundStyle(.indigo);Text("Keyboard Shortcuts").font(.title.weight(.semibold));Text("View and change shortcuts in Settings.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:410);VStack(spacing:14){shortcut("⌃⌥ ← ↑ ↓ →","Change Focus");shortcut("⌃⌥⇧ ← ↑ ↓ →","Move Window");shortcut("⌃⌥ F","Float Window")}.padding(22).background(.quaternary,in:RoundedRectangle(cornerRadius:14)).frame(width:420)}
                } else {
                    VStack(spacing:20){Image(systemName:"checkmark.circle.fill").font(.system(size:68)).foregroundStyle(.green);Text("Setup Complete").font(.system(size:30,weight:.semibold));Text("Open windows to start tiling. Use the menu bar to change settings.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:420);TilingPreview(store:store,animated:false).frame(width:430,height:160)}
                }
            }.transition(reduceMotion ? .opacity:.opacity.combined(with:.move(edge:.trailing)))
            Spacer(minLength:22)
            HStack {HStack(spacing:7){ForEach(0..<4){index in Circle().fill(index==step ? Color.accentColor:Color.secondary.opacity(0.25)).frame(width:6,height:6)}};Spacer();if step>1 {Button("Back"){withAnimation(reduceMotion ? nil:.easeInOut(duration:0.2)){step-=1}}};if step != 1 {Button(step==3 ? "Done":"Continue"){step==3 ? finish():advance()}.buttonStyle(.borderedProminent).controlSize(.large)}}.padding(28)
        }.frame(width:580,height:570).background(Color(nsColor:.windowBackgroundColor))
            .tint(UIStyle.accent)
            .task {step=initialStep;withAnimation(reduceMotion ? nil:.easeOut(duration:0.6)){appeared=true};try? await Task.sleep(nanoseconds:2_500_000_000);if !Task.isCancelled && !preview && step==0 {advance()}}
    }
    private func shortcut(_ key:String,_ action:String)->some View {HStack{Text(action);Spacer();Text(key).font(.system(.body,design:.rounded).weight(.medium)).foregroundStyle(.secondary)}}
    private func advance(){withAnimation(reduceMotion ? nil:.easeInOut(duration:0.25)){step=min(3,step+1)}}
    private func finish(){if !preview {UserDefaults.standard.set(true,forKey:"hyprwm.onboarding.completed.v1")};completion()}
}

/// One finite Core Animation entrance, with no display link or repeating timer.
struct StartupMarkView:NSViewRepresentable {
    func makeNSView(context:Context)->StartupMarkCanvas{StartupMarkCanvas()}
    func updateNSView(_ view:StartupMarkCanvas,context:Context){}
    static func dismantleNSView(_ view:StartupMarkCanvas,coordinator:()){view.layer?.sublayers?.forEach{$0.removeAllAnimations()}}
}
final class StartupMarkCanvas:NSView {
    private let gradient=CAGradientLayer()
    private let tiles=(0..<3).map{_ in CAShapeLayer()}
    private var played=false
    override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;layer=CALayer();gradient.colors=[NSColor.controlAccentColor.cgColor,NSColor.controlAccentColor.cgColor];gradient.startPoint=CGPoint(x:0,y:1);gradient.endPoint=CGPoint(x:1,y:0);layer?.addSublayer(gradient);for (index,tile) in tiles.enumerated(){tile.fillColor=NSColor.white.withAlphaComponent(index==2 ? 0.6:0.95).cgColor;layer?.addSublayer(tile)}}
    required init?(coder:NSCoder){fatalError("init(coder:) is unsupported")}
    override func layout(){super.layout();let w=bounds.width,h=bounds.height
        CATransaction.begin();CATransaction.setDisableActions(true);gradient.frame=bounds;gradient.cornerRadius=w*0.24
        let rectangles=[CGRect(x:w*0.21,y:h*0.21,width:w*0.26,height:h*0.58),CGRect(x:w*0.53,y:h*0.53,width:w*0.26,height:h*0.26),CGRect(x:w*0.53,y:h*0.21,width:w*0.26,height:h*0.26)]
        for(index,tile)in tiles.enumerated(){tile.frame=bounds;tile.path=CGPath(roundedRect:rectangles[index],cornerWidth:w*0.06,cornerHeight:h*0.06,transform:nil)};CATransaction.commit()
        guard !played,w>0 else{return};played=true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else{return}
        for(index,tile)in tiles.enumerated(){let reveal=CABasicAnimation(keyPath:"opacity");reveal.fromValue=0;reveal.toValue=1;reveal.duration=0.7;reveal.beginTime=CACurrentMediaTime()+Double(index)*0.07;reveal.fillMode = .both;reveal.timingFunction=CAMediaTimingFunction(name:.easeOut);tile.add(reveal,forKey:"hyprwm.brand.reveal")}
    }
}
