import Carbon
import Foundation
import HyprCore

/// Public Carbon hotkey: available without an event tap or Input Monitoring.
/// Engine mode retains this instance; Lite registers its own equivalent chord.
final class PanicHotkey {
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private let action: () -> Void
    private static let signature: OSType = 0x48595052 // HYPR
    init(action: @escaping () -> Void) throws {
        self.action=action
        var kind=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let result=InstallEventHandler(GetApplicationEventTarget(),{ _,event,context in
            guard let event,let context else { return OSStatus(eventNotHandledErr) }
            var identity=EventHotKeyID()
            guard GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&identity)==noErr,
                  identity.signature==PanicHotkey.signature,identity.id==1 else { return OSStatus(eventNotHandledErr) }
            Unmanaged<PanicHotkey>.fromOpaque(context).takeUnretainedValue().action()
            return noErr
        },1,&kind,Unmanaged.passUnretained(self).toOpaque(),&handler)
        guard result==noErr else { throw CmdError("Cannot install panic hotkey handler (\(result))") }
        let registered=RegisterEventHotKey(35,UInt32(controlKey|optionKey),EventHotKeyID(signature:Self.signature,id:1),GetApplicationEventTarget(),0,&hotkey)
        guard registered==noErr else {
            if let handler { RemoveEventHandler(handler); self.handler=nil }
            throw CmdError("Ctrl+Option+P is unavailable (\(registered)); use the menu to pause")
        }
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
