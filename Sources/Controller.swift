import AppKit
import SwiftUI

let debug = ProcessInfo.processInfo.environment["CG_DEBUG"] != nil
let started = Date()
/// Off unless turned on (`defaults write com.sttark.sttark-grammar logToFile -bool true`): fixes and tidy-ups
/// are noted in ~/Library/Logs/SttarkGrammar.log, with pieces of the text, so a run that went wrong can be read
/// afterward. The file starts over past 1 MB.
let logFile: FileHandle? = {
    guard UserDefaults.standard.bool(forKey: "logToFile") else { return nil }
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SttarkGrammar.log")
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: url) }
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let h = try? FileHandle(forWritingTo: url); _ = try? h?.seekToEnd(); return h
}()
func log(_ s: @autoclosure () -> String) {
    if debug { FileHandle.standardError.write((String(format: "%7.3f ", Date().timeIntervalSince(started)) + s() + "\n").data(using: .utf8)!) }
}
/// What fixes and tidy-ups did: to the debug log, and to the log file when that's turned on.
func note(_ s: String) {
    log(s)
    guard let logFile else { return }
    let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss.SSS"
    logFile.write((f.string(from: Date()) + " " + s + "\n").data(using: .utf8)!)
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
    var dictionary: Set<String> = []          // lowercase, for matching
    var names: [String] = []                  // dictionary words saved with a capital, like Sttark: always written that way
    // tidy up: Claude's cleaned-up copy of the whole message, offered as one change
    var tidyCache: [String: Tidy] = [:]        // whole message -> its tidy-up
    var tidyChecked: Set<String> = []          // messages already sent, with or without a tidy-up
    /// Messages whose tidy-up check is out. A check for older text doesn't hold up one for the text as it is now.
    var tidyInflight: Set<String> = []
    var tidyDismissed: Set<String> = []
    /// Messages Tidy up left alone because a tag sits in the middle (a paste would turn it into plain text).
    var tagSkipped: Set<String> = []
    /// Messages with a picture in what you wrote: Tidy up pastes text only, so it isn't offered.
    var pictureSkipped: Set<String> = []
    /// Apps whose box drops bold from a paste (the Claude app's chat box has no bold). Tidy-ups there leave bold out.
    var noBold: Set<String> {
        get { Set(defaults.stringArray(forKey: "noBold") ?? ["com.anthropic.claudefordesktop"]) }
        set { defaults.set(Array(newValue), forKey: "noBold") }
    }
    /// The same words and lines, ignoring blank lines, bullet symbols and spaces at the ends of lines.
    static func sameText(_ a: String, _ b: String) -> Bool {
        // a "•" the box shows and a "-" Claude writes are the same bullet
        let n = { (x: String) in x.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { $0.hasPrefix("• ") ? "- " + $0.dropFirst(2) : $0 } }
        return n(a) == n(b)
    }
    var dotCardOpen = false
    var dotPinned = false                      // opened by a click: stays until a click elsewhere or Esc
    /// The tidy-up for the message as it is right now.
    var tidy: Tidy? {
        guard tidyOn, !tidyDismissed.contains(value as String), let t = tidyCache[value as String] else { return nil }
        // with every fix the spell check found in it, so Tidy up never leaves one behind (worked out once per
        // message and set of fixes: the dot asks many times a second)
        let key = "\(value.hash) \(value.length) " + issues.map { "\($0.range.location):\($0.suggestion)" }.joined(separator: ",")
        if let c = tidyWithFixes, c.key == key { return c.tidy }
        let full = t.including(issues, from: value).keepingAddresses(from: value as String)
        tidyWithFixes = (key, full)
        return full
    }
    var tidyWithFixes: (key: String, tidy: Tidy)?
    /// Apps whose text box quietly undid a fix made through Accessibility; fixes there are pasted instead.
    var pasteOnly: Set<String> = []
    var appID: String { NSRunningApplication(processIdentifier: element.map(AX.pid) ?? 0)?.bundleIdentifier ?? appName }

    /// When each app was last asked to share its text boxes (see askToShare).
    var axAsked: [pid_t: Date] = [:]

    /// Electron apps (the Claude app, Slack) show no text box to other apps until asked, and forget when they
    /// restart, which the Claude app does by itself when it updates. An ask made while the app is still starting
    /// doesn't take, so ask again every few seconds for as long as the app shows no text box.
    func askToShare(_ pid: pid_t) {
        guard pid != getpid(), Date().timeIntervalSince(axAsked[pid] ?? .distantPast) > 3 else { return }
        if axAsked[pid] != nil { log("asked \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") again to share its text boxes") }
        AX.enableAppAccessibility(pid)
        axAsked[pid] = Date()
    }

    // screen
    let overlay = makePanel(mouse: false)
    let underlines = UnderlineView()
    let card = makePanel(mouse: true)
    let badge: NSPanel = {
        // no window shadow: around a small round dot on a see-through window it draws a jagged dark edge
        let p = makePanel(mouse: true); p.hasShadow = false; return p
    }()
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

    var dictionaryURL: URL { supportDir.appendingPathComponent("dictionary.txt") }
    let updater = Updater()

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
        updater.changed = { [weak self] in self?.updateStatus() }
        updater.start()
        // the newest Haiku and Sonnet models, now and once a day
        let refreshModels = { Task { if let k = Checker.apiKey { await Model.refresh(key: k) } } }
        _ = refreshModels()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { _ in _ = refreshModels() }
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
        alert.informativeText = "Claude can't speak, so Read aloud sends the text you select to OpenAI's voice model. Paste the OpenAI API key you got from DT. It's saved on this Mac where only your account can read it."
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
        alert.informativeText = "Sttark Grammar sends what you type to Claude to check it. Paste the Anthropic API key you got from DT. It's saved on this Mac where only your account can read it."
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
            if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier { askToShare(front) }
            reset(); updateStatus(); return
        }
        let pid = AX.pid(el)
        if pid == getpid() { return }                   // mouse is on our card; keep state
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier, skipped.contains(id) { reset(); updateStatus(); return }
        if axAsked[pid] == nil { askToShare(pid) }

        guard isTextBox(el), let str = AX.string(el, kAXValueAttribute) else { askToShare(pid); reset(); updateStatus(); return }
        let v = str as NSString
        if element == nil || !CFEqual(element!, el) {
            element = el
            wasChecking = false                  // a green "done" belongs to checks in this box only
            doneAt = .distantPast
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
            // a picture: the box counts it as one character (U+FFFC) that our text doesn't have
            else if j < b.length && b.character(at: j) == 0xFFFC { j += 1 }
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

    /// The paragraphs you wrote: a forwarded or quoted email below them isn't checked or fixed.
    func paragraphs(_ s: NSString) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: Diff.quoteStart(s) ?? s.length), options: [.byParagraphs]) { sub, r, _, _ in
            if let sub { out.append((r, sub)) }
        }
        return out
    }

    /// A fix never goes over an Asana mention chip: the paste would turn it into plain text.
    func notOnChip(_ i: Issue) -> Bool {
        guard let el = element, let chips = pills(el) else { return true }
        return !chips.ranges.contains { NSIntersectionRange($0, i.range).length > 0 || ($0.location <= i.range.location && i.range.location < $0.upperBound) }
    }

    func allowed(_ i: Issue) -> Bool {
        if ignored.contains(i.ignoreKey) { return false }
        // a dictionary word is spelled right, but a fix that only gives it a capital still shows
        if i.kind == .spelling && dictionary.contains(i.original.lowercased()) && i.original.lowercased() != i.suggestion.lowercased() { return false }
        // a fix that would change a dictionary word, like "docs.sttark.com" -> "docs.stark.com"
        let words = { (s: String) in Set(s.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)) }
        return words(i.original).subtracting(words(i.suggestion)).isDisjoint(with: dictionary)
    }

    /// A line typed again, typed back after an edit, or left alone by Fix all matches a result already in hand:
    /// show it. Lines that already show it keep their underlines as they are.
    func showSaved() {
        for (r, t) in paragraphs(value) {
            guard let saved = cache[t] else { continue }
            let want = saved.filter(allowed).map { $0.shifted(by: r.location) }.filter(notOnChip)
            let have = issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound }
            if have.map(\.range) == want.map(\.range) && have.map(\.suggestion) == want.map(\.suggestion) { continue }
            issues.removeAll { $0.range.location >= r.location && $0.range.location < r.upperBound }
            issues += want
        }
        issues.sort { $0.range.location < $1.range.location }
    }

    func issuesFromCache(_ s: NSString) -> [Issue] {
        paragraphs(s).flatMap { r, t in (cache[t] ?? []).filter(allowed).map { $0.shifted(by: r.location) } }.filter { s === value ? notOnChip($0) : true }
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
            let known = dictionary.map { w in names.first { $0.lowercased() == w } ?? w }.sorted()
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
        var caps = Diff.capitalIssues(text, besides: claude.issues) + Diff.nameIssues(text, names: names, besides: claude.issues)
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
            issues += res.issues.filter(allowed).map { $0.shifted(by: r.location) }.filter(notOnChip)
        }
        issues.sort { $0.range.location < $1.range.location }
        updateStatus()
    }

    // MARK: screen positions

    /// Every edge within d points (a pixel and a half unless asked): the same spot, give or take a twitch.
    static func nearlySame(_ a: CGRect, _ b: CGRect, by d: CGFloat = 1.5) -> Bool {
        abs(a.minX - b.minX) <= d && abs(a.minY - b.minY) <= d && abs(a.maxX - b.maxX) <= d && abs(a.maxY - b.maxY) <= d
    }

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
            // Chrome can report a box's edge a pixel off every other time (seen 8 times a second); a layer that
            // followed it jiggled the text under it. Move only for a real change.
            // The layer gets a roomy area that stays put while the box only twitches: Claude's chat box reported
            // its edges moving 2 to 8 px several times a second, and a layer that followed jiggled the text under
            // it. It moves when the box really moves (over 20 px) or a line would fall outside it.
            var win = visible.insetBy(dx: -14, dy: -14)
            if overlay.isVisible && Self.nearlySame(overlay.frame.insetBy(dx: 12, dy: 12), visible, by: 20)
                && rects.values.joined().allSatisfy({ overlay.frame.contains($0) }) {
                win = overlay.frame
            }
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

    /// When the app last changed the text itself (Fix all, Tidy up, a single fix).
    var lastOwnEdit = Date.distantPast

    /// The dot spins while a paragraph or the whole message is being checked, and in the pause after Fix all
    /// or Tidy up before the tidy-up check of the new text goes out, so there's no still gap before it appears.
    var isChecking: Bool { paragraphChecking || tidyChecking }

    /// The message is long enough for a tidy-up check.
    var tidyEligible: Bool {
        let key = Diff.flattenTags(Diff.ownPart(value as String))
        let words = key.split(whereSeparator: \.isWhitespace).count, lines = key.split(separator: "\n").count
        return tidyOn && value.length <= 8000 && (words >= 3 || lines >= 3)
    }
    /// You've paused long enough that the checks are about to go out (they go at 2 s): show it from 0.6 s on.
    var paused: Bool { Date().timeIntervalSince(lastChange) > 0.6 || Date().timeIntervalSince(lastOwnEdit) < 4 }

    var tidyChecking: Bool {
        tidyInflight.contains(value as String) || (tidyEligible && !tidyChecked.contains(value as String) && paused)
    }

    var paragraphChecking: Bool {
        paragraphs(value).contains { r, t in
            if inflight.contains(t) { return true }
            let words = t.split(whereSeparator: { $0.isWhitespace }).count
            let failed = failedAt[t].map { Date().timeIntervalSince($0) < 30 } ?? false
            return paused && cache[t] == nil && words >= 3 && t.utf16.count <= 4000 && !failed
        }
    }

    /// When the last check finished with nothing to show: the dot gives a green check for a moment.
    var doneAt = Date.distantPast
    var wasChecking = false

    func placeBadge(_ frame: CGRect, _ el: AXUIElement) {
        let checking = isChecking
        let count = issues.count
        let tidyNow = tidy != nil
        if wasChecking && !checking && count == 0 && !tidyNow { doneAt = Date() }
        wasChecking = checking
        let done = !checking && count == 0 && !tidyNow && Date().timeIntervalSince(doneAt) < 1.5
        let layoutFine = !checking && !tidyNow && tidyEligible && tidyChecked.contains(value as String) && !tagSkipped.contains(value as String) && !pictureSkipped.contains(value as String)
        guard count > 0 || checking || tidyNow || done else { badge.orderOut(nil); return }
        let state = "\(count) \(checking) \(tidyNow) \(done) \(layoutFine)"
        if state != badgeState || badge.contentView == nil {
            badgeState = state
            badge.contentView = ClickThroughHostingView(rootView: DotView(count: count, checking: checking, tidy: tidyNow, done: done, layoutFine: layoutFine) { [weak self] in self?.clickDot() })
        }
        let size = badge.contentView!.fittingSize
        let display = NSScreen.screens.first { $0.frame.intersects(frame) }
        let screen = display?.visibleFrame ?? frame
        // the whole screen below the menu bar: a hidden Dock's strip at the bottom still counts (the Claude app's
        // box sits in it)
        let room = display.map { CGRect(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.visibleFrame.maxY - $0.frame.minY) } ?? screen
        let area = frame.intersection(screen).isNull ? frame : frame.intersection(screen)
        let f = badgeSpot(size, area: area, box: frame, screen: room, lastLine: lastLine(el, box: frame), el)
        // the dot follows a real change, like a new line of text, not the box's few-pixel twitches
        if badge.frame != f && !(badge.isVisible && Self.nearlySame(badge.frame, f, by: 8)) { badge.setFrame(f, display: true) }
        if !badge.isVisible { badge.orderFrontRegardless() }
    }

    /// Buttons around the box (the Claude app's mic and send buttons sit inside its chat box), found in the
    /// background every 2 seconds so the dot never covers one.
    var buttonsFor: AXUIElement?
    var buttonFrames: [CGRect] = []
    var buttonsAt = Date.distantPast
    var buttonsLooking = false

    func nearbyButtons(_ el: AXUIElement, box: CGRect) -> [CGRect] {
        let same = buttonsFor.map { CFEqual($0, el) } ?? false
        if !buttonsLooking && (!same || Date().timeIntervalSince(buttonsAt) > 2) {
            buttonsLooking = true
            DispatchQueue.global(qos: .userInitiated).async {
                // a few levels up from the box, then every button below that sits near it
                var top = el
                for _ in 0..<4 { if let p = AX.attr(top, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() { top = p as! AXUIElement } }
                let near = box.insetBy(dx: -40, dy: -40)
                var found: [CGRect] = [], seen = 0
                let roles: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton", "AXCheckBox", "AXRadioButton"]
                func walk(_ e: AXUIElement, _ depth: Int) {
                    seen += 1
                    guard seen < 600, depth < 10 else { return }
                    if roles.contains(AX.string(e, kAXRoleAttribute) ?? ""), let f = AX.frame(e) {
                        let r = AX.toCocoa(f)
                        if r.intersects(near) && r.width < 200 && r.height < 120 { found.append(r) }
                        return
                    }
                    for c in AX.children(e) { walk(c, depth + 1) }
                }
                walk(top, 0)
                DispatchQueue.main.async {
                    if found != self.buttonFrames || !same { log("buttons near the box: \(found.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })") }
                    self.buttonsFor = el
                    self.buttonFrames = found
                    self.buttonsAt = Date()
                    self.buttonsLooking = false
                }
            }
        }
        return same ? buttonFrames : []
    }

    /// Where the dot lives in this box, chosen once when the box gets focus and kept while you type, so the dot
    /// never moves under your hands. In a box with room for several lines (an email), inside its bottom-right corner.
    /// In a one-line box, right beside it, level with the line you're typing (Google Chat, before its format
    /// buttons). Else below the bottom-right corner; above the top-right corner when buttons sit along the box
    /// (the Claude app's mic and send) or there's no room below. Always off buttons, on screen and inside the app's window.
    enum DotHome { case beside, corner, above, below }

    /// The frame of the window holding the box (Cocoa coordinates), asked once per box.
    var windowFor: AXUIElement?
    var windowRect: CGRect?

    func windowFrame(_ el: AXUIElement) -> CGRect? {
        if let w = windowFor, CFEqual(w, el) { return windowRect }
        windowFor = el
        windowRect = AX.attr(el, kAXWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? AX.frame($0 as! AXUIElement) : nil }.map(AX.toCocoa)
        return windowRect
    }

    /// Where the last line of text sits (Cocoa coordinates), asked once per text and box position.
    var lastLineKey = ""
    var lastLineRect: CGRect?

    func lastLine(_ el: AXUIElement, box: CGRect) -> CGRect? {
        let key = "\(value.hash) \(value.length) \(Int(box.minX)) \(Int(box.maxY))"
        if key == lastLineKey { return lastLineRect }
        lastLineKey = key
        var i = value.length - 1
        while i >= 0, let c = Unicode.Scalar(value.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(c) { i -= 1 }
        lastLineRect = i < 0 ? nil : lineRects(el, NSRange(location: i, length: 1)).last.map(AX.toCocoa).flatMap { box.insetBy(dx: -4, dy: -4).intersects($0) ? $0 : nil }
        return lastLineRect
    }
    var dotHomeFor: AXUIElement?
    var dotHome: DotHome = .below

    func badgeSpot(_ size: CGSize, area: CGRect, box: CGRect, screen: CGRect, lastLine: CGRect?, _ el: AXUIElement) -> CGRect {
        let buttons = nearbyButtons(el, box: box)
        let clear = { (r: CGRect) in !buttons.contains { $0.insetBy(dx: -3, dy: -3).intersects(r) } }
        let above = CGRect(x: box.maxX - size.width, y: box.maxY + 2, width: size.width, height: size.height)
        let below = CGRect(x: box.maxX - size.width, y: box.minY - size.height - 2, width: size.width, height: size.height)
        // inside the app's own window too (Messages: below its box is the window's bottom edge)
        let win = windowFrame(el).map { $0.insetBy(dx: -2, dy: -2) } ?? screen
        let fits = { (r: CGRect) in screen.contains(r) && win.contains(r) && clear(r) }
        // a box with room for several lines (an email, an Asana description): inside its bottom-right corner,
        // where the text reaches last
        let tall = box.height > 60
        let corner = CGRect(x: box.maxX - size.width - 4, y: box.minY + 4, width: size.width, height: size.height)
        // just right of a one-line box, level with the line you're typing (Google Chat: between the box and its
        // format buttons)
        let lineMid = lastLine.map { min(max($0.midY, box.minY + size.height / 2), box.maxY - size.height / 2) } ?? box.minY + min(box.height, 28) / 2
        let beside = CGRect(x: box.maxX, y: lineMid - size.height / 2, width: size.width, height: size.height)
        let same = dotHomeFor.map { CFEqual($0, el) } ?? false
        // decide once per box, after the buttons around it are known
        if !same && Date().timeIntervalSince(buttonsAt) < 3 && buttonsFor.map({ CFEqual($0, el) }) == true {
            let alongBox = buttons.contains { $0.insetBy(dx: -3, dy: -3).intersects(box) }
            let besideFits = screen.contains(beside) && win.contains(beside) && !buttons.contains { $0.intersects(beside.insetBy(dx: 3, dy: 3)) }
            dotHome = tall && fits(corner) ? .corner
                : !tall && besideFits && !alongBox ? .beside
                : !alongBox && fits(below) ? .below : fits(above) ? .above : .below
            dotHomeFor = el
            if debug { log("dot home for this box: \(dotHome) (buttons along the box: \(alongBox)) box \(box) last line \(lastLine.map { "\($0)" } ?? "none") beside fits \(besideFits) below fits \(fits(below)) above fits \(fits(above))") }
        }
        switch same || dotHomeFor.map({ CFEqual($0, el) }) == true ? dotHome : (fits(below) ? .below : .above) {
        case .beside: return beside
        // once the text reaches the corner, step outside the box so the dot never covers what you typed
        case .corner: return lastLine.map { $0.insetBy(dx: -2, dy: -2).intersects(corner) } == true ? (fits(below) ? below : above) : corner
        case .above: return above
        case .below: return below
        }
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
        case "tryfix":
            // debug: fix the first "<word>" to "<fix>" by the same steps a click on a card takes
            if w.count >= 3 {
                let word = w[1], fix = w[2].trimmingCharacters(in: .whitespacesAndNewlines)
                let r = value.range(of: word)
                if r.location != NSNotFound { replace([Issue(range: r, original: word, suggestion: fix, kind: .grammar, reason: "test")]) }
            }
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
        let checking = isChecking
        let rich = element.map { !AX.children($0).isEmpty } ?? false
        let layout: DotCardView.Layout = tidy != nil ? .offer : tagSkipped.contains(value as String) ? .tagged : pictureSkipped.contains(value as String) ? .picture : !tidyEligible ? .short : tidyChecking ? .checking : .fine
        let view = DotCardView(count: issues.filter(\.hasFix).count, checking: checking, tidy: tidy, layout: layout, warn: rich,
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
        if i.original.contains(where: \.isUppercase) && !names.contains(i.original) { names.append(i.original) }
        saveDictionary()
        issues.removeAll { !allowed($0) }
        hideCard()
    }

    func fixAll() {
        note("fix all in \(appName): \(issues.filter(\.hasFix).count) fixes")
        hideCard()
        replace(issues)
    }


    /// Apply fixes from last to first so earlier positions stay valid.
    func replace(_ all: [Issue], retry: Bool = true, then: (() -> Void)? = nil) {
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
            lastOwnEdit = Date()
            editing = false
            log("fixes done")
            updateStatus()
            then?()
            stillThere(list.filter { !failed.contains($0.id) }, before: before, after: after, el: el, retry: retry)
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

    /// Some boxes (the Claude app, once) take a fix and then quietly put their own copy of the text back.
    /// A second later, look for each fix by the words around it. One that's been undone is put in again, once,
    /// by pasting, and fixes in that app are pasted from then on.
    func stillThere(_ applied: [Issue], before: NSString, after: NSString, el: AXUIElement, retry: Bool) {
        guard !applied.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, let cur = self.element, CFEqual(cur, el), !self.editing,
                  let later = AX.string(el, kAXValueAttribute) as NSString? else { return }
            if later == after { note("fix all in \(self.appName): all \(applied.count) still in a second later"); return }
            let text = later as String
            var undone: [Issue] = []
            for i in applied {
                let a = max(0, i.range.location - 12), b = min(before.length, i.range.upperBound + 12)
                let left = before.substring(with: NSRange(location: a, length: i.range.location - a))
                let right = before.substring(with: NSRange(location: i.range.upperBound, length: b - i.range.upperBound))
                let r = later.range(of: left + i.original + right)
                guard r.location != NSNotFound, !text.contains(left + i.suggestion + right) else { continue }
                undone.append(Issue(range: NSRange(location: r.location + (left as NSString).length, length: i.range.length),
                                    original: i.original, suggestion: i.suggestion, kind: i.kind, reason: i.reason))
            }
            guard !undone.isEmpty else { return }
            note("fix all in \(self.appName): the box undid \(undone.count) of \(applied.count): \(undone.map(\.original).joined(separator: ", ")); pasting fixes here from now on")
            self.pasteOnly.insert(self.appID)
            self.value = later
            self.issues = self.issues.filter { i in !undone.contains { NSIntersectionRange($0.range, i.range).length > 0 } } + undone
            if retry { self.replace(undone, retry: false) } else { self.showSaved(); self.updateStatus() }
        }
    }

    // MARK: tidy up

    /// The whole message goes to Claude once you pause, if it's long enough to have a layout.
    func sendTidyCheck(_ el: AXUIElement) {
        let key = value as String
        guard tidyOn, !tidyInflight.contains(key), tidyInflight.count < 3, !tidyChecked.contains(key), value.length <= 8000 else { return }
        // a tag counts as the name it shows, not as the lines a box like Google Chat reports for it
        let flat = Diff.flattenTags(Diff.ownPart(key))
        let words = flat.split(whereSeparator: \.isWhitespace).count
        let lines = flat.split(separator: "\n").count
        guard words >= 3 || lines >= 3 else { return }   // the same floor as the spell check
        // A paste can't put a tag back, only text. With a tag in the middle there's nowhere to paste around it.
        if !Diff.tags(in: value).isEmpty && !Diff.tagsAtStart(value) {
            tidyChecked.insert(key)
            tagSkipped.insert(key)
            note("tidy: skipped in \(appName), a tag sits in the middle of the message")
            return
        }
        // A paste can't put a picture back (a Gmail draft's pasted images): Claude gets "[picture N]" lines where
        // they sit, and the text around them is tidied piece by piece
        let pics = pictureSplit(el)
        if let pics, pics.runs.isEmpty {
            tidyChecked.insert(key)
            pictureSkipped.insert(key)
            note("tidy: skipped in \(appName), couldn't find the text around its pictures")
            return
        }
        // Asana's mention chips: the same rules as Google Chat's tags
        let chips = pills(el)
        if let chips, !pillsAtStart(chips) {
            tidyChecked.insert(key)
            tagSkipped.insert(key)
            note("tidy: skipped in \(appName), a mention sits in the middle of the message")
            return
        }
        tidyInflight.insert(key)
        // only what you wrote above a forwarded or quoted email
        // a real list in a web box comes through with each number or bullet on a line of its own ("1.\nDid…"):
        // put them back on their lines, or Claude "fixes" a list that's already right
        let text = (pics?.text ?? chips?.text ?? Diff.flattenTags(Diff.ownPart(displayText(el))))
            .replacingOccurrences(of: #"(?m)^[ \t]*(\d+[.)]|[-•◦▪*])[ \t]*\n+"#, with: "$1 ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pictureCount = pics.map { $0.runs.count - 1 } ?? 0
        note("tidy check in \(appName) with \(model.rawValue): \(words) words, \(lines) lines, sent \(String(text.prefix(2000)).debugDescription)")
        let m = model
        let plainBox = noBold.contains(appID)
        let known = dictionary.map { w in names.first { $0.lowercased() == w } ?? w }.sorted()
        Task {
            do {
                let (got, inTokens, outTokens, raw) = try await TidyChecker.check(text, model: m, words: known)
                await MainActor.run {
                    self.tidyInflight.remove(key)
                    self.tidyChecked.insert(key)
                    // where bold can't stick, leave it out, and offer nothing if bold was the only change
                    var t = got
                    if plainBox, var x = t {
                        x.bold = []
                        // (this box doesn't show its blank lines to other apps, so they don't count as a change)
                        t = Self.sameText(x.plain(blankLines: true), text) ? nil : x
                    }
                    // every picture has to come back once, in order, or there's no safe way to paste around them
                    if pictureCount > 0, let x = t, x.split(pictures: pictureCount) == nil {
                        note("tidy: Claude's copy lost or moved a picture; nothing offered")
                        t = nil
                    }
                    if let t { self.tidyCache[key] = t }
                    self.recordUsage(CheckResult(issues: [], inputTokens: inTokens, outputTokens: outTokens), model: m)
                    note("tidy got \(t.map { "\($0.lines.count) lines, \($0.bold.count) bold" } ?? "nothing") | Claude said \(raw.prefix(1500))")
                    self.updateStatus()
                }
            } catch {
                await MainActor.run { self.tidyInflight.remove(key); self.tidyChecked.insert(key); note("tidy error \(error)") }
            }
        }
    }


    /// The box already puts space between paragraphs (like a web page does), so an empty line would look like two.
    /// Measured on screen: from the end of one paragraph to the start of the next, more than half a line.
    func paragraphsSpaced(_ el: AXUIElement) -> Bool {
        // Rich boxes (the Claude app, web editors) show each paragraph as a block, and a blank line as an empty
        // block. Measure between two paragraph blocks that sit right after each other.
        let blocks = AX.children(el).filter { AX.string($0, kAXRoleAttribute) == "AXGroup" || AX.string($0, kAXRoleAttribute) == "AXList" }
        if blocks.count >= 2 {
            for (a, b) in zip(blocks, blocks.dropFirst()) {
                guard AX.string(a, kAXRoleAttribute) == "AXGroup", AX.string(b, kAXRoleAttribute) == "AXGroup",
                      AX.string(a, kAXSubroleAttribute) != "AXEmptyGroup", AX.string(b, kAXSubroleAttribute) != "AXEmptyGroup",
                      let fa = AX.frame(a), let fb = AX.frame(b), fa.height > 0 else { continue }
                let gap = fb.minY - fa.maxY                             // screen positions run downward
                note("tidy: paragraph gap \(Int(gap)) between blocks")
                return gap > 6
            }
            return false                                            // no two paragraphs side by side to measure
        }
        let lines = value.components(separatedBy: "\n")
        // Chrome leaves blank lines out of the text it hands over, so check the box's own text for one between
        let shown = displayText(el)
        var at = 0
        for k in 0..<max(0, lines.count - 1) {
            let a = lines[k] as NSString, b = lines[k + 1] as NSString
            let next = at + a.length + 1
            defer { at = next }
            // two paragraphs with text, neither a list item
            guard a.length > 0, b.length > 0,
                  a.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression).location == NSNotFound,
                  b.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression).location == NSNotFound,
                  !shown.contains(String((a as String).suffix(24)) + "\n\n" + String((b as String).prefix(24))),
                  let end = bounds(el, NSRange(location: next - 2, length: 1)),
                  let start = bounds(el, NSRange(location: next, length: 1)) else { continue }
            let gap = start.minY - end.maxY                         // screen positions run downward
            note("tidy: paragraph gap \(Int(gap)) for line height \(Int(end.height))")
            return gap > end.height / 2
        }
        return false
    }

    /// How tall, in lines, the space is where the first blank line went: from the end of the line above to the
    /// start of the line below. About 1 in a box that doesn't space paragraphs, about 3 in one that does.
    func blankLineGap(_ el: AXUIElement, _ t: Tidy) -> CGFloat? {
        guard let k = t.lines.indices.first(where: { $0 > 0 && t.lines[$0].blankBefore }) else { return nil }
        let want = t.lines[k].text.split(separator: " ").prefix(4).joined(separator: " ")
        let at = value.range(of: want, options: .caseInsensitive)
        guard at.location != NSNotFound, at.location >= 2,
              let below = bounds(el, NSRange(location: at.location, length: 1)),
              let above = bounds(el, NSRange(location: at.location - 2, length: 1)), above.height > 0 else { return nil }
        let gap = (below.minY - above.maxY) / above.height
        note("tidy: blank line gap \(String(format: "%.1f", gap)) lines")
        return gap
    }

    /// The first line of the tidied text is in the box now.
    func lineStartLive(_ el: AXUIElement, _ first: String) -> Bool {
        // a box can show a list item's number or bullet in its text ("1. Yes.", "• Yes."): read past it
        let marker = #"^\s*(?:[-*•◦▪]|\d+[.)])?\s*"#
        let strip = { (s: String) in s.replacingOccurrences(of: marker, with: "", options: .regularExpression).lowercased() }
        let want = strip(first.split(separator: " ").prefix(4).joined(separator: " "))
        return strip(AX.string(el, kAXValueAttribute) ?? "").hasPrefix(want)
    }

    /// Tidy up replaces the whole message in one paste: Command-A, then a paste that carries a formatted copy
    /// (real lists, bold, blank lines) for rich boxes and a plain copy for plain ones. Nothing is typed after,
    /// and Return is never pressed (it sends in the Claude app and Slack).
    func applyTidy() {
        guard let el = element, let t = tidy, !editing else { return }
        // pictures stay where they are: only the text around them is replaced
        if let pics = pictureSplit(el) {
            guard !pics.runs.isEmpty, let pieces = t.split(pictures: pics.runs.count - 1) else {
                pictureSkipped.insert(value as String)
                tidyCache[value as String] = nil
                note("tidy up refused in \(appName): couldn't line up the text around its pictures")
                updateStatus()
                return
            }
            hideCard()
            editing = true
            return applyTidyAroundPictures(el, pieces, runs: pics.runs, blankLines: !paragraphsSpaced(el) && !pIsSpaced.contains(appID))
        }
        hideCard()
        editing = true
        // a box that already spaces its paragraphs (like a web page) gets no empty lines, or they'd look doubled
        let spaced = paragraphsSpaced(el)
        note("tidy up in \(appName): \(t.lines.count) lines, \(t.lines.filter { $0.marker != nil }.count) list items, \(t.bold.count) bold, blank lines \(spaced ? "left to the box" : "added")")
        // Tags at the start (Google Chat's mention chips) stay as they are: paste only over the text after them.
        if let last = Diff.tags(in: value).last, Diff.tagsAtStart(value) {
            return applyTidyAfterTags(el, t, after: last.0.upperBound, names: Diff.tags(in: value).map(\.1), spaced: spaced)
        }
        // Asana's mention chips at the start stay too, the same way
        if let chips = pills(el), pillsAtStart(chips), let last = chips.ranges.last {
            return applyTidyAfterTags(el, t, after: last.upperBound, names: chips.names.map { "@" + $0 }, spaced: spaced, keepSpace: true)
        }
        // A forwarded or quoted email below stays as it is: paste only over what you wrote above it.
        if let cut = Diff.quoteStart(value) {
            return applyTidyAbove(el, t, end: cut, spaced: spaced)
        }
        let first = t.lines[0].text
        func finish(_ ok: Bool) {
            refresh(el)
            lastChange = Date()
            lastOwnEdit = Date()
            editing = false
            note(ok ? "tidy up done" : "tidy up didn't go in")
            updateStatus()
        }
        Self.key(0, .maskCommand)                                       // Command-A
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let before = AX.string(el, kAXValueAttribute)
            let boxNow = { AX.boxText(el, upTo: (AX.string(el, kAXValueAttribute) ?? "").utf16.count) ?? "" }
            let shownBefore = boxNow()
            self.paste(t.plain(blankLines: !spaced), html: t.html(blankLines: !spaced)) {
                // a whole message can take a moment to show up. Chrome's text leaves blank lines out, so a change
                // to blank lines alone shows only in the box's own text.
                Self.wait(until: { (AX.string(el, kAXValueAttribute) != before || boxNow() != shownBefore) && self.lineStartLive(el, first) }, tries: 100) { landed in
                    if !landed {
                        // a box that turned the paste into something else (like an attachment) gets it undone
                        let changed = AX.string(el, kAXValueAttribute) != before
                        note("tidy paste didn't land as text\(changed ? "; undoing" : "")")
                        if changed { Self.key(6, .maskCommand) }            // Command-Z
                        // nothing changed at all: the box already looks like the tidy-up, so stop offering it
                        if !changed && t.bold.isEmpty {
                            self.tidyDismissed.insert(self.value as String)
                            note("tidy: the paste changed nothing; offer dropped for this text")
                        }
                        // nothing showed because the only change was bold, which this box drops: stop offering it
                        if !changed && !t.bold.isEmpty {
                            self.noBold.insert(self.appID)
                            self.tidyDismissed.insert(self.value as String)
                            note("tidy: \(self.appName) drops bold; tidy-ups there leave it out from now on")
                        }
                    }
                    self.refresh(el)
                    // A box that started as one paragraph couldn't be measured before. If an empty line now
                    // takes up more than two lines of space, the box spaces its own paragraphs: paste once more
                    // without the empty lines so they don't look doubled.
                    if landed && !spaced, let gap = self.blankLineGap(el, t), gap > 1.8 {
                        note("tidy: a blank line here is \(String(format: "%.1f", gap)) lines tall; pasting again without them")
                        self.pIsSpaced.insert(self.appID)
                        Self.key(0, .maskCommand)
                        return DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.paste(t.plain(blankLines: false), html: t.html(blankLines: false)) {
                                Self.wait(until: { false }, tries: 10) { _ in finish(true) }
                            }
                        }
                    }
                    finish(landed)
                }
            }
        }
    }


    /// Tidy up for a message that starts with tags: the tidied text without its leading "@Name"s goes over the text
    /// after the last tag, never over the tags. If that text can't be selected exactly, nothing is pasted.
    func applyTidyAfterTags(_ el: AXUIElement, _ t: Tidy, after tagEnd: Int, names: [String], spaced: Bool, keepSpace: Bool = false) {
        // Asana drops a space at the start of a paste: the space after the last mention stays out of the selection
        var start = tagEnd
        if keepSpace { while start < value.length, let c = Unicode.Scalar(value.character(at: start)), c == " " || c == "\u{00A0}" { start += 1 } }
        // mentions on a line of their own (the tidied first line is only the names): they keep their line and the
        // blank line under them, and the paste starts where your words start
        var ownLine = false
        do {
            var h = t.lines.first?.text ?? ""
            for n in names { h = h.trimmingCharacters(in: .whitespaces); if h.lowercased().hasPrefix(n.lowercased()) { h = String(h.dropFirst(n.count)) } }
            ownLine = h.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if ownLine { while start < value.length, let c = Unicode.Scalar(value.character(at: start)), CharacterSet.whitespacesAndNewlines.contains(c) || c == "\u{00A0}" { start += 1 } }
        var tail = t
        var head = tail.lines.first?.text ?? ""
        for n in names {
            head = head.trimmingCharacters(in: .whitespaces)
            if head.lowercased().hasPrefix(n.lowercased()) { head = String(head.dropFirst(n.count)) }
        }
        head = head.trimmingCharacters(in: .whitespaces)
        if head.isEmpty { tail.lines.removeFirst(); if !tail.lines.isEmpty { tail.lines[0].blankBefore = false } }
        else { tail.lines[0].text = head }
        func finish(_ ok: Bool) {
            refresh(el)
            lastChange = Date()
            lastOwnEdit = Date()
            editing = false
            note(ok ? "tidy up done, tags kept" : "tidy up didn't go in")
            updateStatus()
        }
        guard let first = tail.lines.first?.text, start < value.length else { return finish(false) }
        let range = NSRange(location: start, length: value.length - start)
        let old = value.substring(with: range)
        let want = first.split(separator: " ").prefix(4).joined(separator: " ").lowercased()
        note("tidy up in \(appName) after \(names.count) tag\(names.count == 1 ? "" : "s"): \(tail.lines.count) lines")
        select(el, range, expect: old, loose: true) { ok in
            guard ok else { note("tidy: couldn't select the text after the tags; nothing pasted"); return finish(false) }
            let before = AX.string(el, kAXValueAttribute)
            // the space between the last tag and the words stays (a no-break space, so a rich box keeps it)
            let lead = !keepSpace && !ownLine && old.first.map { $0 == " " || $0 == "\u{00A0}" } == true ? "\u{00A0}" : ""
            // plain text only: a formatted paste can start a new paragraph and push the words below the tag
            // Asana keeps a formatted paste on the line after its mentions, and needs it for blank lines and bullets
            self.paste(lead + tail.plain(blankLines: !spaced), html: keepSpace ? tail.html(blankLines: !spaced) : nil) {
                Self.wait(until: { let v = AX.string(el, kAXValueAttribute) ?? ""; return v != before && Diff.flattenTags(v).lowercased().contains(want) }, tries: 100) { landed in
                    if !landed { note("tidy paste after tags didn't show") }
                    finish(landed)
                }
            }
        }
    }

    /// Asana's mention chips (@Christopher Price, a task, a project): links the box shows as a name with its
    /// picture. Its text gives only the name, with a stray line break or two, so they're read from the box's parts.
    /// Each comes with where its name sits in our text, in order; and the message as you'd read it, each chip
    /// written as "@Name", paragraphs one per line.
    struct Pills { var names: [String]; var ranges: [NSRange]; var text: String }
    var pillsKey = ""
    var pillsFound: Pills?

    func pills(_ el: AXUIElement) -> Pills? {
        let key = "\(value.hash) \(value.length)"
        if key == pillsKey { return pillsFound }
        pillsKey = key
        pillsFound = nil
        guard value.length <= 8000 else { return nil }
        var names: [String] = [], seen = 0
        func isPill(_ e: AXUIElement) -> Bool {
            AX.string(e, kAXRoleAttribute) == "AXLink" && ((AX.attr(e, "AXDOMClassList") as? [String])?.contains("HypertextLink-navigationPill") == true)
        }
        func leafText(_ e: AXUIElement) -> String {
            seen += 1
            guard seen < 3000 else { return "" }
            if isPill(e) {
                let name = AX.children(e).compactMap { AX.string($0, kAXValueAttribute) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                names.append(name)
                return "@" + name
            }
            if AX.string(e, kAXRoleAttribute) == "AXStaticText" { return AX.string(e, kAXValueAttribute) ?? "" }
            return AX.children(e).map(leafText).joined()
        }
        // a list comes as its items, each on a line of its own with its number or bullet
        func isBlock(_ e: AXUIElement) -> Bool {
            AX.string(e, kAXRoleAttribute) == "AXList" || (AX.attr(e, "AXDOMClassList") as? [String])?.contains("ProsemirrorEditor-paragraph") == true
        }
        func blockLines(_ e: AXUIElement) -> [String] {
            guard AX.string(e, kAXRoleAttribute) == "AXList" else { return [leafText(e)] }
            return AX.children(e).flatMap { item -> [String] in
                var kids = AX.children(item), marker = "- "
                if let first = kids.first, !isBlock(first) {
                    let m = leafText(first).trimmingCharacters(in: .whitespaces)
                    if m.range(of: #"^(\d+[.)]|[•◦▪·*-])$"#, options: .regularExpression) != nil {
                        marker = m.first!.isNumber ? m + " " : "- "
                        kids.removeFirst()
                    }
                }
                let inner = kids.flatMap(blockLines)
                guard let head = inner.first else { return [marker.trimmingCharacters(in: .whitespaces)] }
                return [marker + head] + inner.dropFirst()
            }
        }
        let paras = AX.children(el).flatMap(blockLines)
        guard !names.isEmpty else { return nil }
        var ranges: [NSRange] = [], from = 0
        for n in names {
            let r = value.range(of: n, options: [], range: NSRange(location: from, length: value.length - from))
            guard r.location != NSNotFound else { return nil }
            ranges.append(r)
            from = r.upperBound
        }
        pillsFound = Pills(names: names, ranges: ranges, text: paras.joined(separator: "\n"))
        return pillsFound
    }

    /// The pictures in what you wrote (above any forwarded or quoted email), as the runs of text around them:
    /// where each run sits in our text, and the message as you see it with "[picture N]" lines where the pictures
    /// are. A box's text shows a picture only as an empty line, so they're found in the box's parts, in order.
    /// Emoji and the faces on mention chips are pictures too, but small ones: only something bigger than a line
    /// of text counts. Nil when there's no picture; an empty list when the runs can't be found in the text.
    struct PictureSplit { var runs: [NSRange]; var text: String }

    func pictureSplit(_ el: AXUIElement) -> PictureSplit? {
        var seen = 0, quoted = false, pictures = 0
        var groups: [[String]] = [[]]
        func walk(_ e: AXUIElement) {
            seen += 1
            guard seen < 4000, !quoted else { return }
            let role = AX.string(e, kAXRoleAttribute) ?? ""
            if role == "AXImage", let f = AX.frame(e), f.height >= 32 || f.width >= 48 { pictures += 1; groups.append([]); return }
            if role == "AXStaticText" {
                guard let t = AX.string(e, kAXValueAttribute) else { return }
                if Diff.quoteStart((t + "\n") as NSString) != nil || t.contains("Forwarded message") { quoted = true; return }
                let k = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !k.isEmpty { groups[groups.count - 1].append(k) }
                return
            }
            AX.children(e).forEach(walk)
        }
        walk(el)
        guard pictures > 0 else { return nil }
        let shown = displayText(el) as NSString
        var runs: [NSRange] = [], parts: [String] = [], from = 0, shownFrom = 0
        func find(_ s: NSString, _ t: String, _ start: Int) -> NSRange {
            s.range(of: t, options: [], range: NSRange(location: start, length: max(0, s.length - start)))
        }
        for g in groups {
            guard let a = g.first, let z = g.last else { runs.append(NSRange(location: from, length: 0)); parts.append(""); continue }
            let s0 = find(value, a, from), d0 = find(shown, a, shownFrom)
            guard s0.location != NSNotFound, d0.location != NSNotFound else { return PictureSplit(runs: [], text: "") }
            let s1 = find(value, z, s0.location), d1 = find(shown, z, d0.location)
            guard s1.location != NSNotFound, d1.location != NSNotFound else { return PictureSplit(runs: [], text: "") }
            runs.append(NSRange(location: s0.location, length: s1.upperBound - s0.location))
            parts.append(shown.substring(with: NSRange(location: d0.location, length: d1.upperBound - d0.location)))
            from = s1.upperBound
            shownFrom = d1.upperBound
        }
        var text = parts[0]
        for (i, p) in parts.dropFirst().enumerated() { text += (text.isEmpty ? "" : "\n\n") + "[picture \(i + 1)]" + (p.isEmpty ? "" : "\n\n" + p) }
        return PictureSplit(runs: runs, text: text)
    }

    /// Every chip comes before anything you wrote, with only spaces and line breaks around them.
    func pillsAtStart(_ p: Pills) -> Bool {
        guard let last = p.ranges.last else { return false }
        let head = NSMutableString(string: value.substring(to: last.upperBound))
        for r in p.ranges.reversed() { head.replaceCharacters(in: r, with: "") }
        return (head as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Apps whose pasted paragraphs already have space between them (Gmail): no empty lines in the paste.
    var pIsSpaced: Set<String> = []

    /// Tidy up around pictures: each tidied piece goes over its run of text, the last one first so the places of
    /// the ones above don't move. The pictures are never selected. If a run can't be selected exactly, it stops
    /// there; what's already pasted stays, and Command-Z takes it back.
    func applyTidyAroundPictures(_ el: AXUIElement, _ pieces: [Tidy], runs: [NSRange], blankLines: Bool) {
        func finish(_ ok: Bool, _ why: String) {
            refresh(el)
            lastChange = Date()
            lastOwnEdit = Date()
            editing = false
            note(ok ? "tidy up done around \(runs.count - 1) picture\(runs.count == 2 ? "" : "s")" : "tidy up stopped: \(why)")
            updateStatus()
        }
        // a run that's empty (a picture at the very start) can't take new text
        if let i = runs.indices.first(where: { runs[$0].length == 0 && !pieces[$0].lines.isEmpty }) {
            return finish(false, "there's text to put where piece \(i + 1) has none")
        }
        let order = runs.indices.filter { runs[$0].length > 0 }.reversed().map { $0 }
        note("tidy up in \(appName) around \(runs.count - 1) pictures: \(order.count) pieces, blank lines \(blankLines ? "added" : "left to the box")")
        var blank = blankLines
        func step(_ k: Int) {
            guard k < order.count else { return finish(true, "") }
            let i = order[k], range = runs[i], piece = pieces[i]
            guard range.upperBound <= value.length, !piece.lines.isEmpty else { return finish(false, "piece \(i + 1) is empty") }
            // A selection that starts right after a picture takes the picture too (the two share a position), and
            // the paste would delete it. So text after a picture is selected from its second letter, and the one
            // letter left in front is deleted after the paste.
            let afterPicture = i > 0 && range.length > 1
            let sel = afterPicture ? NSRange(location: range.location + 1, length: range.length - 1) : range
            let old = value.substring(with: sel)
            select(el, sel, expect: old, loose: true) { ok in
                guard ok else { return finish(false, "couldn't select piece \(i + 1)") }
                let before = AX.string(el, kAXValueAttribute)
                let want = piece.lines[0].text.split(separator: " ").prefix(4).joined(separator: " ").lowercased()
                self.paste(piece.plain(blankLines: blank), html: piece.html(blankLines: blank)) {
                    Self.wait(until: { let v = AX.string(el, kAXValueAttribute) ?? ""; return v != before && v.lowercased().contains(want) }, tries: 100) { landed in
                        guard landed else { return finish(false, "piece \(i + 1) didn't show") }
                        self.refresh(el)
                        // the first piece shows whether this box spaces its own paragraphs: if an empty line now
                        // takes more than two lines, undo it and paste the rest without empty lines
                        if blank, let gap = self.blankLineGap(el, piece), gap > 1.8 {
                            note("tidy: a blank line here is \(String(format: "%.1f", gap)) lines tall; pasting again without them")
                            self.pIsSpaced.insert(self.appID)
                            blank = false
                            Self.key(6, .maskCommand)                   // Command-Z
                            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.refresh(el); step(k) }
                        }
                        if afterPicture {
                            // the caret goes right after the letter left in front (between two letters, so it can't
                            // land on the picture), and Delete takes it out
                            self.select(el, NSRange(location: range.location + 1, length: 0))
                            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                Self.key(51, [])                            // Delete
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.refresh(el); step(k + 1) }
                            }
                        }
                        step(k + 1)
                    }
                }
            }
        }
        step(0)
    }

    /// Tidy up for an email with a forwarded or quoted email below: the tidied text goes over what you wrote above
    /// it, never over the quote. If that text can't be selected exactly, nothing is pasted.
    func applyTidyAbove(_ el: AXUIElement, _ t: Tidy, end: Int, spaced: Bool) {
        func finish(_ ok: Bool) {
            refresh(el)
            lastChange = Date()
            lastOwnEdit = Date()
            editing = false
            note(ok ? "tidy up done, quoted email kept" : "tidy up didn't go in")
            updateStatus()
        }
        // up to the end of your last line: the empty lines before the quote stay
        var stop = end
        while stop > 0, let c = Unicode.Scalar(value.character(at: stop - 1)), CharacterSet.whitespacesAndNewlines.contains(c) { stop -= 1 }
        guard stop > 0, let first = t.lines.first?.text else { return finish(false) }
        let range = NSRange(location: 0, length: stop)
        let old = value.substring(with: range)
        let want = first.split(separator: " ").prefix(4).joined(separator: " ").lowercased()
        note("tidy up in \(appName) above a quoted email: \(t.lines.count) lines")
        select(el, range, expect: old, loose: true) { ok in
            guard ok else { note("tidy: couldn't select the text above the quoted email; nothing pasted"); return finish(false) }
            let before = AX.string(el, kAXValueAttribute)
            self.paste(t.plain(blankLines: !spaced), html: t.html(blankLines: !spaced)) {
                Self.wait(until: { let v = AX.string(el, kAXValueAttribute) ?? ""; return v != before && v.lowercased().contains(want) }, tries: 100) { landed in
                    if !landed { note("tidy paste above the quoted email didn't show") }
                    finish(landed)
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
            else if j < b.length && b.character(at: j) == 0xFFFC { j += 1 }        // a picture
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

    /// Selects a range and waits until the box reports exactly that text as selected. Positions alone can't be
    /// trusted at the end of a line: rich boxes like the Claude app may take the line break too, and their
    /// positions don't count it. If the selection runs long, select all but the last letter and take one more
    /// with Shift-Right, which stays on the line.
    func select(_ el: AXUIElement, _ r: NSRange, expect text: String, loose: Bool = false, done: @escaping (Bool) -> Void) {
        let selected = { AX.string(el, kAXSelectedTextAttribute) }
        // A block of lines (the text after a mention, above a quoted email, between pictures): a web box reports
        // its selection with its own line breaks and list numbers, so only the words and marks have to match.
        // A picture (U+FFFC) or a tag's marks still count, so neither can slip into the selection.
        if loose {
            let words = { (s: String) in s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined() }
            let want = words(text)
            select(el, r)
            Self.wait(until: { words(selected() ?? "") == want }) { ok in
                if !ok { log("selected \((selected() ?? "nil").prefix(200).debugDescription) for \(text.prefix(200).debugDescription)") }
                done(ok)
            }
            return
        }
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
        let direct = !pasteOnly.contains(appID)
        if direct { select(el, i.range) }
        let ok = direct && AX.setSelectedText(el, i.suggestion)
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.03 : 0)) {
            let now = AX.string(el, kAXValueAttribute) ?? ""
            if now == expected { note("fix '\(i.original)' -> '\(i.suggestion)' went in directly"); done(true); return }
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
                Self.wait(until: { AX.string(el, kAXValueAttribute) == expected as String }) { ok in
                    var seen = ""
                    if !ok {
                        // what the box shows around the spot, and what was selected, to tell a wrong spot from a paste that didn't take
                        let now = (AX.string(el, kAXValueAttribute) ?? "") as NSString
                        let a = max(0, i.range.location - 15), b = min(now.length, i.range.upperBound + 15)
                        seen = "; box shows \(now.substring(with: NSRange(location: a, length: max(0, b - a))).debugDescription), wanted \((expected as NSString).substring(with: NSRange(location: a, length: max(0, min(b, (expected as NSString).length) - a))).debugDescription), selection \(self.selection(el).map { "\($0)" } ?? "nil") for \(i.range)"
                    }
                    note("fix '\(i.original)' -> '\(i.suggestion)' \(ok ? "went in by paste" : "pasted but the box didn't show it")\(seen)")
                    // Chrome sometimes takes a paste and drops it (seen in a docs.sttark.com comment box). With the text
                    // unchanged, select the word again and type the fix, the way a person would. A fix has no line
                    // break in it, so Return is never pressed.
                    guard !ok, AX.string(el, kAXValueAttribute) == cur as String, !i.suggestion.contains("\n") else { return done(ok) }
                    self.select(el, i.range, expect: i.original) { selected in
                        guard selected else { return done(false) }
                        Self.typeText(i.suggestion)
                        Self.wait(until: { AX.string(el, kAXValueAttribute) == expected as String }) { typed in
                            note("fix '\(i.original)' -> '\(i.suggestion)' \(typed ? "went in by typing" : "typed but the box didn't show it either")")
                            done(typed)
                        }
                    }
                }
            }
        }
    }

    /// Types text as key presses carrying the characters; an empty string presses Delete to clear the selection.
    static func typeText(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        if text.isEmpty { return key(51, []) }
        let units = Array(text.utf16)
        for chunk in stride(from: 0, to: units.count, by: 16).map({ Array(units[$0..<min($0 + 16, units.count)]) }) {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
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

    func paste(_ s: String, html: String? = nil, then: @escaping () -> Void) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        } ?? []
        pb.clearContents()
        pb.setString(s, forType: .string)
        if let html { pb.setString("<meta charset=\"utf-8\">" + html, forType: .html) }
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

    /// The clipboard's plain version, when its formatted version holds two or more paragraphs and the plain one
    /// has blank lines between them.
    static func plainOfParagraphs() -> String? {
        let pb = NSPasteboard.general
        guard let html = pb.string(forType: .html), let plain = pb.string(forType: .string), plain.contains("\n\n") else { return nil }
        let paragraphs = html.components(separatedBy: "<p").count - 1
        return paragraphs >= 2 ? plain : nil
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
        // Messages pastes a copy's formatted version and shows each paragraph as one line, so a copy from the
        // Claude app loses its blank lines. When the copy has paragraphs, paste its plain version instead, which
        // keeps them. (Our own paste comes back through here with only the plain version, so it passes.)
        if code == 9 && f == .maskCommand && running,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.MobileSMS",
           let plain = Self.plainOfParagraphs() {
            DispatchQueue.main.async {
                note("paste in Messages: plain copy, so the blank lines between paragraphs stay")
                self.paste(plain) {}
            }
            return true
        }
        // taken every time in a watched box, even with nothing to tidy, so a key like Option-` doesn't fall
        // through and start an accent on the next letter
        if Action.tidyUp.shortcut?.matches(e) == true && running && element != nil {
            DispatchQueue.main.async { if self.tidy != nil { self.applyTidy() } }
            return true
        }
        if Action.fixAll.shortcut?.matches(e) == true && running && element != nil {
            DispatchQueue.main.async { self.fixAll() }
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
        let words = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        dictionary = Set(words.map { $0.lowercased() })
        names = words.filter { $0.contains(where: \.isUppercase) }
    }

    /// The file keeps the case each word was saved in, so a name like Sttark stays a name.
    func saveDictionary() {
        var byLower: [String: String] = [:]
        for w in dictionary { byLower[w] = w }
        for n in names { byLower[n.lowercased()] = n }
        try? (byLower.values.sorted { $0.lowercased() < $1.lowercased() }.joined(separator: "\n") + "\n").write(to: dictionaryURL, atomically: true, encoding: .utf8)
    }

    // MARK: menu bar

    static let sIcon: NSImage? = {
        guard let u = Bundle.main.url(forResource: "MenuIcon", withExtension: "pdf"), let i = NSImage(contentsOf: u) else { return nil }
        i.size = NSSize(width: 16.7, height: 15)
        i.isTemplate = true
        i.accessibilityDescription = "character.cursor.ibeam"
        return i
    }()

    func updateStatus() {
        guard let b = statusItem?.button else { return }
        let symbol = speaker.isReading ? "speaker.wave.2.fill" : !AXIsProcessTrusted() || Checker.apiKey == nil ? "exclamationmark.triangle" : !running ? "pause.circle" : lastError != nil ? "exclamationmark.triangle" : "character.cursor.ibeam"
        if b.image?.accessibilityDescription != symbol {
            // the Sttark S when all is well; a symbol that says what's wrong otherwise
            b.image = symbol == "character.cursor.ibeam" ? Self.sIcon ?? NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                : NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
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
        item("Sttark Grammar \(Updater.version)", nil)
        updater.check()
        if updater.installing {
            item("Updating…", nil)
        } else if let r = updater.available {
            item("Update to \(r.version)", #selector(installUpdate)).attributedTitle = NSAttributedString(
                string: "Update to \(r.version)", attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        }
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
        shortcutItem("Fix all", #selector(fixAllMenu), .fixAll)
        shortcutItem("Tidy up", #selector(tidyUpMenu), .tidyUp)
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
        for m in Model.available + (Model.available.contains(model) ? [] : [model]) {
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
        if updater.available == nil && !updater.installing { item("Check for updates", #selector(checkForUpdates)) }
        menu.addItem(.separator())
        item("Quit", #selector(quit), key: "q", mods: .command)
    }

    @objc func installUpdate() { updater.install() }
    @objc func checkForUpdates() {
        updater.check(force: true) { msg in
            let a = NSAlert()
            a.messageText = self.updater.available == nil ? "No update" : "Update ready"
            a.informativeText = msg
            if self.updater.available != nil { a.addButton(withTitle: "Update now"); a.addButton(withTitle: "Later") }
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn && self.updater.available != nil { self.updater.install() }
        }
    }
    @objc func toggleTidy() { tidyOn.toggle(); if !tidyOn { hideCard() }; updateStatus() }
    @objc func toggleOn() { enabled.toggle(); if !enabled { reset() }; updateStatus() }
    @objc func pause() { pausedUntil = Date().addingTimeInterval(3600); reset(); updateStatus() }
    @objc func resume() { pausedUntil = nil; updateStatus() }
    @objc func fixAllMenu() { fixAll() }
    @objc func tidyUpMenu() { applyTidy() }
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
