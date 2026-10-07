import AppKit
import SwiftUI

let debug = ProcessInfo.processInfo.environment["CG_DEBUG"] != nil
let started = Date()
/// Fixes and layout changes also go to ~/Library/Logs/ClaudeGrammar.log, so a run that went wrong can be read
/// afterward. The file starts over past 1 MB.
let logFile: FileHandle? = {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeGrammar.log")
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: url); _ = try? h?.seekToEnd(); return h
}()
func log(_ s: @autoclosure () -> String) {
    if debug { FileHandle.standardError.write((String(format: "%7.3f ", Date().timeIntervalSince(started)) + s() + "\n").data(using: .utf8)!) }
}
/// Always written, to the log file: what fixes and layout changes did.
func note(_ s: String) {
    log(s)
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
    logFile?.write((f.string(from: Date()) + " " + s + "\n").data(using: .utf8)!)
}

final class Controller: NSObject, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem!
    var timer: Timer?

    // what is focused now
    var element: AXUIElement?
    var appName = ""
    var value: NSString = ""
    var issues: [Issue] = []
    var lastChange = Date.distantPast
    var editing = false

    // checks
    var cache: [String: [Issue]] = [:]          // paragraph text -> issues, ranges relative to the paragraph
    var inflight: Set<String> = []
    var failedAt: [String: Date] = [:]
    var lastError: String?
    var ignored: Set<String> = []
    var dictionary: Set<String> = []
    // tidy up: Claude's cleaned-up copy of the whole message, offered as one change
    var tidyCache: [String: Tidy] = [:]        // whole message -> its tidy-up
    var tidyChecked: Set<String> = []          // messages already sent, with or without a tidy-up
    var tidyInflight: String?
    var tidyDismissed: Set<String> = []
    var dotCardOpen = false
    var dotPinned = false                      // opened by a click: stays until a click elsewhere or Esc
    /// The tidy-up for the message as it is right now.
    var tidy: Tidy? { tidyOn && !tidyDismissed.contains(value as String) ? tidyCache[value as String] : nil }
    var axEnabled: Set<pid_t> = []

    // screen
    let overlay = makePanel(mouse: false)
    let underlines = UnderlineView()
    let card = makePanel(mouse: true)
    let badge = makePanel(mouse: true)
    var rects: [UUID: [CGRect]] = [:]           // screen rects of each issue, AppKit coordinates
    var hoverID: UUID?
    var lastInside = Date.distantPast
    var tap: CFMachPort?
    var badgeState = ""
    var loggedMissing: Set<UUID> = []
    let translator = Translator()
    let speaker = Speaker()
    var recordingShortcut = false               // the Shortcuts box is open: let keys through to it

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    var pausedUntil: Date? {
        get { defaults.object(forKey: "pausedUntil") as? Date }
        set { defaults.set(newValue, forKey: "pausedUntil") }
    }
    var model: Model {
        get { Model(rawValue: defaults.string(forKey: "model") ?? "") ?? .haiku }
        set { defaults.set(newValue.rawValue, forKey: "model") }
    }
    var skipped: Set<String> {
        get { Set(defaults.stringArray(forKey: "skipped") ?? ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                                            "dev.warp.Warp-Stable", "com.1password.1password", "com.apple.keychainaccess"]) }
        set { defaults.set(Array(newValue), forKey: "skipped") }
    }
    var running: Bool { enabled && (pausedUntil.map { $0 < Date() } ?? true) }
    var tidyOn: Bool {
        get { defaults.object(forKey: "tidyOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "tidyOn") }
    }

    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeGrammar")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var dictionaryURL: URL { Self.supportDir.appendingPathComponent("dictionary.txt") }

    var clickMonitor: Any?

    func start() {
        // a click in another app (anywhere but the dot and its card) closes the dot's card
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.dotCardOpen else { return }
            let m = NSEvent.mouseLocation
            if !self.card.frame.contains(m) && !self.badge.frame.contains(m) { self.hideCard() }
        }
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
        }
        loadDictionary()
        NSApp.servicesProvider = translator
        NSUpdateDynamicServices()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        overlay.contentView = underlines
        // Read both keys before watching the keyboard. After a rebuild macOS asks for your
        // password to unlock them, and that question freezes this thread until you answer.
        // With the key watcher already running, every key press on the Mac waits on this
        // thread too, so you couldn't type the password and the keyboard locked up.
        _ = Checker.apiKey
        _ = Speaker.apiKey
        installKeyTap()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        speaker.changed = { [weak self] in self?.updateStatus() }
        updateStatus()
        if Checker.apiKey == nil { DispatchQueue.main.async { self.askForKey() } }
    }

    @objc func askForOpenAIKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        alert.messageText = "OpenAI API key for Read aloud"
        alert.informativeText = "Claude can't speak, so Read aloud sends the text you select to OpenAI's voice model. Paste an API key from platform.openai.com. It's kept in your Mac's Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            let ok = await Speaker.keyWorks(key)
            await MainActor.run {
                if ok && Speaker.saveKey(key) {
                    let a = NSAlert()
                    let s = Action.readAloud.shortcut.map { " or press \($0.display)" } ?? ""
                    a.messageText = "Read aloud is ready"
                    a.informativeText = "Select text in any app and choose Read selection aloud from the menu bar\(s). Do it again to stop."
                    a.runModal()
                } else {
                    let a = NSAlert()
                    a.messageText = ok ? "Couldn't save the key to the Keychain." : "That key didn't work."
                    a.informativeText = ok ? "" : "OpenAI turned it down. Check that you copied the whole key."
                    a.runModal()
                    self.askForOpenAIKey()
                }
            }
        }
    }

    // MARK: read aloud

    func readAloud(anchor: CGPoint) {
        if speaker.isReading { speaker.stop(); return }
        guard Speaker.apiKey != nil else { askForOpenAIKey(); return }
        let fail = { (title: String, msg: String) in
            self.translator.anchor = anchor
            self.translator.show(.failed(title: title, msg))
        }
        let read = { (text: String) in
            guard !text.hasPrefix("sk-") else { return }        // never read an API key aloud
            self.speaker.start(text) { error in if let error { fail("Read aloud stopped", error) } }
        }
        if let el = AX.focused(), AX.pid(el) != getpid(),
           let sel = AX.string(el, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            read(sel)
            return
        }
        // the app won't say what's selected: copy it
        let pb = NSPasteboard.general
        let count = pb.changeCount
        translator.postKey(8, .maskCommand)                        // Command-C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pb.changeCount != count, let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                fail("Nothing selected", "Select some text, then choose Read aloud again.")
                return
            }
            read(text)
        }
    }

    /// Where cards go when started from the menu: under the menu bar icon.
    var menuAnchor: CGPoint {
        let f = statusItem.button?.window?.frame ?? .zero
        return CGPoint(x: f.minX - 8, y: f.minY)
    }

    @objc func askForKey() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)
        alert.messageText = "Anthropic API key"
        alert.informativeText = "ClaudeGrammar sends what you type to Claude to check it. Paste an API key from console.anthropic.com. It's kept in your Mac's Keychain."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        Task {
            let ok = await Checker.keyWorks(key)
            await MainActor.run {
                if ok && Checker.saveKey(key) {
                    self.lastError = nil
                    self.failedAt = [:]
                    self.updateStatus()
                } else {
                    let a = NSAlert()
                    a.messageText = ok ? "Couldn't save the key to the Keychain." : "That key didn't work."
                    a.informativeText = ok ? "" : "Anthropic turned it down. Check that you copied the whole key."
                    a.runModal()
                    self.askForKey()
                }
            }
        }
    }

    // MARK: main loop

    func tick() {
        if tap == nil { installKeyTap() }
        guard running, AXIsProcessTrusted() else { reset(); updateStatus(); return }
        guard !editing else { return }

        guard let el = AX.focused() else {
            // Electron apps (the Claude app, Slack) show no text box until asked, and forget when they restart.
            // With nothing focused there's no app to ask, so ask the one in front.
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != getpid(), !axEnabled.contains(front) {
                AX.enableAppAccessibility(front); axEnabled.insert(front)
                log("nothing focused; asked \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") to share its text boxes")
            }
            reset(); updateStatus(); return
        }
        let pid = AX.pid(el)
        if pid == getpid() { return }                   // mouse is on our card; keep state
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier, skipped.contains(id) { reset(); updateStatus(); return }
        if !axEnabled.contains(pid) { AX.enableAppAccessibility(pid); axEnabled.insert(pid) }

        guard isTextBox(el), let str = AX.string(el, kAXValueAttribute) else { reset(); updateStatus(); return }
        let v = str as NSString
        if element == nil || !CFEqual(element!, el) {
            element = el
            boxMapFor = nil
            runsNeeded = false
            runsFor = nil
            appName = app?.localizedName ?? ""
            log("focus \(appName) role=\(AX.string(el, kAXRoleAttribute) ?? "?") len=\(v.length) frame=\(AX.frame(el).map { "\($0)" } ?? "none")")
            value = v
            issues = issuesFromCache(v)
            lastChange = Date()
        } else if v != value {
            shift(old: value, new: v)
            value = v
            showSaved()
            if dotCardOpen { hideCard() }
            lastChange = Date()
        }
        if Date().timeIntervalSince(lastChange) > 2 { sendChecks(el); sendTidyCheck(el) }
        layout(el)
        hover()
        updateStatus()
    }

    func isTextBox(_ el: AXUIElement) -> Bool {
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        let sub = AX.string(el, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || sub == "AXSecureTextField" || sub == "AXSearchField" { return false }
        // Messages' bubbles claim they can be edited; they can't
        if AX.string(el, kAXIdentifierAttribute) == "CKBalloonTextView" { return false }
        // only text you can type in: selected text on a web page or in a message has a selection but can't be edited
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        return settable.boolValue && AX.selectedRange(el) != nil
    }

    func reset() {
        guard element != nil || overlay.isVisible || badge.isVisible else { return }
        element = nil
        issues = []
        rects = [:]
        overlay.orderOut(nil)
        badge.orderOut(nil)
        hideCard()
    }

    // MARK: text bookkeeping

    /// Chrome-based apps (the Claude app, Slack) hand over their text with a line break between lines, but their
    /// cursor positions skip the break between list items and count a blank line as one. Rather than guess the
    /// rules, the app reads the box's own text and lines it up with ours. boxMap[i] is the box's position for our i.
    var boxMap: [Int]?
    var boxMapFor: NSString?

    func boxMap(_ el: AXUIElement) -> [Int]? {
        if boxMapFor === value, let m = boxMap { return m }
        boxMapFor = value
        boxMap = Self.align(value, AX.boxText(el, upTo: value.length))
        if boxMap == nil { log("can't line up positions in \(appName)") }
        return boxMap
    }

    /// Walks both copies, letting either skip a line break the other has. nil if they differ in anything else.
    /// A box that can't hand over its text is taken to count like ours.
    static func align(_ v: NSString, _ box: String?) -> [Int]? {
        guard let box else { return Array(0...v.length) }
        let b = box as NSString
        if b.isEqual(to: v as String) { return Array(0...v.length) }
        var map = [Int](repeating: 0, count: v.length + 1)
        var i = 0, j = 0
        while i < v.length {
            map[i] = j
            if j < b.length && v.character(at: i) == b.character(at: j) { i += 1; j += 1 }
            else if v.character(at: i) == 10 { i += 1 }
            else if j < b.length && b.character(at: j) == 10 { j += 1 }
            else { return nil }
        }
        map[v.length] = b.length
        return map
    }

    static func toBox(_ r: NSRange, _ map: [Int]) -> NSRange {
        NSRange(location: map[r.location], length: map[r.upperBound] - map[r.location])
    }

    /// The box's position to ours. Where a line break the box doesn't count sits, a start or cursor lands
    /// after the break and the end of a selection before it, so the selection stays on its own line.
    static func fromBox(_ r: NSRange, _ map: [Int]) -> NSRange {
        let after = map.lastIndex(of: r.location) ?? map.firstIndex { $0 > r.location } ?? map.count - 1
        if r.length == 0 { return NSRange(location: after, length: 0) }
        let end = map.firstIndex(of: r.upperBound) ?? map.firstIndex { $0 > r.upperBound } ?? map.count - 1
        return NSRange(location: after, length: max(0, end - after))
    }

    func selection(_ el: AXUIElement) -> NSRange? {
        guard let r = AX.selectedRange(el) else { return nil }
        return boxMap(el).map { Self.fromBox(r, $0) } ?? r
    }

    @discardableResult
    func select(_ el: AXUIElement, _ r: NSRange) -> Bool {
        AX.setSelectedRange(el, boxMap(el).map { Self.toBox(r, $0) } ?? r)
    }

    func paragraphs(_ s: NSString) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byParagraphs]) { sub, r, _, _ in
            if let sub { out.append((r, sub)) }
        }
        return out
    }

    func allowed(_ i: Issue) -> Bool {
        if ignored.contains(i.ignoreKey) { return false }
        if i.kind == .spelling && dictionary.contains(i.original.lowercased()) { return false }
        // a fix that would change a dictionary word, like "docs.sttark.com" -> "docs.stark.com"
        let words = { (s: String) in Set(s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)) }
        return words(i.original).subtracting(words(i.suggestion)).isDisjoint(with: dictionary)
    }

    /// A line typed again, typed back after an edit, or left alone by Fix all matches a result already in hand:
    /// show it. Lines that already show it keep their underlines as they are.
    func showSaved() {
        for (r, t) in paragraphs(value) {
            guard let saved = cache[t] else { continue }
            let want = saved.filter(allowed).map { $0.shifted(by: r.location) }
            let have = issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound }
            if have.map(\.range) == want.map(\.range) && have.map(\.suggestion) == want.map(\.suggestion) { continue }
            issues.removeAll { $0.range.location >= r.location && $0.range.location < r.upperBound }
            issues += want
        }
        issues.sort { $0.range.location < $1.range.location }
    }

    func issuesFromCache(_ s: NSString) -> [Issue] {
        paragraphs(s).flatMap { r, t in (cache[t] ?? []).filter(allowed).map { $0.shifted(by: r.location) } }
    }

    /// Keep underlines in place while you type: move the ones after your edit, drop the ones it touches.
    func shift(old: NSString, new: NSString) {
        let lo = old.length, ln = new.length
        var p = 0
        while p < lo && p < ln && old.character(at: p) == new.character(at: p) { p += 1 }
        var s = 0
        while s < lo - p && s < ln - p && old.character(at: lo - 1 - s) == new.character(at: ln - 1 - s) { s += 1 }
        let endOld = lo - s, delta = ln - lo
        let inserted = new.substring(with: NSRange(location: p, length: ln - s - p)) as NSString
        let firstWord = inserted.length > 0 && Diff.isWordChar(inserted.character(at: 0))
        let lastWord = inserted.length > 0 && Diff.isWordChar(inserted.character(at: inserted.length - 1))
        issues = issues.compactMap { i in
            let r = i.range
            if r.upperBound < p || (r.upperBound == p && !firstWord) { return i }
            if r.location > endOld || (r.location == endOld && !lastWord) { var c = i; c.range.location += delta; return c }
            return nil
        }
    }

    func sendChecks(_ el: AXUIElement) {
        guard inflight.count < 8 else { return }
        let caret = selection(el)?.location ?? 0
        let paras = paragraphs(value).sorted { abs($0.0.location - caret) < abs($1.0.location - caret) }
        for (_, text) in paras {
            guard inflight.count < 8 else { break }
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            guard cache[text] == nil, !inflight.contains(text), words >= 3, text.utf16.count <= 4000 else { continue }
            if let f = failedAt[text], Date().timeIntervalSince(f) < 30 { continue }
            inflight.insert(text)
            log("check \(text.prefix(60))")
            let m = model
            let known = dictionary.sorted()
            Task {
                do {
                    let res = try await Checker.check(text, model: m, words: known)
                    await MainActor.run { self.received(text, res, model: m) }
                } catch {
                    await MainActor.run {
                        self.inflight.remove(text)
                        self.failedAt[text] = Date()
                        self.lastError = "\(error)"
                        log("error \(error)")
                        self.updateStatus()
                    }
                }
            }
        }
    }

    func received(_ text: String, _ claude: CheckResult, model: Model) {
        var caps = Diff.capitalIssues(text, besides: claude.issues)
        var ends = Diff.endIssues(text, besides: claude.issues)
        // a one-word last sentence like "ok" needs both: one fix, "Ok."
        if let e = ends.first, let k = caps.firstIndex(where: { $0.range == e.range }) {
            caps[k] = Issue(range: e.range, original: e.original, suggestion: caps[k].suggestion + String(e.suggestion.last!),
                            kind: .capitals, reason: "Start with a capital letter and end with a period.")
            ends = []
        }
        let mine = caps + ends
        let res = CheckResult(issues: (claude.issues + mine).sorted { $0.range.location < $1.range.location },
                              inputTokens: claude.inputTokens, outputTokens: claude.outputTokens)
        inflight.remove(text)
        lastError = nil
        cache[text] = res.issues
        recordUsage(res, model: model)
        log("got \(res.issues.count) issues, tokens \(res.inputTokens)/\(res.outputTokens): " + res.issues.map { "\($0.original)->\($0.suggestion)" }.joined(separator: ", "))
        for (r, t) in paragraphs(value) where t == text {
            issues.removeAll { $0.range.location >= r.location && $0.range.location < r.upperBound }
            issues += res.issues.filter(allowed).map { $0.shifted(by: r.location) }
        }
        issues.sort { $0.range.location < $1.range.location }
        updateStatus()
    }

    // MARK: screen positions

    func layout(_ el: AXUIElement) {
        guard let axFrame = AX.frame(el) else { overlay.orderOut(nil); badge.orderOut(nil); return }
        let frame = AX.toCocoa(axFrame)
        let visible = frame.insetBy(dx: -3, dy: -4)
        rects = [:]
        for i in issues where i.range.upperBound <= value.length {
            let raw = lineRects(el, i.range)
            let rs = raw.map(AX.toCocoa).filter { visible.intersects($0) }
            if !rs.isEmpty { rects[i.id] = rs }
            else if debug && !loggedMissing.contains(i.id) {
                loggedMissing.insert(i.id)
                var cf = CFRange(location: i.range.location, length: i.range.length)
                var v: AnyObject?
                let err = AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, AXValueCreate(.cfRange, &cf)!, &v)
                log("no rect for '\(i.original)' \(i.range): err=\(err.rawValue) value=\(v.map { "\($0)" } ?? "nil") lineRects=\(raw) frame=\(axFrame)")
            }
        }
        if debug && rects.count != drawnCount { drawnCount = rects.count; log("drawn \(rects.count) underlines") }
        if rects.isEmpty {
            overlay.orderOut(nil)
        } else {
            let win = visible.insetBy(dx: -2, dy: -2)
            if overlay.frame != win { overlay.setFrame(win, display: false) }
            underlines.marks = issues.compactMap { i in
                rects[i.id].map { rs in (rs.map { $0.offsetBy(dx: -win.minX, dy: -win.minY) }, i.kind.color, i.id == hoverID) }
            }
            overlay.orderFrontRegardless()
        }
        placeBadge(frame, el)
    }

    var drawnCount = 0
    var lastSpot = ""
    var runs: [(NSRange, AXUIElement)] = []
    var runsFor: NSString?
    var runsNeeded = false

    /// Screen rect of a range: ask the text box, and if it gives back nothing, ask the run of text holding it.
    func bounds(_ el: AXUIElement, _ r: NSRange) -> CGRect? {
        if !runsNeeded, let b = AX.bounds(el, r) { return b }
        runsNeeded = true
        if runsFor !== value { runs = AX.textRuns(el, value: value); runsFor = value }
        guard let (rr, leaf) = runs.first(where: { NSLocationInRange(r.location, $0.0) }) else { return nil }
        let local = NSRange(location: r.location - rr.location, length: min(r.upperBound, rr.upperBound) - r.location)
        return AX.bounds(leaf, local)
    }

    /// One rect per line: a multi-line range is measured word by word and grouped by line.
    func lineRects(_ el: AXUIElement, _ r: NSRange) -> [CGRect] {
        guard let whole = bounds(el, r) else { return [] }
        let first = bounds(el, NSRange(location: r.location, length: 1)) ?? whole
        if whole.height <= first.height * 1.5 { return [whole] }
        var lines: [CGRect] = []
        for t in Diff.tokenize(value.substring(with: r)) where t.isWord {
            guard let b = bounds(el, NSRange(location: r.location + t.range.location, length: t.range.length)) else { continue }
            if let k = lines.indices.last, abs(lines[k].midY - b.midY) < b.height / 2 { lines[k] = lines[k].union(b) } else { lines.append(b) }
        }
        return lines
    }

    func placeBadge(_ frame: CGRect, _ el: AXUIElement) {
        let checking = paragraphs(value).contains { inflight.contains($0.1) }
        let count = issues.count
        let tidyNow = tidy != nil
        guard count > 0 || checking || tidyNow else { badge.orderOut(nil); return }
        let state = "\(count) \(checking) \(tidyNow)"
        if state != badgeState || badge.contentView == nil {
            badgeState = state
            badge.contentView = ClickThroughHostingView(rootView: DotView(count: count, checking: checking, tidy: tidyNow) { [weak self] in self?.clickDot() })
        }
        let size = badge.contentView!.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? frame
        let area = frame.intersection(screen).isNull ? frame : frame.intersection(screen)
        let f = badgeSpot(size, area: area, box: frame, screen: screen, el)
        if badge.frame != f { badge.setFrame(f, display: true) }
        if !badge.isVisible { badge.orderFrontRegardless() }
    }

    /// Somewhere the buttons don't cover the text you're typing: to the right of the last line if there's room,
    /// else in the empty space under the text, else just outside the box (below it, or above if there's no room).
    func badgeSpot(_ size: CGSize, area: CGRect, box: CGRect, screen: CGRect, _ el: AXUIElement) -> CGRect {
        let corner = CGRect(x: area.maxX - size.width - 4, y: area.minY + 4, width: size.width, height: size.height)
        guard value.length > 0 else { return corner }
        // the last line: where the last character sits (AppKit coordinates, origin bottom-left)
        guard let raw = bounds(el, NSRange(location: value.length - 1, length: 1)) else { return corner }
        var last = AX.toCocoa(raw)
        if value.character(at: value.length - 1) == 10 { last.size.width = 0 }    // an empty last line
        let right = CGRect(x: area.maxX - size.width - 4, y: last.midY - size.height / 2, width: size.width, height: size.height)
        func spot(_ name: String, _ r: CGRect) -> CGRect {
            if debug && name != lastSpot { lastSpot = name; log("badge \(name) of text: last line ends at x \(Int(last.maxX)), badge \(r)") }
            return r
        }
        // the buttons are taller than a line of text, so they may stick a little past the box's edge
        if right.minX >= last.maxX + 8 && right.minX >= area.minX && right.midY >= area.minY && right.midY <= area.maxY {
            return spot("right of last line", right)
        }
        if last.minY - area.minY >= size.height + 6 { return spot("under the text", corner) }
        let below = CGRect(x: box.maxX - size.width, y: box.minY - size.height - 2, width: size.width, height: size.height)
        if below.minY >= screen.minY { return spot("below the box", below) }
        return spot("above the box", CGRect(x: box.maxX - size.width, y: box.maxY + 2, width: size.width, height: size.height))
    }

    // MARK: hover card

    var fakeMouse: CGPoint?

    /// Test hook: with CG_DEBUG set, commands written to /tmp/cg-cmd drive the app without touching the real mouse.
    func debugCommand() {
        guard debug, let cmd = try? String(contentsOfFile: "/tmp/cg-cmd", encoding: .utf8) else { return }
        try? FileManager.default.removeItem(atPath: "/tmp/cg-cmd")
        let w = cmd.split(separator: " ").map(String.init)
        switch w.first?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "hover":
            if let i = issues.first(where: { $0.original == w[1].trimmingCharacters(in: .whitespacesAndNewlines) }), let r = rects[i.id]?.first {
                fakeMouse = CGPoint(x: r.midX, y: r.midY)
            }
        case "away": fakeMouse = CGPoint(x: -5000, y: -5000)
        case "overbadge": fakeMouse = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        case "tab": if let id = hoverID { accept(id) }
        case "esc": if let id = hoverID { ignore(id) }
        case "fixall": fixAll()
        case "tidyreplace": applyTidy()
        case "dothover": fakeMouse = CGPoint(x: badge.frame.midX, y: badge.frame.midY)
        case "dotclick": clickDot()
        case "translate": translateMenu()
        case "dump":
            log("value: \(value)")
            for i in issues { log("  \(i.range) \(i.kind) \(i.original) -> \(i.suggestion) rects=\(rects[i.id] ?? [])") }
            log("card \(card.isVisible ? "\(card.frame)" : "hidden") badge \(badge.isVisible ? "\(badge.frame)" : "hidden") tidy \(tidy.map { "\($0.lines.count) lines" } ?? "none") dotcard \(dotCardOpen) pinned \(dotPinned)")
        default: break
        }
    }

    func hover() {
        debugCommand()
        let m = fakeMouse ?? NSEvent.mouseLocation
        // the dot's card stays while the mouse is on the dot or the card, and goes a moment after it leaves
        if dotCardOpen {
            if card.frame.insetBy(dx: -6, dy: -6).contains(m) || badge.frame.insetBy(dx: -4, dy: -4).contains(m) { lastInside = Date(); return }
            if dotPinned || Date().timeIntervalSince(lastInside) < 0.35 { return }
            hideCard()
        }
        if card.isVisible && card.frame.insetBy(dx: -4, dy: -4).contains(m) { lastInside = Date(); return }
        // the dot can sit on top of an underlined word: over the dot, it's the dot, not the word
        if badge.isVisible && badge.frame.insetBy(dx: -2, dy: -2).contains(m) { showDotCard(pinned: false); return }
        if let i = issues.first(where: { rects[$0.id]?.contains { $0.insetBy(dx: -1, dy: -4).contains(m) } ?? false }) {
            lastInside = Date()
            if hoverID != i.id { showCard(i) }
            return
        }
        if hoverID != nil && Date().timeIntervalSince(lastInside) > 0.3 { hideCard() }
    }

    /// Hovering the dot shows this card; clicking the dot keeps it open.
    func showDotCard(pinned: Bool) {
        if dotCardOpen { dotPinned = dotPinned || pinned; return }
        hideCard()
        let checking = paragraphs(value).contains { inflight.contains($0.1) } || tidyInflight != nil
        let rich = element.map { !AX.children($0).isEmpty } ?? false
        let view = DotCardView(count: issues.filter(\.hasFix).count, checking: checking, tidy: tidy, warn: rich,
                               fixAll: { [weak self] in self?.hideCard(); self?.fixAll() },
                               tidyUp: { [weak self] in self?.hideCard(); self?.applyTidy() })
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        let anchor = badge.frame
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = CGPoint(x: anchor.maxX - size.width, y: anchor.maxY + 4)
        if origin.y + size.height > screen.maxY { origin.y = anchor.minY - 4 - size.height }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        card.contentView = host
        card.setFrame(CGRect(origin: origin, size: size), display: true)
        card.orderFrontRegardless()
        dotCardOpen = true
        dotPinned = pinned
        lastInside = Date()
    }

    func clickDot() {
        if dotCardOpen && dotPinned { hideCard() } else { dotCardOpen = false; showDotCard(pinned: true) }
    }

    func showCard(_ i: Issue) {
        hoverID = i.id
        let view = CardView(issue: i, total: issues.filter(\.hasFix).count,
                            accept: { [weak self] in self?.accept(i.id) },
                            ignore: { [weak self] in self?.ignore(i.id) },
                            addWord: { [weak self] in self?.addToDictionary(i.id) },
                            fixAll: { [weak self] in self?.fixAll() })
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        guard let anchor = rects[i.id]?.last else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = CGPoint(x: anchor.minX - 14, y: anchor.minY - 8 - size.height)
        if origin.y < screen.minY { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        card.contentView = host
        card.setFrame(CGRect(origin: origin, size: size), display: true)
        card.orderFrontRegardless()
    }

    func hideCard() {
        hoverID = nil
        dotCardOpen = false
        dotPinned = false
        card.orderOut(nil)
    }

    // MARK: actions

    func accept(_ id: UUID) {
        guard let i = issues.first(where: { $0.id == id }) else { return }
        hideCard()
        replace([i])
    }

    func ignore(_ id: UUID) {
        guard let i = issues.first(where: { $0.id == id }) else { return }
        ignored.insert(i.ignoreKey)
        issues.removeAll { $0.id == id }
        hideCard()
    }

    func addToDictionary(_ id: UUID) {
        guard let i = issues.first(where: { $0.id == id }) else { return }
        dictionary.insert(i.original.lowercased())
        try? (dictionary.sorted().joined(separator: "\n") + "\n").write(to: dictionaryURL, atomically: true, encoding: .utf8)
        issues.removeAll { !allowed($0) }
        hideCard()
    }

    func fixAll() {
        note("fix all in \(appName): \(issues.filter(\.hasFix).count) fixes")
        hideCard()
        replace(issues)
    }

    func fixParagraph() {
        guard let el = element else { return }
        let caret = selection(el)?.location ?? 0
        guard let (r, _) = paragraphs(value).first(where: { caret >= $0.0.location && caret <= $0.0.upperBound }) else { return }
        replace(issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound })
    }

    /// Apply fixes from last to first so earlier positions stay valid.
    func replace(_ all: [Issue], then: (() -> Void)? = nil) {
        let list = all.filter(\.hasFix)
        guard let el = element, !list.isEmpty, !editing else { then?(); return }
        editing = true
        let before = value
        let caret = selection(el)
        var todo = Self.perLine(list, in: before)
        var failed = Set<UUID>()

        func finish() {
            let after = (AX.string(el, kAXValueAttribute) ?? before as String) as NSString
            shift(old: before, new: after)
            // a fix that didn't go in keeps its underline
            let removed = Set(list.map(\.id)).subtracting(failed)
            issues.removeAll { removed.contains($0.id) }
            value = after
            // remember what is left so the edited paragraph is not sent again
            let old = Set(paragraphs(before).map(\.1))
            for (r, t) in paragraphs(after) where cache[t] == nil && !old.contains(t) {
                cache[t] = issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound }
                    .map { $0.shifted(by: -r.location) }
            }
            // lines Fix all didn't change, like one whose fix didn't go in, keep their underlines
            showSaved()
            if let c = caret {
                let delta = after.length - before.length
                let loc = c.location >= (list.map(\.range.upperBound).max() ?? 0) ? c.location + delta : min(c.location, after.length)
                select(el, NSRange(location: max(0, loc), length: 0))
            }
            lastChange = Date()
            editing = false
            log("fixes done")
            updateStatus()
            then?()
        }

        func next() {
            guard let (i, ids) = todo.first else { finish(); return }
            todo.removeFirst()
            replaceOne(el, i) { ok in
                if !ok { failed.formUnion(ids); note("fix '\(i.original)' -> '\(i.suggestion)' didn't go in") }
                next()
            }
        }
        next()
    }

    // MARK: tidy up

    /// The whole message goes to Claude once you pause, if it's long enough to have a layout.
    func sendTidyCheck(_ el: AXUIElement) {
        let key = value as String
        guard tidyOn, tidyInflight == nil, !tidyChecked.contains(key), value.length <= 8000 else { return }
        let words = key.split(whereSeparator: \.isWhitespace).count
        let lines = key.split(separator: "\n").count
        guard words >= 20 || lines >= 3 else { return }
        tidyInflight = key
        let text = displayText(el)
        note("tidy check in \(appName) with \(model.rawValue): \(words) words, \(lines) lines, sent \(String(text.prefix(2000)).debugDescription)")
        let m = model
        Task {
            do {
                let (t, inTokens, outTokens, raw) = try await TidyChecker.check(text, model: m)
                await MainActor.run {
                    self.tidyInflight = nil
                    self.tidyChecked.insert(key)
                    if let t { self.tidyCache[key] = t }
                    self.recordUsage(CheckResult(issues: [], inputTokens: inTokens, outputTokens: outTokens), model: m)
                    note("tidy got \(t.map { "\($0.lines.count) lines, \($0.bold.count) bold" } ?? "nothing") | Claude said \(raw.prefix(1500))")
                    self.updateStatus()
                }
            } catch {
                await MainActor.run { self.tidyInflight = nil; self.tidyChecked.insert(key); note("tidy error \(error)") }
            }
        }
    }


    /// The box already puts space between paragraphs (like a web page does), so an empty line would look like two.
    /// Measured on screen: from the end of one paragraph to the start of the next, more than half a line.
    func paragraphsSpaced(_ el: AXUIElement) -> Bool {
        let lines = value.components(separatedBy: "\n")
        var at = 0
        for k in 0..<max(0, lines.count - 1) {
            let a = lines[k] as NSString, b = lines[k + 1] as NSString
            let next = at + a.length + 1
            defer { at = next }
            // two paragraphs with text, neither a list item
            guard a.length > 0, b.length > 0,
                  a.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression).location == NSNotFound,
                  b.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression).location == NSNotFound,
                  let end = bounds(el, NSRange(location: next - 2, length: 1)),
                  let start = bounds(el, NSRange(location: next, length: 1)) else { continue }
            let gap = start.minY - end.maxY                         // screen positions run downward
            note("tidy: paragraph gap \(Int(gap)) for line height \(Int(end.height))")
            return gap > end.height / 2
        }
        return false
    }

    /// The first line of the tidied text is in the box now.
    func lineStartLive(_ el: AXUIElement, _ first: String) -> Bool {
        let want = first.split(separator: " ").prefix(4).joined(separator: " ").lowercased()
        return (AX.string(el, kAXValueAttribute) ?? "").lowercased().hasPrefix(want)
    }

    /// Where a line starts, by its first words, after a list marker the box may show in its text.
    func lineStart(of text: String) -> Int? {
        let want = text.split(separator: " ").prefix(4).joined(separator: " ").lowercased()
        guard !want.isEmpty else { return nil }
        var i = 0
        while i <= value.length {
            if i == 0 || value.character(at: i - 1) == 10 {
                let body = value.substring(from: i).replacingOccurrences(of: #"^([-*•]|\d+[.)])\s+"#, with: "", options: .regularExpression)
                if body.lowercased().hasPrefix(want) { return i }
            }
            let next = value.range(of: "\n", options: [], range: NSRange(location: i, length: value.length - i))
            if next.location == NSNotFound { return nil }
            i = next.upperBound
        }
        return nil
    }

    /// Replace swaps the whole message for the tidied lines in one paste, never pressing Return (it sends in
    /// the Claude app and Slack). Then, the ways that work in every box tested: list markers typed at the start
    /// of each item, which rich boxes turn into a real list; one pasted break at a line start for each blank
    /// line; and bold by selecting the phrase and pressing Command-B.
    func applyTidy() {
        guard let el = element, let t = tidy, !editing else { return }
        hideCard()
        editing = true
        note("tidy up in \(appName): \(t.lines.count) lines, \(t.lines.filter { $0.marker != nil }.count) list items, \(t.bold.count) bold")
        let first = t.lines[0].text
        func finish(_ ok: Bool) {
            refresh(el)
            lastChange = Date()
            editing = false
            note(ok ? "tidy up done" : "tidy up stopped partway")
            updateStatus()
        }
        // 2. list markers, top down, numbered within each list
        func markers(_ k: Int, _ n: Int) {
            guard k < t.lines.count else {
                refresh(el)
                // a box that spaces its paragraphs and made a real list already sets the list apart; where the
                // list is typed dashes, every line is spaced alike, so empty lines still group it
                let hasList = t.lines.contains { $0.marker != nil }
                if paragraphsSpaced(el) && (!hasList || AX.count(el, role: "AXList", depth: 6) > 0) {
                    note("tidy: this box already spaces its paragraphs; no empty lines added"); return bolds(0)
                }
                return blanks(t.lines.count - 1)
            }
            let line = t.lines[k]
            guard let m = line.marker else { return markers(k + 1, 0) }
            let number = m == "1. " ? n + 1 : 0
            let mark = m == "1. " ? "\(number). " : "- "
            refresh(el)
            guard let at = lineStart(of: line.text) else { note("tidy: list line \(k + 1) not found"); return markers(k + 1, number) }
            func attempt(_ tries: Int) {
                caret(el, at: at) { ok in
                    guard ok else { note("tidy: no cursor at list line \(k + 1)"); return markers(k + 1, number) }
                    let look = { "\(AX.string(el, kAXValueAttribute) ?? "")\u{1}\(AX.count(el, role: "AXListMarker", depth: 6))" }
                    let was = look()
                    Self.type(mark)
                    Self.wait(until: { look() != was }) { changed in
                        // keys that went nowhere changed nothing, so typing again can't double up
                        if !changed && tries > 0 { return DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt(tries - 1) } }
                        if !changed { note("tidy: marker didn't go in on line \(k + 1)") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { markers(k + 1, number) }
                    }
                }
            }
            attempt(1)
        }
        // 3. blank lines, bottom up so the spots above don't move
        func blanks(_ k: Int) {
            guard k > 0 else { return bolds(0) }
            let line = t.lines[k]
            guard line.blankBefore else { return blanks(k - 1) }
            refresh(el)
            let start = line.text.split(separator: " ").prefix(4).joined(separator: " ")
            if displayText(el).range(of: "\n\n" + start, options: .caseInsensitive) != nil { note("tidy: line \(k + 1) already has a blank line above"); return blanks(k - 1) }
            guard let at = lineStart(of: line.text), at > 0 else { note("tidy: line \(k + 1) not found for its blank line (\(start))"); return blanks(k - 1) }
            insert(el, over: NSRange(location: at, length: 0), "\n") { ok in
                note("tidy: blank line above line \(k + 1) at \(at): \(ok ? "added" : "didn't go in")")
                blanks(k - 1)
            }
        }
        // 4. bold, where the box keeps styles
        func bolds(_ k: Int) {
            guard k < t.bold.count, canStyle(el), !styleRuledOut(.bold) else { return finish(true) }
            refresh(el)
            let r = value.range(of: t.bold[k])
            guard r.location != NSNotFound else { return bolds(k + 1) }
            let alone = styledAlone(el, t.bold[k])
            select(el, r, expect: t.bold[k]) { ok in
                guard ok else { return bolds(k + 1) }
                Self.key(11, .maskCommand)                              // Command-B
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if !(alone || self.styledAlone(el, t.bold[k]) || self.nativeStyled(el, r, .bold)) {
                        self.noStyle.insert(self.styleKey(.bold))
                        note("bold doesn't work in \(self.appName); won't try it here again")
                    }
                    self.select(el, NSRange(location: r.upperBound, length: 0))
                    bolds(k + 1)
                }
            }
        }
        // 1. everything in the box, replaced by one paste
        Self.key(0, .maskCommand)                                       // Command-A
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let before = AX.string(el, kAXValueAttribute)
            self.paste(t.plain) {
                // a whole message can take a moment to show up
                Self.wait(until: { AX.string(el, kAXValueAttribute) != before && self.lineStartLive(el, first) }, tries: 100) { changed in
                    self.refresh(el)
                    // a box that turned the paste into something else (like an attachment) gets it undone
                    guard changed, self.lineStart(of: first) != nil else {
                        note("tidy paste didn't land as text; undoing")
                        if changed { Self.key(6, .maskCommand) }        // Command-Z
                        return finish(false)
                    }
                    markers(0, 0)
                }
            }
        }
    }


    /// The message as you see it, blank lines included. Chrome-based apps leave blank lines out of the text
    /// they hand over, but their own count has one break per blank line and none for a plain line break.
    func displayText(_ el: AXUIElement) -> String {
        guard let box = AX.boxText(el, upTo: value.length) else { return value as String }
        let b = box as NSString
        if b.isEqual(to: value as String) { return value as String }
        var out: [unichar] = [], i = 0, j = 0
        while i < value.length {
            let c = value.character(at: i)
            if j < b.length && c == b.character(at: j) { out += c == 10 ? [10, 10] : [c]; i += 1; j += 1 }
            else if c == 10 { out.append(10); i += 1 }
            else if j < b.length && b.character(at: j) == 10 { out.append(10); j += 1 }
            else { return value as String }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    /// Bring our copy up to date between edits, moving underlines with it.
    func refresh(_ el: AXUIElement) {
        guard let now = AX.string(el, kAXValueAttribute) as NSString?, now != value else { return }
        shift(old: value, new: now)
        value = now
    }

    /// Bold and underline need a box that keeps styles: a rich web box (its text comes in pieces), or a Mac
    /// text view whose text carries fonts. Never underline in Slack, where Command-U uploads a file.
    func canStyle(_ el: AXUIElement) -> Bool {
        if !AX.children(el).isEmpty { return true }
        var cf = CFRange(location: 0, length: min(1, value.length)); var v: AnyObject?
        guard let arg = AXValueCreate(.cfRange, &cf),
              AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let a = v as? NSAttributedString, a.length > 0,
              let font = a.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any] else { return false }
        return font["AXFontName"] != nil
    }

    var noStyle: Set<String> {
        // Slack: Command-U uploads a file. The Claude app's box has no bold or underline (tested).
        get { Set(defaults.stringArray(forKey: "noStyle") ?? ["com.tinyspeck.slackmacgap/underline",
                                                             "com.anthropic.claudefordesktop/bold", "com.anthropic.claudefordesktop/underline"]) }
        set { defaults.set(Array(newValue), forKey: "noStyle") }
    }
    /// Ruled out for this kind of box, or for the whole app.
    func styleRuledOut(_ c: Style) -> Bool {
        let app = NSRunningApplication(processIdentifier: element.map(AX.pid) ?? 0)?.bundleIdentifier ?? appName
        return noStyle.contains(styleKey(c)) || noStyle.contains("\(app)/\(c.rawValue)")
    }

    /// Per app, and in a browser per kind of box (its page classes), so one site that can't underline doesn't
    /// turn it off for every site.
    func styleKey(_ c: Style) -> String {
        let app = NSRunningApplication(processIdentifier: element.map(AX.pid) ?? 0)?.bundleIdentifier ?? appName
        let classes = (element.flatMap { AX.attr($0, "AXDOMClassList") } as? [String] ?? [])
            .filter { !$0.localizedCaseInsensitiveContains("focus") }.sorted().joined(separator: ".")
        return classes.isEmpty ? "\(app)/\(c.rawValue)" : "\(app)/\(classes)/\(c.rawValue)"
    }

    /// In a web box: the phrase is a piece of text on its own.
    func styledAlone(_ el: AXUIElement, _ phrase: String) -> Bool {
        AX.textRuns(el, value: value).contains { value.substring(with: $0.0) == phrase }
    }

    /// In a Mac text view: the font at the phrase is bold, or it's underlined.
    func nativeStyled(_ el: AXUIElement, _ r: NSRange, _ c: Style) -> Bool {
        guard AX.children(el).isEmpty else { return false }
        var cf = CFRange(location: r.location, length: r.length); var v: AnyObject?
        guard let arg = AXValueCreate(.cfRange, &cf),
              AXUIElementCopyParameterizedAttributeValue(el, kAXAttributedStringForRangeParameterizedAttribute as CFString, arg, &v) == .success,
              let a = v as? NSAttributedString, a.length > 0 else { return false }
        let attrs = a.attributes(at: 0, effectiveRange: nil)
        if c == .underline { return (attrs[NSAttributedString.Key("AXUnderline")] as? Int ?? 0) != 0 }
        let name = (attrs[NSAttributedString.Key("AXFont")] as? [String: Any])?["AXFontName"] as? String ?? ""
        return name.localizedCaseInsensitiveContains("bold")
    }

    /// Selects a range (or puts the cursor at a spot) and pastes text over it, after checking it's the right text.
    func insert(_ el: AXUIElement, over r: NSRange, _ text: String, done: @escaping (Bool) -> Void) {
        guard r.location >= 0, r.upperBound <= value.length, let map = boxMap(el) else { return done(false) }
        if r.length > 0, let at = AX.string(el, for: Self.toBox(r, map)), at != value.substring(with: r) { return done(false) }
        let go = { (ok: Bool) in
            guard ok else { note("could not put the cursor at \(r.location) (box reports \(self.selection(el).map { "\($0)" } ?? "nil"))"); return done(false) }
            // an empty line doesn't show in the text Chrome hands over, only in the box's own text
            let live = { "\(AX.string(el, kAXValueAttribute) ?? "")\u{1}\(AX.boxText(el, upTo: (AX.string(el, kAXValueAttribute) ?? "").utf16.count) ?? "")" }
            let before = live()
            self.paste(text) { Self.wait(until: { live() != before }) { done($0) } }
        }
        if r.length > 0 { select(el, r, expect: value.substring(with: r), done: go) }
        else { caret(el, at: r.location, done: go) }
    }

    /// Selects a range and waits until the box reports exactly that text as selected. Positions alone can't be
    /// trusted at the end of a line: rich boxes like the Claude app may take the line break too, and their
    /// positions don't count it. If the selection runs long, select all but the last letter and take one more
    /// with Shift-Right, which stays on the line.
    func select(_ el: AXUIElement, _ r: NSRange, expect text: String, done: @escaping (Bool) -> Void) {
        let selected = { AX.string(el, kAXSelectedTextAttribute) }
        func shiftRight() {
            if r.length > 1 { select(el, NSRange(location: r.location, length: r.length - 1)) } else { select(el, NSRange(location: r.location, length: 0)) }
            Self.wait(until: { r.length == 1 ? self.selection(el)?.length == 0 : selected() == String(text.dropLast()) }) { ok in
                guard ok else { log("still selected \((selected() ?? "nil").debugDescription)"); return done(false) }
                Self.key(124, .maskShift)
                Self.wait(until: { selected() == text }) { ok in
                    if !ok { log("after Shift-Right selected \((selected() ?? "nil").debugDescription)") }
                    done(ok)
                }
            }
        }
        // Ending right at a line end, a rich box may also take the line break while reporting only the word,
        // so a paste would join the two lines. There, never select up to the end directly.
        if r.upperBound == value.length || value.character(at: r.upperBound) == 10 { return shiftRight() }
        select(el, r)
        Self.wait(until: { (selected() ?? "").isEmpty == false || self.selection(el) == r && selected() == nil }) { _ in
            let got = selected()
            if got == text || (got == nil && self.selection(el) == r) { return done(true) }
            log("selected \((got ?? "nil").debugDescription) for \(text.debugDescription); trying Shift-Right")
            shiftRight()
        }
    }

    func caret(_ el: AXUIElement, at loc: Int, done: @escaping (Bool) -> Void) {
        let r = NSRange(location: loc, length: 0)
        select(el, r)
        Self.wait(until: { self.selection(el) == r }, then: done)
    }

    /// Types text as real key presses, so a box's own shortcuts (like "- " for a list) see it.
    /// Only what list markers need: digits, ".", "-" and space.
    static let keyCodes: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
                                                    "8": 28, "9": 25, ".": 47, "-": 27, " ": 49]
    static func type(_ s: String) {
        for ch in s { if let k = keyCodes[ch] { key(k, []) } }
    }

    /// Fixes on the same line become one fix from the first to the last, so each line takes one paste.
    /// Lines run last to first so earlier positions stay valid. Each comes with the fixes it stands for.
    static func perLine(_ list: [Issue], in v: NSString) -> [(Issue, [UUID])] {
        var groups: [NSRange: [Issue]] = [:]
        for i in list {
            let line = v.lineRange(for: NSRange(location: i.range.location, length: 0))
            groups[line, default: []].append(i)
        }
        return groups.values.map { g -> (Issue, [UUID]) in
            let g = g.sorted { $0.range.location < $1.range.location }
            guard g.count > 1, zip(g, g.dropFirst()).allSatisfy({ $0.range.upperBound <= $1.range.location }) else {
                return (g[0], g.map(\.id))
            }
            let span = NSRange(location: g[0].range.location, length: g.last!.range.upperBound - g[0].range.location)
            var fixed = "", at = span.location
            for i in g {
                fixed += v.substring(with: NSRange(location: at, length: i.range.location - at)) + i.suggestion
                at = i.range.upperBound
            }
            return (Issue(range: span, original: v.substring(with: span), suggestion: fixed, kind: g[0].kind, reason: ""), g.map(\.id))
        }.sorted { $0.0.range.location > $1.0.range.location }
    }

    /// Try the Accessibility API first; apps that ignore it get the fix pasted over a selection.
    func replaceOne(_ el: AXUIElement, _ whole: Issue, done: @escaping (Bool) -> Void) {
        guard let cur = AX.string(el, kAXValueAttribute) as NSString?,
              whole.range.upperBound <= cur.length, cur.substring(with: whole.range) == whole.original else { done(false); return }
        // replace only the part that changes, never starting or ending with a space
        let (r, fix) = Diff.tighten(whole.range, whole.suggestion, in: cur)
        let i = Issue(range: r, original: cur.substring(with: r), suggestion: fix, kind: whole.kind, reason: whole.reason)
        let expected = cur.replacingCharacters(in: i.range, with: i.suggestion)
        // never type over text that isn't the flagged word
        guard let map = boxMap(el) else { done(false); return }
        // ask the box what sits at that spot; reading the selection back right away comes back empty in Chrome
        if let at = AX.string(el, for: Self.toBox(i.range, map)), at != i.original {
            log("found '\(at)' instead of '\(i.original)' in \(appName); skipping")
            done(false); return
        }
        select(el, i.range)
        let ok = AX.setSelectedText(el, i.suggestion)
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.03 : 0)) {
            let now = AX.string(el, kAXValueAttribute) ?? ""
            if now == expected { done(true); return }
            guard now == cur as String else { done(false); return }
            self.select(el, i.range, expect: i.original) { ok in
                guard ok else {
                    log("could not select '\(i.original)' in \(self.appName); not pasting")
                    return done(false)
                }
                pasteFix()
            }
        }

        func pasteFix() {
            paste(i.suggestion) {
                Self.wait(until: { AX.string(el, kAXValueAttribute) == expected as String }) { done($0) }
            }
        }
    }

    static func key(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Checks every 15 ms for up to half a second.
    static func wait(until ok: @escaping () -> Bool, tries: Int = 33, then: @escaping (Bool) -> Void) {
        if ok() { then(true); return }
        guard tries > 0 else { then(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { wait(until: ok, tries: tries - 1, then: then) }
    }

    func paste(_ s: String, then: @escaping () -> Void) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        pb.clearContents()
        pb.setString(s, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down)   // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        // put the clipboard back once the paste has landed (the box changed), or after half a second
        let before = element.flatMap { AX.string($0, kAXValueAttribute) }
        Self.wait(until: { self.element.flatMap { AX.string($0, kAXValueAttribute) } != before }) { _ in
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
            then()
        }
    }

    // MARK: keys: Tab takes the fix, Esc ignores it (only while a card is open), plus the shortcuts in the Shortcuts menu

    func installKeyTap() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            let c = Unmanaged<Controller>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = c.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return c.key(event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true when the key was ours and should not reach the app.
    func key(_ e: CGEvent) -> Bool {
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let f = e.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        if recordingShortcut { return false }
        if Action.fixParagraph.shortcut?.matches(e) == true && running && element != nil {
            DispatchQueue.main.async { self.fixParagraph() }
            return true
        }
        if Action.readAloud.shortcut?.matches(e) == true {
            DispatchQueue.main.async { self.readAloud(anchor: NSEvent.mouseLocation) }
            return true
        }
        if Action.translate.shortcut?.matches(e) == true {
            DispatchQueue.main.async { self.translator.translateSelection(anchor: NSEvent.mouseLocation) }
            return true
        }
        if code == 53 && f.isEmpty && translator.visible { DispatchQueue.main.async { self.translator.close() }; return true }
        if code == 53 && f.isEmpty && dotCardOpen { DispatchQueue.main.async { self.hideCard() }; return true }
        guard let id = hoverID, f.isEmpty else { return false }
        if code == 48, issues.first(where: { $0.id == id })?.hasFix == true { DispatchQueue.main.async { self.accept(id) }; return true }
        if code == 53 { DispatchQueue.main.async { self.ignore(id) }; return true }
        return false
    }

    // MARK: usage

    var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "usage-" + f.string(from: Date())
    }

    func recordUsage(_ r: CheckResult, model: Model) {
        var u = defaults.dictionary(forKey: todayKey) as? [String: Double] ?? [:]
        u["checks", default: 0] += 1
        u["cost", default: 0] += Double(r.inputTokens) * model.price.0 / 1e6 + Double(r.outputTokens) * model.price.1 / 1e6
        defaults.set(u, forKey: todayKey)
    }

    func loadDictionary() {
        let s = (try? String(contentsOf: dictionaryURL, encoding: .utf8)) ?? ""
        dictionary = Set(s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: menu bar

    func updateStatus() {
        guard let b = statusItem?.button else { return }
        let symbol = speaker.isReading ? "speaker.wave.2.fill" : !AXIsProcessTrusted() || Checker.apiKey == nil ? "exclamationmark.triangle" : !running ? "pause.circle" : lastError != nil ? "exclamationmark.triangle" : "character.cursor.ibeam"
        if b.image?.accessibilityDescription != symbol {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        }
        let t = running && !issues.isEmpty ? " \(issues.count)" : ""
        if b.title != t { b.title = t; b.imagePosition = .imageLeading }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ action: Selector?, key: String = "", mods: NSEvent.ModifierFlags = [], on: Bool = false) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = self
            i.keyEquivalentModifierMask = mods
            i.state = on ? .on : .off
            if action == nil { i.isEnabled = false }
            menu.addItem(i)
            return i
        }
        item("Claude grammar checker", nil)
        if !AXIsProcessTrusted() {
            item("Needs Accessibility permission…", #selector(openAccessibility))
        }
        if Checker.apiKey == nil { item("Add your Anthropic API key…", #selector(askForKey)) }
        if let e = lastError { item("Last check failed: \(e)", nil) }
        item("On", #selector(toggleOn), on: enabled)
        item("Offer to tidy up (paragraphs, lists)", #selector(toggleTidy), on: tidyOn)
        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            item("Skip in \(front?.localizedName ?? id)", #selector(toggleSkip(_:)), on: skipped.contains(id)).representedObject = id
        }
        if let p = pausedUntil, p > Date() {
            let f = DateFormatter(); f.timeStyle = .short
            item("Paused until \(f.string(from: p)). Resume", #selector(resume))
        } else {
            item("Pause for 1 hour", #selector(pause))
        }
        menu.addItem(.separator())
        func shortcutItem(_ title: String, _ action: Selector, _ a: Action) {
            let s = a.shortcut
            item(title, action, key: s?.key ?? "", mods: s?.menuMods ?? [])
        }
        shortcutItem(speaker.isReading ? "Stop reading" : "Read selection aloud", #selector(readAloudMenu), .readAloud)
        let speeds = NSMenuItem(title: "Reading speed", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        for v in Speaker.speeds {
            let i = NSMenuItem(title: String(format: "%g×", v), action: #selector(pickSpeed(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = v
            i.state = v == speaker.speed ? .on : .off
            speedMenu.addItem(i)
        }
        speeds.submenu = speedMenu
        menu.addItem(speeds)
        shortcutItem("Translate selection to Chinese", #selector(translateMenu), .translate)
        shortcutItem("Fix this paragraph", #selector(fixParagraphMenu), .fixParagraph)
        let keys = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        let keysMenu = NSMenu()
        for a in Action.allCases {
            let i = NSMenuItem(title: "\(a.label): \(a.shortcut?.display ?? "none")…", action: #selector(changeShortcut(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = a.rawValue
            keysMenu.addItem(i)
        }
        keys.submenu = keysMenu
        menu.addItem(keys)
        menu.addItem(.separator())
        let models = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for m in Model.allCases {
            let i = NSMenuItem(title: m.label, action: #selector(pickModel(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = m.rawValue
            i.state = m == model ? .on : .off
            sub.addItem(i)
        }
        models.submenu = sub
        menu.addItem(models)
        let u = defaults.dictionary(forKey: todayKey) as? [String: Double] ?? [:]
        item(String(format: "Today: %d checks, $%.2f", Int(u["checks"] ?? 0), u["cost"] ?? 0), nil)
        item("My dictionary…", #selector(openDictionary))
        if Checker.apiKey != nil { item("Change API key…", #selector(askForKey)) }
        if Speaker.apiKey != nil { item("Change OpenAI key for Read aloud…", #selector(askForOpenAIKey)) }
        menu.addItem(.separator())
        item("Quit", #selector(quit), key: "q", mods: .command)
    }

    @objc func toggleTidy() { tidyOn.toggle(); if !tidyOn { hideCard() }; updateStatus() }
    @objc func toggleOn() { enabled.toggle(); if !enabled { reset() }; updateStatus() }
    @objc func pause() { pausedUntil = Date().addingTimeInterval(3600); reset(); updateStatus() }
    @objc func resume() { pausedUntil = nil; updateStatus() }
    @objc func fixParagraphMenu() { fixParagraph() }
    @objc func translateMenu() {
        // the card goes under the menu bar icon; the menu has closed, so the app you were in has focus again
        let anchor = menuAnchor
        DispatchQueue.main.async { self.translator.translateSelection(anchor: anchor) }
    }
    @objc func readAloudMenu() {
        let anchor = menuAnchor
        DispatchQueue.main.async { self.readAloud(anchor: anchor) }
    }
    @objc func pickSpeed(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        speaker.speed = v                       // used from the next read on
    }
    @objc func changeShortcut(_ sender: NSMenuItem) {
        guard let a = Action(rawValue: sender.representedObject as? String ?? "") else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        alert.messageText = "Shortcut for \(a.label)"
        alert.informativeText = "Press the new keys. Use at least one of ⌘ Command, ⌃ Control or ⌥ Option."
        let field = NSTextField(labelWithString: a.shortcut?.display ?? "None")
        field.font = .systemFont(ofSize: 22, weight: .medium)
        field.alignment = .center
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "No shortcut")
        var picked = a.shortcut
        recordingShortcut = true
        defer { recordingShortcut = false }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // plain keys still work the buttons: Return saves, Esc cancels
            guard !e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return e }
            let s = Shortcut(e)
            if let other = Action.allCases.first(where: { $0 != a && $0.shortcut == s }) {
                field.stringValue = "\(s.display) is used by \(other.label)"
                return nil
            }
            picked = s
            field.stringValue = s.display
            return nil
        }
        let result = alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        switch result {
        case .alertFirstButtonReturn: a.shortcut = picked
        case .alertThirdButtonReturn: a.shortcut = nil
        default: break
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleSkip(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var s = skipped
        if s.contains(id) { s.remove(id) } else { s.insert(id); reset() }
        skipped = s
    }
    @objc func pickModel(_ sender: NSMenuItem) {
        guard let m = Model(rawValue: sender.representedObject as? String ?? "") else { return }
        model = m
        cache = [:]
    }
    @objc func openDictionary() {
        if !FileManager.default.fileExists(atPath: dictionaryURL.path) { try? "".write(to: dictionaryURL, atomically: true, encoding: .utf8) }
        NSWorkspace.shared.open(dictionaryURL)
    }
    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
