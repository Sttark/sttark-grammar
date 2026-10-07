import AppKit
import ApplicationServices

/// Thin wrappers over the macOS Accessibility API: read the focused text box,
/// find where a range of its text sits on screen, and edit it.
enum AX {
    static let system = AXUIElementCreateSystemWide()

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func focused() -> AXUIElement? {
        // Asking across all apps sometimes fails (the Claude app after a restart); then ask the app in front.
        var v = attr(system, kAXFocusedUIElementAttribute)
        if v == nil, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            v = attr(AXUIElementCreateApplication(front), kAXFocusedUIElementAttribute)
        }
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0
        AXUIElementGetPid(el, &p)
        return p
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let v = attr(el, kAXSelectedTextRangeAttribute),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange()
        guard AXValueGetValue(v as! AXValue, .cfRange, &r) else { return nil }
        return NSRange(location: r.location, length: r.length)
    }

    @discardableResult
    static func setSelectedRange(_ el: AXUIElement, _ r: NSRange) -> Bool {
        var cf = CFRange(location: r.location, length: r.length)
        guard let v = AXValueCreate(.cfRange, &cf) else { return false }
        return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v) == .success
    }

    static func setSelectedText(_ el: AXUIElement, _ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, s as CFString) == .success
    }

    /// The text the box itself holds at a range, in its own position count.
    static func string(_ el: AXUIElement, for r: NSRange) -> String? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let arg = AXValueCreate(.cfRange, &cf) else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, arg, &v) == .success else { return nil }
        return v as? String
    }

    /// The box's whole text in its own position count, which can be shorter than its value. Chrome refuses
    /// a range past the end, so this finds the longest one it accepts. nil if it won't answer at all.
    static func boxText(_ el: AXUIElement, upTo n: Int) -> String? {
        if let s = string(el, for: NSRange(location: 0, length: n)) { return s }
        var lo = 1, hi = n          // string(0, lo) works, string(0, hi) doesn't
        guard n > 1, string(el, for: NSRange(location: 0, length: 1)) != nil else { return nil }
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if string(el, for: NSRange(location: 0, length: mid)) != nil { lo = mid } else { hi = mid }
        }
        return string(el, for: NSRange(location: 0, length: lo))
    }

    /// Screen rect of a text range, in AX coordinates (origin top-left of the main screen).
    static func bounds(_ el: AXUIElement, _ r: NSRange) -> CGRect? {
        var cf = CFRange(location: r.location, length: r.length)
        guard let arg = AXValueCreate(.cfRange, &cf) else { return nil }
        var v: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &rect), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Chrome-based apps (Claude, Slack, web pages) return an empty rect when asked about a range of a rich
    /// text box, but answer correctly for each run of text inside it. This maps the box's text to those runs.
    static func textRuns(_ el: AXUIElement, value: NSString) -> [(NSRange, AXUIElement)] {
        var leaves: [(String, AXUIElement)] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 40, leaves.count < 2000 else { return }
            let kids = children(e)
            if kids.isEmpty {
                if string(e, kAXRoleAttribute) == "AXStaticText", let t = string(e, kAXValueAttribute), !t.isEmpty { leaves.append((t, e)) }
            } else {
                kids.forEach { walk($0, depth + 1) }
            }
        }
        walk(el, 0)
        var out: [(NSRange, AXUIElement)] = []
        var cursor = 0
        for (t, e) in leaves {
            let r = value.range(of: t, options: [], range: NSRange(location: cursor, length: value.length - cursor))
            guard r.location != NSNotFound else { continue }
            out.append((r, e))
            cursor = r.upperBound
        }
        return out
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Electron and Chrome apps hide their text boxes from the Accessibility API until asked.
    static func enableAppAccessibility(_ pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// AX rects use a top-left origin on the main screen; AppKit uses bottom-left.
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
