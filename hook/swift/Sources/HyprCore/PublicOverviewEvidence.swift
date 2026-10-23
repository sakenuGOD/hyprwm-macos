import Foundation

/// Dock can retain its AX overview tree after all of its overview surfaces close.
public enum PublicOverviewEvidence {
    public static func active(containerPresent:Bool,surfaces:[WinInfo],displays:[Rect])->Bool {
        guard containerPresent else{return false}
        return surfaces.contains { window in
            window.on && window.layer>=0 && window.alpha.isFinite && window.alpha>0.001 &&
                window.w>0 && window.h>0 && displays.contains {display in window.rect.maxDiff(display)<=2}
        }
    }
}
