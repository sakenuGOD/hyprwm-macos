import AppKit
import QuartzCore
import ScreenCaptureKit
import HyprCore

final class LiteOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        ignoresMouseEvents = true; hidesOnDeactivate = false; animationBehavior = .none
        level = .normal; isReleasedWhenClosed = false
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size)); view.wantsLayer = true
        view.layer = CALayer(); contentView = view
    }
}

/// Only Apple's public ScreenCaptureKit is used for pixels. Denial is a capability
/// downgrade to direct AX placement, never permission to hide a live window.
final class LiteCaptures {
    private var windows: [CGWindowID: SCWindow] = [:]
    private var sampled = 0.0
    private var refreshing = false
    private var waiters: [() -> Void] = []
    private(set) var lastError: String?
    var permitted: Bool { CGPreflightScreenCaptureAccess() }
    func image(_ wid: Int, pid: Int, frame: Rect, completion: @escaping (CGImage?) -> Void) {
        guard permitted else { completion(nil); return }
        func capture() {
            guard let window = self.windows[CGWindowID(wid)], window.owningApplication?.processID == pid_t(pid) else { completion(nil); return }
            let filter = SCContentFilter(desktopIndependentWindow: window), config = SCStreamConfiguration()
            let scale = min(2, 3200 / max(frame.w, frame.h, 1))
            config.width = max(1, Int(frame.w * scale)); config.height = max(1, Int(frame.h * scale))
            config.showsCursor = false; config.ignoreShadowsSingleWindow = true
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
                DispatchQueue.main.async {
                    self.lastError = error.map { String(describing: type(of: $0)) }
                    completion(image)
                }
            }
        }
        if windows[CGWindowID(wid)] != nil, ProcessInfo.processInfo.systemUptime - sampled < 1 { capture(); return }
        waiters.append(capture)
        guard !refreshing else { return }; refreshing = true
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                self.refreshing = false
                if let content {
                    self.windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
                    self.sampled = ProcessInfo.processInfo.systemUptime
                }
                self.lastError = error.map { String(describing: type(of: $0)) }
                let waiters = self.waiters; self.waiters.removeAll()
                for waiter in waiters { waiter() }
            }
        }
    }
}

enum LiteMotion {
    static func progress(_ curve: Curve?, _ t: Double, duration: Double, timeScale: Double) -> Double {
        if t >= 1 { return 1 }; if t <= 0 { return 0 }
        switch curve {
        case let .bezier(p1, p2):
            func point(_ a: Double, _ b: Double, _ value: Double) -> Double {
                3 * (1-value) * (1-value) * value * a + 3 * (1-value) * value * value * b + value * value * value
            }
            var low = 0.0, high = 1.0
            for _ in 0..<16 { let mid = (low+high)/2; if point(p1.0, p2.0, mid) < t { low = mid } else { high = mid } }
            return point(p1.1, p2.1, (low+high)/2)
        case let .spring(mass, stiffness, damping):
            let seconds = t * duration / max(0.05, timeScale)
            let omega = sqrt(max(0.001, stiffness) / max(0.001, mass))
            let decay = damping / (2 * max(0.001, mass)), square = omega * omega - decay * decay
            let displacement: Double
            if square > 0.00001 {
                let damped = sqrt(square)
                displacement = exp(-decay * seconds) * (cos(damped * seconds) + decay/damped * sin(damped * seconds))
            } else if square < -0.00001 {
                let root = sqrt(-square), r1 = -decay + root, r2 = -decay - root
                displacement = (-r2 * exp(r1*seconds) + r1 * exp(r2*seconds)) / (r1-r2)
            } else { displacement = exp(-decay*seconds) * (1+decay*seconds) }
            // Fade the tiny terminal remainder over the final 15%; the model lands exactly.
            let settle = t > 0.85 ? pow((1-t)/0.15, 2) : 1
            return 1 - displacement * settle
        case nil: return 1 - pow(1-t, 3)
        }
    }
    static func frames(from: Rect, to: Rect, velocity: [Double], duration: Double, curve: Curve?, timeScale: Double) -> [Rect] {
        let count = max(2, min(240, Int(ceil(duration * 120))))
        let derivative = progress(curve, 0.0001, duration: duration, timeScale: timeScale) / max(0.000001, 0.0001 * duration)
        return (0...count).map { index in
            let t = Double(index)/Double(count), progress = progress(curve, t, duration: duration, timeScale: timeScale)
            let blend = t * duration * pow(1-t, 2)
            let values = zip(from.arr, to.arr).enumerated().map { offset, pair -> Double in
                let delta = pair.1 - pair.0, correction = ((velocity.indices.contains(offset) ? velocity[offset] : 0) - delta * derivative) * blend
                return pair.0 + delta * progress + (velocity.isEmpty ? 0 : correction)
            }
            return Rect(values[0], values[1], max(1, values[2]), max(1, values[3]))
        }
    }
}

