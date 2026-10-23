import Foundation

public enum SystemUI {
    static let shells: [String:String]=[
        "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter":"com.apple.notificationcenterui",
        "/System/Library/CoreServices/UserNotificationCenter.app/Contents/MacOS/UserNotificationCenter":"com.apple.UserNotificationCenter",
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter":"com.apple.controlcenter",
        "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer":"com.apple.systemuiserver",
        "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock":"com.apple.dock",
        "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight":"com.apple.Spotlight"
    ]
    public static func protected(executable: String, bundle: String?) -> Bool {
        guard let expected=shells[executable], let bundle else { return false }
        return expected == bundle
    }
}
