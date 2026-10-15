import Foundation

public struct RGBA: Equatable {
    public let r, g, b, a: Double
    public var values: [Double] { [r,g,b,a] }
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double) { self.r=r; self.g=g; self.b=b; self.a=a }
    public static func parse(_ text: String) throws -> RGBA {
        let value: UInt64, alphaFirst: Bool
        if text.hasPrefix("rgb("), text.hasSuffix(")"), text.count == 11,
           let hex = UInt64(text.dropFirst(4).dropLast(), radix: 16) { value = hex<<8|255; alphaFirst=false }
        else if text.hasPrefix("rgba("), text.hasSuffix(")"), text.count == 14,
                let hex = UInt64(text.dropFirst(5).dropLast(), radix: 16) { value=hex; alphaFirst=false }
        else if text.hasPrefix("0x"), text.count == 10, let hex = UInt64(text.dropFirst(2), radix:16) { value=hex; alphaFirst=true }
        else { throw CmdError("color: expected rgb(RRGGBB), rgba(RRGGBBAA) or 0xAARRGGBB") }
        let packed = alphaFirst ? ((value&0xffffff)<<8)|(value>>24) : value
        return RGBA(Double((packed>>24)&255)/255, Double((packed>>16)&255)/255, Double((packed>>8)&255)/255, Double(packed&255)/255)
    }
    public static func mix(_ first: RGBA, _ second: RGBA, _ t: Double) -> RGBA {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055,2.4) }
        func gamma(_ c: Double) -> Double { let c = min(1,max(0,c)); return c <= 0.0031308 ? 12.92*c : 1.055*pow(c,1/2.4)-0.055 }
        func lab(_ color: RGBA) -> [Double] {
            let r=linear(color.r), g=linear(color.g), b=linear(color.b)
            let l=cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b)
            let m=cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b)
            let s=cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
            return [0.2104542553*l+0.7936177850*m-0.0040720468*s,1.9779984951*l-2.4285922050*m+0.4505937099*s,0.0259040371*l+0.7827717662*m-0.8086757660*s]
        }
        let x=lab(first), y=lab(second), p=zip(x,y).map { $0+($1-$0)*t }
        let l=pow(p[0]+0.3963377774*p[1]+0.2158037573*p[2],3)
        let m=pow(p[0]-0.1055613458*p[1]-0.0638541728*p[2],3)
        let s=pow(p[0]-0.0894841775*p[1]-1.2914855480*p[2],3)
        return RGBA(gamma(4.0767416621*l-3.3077115913*m+0.2309699292*s),gamma(-1.2684380046*l+2.6097574011*m-0.3413193965*s),gamma(-0.0041960863*l-0.7034186147*m+1.7076147010*s),first.a+(second.a-first.a)*t)
    }
}

public struct Appearance {
    public let width, radius, roundingPower, angle: Double
    public let active: [RGBA], inactive: RGBA
    public let shadowOn: Bool
    public let shadowRange, shadowPower, shadowScale: Double
    public let shadowOffset: (Double,Double), shadowActive, shadowInactive: RGBA
    public let exactShadow: Bool
    public let glowOn: Bool
    public let glowRange, glowPower: Double
    public let glowActive, glowInactive: RGBA
    public var gradient: [RGBA] {
        let colors=active.count > 1 ? active : active+active
        return (0..<8).map { i in
            let t=Double(i)/7*Double(colors.count-1), k=min(Int(t),colors.count-2)
            return RGBA.mix(colors[k],colors[k+1],t-Double(k))
        }
    }
    public var endpoints: ([Double],[Double]) {
        let sa=min(1,max(0,sin(angle/180*Double.pi))), vx=1-sa, vy=sa, square=max(vx*vx+vy*vy,0.0001)
        return ([0,1],[vx/square,1-vy/square])
    }
    public var shadowPacket: [Double] {
        [shadowRange,shadowPower,shadowScale,shadowOffset.0,shadowOffset.1]+shadowActive.values+shadowInactive.values
    }
    public func effectsPacket(_ duration: Double) -> [Double] {
        [radius,roundingPower,glowRange,glowPower]+glowActive.values+glowInactive.values+[duration]
    }
    public init(_ cfg: HyprConfig) throws {
        let general=cfg.general, decoration=cfg.raw["config"]?["decoration"] ?? .object([])
        func number(_ value: JSON?, _ name: String, _ range: ClosedRange<Double>, _ fallback: Double) throws -> Double {
            guard let value else { return fallback }
            guard let n=value.double, n.isFinite, range.contains(n) else { throw CmdError("\(name): invalid number") }; return n
        }
        func bool(_ value: JSON?, _ name: String, _ fallback: Bool) throws -> Bool {
            guard let value else { return fallback }; guard case let .bool(b)=value else { throw CmdError("\(name): expected boolean") }; return b
        }
        width=try number(general["border_size"],"border_size",0...20,2)
        radius=try number(decoration["rounding"],"rounding",0...100,18)
        roundingPower=try number(decoration["rounding_power"],"rounding_power",1...10,2)
        let border=general["col"]?["active_border"] ?? .object([("colors",.array([.string("rgba(ffffffee)")]))])
        let colorStrings=border["colors"]?.array?.compactMap(\.string) ?? [border.string ?? "rgba(ffffffee)"]
        guard !colorStrings.isEmpty, colorStrings.count <= 8, border["colors"]?.array?.count == nil || colorStrings.count == border["colors"]?.array?.count else { throw CmdError("active_border: expected 1..8 colors") }
        active=try colorStrings.map(RGBA.parse)
        angle=try number(border["angle"],"border.angle",-3600...3600,45)
        inactive=try RGBA.parse(general["col"]?["inactive_border"]?.string ?? "rgba(77777755)")
        let shadow=decoration["shadow"] ?? .object([])
        shadowOn=try bool(shadow["enabled"],"shadow.enabled",true)
        shadowRange=try number(shadow["range"],"shadow.range",1...4096,34)
        shadowPower=try number(shadow["render_power"],"shadow.render_power",1...10,3)
        shadowScale=try number(shadow["scale"],"shadow.scale",0...1,1)
        let offset=shadow["offset"]?.array ?? [.int(0),.int(10)]
        guard offset.count == 2 else { throw CmdError("shadow.offset: expected [x,y]") }
        shadowOffset=(try number(offset[0],"shadow.offset.x",-1e7...1e7,0),try number(offset[1],"shadow.offset.y",-1e7...1e7,10))
        shadowActive=try RGBA.parse(shadow["color"]?.string ?? "rgba(00000077)")
        shadowInactive=try RGBA.parse(shadow["color_inactive"]?.string ?? shadow["color"]?.string ?? "rgba(00000044)")
        let sharp=try bool(shadow["sharp"],"shadow.sharp",false), ignore=try bool(shadow["ignore_window"],"shadow.ignore_window",true)
        exactShadow=shadowPower <= 4 && shadowPower.rounded() == shadowPower && shadowActive.values.prefix(3).elementsEqual(shadowInactive.values.prefix(3)) &&
            !sharp && ignore
        let glow=decoration["glow"] ?? .object([])
        glowOn=try bool(glow["enabled"],"glow.enabled",false)
        glowRange=try number(glow["range"],"glow.range",0...200,18)
        glowPower=try number(glow["render_power"],"glow.render_power",1...10,3)
        glowActive=try RGBA.parse(glow["color"]?.string ?? "rgba(ffffff00)")
        glowInactive=try RGBA.parse(glow["color_inactive"]?.string ?? glow["color"]?.string ?? "rgba(ffffff00)")
    }
}