/// Body and border share the same sampled frames and Core Animation beginTime.
/// No timer tries to chase a separately animated foreign window.
final class LiteProxy {
    let window: LiteOverlayWindow, imageLayer = CALayer(), border = CAGradientLayer(), mask = CAShapeLayer()
    let image: CGImage
    let canvas: Rect
    let target: Rect
    let width: Double, radius: Double
    private(set) var began = 0.0, duration = 0.0
    private var focusColors: [RGBA] = []
    init(image: CGImage, from: Rect, to: Rect, appearance: Appearance, focused: Bool, relativeTo wid: Int) {
        self.image = image; target = to; width = appearance.width; radius = appearance.radius
        let padding = max(appearance.width + 4, 8)
        let x = min(from.x, to.x) - padding, y = min(from.y, to.y) - padding
        canvas = Rect(x, y, max(from.x+from.w, to.x+to.w)-x+padding, max(from.y+from.h, to.y+to.h)-y+padding)
        window = LiteOverlayWindow(frame: LiteSys.cocoa(canvas))
        guard let root = window.contentView?.layer else { return }
        imageLayer.contents = image; imageLayer.contentsGravity = .resize; imageLayer.masksToBounds = true
        imageLayer.cornerRadius = min(radius, min(from.w, from.h)/2)
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        root.addSublayer(imageLayer); root.addSublayer(border)
        focusColors = focused ? appearance.gradient : Array(repeating: appearance.inactive, count: 8)
        border.colors = focusColors.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a).cgColor }
        let endpoints = appearance.endpoints
        border.startPoint = CGPoint(x: endpoints.0[0], y: endpoints.0[1]); border.endPoint = CGPoint(x: endpoints.1[0], y: endpoints.1[1])
        mask.fillColor = nil; mask.strokeColor = NSColor.white.cgColor; mask.lineWidth = width; border.mask = mask
        setModel(from)
        window.order(.above, relativeTo: wid)
    }
    private func point(_ frame: Rect) -> CGPoint {
        CGPoint(x: frame.x-canvas.x+frame.w/2, y: canvas.h-(frame.y-canvas.y)-frame.h/2)
    }
    private func path(_ frame: Rect) -> CGPath {
        CGPath(roundedRect: CGRect(x: width/2, y: width/2, width: frame.w+width, height: frame.h+width),
               cornerWidth: radius+width/2, cornerHeight: radius+width/2, transform: nil)
    }
    private func setModel(_ frame: Rect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: frame.w, height: frame.h); imageLayer.position = point(frame)
        border.bounds = CGRect(x: 0, y: 0, width: frame.w+2*width, height: frame.h+2*width); border.position = point(frame)
        mask.frame = border.bounds; mask.path = path(frame)
        CATransaction.commit()
    }
    func animate(frames: [Rect], duration: Double, started: Double, fromAlpha: Double = 1, toAlpha: Double = 1) {
        guard let last = frames.last else { return }; self.duration = duration; began = started
        setModel(last)
        let positions = frames.map { NSValue(point: point($0)) }
        func animation(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let value = CAKeyframeAnimation(keyPath: key); value.values = values; value.duration = duration
            value.beginTime = started; value.calculationMode = .linear; value.fillMode = .backwards; return value
        }
        imageLayer.add(animation("position", positions), forKey: "position")
        imageLayer.add(animation("bounds", frames.map { NSValue(rect: NSRect(x: 0, y: 0, width: $0.w, height: $0.h)) }), forKey: "bounds")
        border.add(animation("position", positions), forKey: "position")
        border.add(animation("bounds", frames.map { NSValue(rect: NSRect(x: 0, y: 0, width: $0.w+2*width, height: $0.h+2*width)) }), forKey: "bounds")
        mask.add(animation("path", frames.map(path)), forKey: "path")
        if fromAlpha != toAlpha {
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = fromAlpha; fade.toValue = toAlpha
            fade.duration = duration; fade.beginTime = started; fade.fillMode = .backwards
            imageLayer.opacity = Float(toAlpha); border.opacity = Float(toAlpha)
            imageLayer.add(fade, forKey: "opacity"); border.add(fade, forKey: "opacity")
        }
    }
    var presented: Rect {
        let layer = imageLayer.presentation() ?? imageLayer, bounds = layer.bounds, position = layer.position
        return Rect(canvas.x+position.x-bounds.width/2, canvas.y+canvas.h-position.y-bounds.height/2, bounds.width, bounds.height)
    }
    func freeze() {
        let frame = presented
        imageLayer.removeAllAnimations(); border.removeAllAnimations(); mask.removeAllAnimations()
        setModel(frame)
    }
    func focus(_ active: Bool, appearance: Appearance, config: HyprConfig) {
        let colors = active ? appearance.gradient : Array(repeating: appearance.inactive, count: 8)
        guard colors != focusColors else { return }; focusColors = colors
        let previous = border.presentation()?.colors ?? border.colors
        CATransaction.begin(); CATransaction.setDisableActions(true)
        border.colors = colors.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a).cgColor }
        CATransaction.commit()
        let animation = config.anim("border")
        guard let previous, animation.on, animation.dur > 0 else { return }
        let fade = CABasicAnimation(keyPath: "colors"); fade.fromValue = previous; fade.toValue = border.colors; fade.duration = animation.dur
        if case let .bezier(p1, p2)? = config.curves()[config.animation("border").curve] {
            fade.timingFunction = CAMediaTimingFunction(controlPoints: Float(p1.0), Float(p1.1), Float(p2.0), Float(p2.1))
        }
        border.add(fade, forKey: "focus")
    }
    func close() { window.orderOut(nil); window.close() }
}

