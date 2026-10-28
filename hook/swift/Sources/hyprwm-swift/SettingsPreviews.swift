import AppKit
import SwiftUI
import HyprCore

struct TilingPreview: View {
    @ObservedObject var store: SettingsStore
    var animated: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shifted=false
    @State private var visible=false
    var body: some View {
        GeometryReader { geometry in
            let inset=min(26,store.number("layout.gaps_out.left",12)*0.65+10),rightInset=min(26,store.number("layout.gaps_out.right",12)*0.65+10),topInset=min(22,store.number("layout.gaps_out.top",8)*0.35+10),bottomInset=min(22,store.number("layout.gaps_out.bottom",12)*0.35+10)
            let gap=min(20,store.number("layout.gaps_in",3)*1.5+3)
            let width=geometry.size.width-inset-rightInset, height=geometry.size.height-topInset-bottomInset-20
            let split=shifted ? 0.37 : min(0.7,max(0.3,store.number("layout.default_split_ratio",1)/2))
            ZStack(alignment:.topLeading) {
                Color(nsColor:.windowBackgroundColor)
                previewWindow("Editor",symbol:"chevron.left.forwardslash.chevron.right",active:true).frame(width:width*split-gap/2,height:height).offset(x:inset,y:topInset)
                previewWindow("Notes",symbol:"note.text",active:false).frame(width:width*(1-split)-gap/2,height:(height-gap)/2).offset(x:inset+width*split+gap/2,y:topInset)
                previewWindow("Browser",symbol:"globe",active:false).frame(width:width*(1-split)-gap/2,height:(height-gap)/2).offset(x:inset+width*split+gap/2,y:topInset+(height+gap)/2)
                HStack {Text("Preview").font(.caption2).foregroundStyle(.secondary);Spacer();if animated {Button {play()} label:{Label("Replay",systemImage:"play.fill").font(.caption)}.buttonStyle(.borderless)}}.padding(.horizontal,15).frame(maxHeight:.infinity,alignment:.bottom).padding(.bottom,6)
            }.clipShape(RoundedRectangle(cornerRadius:12))
        }.onAppear {visible=true}.onDisappear {visible=false}
        .task {guard animated && !reduceMotion else {return};try? await Task.sleep(nanoseconds:500_000_000);if !Task.isCancelled {play()};try? await Task.sleep(nanoseconds:950_000_000);if !Task.isCancelled {play()}}
        .onChange(of:store.document.description) { if animated && visible {play()} }
        .accessibilityElement(children:.combine).accessibilityLabel("Three-window layout preview")
    }
    private func play() { guard visible else {return}; if reduceMotion {shifted.toggle()} else {withAnimation(animation){shifted.toggle()}} }
    private var animation: Animation {
        let curves=(store.base["curves"] as? [String:[String:Any]] ?? [:]).merging(store.document["curves"] as? [String:[String:Any]] ?? [:]) {_,new in new}
        let selected=store.string("animations.windowsMove.curve","drift"), curve=curves[selected] ?? [:], scale=store.number("time_scale",1)*store.number("animations.windowsMove.time_scale",1)
        if curve["type"] as? String == "spring" { return .interpolatingSpring(mass:(curve["mass"] as? Double ?? 1),stiffness:(curve["stiffness"] as? Double ?? 250)/(scale*scale),damping:(curve["damping"] as? Double ?? curve["dampening"] as? Double ?? 25)/scale) }
        let points=curve["points"] as? [[Double]] ?? [[0.25,0.1],[0.25,1]]
        return .timingCurve(points[0][0],points[0][1],points[1][0],points[1][1],duration:store.number("animations.windowsMove.duration_ms",500)/1000*scale)
    }
    private func previewWindow(_ title:String,symbol:String,active:Bool) -> some View {
        let colors=(store.value("appearance.border.active.colors",fallback:["rgba(ffb4a4ee)","rgba(7fd0f5ee)"]) as? [String] ?? []).map(nativeColor)
        let radius=min(22,store.number("appearance.rounding",18)*0.65), border=min(6,store.number("appearance.border.size",2)),angle=store.number("appearance.border.active.angle",45)*Double.pi/180
        let gradientStart=UnitPoint(x:0.5-cos(angle)*0.5,y:0.5-sin(angle)*0.5),gradientEnd=UnitPoint(x:0.5+cos(angle)*0.5,y:0.5+sin(angle)*0.5)
        return VStack(alignment:.leading,spacing:0) {
            HStack(spacing:4) {ForEach(0..<3){i in Circle().fill([Color.red,Color.yellow,Color.green][i].opacity(0.6)).frame(width:5,height:5)};Spacer();Image(systemName:symbol).font(.system(size:9)).foregroundStyle(.secondary)}.padding(9)
            Divider().opacity(0.45)
            VStack(alignment:.leading,spacing:8) { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary);ForEach(0..<(active ? 3:0),id:\.self){i in RoundedRectangle(cornerRadius:3).fill(.secondary.opacity(i==0 ? 0.15:0.08)).frame(maxWidth:i==2 ? 65:100).frame(height:5)}}.padding(active ? 12:8)
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:radius))
            .overlay(RoundedRectangle(cornerRadius:radius).strokeBorder(active ? LinearGradient(colors:colors.isEmpty ? [.accentColor]:colors,startPoint:gradientStart,endPoint:gradientEnd):LinearGradient(colors:[nativeColor(store.string("appearance.border.inactive","rgba(53434155)"))],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:border))

            .shadow(color:store.bool("appearance.shadow.enabled") ? nativeColor(store.string(active ? "appearance.shadow.color":"appearance.shadow.color_inactive","rgba(00000044)")):.clear,radius:min(16,store.number("appearance.shadow.range",34)*0.3*store.number("appearance.shadow.scale",1)),x:min(12,max(-12,store.number("appearance.shadow.offset.0",0)*0.3)),y:min(12,max(-12,store.number("appearance.shadow.offset.1",10)*0.3)))
    }
}
struct AnimationSettings: View {
    @ObservedObject var store: SettingsStore
    @State private var event="windowsMove"
    @State private var curve="drift"
    @State private var newName=""
    @State private var newKind="bezier"
    var curves:[String:[String:Any]] { (store.base["curves"] as? [String:[String:Any]] ?? [:]).merging(store.document["curves"] as? [String:[String:Any]] ?? [:]){_,new in new} }
    let events:[(String,String)]=[("windowsMove","Window Movement"),("windowsIn","Window Opening"),("windowsOut","Window Closing"),("fadeIn","Fade In"),("fadeOut","Fade Out"),("fadeSwitch","Focus Change"),("border","Border"),("fadeShadow","Shadow"),("fadeGlow","Glow")]
    var selectedCurve: String {
        let override=store.string("animations."+event+".curve");if !override.isEmpty {return override}
        let records=store.base["animations"] as? [[String:Any]] ?? []
        let record=records.first{$0["leaf"] as? String == event} ?? [:]
        return record["spring"] as? String ?? record["bezier"] as? String ?? "smooth"
    }
    var body: some View {
        Section("Animation Events") {
            Picker("Action",selection:$event){ForEach(events,id:\.0){Text($0.1).tag($0.0)}}
            Toggle("Enable Animation",isOn:Binding(get:{store.bool("animations."+event+".enabled")},set:{store.set("animations."+event+".enabled",$0)}))
            HStack {Text("Curve");Spacer();NativeCurvePicker(names:curves.keys.sorted().filter{!["border","fadeShadow"].contains(event) || curves[$0]?["type"] as? String != "spring"},selection:Binding(get:{selectedCurve},set:{name in store.reset("animations."+event+".duration_ms");store.set("animations."+event+".curve",name)})).frame(width:200)}
            SettingRow(store:store,spec:.init("animations."+event+".time_scale","Time Scale",.animations,"",.number(0.1...4,0.05,"×"),1))
            if curves[selectedCurve]?["type"] as? String != "spring" { SettingRow(store:store,spec:.init("animations."+event+".duration_ms","Duration",.animations,"",.number(0...10000,10,"ms"),duration)) }
            if ["windowsIn","windowsOut"].contains(event) {
                let style=store.string("animations."+event+".style",event == "windowsIn" ? "popin 86%":"popin 92%")
                let percent=Double(style.replacingOccurrences(of:"popin ",with:"").replacingOccurrences(of:"%",with:"")) ?? 86
                Picker("Style",selection:Binding(get:{style.hasPrefix("popin") ? "popin":style.isEmpty ? "center":"fade"},set:{store.set("animations."+event+".style",$0=="popin" ? "popin \(Int(percent))%":$0=="center" ? "":"fade")})) {
                    Text("Scale").tag("popin");Text("From Center").tag("center");Text("Opacity").tag("fade")
                }
                if style.hasPrefix("popin") {HStack{Text(event=="windowsIn" ? "Initial Size":"Final Size");Spacer();Slider(value:Binding(get:{percent},set:{store.set("animations."+event+".style","popin \(Int($0))%")}),in:0...100).frame(width:180);Text("\(Int(percent))%").monospacedDigit().frame(width:44)}}
            }
            if !store.isDefault("animations."+event,fallback:[:]) {Button("Reset Event"){store.reset("animations."+event)}.foregroundStyle(.secondary)}
        }
        Section("Curve Editor") {
            Picker("Curve",selection:$curve){Text("Choose a Curve").tag("");ForEach(curves.keys.sorted(),id:\.self){Text($0).tag($0)}}
            if let spec=curves[curve], !curve.isEmpty { CurveEditor(store:store,name:curve,value:spec).id(curve) }
            HStack {TextField("New Curve Name",text:$newName);Picker("Type",selection:$newKind){Text("Bézier").tag("bezier");Text("Spring").tag("spring")}.labelsHidden().frame(width:110);Button("Add") {
                store.set("curves."+newName,newKind=="spring" ? ["type":"spring","mass":1.0,"stiffness":250.0,"damping":25.0] as [String:Any]:["type":"bezier","points":[[0.25,0.1],[0.25,1.0]]] as [String:Any]);curve=newName;newName=""
            }.disabled(newName.range(of:"^[A-Za-z][A-Za-z0-9_-]{0,63}$",options:.regularExpression)==nil || curves[newName] != nil)}
        }
    }
    var duration:Double { let record=(store.base["animations"] as? [[String:Any]] ?? []).first{$0["leaf"] as? String == event};return (record?["speed"] as? Double ?? 5)*100 }
}
struct CurveEditor: View {
    @ObservedObject var store: SettingsStore;let name:String;let value:[String:Any]
    var spring:Bool {value["type"] as? String == "spring"}
    var points:[[Double]] {value["points"] as? [[Double]] ?? [[0.25,0.1],[0.25,1]]}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            CurveGraph(value:value,onMove:{index,point in var next=points;next[index]=[Double(point.x),Double(point.y)];store.set("curves."+name,["type":"bezier","points":next])}).frame(height:155)
            if spring {
                ForEach([("mass","Mass",0.001...100,0.1,1.0),("stiffness","Stiffness",0.001...100000,1.0,250.0),("damping","Damping",0.001...10000,0.5,25.0)],id:\.0) { key,title,range,step,fallback in
                    HStack {Text(title);Spacer();Slider(value:Binding(get:{(value[key] as? Double) ?? fallback},set:{n in var next=value;next[key]=n;next.removeValue(forKey:"dampening");store.set("curves."+name,next)}),in:range).frame(width:180);TextField("",value:Binding(get:{(value[key] as? Double) ?? fallback},set:{n in if n.isFinite && range.contains(n) {var next=value;next[key]=n;next.removeValue(forKey:"dampening");store.set("curves."+name,next)}}),format:.number.precision(.fractionLength(0...3))).frame(width:75)}
                }
            } else {
                ForEach(0..<2,id:\.self) {index in HStack {Text("Point \(index+1)");Spacer();ForEach(0..<2,id:\.self){axis in Text(axis==0 ? "X":"Y").font(.caption).foregroundStyle(.secondary);TextField("",value:Binding(get:{points[index][axis]},set:{n in if n.isFinite && (axis==0 ? 0...1 : -10...10).contains(n) {var next=points;next[index][axis]=n;store.set("curves."+name,["type":"bezier","points":next])}}),format:.number.precision(.fractionLength(0...3))).frame(width:68)}} }
                Text("Drag the control points or enter their coordinates.").font(.caption).foregroundStyle(.secondary)
            }
            if !store.isDefault("curves."+name,fallback:[:]) {Button("Reset Curve"){store.reset("curves."+name)}.foregroundStyle(.secondary)}
        }.padding(.vertical,5)
    }
}
struct CurveGraph:View {
    let value:[String:Any]; var onMove:((Int,CGPoint)->Void)?
    var body:some View {
        GeometryReader {geo in
            let w=geo.size.width-30,h=geo.size.height-20
            ZStack(alignment:.topLeading) {
                Canvas {context,size in
                    var grid=Path();for i in 0...4 {let x=15+w*Double(i)/4,y=10+h*Double(i)/4;grid.move(to:CGPoint(x:x,y:10));grid.addLine(to:CGPoint(x:x,y:10+h));grid.move(to:CGPoint(x:15,y:y));grid.addLine(to:CGPoint(x:15+w,y:y))};context.stroke(grid,with:.color(.secondary.opacity(0.12)),lineWidth:1)
                    var line=Path()
                    for i in 0...160 { let t=Double(i)/160, y=response(t);let point=CGPoint(x:15+w*CGFloat(horizontal(t)),y:10+h*CGFloat(1-y));if i==0{line.move(to:point)}else{line.addLine(to:point)} };context.stroke(line,with:.color(.accentColor),style:StrokeStyle(lineWidth:2.5,lineCap:.round))
                }
                if value["type"] as? String == "bezier", let points=value["points"] as? [[Double]] {
                    ForEach(0..<2,id:\.self){index in
                        Circle().fill(Color.accentColor).overlay(Circle().stroke(.white,lineWidth:2)).frame(width:12,height:12).position(x:15+w*points[index][0],y:10+h*(1-points[index][1]))
                            .gesture(DragGesture(minimumDistance:0).onChanged{drag in onMove?(index,CGPoint(x:min(1,max(0,(drag.location.x-15)/w)),y:min(10,max(-10,1-(drag.location.y-10)/h))))})
                            .accessibilityLabel("Control Point \(index+1)")
                    }
                }
            }.background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:8)).clipped()
        }
    }
    private func horizontal(_ t:Double)->Double {
        guard value["type"] as? String == "bezier",let points=value["points"] as? [[Double]] else {return t}
        return 3*pow(1-t,2)*t*points[0][0]+3*(1-t)*t*t*points[1][0]+t*t*t
    }
    private func response(_ t:Double)->Double {
        if value["type"] as? String == "spring" {
            let m=value["mass"] as? Double ?? 1,k=value["stiffness"] as? Double ?? 250,c=value["damping"] as? Double ?? value["dampening"] as? Double ?? 25
            let omega=sqrt(k/m),z=c/(2*sqrt(k*m)),time=t*1.3
            if z<1 {let wd=omega*sqrt(1-z*z);return 1-exp(-z*omega*time)*(cos(wd*time)+z/sqrt(1-z*z)*sin(wd*time))}
            if abs(z-1)<0.0001 {return 1-exp(-omega*time)*(1+omega*time)}
            let spread=sqrt(z*z-1),r1 = -omega*(z-spread),r2 = -omega*(z+spread)
            return 1+(r2*exp(r1*time)-r1*exp(r2*time))/(r1-r2)
        }
        let p=value["points"] as? [[Double]] ?? [[0.25,0.1],[0.25,1]]
        return 3*pow(1-t,2)*t*p[0][1]+3*(1-t)*t*t*p[1][1]+t*t*t
    }
}

/// NSPopUpButton updates its selected title deterministically when the asynchronous curve list arrives.
struct NativeCurvePicker:NSViewRepresentable {
    let names:[String];@Binding var selection:String
    func makeCoordinator()->Coordinator{Coordinator(selection:$selection)}
    func makeNSView(context:Context)->NSPopUpButton {let button=NSPopUpButton(frame:.zero,pullsDown:false);button.target=context.coordinator;button.action=#selector(Coordinator.choose(_:));button.setAccessibilityLabel("Animation Curve");return button}
    func updateNSView(_ button:NSPopUpButton,context:Context){context.coordinator.selection=$selection;if button.itemTitles != names{button.removeAllItems();button.addItems(withTitles:names)};button.selectItem(withTitle:selection);button.isEnabled = !names.isEmpty}
    final class Coordinator:NSObject {var selection:Binding<String>;init(selection:Binding<String>){self.selection=selection};@objc func choose(_ sender:NSPopUpButton){if let title=sender.titleOfSelectedItem{selection.wrappedValue=title}}}
}
