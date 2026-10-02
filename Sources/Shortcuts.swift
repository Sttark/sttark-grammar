import AppKit

/// Keyboard shortcuts people can change from the menu bar (Shortcuts submenu).
enum Action: String, CaseIterable {
    case readAloud, fixParagraph, translate

    var label: String {
        switch self {
        case .readAloud: return "Read selection aloud"
        case .fixParagraph: return "Fix this paragraph"
        case .translate: return "Translate selection to Chinese"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .readAloud: return Shortcut(code: 50, mods: CGEventFlags.maskCommand.rawValue, key: "`")
        case .fixParagraph: return Shortcut(code: 3, mods: CGEventFlags([.maskControl, .maskAlternate]).rawValue, key: "f")
        case .translate: return nil
        }
    }

    /// nil when the person turned the shortcut off.
    var shortcut: Shortcut? {
        get {
            guard let d = UserDefaults.standard.dictionary(forKey: "shortcut-" + rawValue) else { return defaultShortcut }
            guard let code = d["code"] as? Int, let mods = d["mods"] as? Int, let key = d["key"] as? String else { return nil }
            return Shortcut(code: Int64(code), mods: UInt64(mods), key: key)
        }
        nonmutating set {
            let d: [String: Any] = newValue.map { ["code": Int($0.code), "mods": Int($0.mods), "key": $0.key] } ?? [:]
            UserDefaults.standard.set(d, forKey: "shortcut-" + rawValue)
        }
    }
}

struct Shortcut: Equatable {
    let code: Int64      // the physical key
    let mods: UInt64     // Command, Control, Option, Shift as CGEventFlags
    let key: String      // the character on the key, for the menu

    static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    init(code: Int64, mods: UInt64, key: String) {
        self.code = code
        self.mods = mods
        self.key = key
    }

    init(_ e: NSEvent) {
        let f = e.modifierFlags
        var m: CGEventFlags = []
        if f.contains(.command) { m.insert(.maskCommand) }
        if f.contains(.control) { m.insert(.maskControl) }
        if f.contains(.option) { m.insert(.maskAlternate) }
        if f.contains(.shift) { m.insert(.maskShift) }
        self.init(code: Int64(e.keyCode), mods: m.rawValue, key: e.characters(byApplyingModifiers: [])?.lowercased() ?? "")
    }

    func matches(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(.keyboardEventKeycode) == code
            && e.flags.intersection(Self.modifiers).rawValue == mods
    }

    var menuMods: NSEvent.ModifierFlags {
        let f = CGEventFlags(rawValue: mods)
        var m: NSEvent.ModifierFlags = []
        if f.contains(.maskCommand) { m.insert(.command) }
        if f.contains(.maskControl) { m.insert(.control) }
        if f.contains(.maskAlternate) { m.insert(.option) }
        if f.contains(.maskShift) { m.insert(.shift) }
        return m
    }

    static let keyNames: [Int64: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc", 117: "Forward Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Like "⌃⌥F" or "⌘`".
    var display: String {
        let f = CGEventFlags(rawValue: mods)
        var s = ""
        if f.contains(.maskControl) { s += "⌃" }
        if f.contains(.maskAlternate) { s += "⌥" }
        if f.contains(.maskShift) { s += "⇧" }
        if f.contains(.maskCommand) { s += "⌘" }
        return s + (Self.keyNames[code] ?? key.uppercased())
    }
}