final class LiteBorders {
    private final class Item {
        let window: LiteOverlayWindow, gradient: CAGradientLayer, mask: CAShapeLayer
        var colors: [RGBA] = [], frame: Rect?
        var visible = false
        init(window: LiteOverlayWindow, gradient: CAGradientLayer, mask: CAShapeLayer) { self.window = window; self.gradient = gradient; self.mask = mask }
    }
    private var items: [Int: Item] = [:]
    var appearance: Appearance
    init(config: HyprConfig) throws { appearance = try Appearance(config) }
    func update(_ wid: Int, frame: Rect, focused: Bool, visible: Bool, duration: Double = 0.12) {
        guard visible, appearance.width > 0 else { hide(wid); return }
        let width = appearance.width
        let item: Item
        if let existing = items[wid] { item = existing }
        else {
            let window = LiteOverlayWindow(frame: .zero), gradient = CAGradientLayer(), mask = CAShapeLayer()
            window.contentView?.layer?.addSublayer(gradient); gradient.mask = mask
            item = Item(window: window, gradient: gradient, mask: mask); items[wid] = item
        }
        let outer = Rect(frame.x-width, frame.y-width, frame.w+2*width, frame.h+2*width)
        if item.frame != outer { item.window.setFrame(LiteSys.cocoa(outer), display: false); item.frame = outer }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        item.gradient.frame = NSRect(x: 0, y: 0, width: outer.w, height: outer.h)
        item.mask.frame = item.gradient.bounds; item.mask.lineWidth = width
        item.mask.fillColor = nil; item.mask.strokeColor = NSColor.white.cgColor
        item.mask.path = CGPath(roundedRect: CGRect(x: width/2, y: width/2, width: frame.w+width, height: frame.h+width), cornerWidth: appearance.radius+width/2, cornerHeight: appearance.radius+width/2, transform: nil)
        let endpoints = appearance.endpoints
        item.gradient.startPoint = CGPoint(x: endpoints.0[0], y: endpoints.0[1]); item.gradient.endPoint = CGPoint(x: endpoints.1[0], y: endpoints.1[1])
        CATransaction.commit()
        let rgba = focused ? appearance.gradient : Array(repeating: appearance.inactive, count: 8)
        if item.colors != rgba {
            let previous = item.gradient.presentation()?.colors ?? item.gradient.colors
            CATransaction.begin(); CATransaction.setDisableActions(true)
            item.gradient.colors = rgba.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: $0.a).cgColor }
            CATransaction.commit(); item.colors = rgba
            if let previous, duration > 0 {
                let fade = CABasicAnimation(keyPath: "colors"); fade.fromValue = previous; fade.toValue = item.gradient.colors; fade.duration = duration
                item.gradient.add(fade, forKey: "focus")
            }
        }
        if !item.visible { item.window.order(.above, relativeTo: wid); item.visible = true }
    }
    func hide(_ wid: Int) { if let item = items[wid], item.visible { item.window.orderOut(nil); item.visible = false } }
    func drop(_ wid: Int) { items.removeValue(forKey: wid)?.window.close() }
    func close() { for item in items.values { item.window.close() }; items.removeAll() }
}
