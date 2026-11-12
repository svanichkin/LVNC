import Carbon
import Foundation

/// Keyboard input sources (layouts and input methods) of the current session.
/// Call on the main thread.
public enum InputSources {
    /// Posted (distributed) when the selected input source changes, e.g. by Karabiner or ⌃Space.
    public static let changedNotification = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    /// TIS id of the selected source, e.g. "com.apple.keylayout.ABC" or
    /// "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese".
    public static func currentID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(source, kTISPropertyInputSourceID)
    }

    /// Select the source with this id, enabling it first if it is installed but not enabled.
    /// Returns a short description of what happened, for the log.
    @discardableResult
    public static func select(_ id: String) -> String {
        if currentID() == id { return "\(id) already selected" }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first
        else { return "\(id) is not installed here" }

        var note = ""
        if !bool(source, kTISPropertyInputSourceIsEnabled) {
            let st = TISEnableInputSource(source)
            note = st == noErr ? " (enabled it)" : " (enable failed: \(st))"
        }
        let st = TISSelectInputSource(source)
        return st == noErr ? "selected \(id)\(note)" : "cannot select \(id): \(st)\(note)"
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
}
