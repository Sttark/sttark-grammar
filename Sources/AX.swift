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
        // test hook: with CG_DEBUG set, /tmp/cg-follow holds a process id and a class name a test put on a box
        // (in the Chrome window named Claude), or just a process id for that app's own focused box, and that box is watched as if it had focus, so a test can type
        // into a window behind the one you're using
        if debug, let s = try? String(contentsOfFile: "/tmp/cg-follow", encoding: .utf8) {
            let w = s.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let p = pid_t(w.first ?? "") else { return nil }
            if w.count == 2 { return followed(p, w[1]) }
            // just a process id: that app's own focused box (a native app like Messages, in the background)
            guard let v = attr(AXUIElementCreateApplication(p), kAXFocusedUIElementAttribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        // Asking across all apps sometimes fails (the Claude app after a restart); then ask the app in front.
        var v = attr(system, kAXFocusedUIElementAttribute)
        let front = NSWorkspace.shared.frontmostApplication
        if v == nil, let front {
            v = attr(AXUIElementCreateApplication(front.processIdentifier), kAXFocusedUIElementAttribute)
        }
        if v == nil, let front, isBrowserWebApp(front) { return focusedByLooking(front.processIdentifier) }
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        let el = v as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return el
    }

    private static var follow: (key: String, el: AXUIElement)?
    private static var followLook = Date.distantPast

    static func followed(_ p: pid_t, _ cls: String) -> AXUIElement? {
        let key = "\(p) \(cls)"
        if let f = follow, f.key == key, (attr(f.el, "AXDOMClassList") as? [String])?.contains(cls) == true { return f.el }
        follow = nil
        guard Date().timeIntervalSince(followLook) > 1 else { return nil }
        followLook = Date()
        var seen = 0
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            seen += 1
            guard seen < 40000, depth < 80 else { return nil }
            if (attr(e, "AXDOMClassList") as? [String])?.contains(cls) == true { return e }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let hit = walk(c, depth + 1) { return hit } }
            return nil
        }
        for w in (attr(AXUIElementCreateApplication(p), kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            if let hit = walk(w, 0) { AXUIElementSetMessagingTimeout(hit, 0.25); follow = (key, hit); return hit }
        }
        return nil
    }

    /// A site installed as an app from Chrome or Edge (Google Chat), which runs in its own process.
    static func isBrowserWebApp(_ app: NSRunningApplication) -> Bool {
        let id = app.bundleIdentifier ?? ""
        return ["com.google.Chrome.app.", "com.microsoft.edgemac.app.", "com.brave.Browser.app."].contains { id.hasPrefix($0) }
    }

    /// Those apps' windows never say which box has focus, though the box itself says it's focused. So look
    /// through the window for it (about a tenth of a second for Google Chat), off the main thread so typing
    /// isn't held up, at most once a second, and keep the box for as long as it stays focused.
    private static var found: AXUIElement?
    private static var looking = false
    private static var lastLook = Date.distantPast

    static func focusedByLooking(_ pid: pid_t) -> AXUIElement? {
        if let f = found, self.pid(f) == pid, attr(f, kAXFocusedAttribute) as? Bool == true { return f }
        found = nil
        guard !looking, Date().timeIntervalSince(lastLook) > 1 else { return nil }
        looking = true
        lastLook = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let hit = lookForFocusedText(AXUIElementCreateApplication(pid))
            DispatchQueue.main.async {
                found = hit
                looking = false
                if let hit { AXUIElementSetMessagingTimeout(hit, 0.25) }
            }
        }
        return nil
    }

    private static func lookForFocusedText(_ app: AXUIElement) -> AXUIElement? {
        var seen = 0
        let leaves: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXLink", "AXPopUpButton", "AXCheckBox"]
        func walk(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
            seen += 1
            guard seen < 6000, depth < 60 else { return nil }
            let role = string(e, kAXRoleAttribute) ?? ""
            if (role == "AXTextArea" || role == "AXTextField") && attr(e, kAXFocusedAttribute) as? Bool == true { return e }
            if leaves.contains(role) { return nil }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { if let hit = walk(c, depth + 1) { return hit } }
            return nil
        }
        for w in (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] { if let hit = walk(w, 0) { return hit } }
        return nil
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

    /// Replaces a box's whole text. Chrome takes this in a plain text box (a textarea) and fires the page's
    /// input event, though it ignores a set of the selected text.
    static func setValue(_ el: AXUIElement, _ s: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, s as CFString) == .success
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
    static func boxText(_ el: AXUIElement, upTo given: Int) -> String? {
        // the box's own count can be longer than the value: it counts each picture, which the value leaves out
        let n = max(given, attr(el, kAXNumberOfCharactersAttribute) as? Int ?? 0)
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
        // A site installed as an app from Chrome (Google Chat) answers only for its window frame: its page is
        // shown by Chrome itself, which shares the page's parts, text box included, only once Chrome is asked
        // too. Before a restart something else on the Mac had usually asked already.
        guard let web = NSRunningApplication(processIdentifier: pid), isBrowserWebApp(web) else { return }
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let id = web.bundleIdentifier ?? ""
        let browser = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"].first { id.hasPrefix($0 + ".app.") }
        for b in NSRunningApplication.runningApplications(withBundleIdentifier: browser ?? "") {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(b.processIdentifier), "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }

    /// AX rects use a top-left origin on the main screen; AppKit uses bottom-left.
    static func toCocoa(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }
}
