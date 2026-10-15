import AppKit
import HyprCore

/// A visible keyboard receiver for an empty virtual workspace. It never asks a
/// foreign app to activate, resign, hide, or change its focused window.
final class LiteWorkspaceReceiver {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    private final class Content: NSView {
        let heading = NSTextField(labelWithString: "")
        var keyEvents = 0
        override var acceptsFirstResponder: Bool { true }
        override var needsPanelToBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) { keyEvents += 1 } // Never retain typed content.
        override func isAccessibilityFocused() -> Bool { window?.isKeyWindow == true && window?.firstResponder === self }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.group)
            setAccessibilityIdentifier("hyprwm-lite-empty-workspace")
            heading.font = .systemFont(ofSize: 20, weight: .medium)
            heading.alignment = .center; heading.frame = NSRect(x: 16, y: 40, width: 248, height: 28)
            let detail = NSTextField(labelWithString: "No windows")
            detail.textColor = .secondaryLabelColor; detail.alignment = .center
            detail.frame = NSRect(x: 16, y: 16, width: 248, height: 20)
            addSubview(heading); addSubview(detail)
        }
        required init?(coder: NSCoder) { nil }
    }
    private let panel: Panel
    private let content = Content(frame: NSRect(x: 0, y: 0, width: 280, height: 88))
    private(set) var sourcePID = 0, sourceWindow = 0
    init() {
        panel = Panel(contentRect: content.frame, styleMask: [.titled, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = content; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.isFloatingPanel = false; panel.level = .normal
        panel.becomesKeyOnlyIfNeeded = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.stationary, .ignoresCycle]
        panel.setAccessibilitySubrole(.dialog)
    }
    var visible: Bool { panel.isVisible }
    var key: Bool { panel.isKeyWindow }
    func rename(workspace: Int) {
        panel.title = "Workspace \(workspace)"; content.heading.stringValue = panel.title
        content.setAccessibilityLabel(panel.title+", no windows")
    }
    func show(workspace: Int, area: Rect, sourcePID: Int, sourceWindow: Int) -> Bool {
        self.sourcePID = sourcePID; self.sourceWindow = sourceWindow
        rename(workspace: workspace)
        panel.setFrameOrigin(LiteSys.cocoa(Rect(area.x+(area.w-280)/2, area.y+(area.h-88)/2, 280, 88)).origin)
        panel.makeFirstResponder(content); panel.makeKeyAndOrderFront(nil)
        guard panel.isKeyWindow, panel.firstResponder === content else { hide(); return false }
        return true
    }
    func hide() { panel.orderOut(nil) }
    var status: JSON {
        .object([("visible", .bool(visible)), ("key", .bool(panel.isKeyWindow)),
                 ("window", .int(panel.windowNumber)), ("key_events", .int(content.keyEvents))])
    }
}
