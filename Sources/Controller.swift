import AppKit
import SwiftUI

let debug = ProcessInfo.processInfo.environment["CG_DEBUG"] != nil
func log(_ s: @autoclosure () -> String) { if debug { FileHandle.standardError.write((s() + "\n").data(using: .utf8)!) } }

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

    static let supportDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeGrammar")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    var dictionaryURL: URL { Self.supportDir.appendingPathComponent("dictionary.txt") }

    func start() {
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
        installKeyTap()
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        updateStatus()
        if Checker.apiKey == nil { DispatchQueue.main.async { self.askForKey() } }
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

        guard let el = AX.focused() else { reset(); updateStatus(); return }
        let pid = AX.pid(el)
        if pid == getpid() { return }                   // mouse is on our card; keep state
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier, skipped.contains(id) { reset(); updateStatus(); return }
        if !axEnabled.contains(pid) { AX.enableAppAccessibility(pid); axEnabled.insert(pid) }

        guard isTextBox(el), let str = AX.string(el, kAXValueAttribute) else { reset(); updateStatus(); return }
        let v = str as NSString
        if element == nil || !CFEqual(element!, el) {
            element = el
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
            lastChange = Date()
        }
        if Date().timeIntervalSince(lastChange) > 1.2 { sendChecks(el) }
        layout(el)
        hover()
        updateStatus()
    }

    func isTextBox(_ el: AXUIElement) -> Bool {
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        let sub = AX.string(el, kAXSubroleAttribute) ?? ""
        if role == "AXSecureTextField" || sub == "AXSecureTextField" || sub == "AXSearchField" { return false }
        return AX.selectedRange(el) != nil
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

    func paragraphs(_ s: NSString) -> [(NSRange, String)] {
        var out: [(NSRange, String)] = []
        s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: [.byParagraphs]) { sub, r, _, _ in
            if let sub { out.append((r, sub)) }
        }
        return out
    }

    func allowed(_ i: Issue) -> Bool {
        !ignored.contains(i.ignoreKey) && !(i.kind == .spelling && dictionary.contains(i.original.lowercased()))
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
        guard inflight.count < 2 else { return }
        let caret = AX.selectedRange(el)?.location ?? 0
        let paras = paragraphs(value).sorted { abs($0.0.location - caret) < abs($1.0.location - caret) }
        for (_, text) in paras {
            guard inflight.count < 2 else { break }
            let words = text.split(whereSeparator: { $0.isWhitespace }).count
            guard cache[text] == nil, !inflight.contains(text), words >= 3, text.utf16.count <= 4000 else { continue }
            if let f = failedAt[text], Date().timeIntervalSince(f) < 30 { continue }
            inflight.insert(text)
            log("check \(text.prefix(60))")
            let m = model
            Task {
                do {
                    let res = try await Checker.check(text, model: m)
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

    /// Typos Claude can't guess a fix for (like "somnerhqw") come back unchanged, so the Mac spell checker
    /// also looks at every word Claude left alone. Capitalized words mid-sentence are skipped as likely names.
    func spellIssues(_ text: String, besides claude: [Issue]) -> [Issue] {
        let sc = NSSpellChecker.shared
        let ns = text as NSString
        var out: [Issue] = []
        var start = 0
        while start < ns.length {
            let r = sc.checkSpelling(of: text, startingAt: start, language: nil, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard r.location != NSNotFound, r.length > 0, r.location >= start else { break }
            start = r.upperBound
            let word = ns.substring(with: r)
            if claude.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { continue }
            if word.contains(where: \.isNumber) { continue }
            if r.location > 0, word.first?.isUppercase == true { continue }
            if let guess = sc.guesses(forWordRange: r, in: text, language: nil, inSpellDocumentWithTag: 0)?.first {
                out.append(Issue(range: r, original: word, suggestion: guess, kind: .spelling, reason: "Not a word. Closest match: \(guess)."))
            } else {
                out.append(Issue(range: r, original: word, suggestion: word, kind: .spelling, reason: "Not a word, and nothing close to it."))
            }
        }
        return out
    }

    func received(_ text: String, _ claude: CheckResult, model: Model) {
        let res = CheckResult(issues: (claude.issues + spellIssues(text, besides: claude.issues)).sorted { $0.range.location < $1.range.location },
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
        placeBadge(frame)
    }

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

    func placeBadge(_ frame: CGRect) {
        let checking = paragraphs(value).contains { inflight.contains($0.1) }
        guard !issues.isEmpty || checking else { badge.orderOut(nil); return }
        let state = "\(issues.count) \(checking)"
        if state != badgeState || badge.contentView == nil {
            badgeState = state
            badge.contentView = ClickThroughHostingView(rootView: BadgeView(count: issues.count, checking: checking) { [weak self] in self?.fixAll() })
        }
        let size = badge.contentView!.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame ?? frame
        let area = frame.intersection(screen).isNull ? frame : frame.intersection(screen)
        var origin = CGPoint(x: area.maxX - size.width - 4, y: area.minY + 4)
        if area.height < 44 { origin.y = area.midY - size.height / 2 }
        let f = CGRect(origin: origin, size: size)
        if badge.frame != f { badge.setFrame(f, display: true) }
        if !badge.isVisible { badge.orderFrontRegardless() }
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
        case "tab": if let id = hoverID { accept(id) }
        case "esc": if let id = hoverID { ignore(id) }
        case "fixall": fixAll()
        case "dump":
            log("value: \(value)")
            for i in issues { log("  \(i.range) \(i.kind) \(i.original) -> \(i.suggestion) rects=\(rects[i.id] ?? [])") }
            log("card \(card.isVisible ? "\(card.frame)" : "hidden") badge \(badge.isVisible ? "\(badge.frame)" : "hidden")")
        default: break
        }
    }

    func hover() {
        debugCommand()
        let m = fakeMouse ?? NSEvent.mouseLocation
        if card.isVisible && card.frame.insetBy(dx: -4, dy: -4).contains(m) { lastInside = Date(); return }
        if let i = issues.first(where: { rects[$0.id]?.contains { $0.insetBy(dx: -1, dy: -4).contains(m) } ?? false }) {
            lastInside = Date()
            if hoverID != i.id { showCard(i) }
            return
        }
        if hoverID != nil && Date().timeIntervalSince(lastInside) > 0.3 { hideCard() }
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
        hideCard()
        replace(issues)
    }

    func fixParagraph() {
        guard let el = element else { return }
        let caret = AX.selectedRange(el)?.location ?? 0
        guard let (r, _) = paragraphs(value).first(where: { caret >= $0.0.location && caret <= $0.0.upperBound }) else { return }
        replace(issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound })
    }

    /// Apply fixes from last to first so earlier positions stay valid.
    func replace(_ all: [Issue]) {
        let list = all.filter(\.hasFix)
        guard let el = element, !list.isEmpty, !editing else { return }
        editing = true
        let before = value
        let caret = AX.selectedRange(el)
        var todo = list.sorted { $0.range.location > $1.range.location }

        func finish() {
            let after = (AX.string(el, kAXValueAttribute) ?? before as String) as NSString
            shift(old: before, new: after)
            let removed = Set(list.map(\.id))
            issues.removeAll { removed.contains($0.id) }
            value = after
            // remember what is left so the edited paragraph is not sent again
            let old = Set(paragraphs(before).map(\.1))
            for (r, t) in paragraphs(after) where cache[t] == nil && !old.contains(t) {
                cache[t] = issues.filter { $0.range.location >= r.location && $0.range.location < r.upperBound }
                    .map { $0.shifted(by: -r.location) }
            }
            if let c = caret {
                let delta = after.length - before.length
                let loc = c.location >= (list.map(\.range.upperBound).max() ?? 0) ? c.location + delta : min(c.location, after.length)
                AX.setSelectedRange(el, NSRange(location: max(0, loc), length: 0))
            }
            lastChange = Date()
            editing = false
            updateStatus()
        }

        func next() {
            guard let i = todo.first else { finish(); return }
            todo.removeFirst()
            replaceOne(el, i) { _ in next() }
        }
        next()
    }

    /// Try the Accessibility API first; apps that ignore it get the fix pasted over a selection.
    func replaceOne(_ el: AXUIElement, _ i: Issue, done: @escaping (Bool) -> Void) {
        guard let cur = AX.string(el, kAXValueAttribute) as NSString?,
              i.range.upperBound <= cur.length, cur.substring(with: i.range) == i.original else { done(false); return }
        let expected = cur.replacingCharacters(in: i.range, with: i.suggestion)
        AX.setSelectedRange(el, i.range)
        let ok = AX.setSelectedText(el, i.suggestion)
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 0.03 : 0)) {
            let now = AX.string(el, kAXValueAttribute) ?? ""
            if now == expected { done(true); return }
            guard now == cur as String else { done(false); return }
            AX.setSelectedRange(el, i.range)
            guard AX.selectedRange(el) == i.range else {
                log("could not select '\(i.original)' in \(self.appName); not pasting")
                done(false); return
            }
            self.paste(i.suggestion) {
                done((AX.string(el, kAXValueAttribute) ?? "") == expected)
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
            then()
        }
    }

    // MARK: keys: Tab takes the fix, Esc ignores it (only while a card is open), Control-Option-F fixes the paragraph

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
        if code == 3 && f == [.maskControl, .maskAlternate] && running && element != nil {
            DispatchQueue.main.async { self.fixParagraph() }
            return true
        }
        if code == 53 && f.isEmpty && translator.visible { DispatchQueue.main.async { self.translator.close() }; return true }
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
        let symbol = !AXIsProcessTrusted() || Checker.apiKey == nil ? "exclamationmark.triangle" : !running ? "pause.circle" : lastError != nil ? "exclamationmark.triangle" : "character.cursor.ibeam"
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
        item("Fix this paragraph", #selector(fixParagraphMenu), key: "f", mods: [.control, .option])
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
        menu.addItem(.separator())
        item("Quit", #selector(quit), key: "q", mods: .command)
    }

    @objc func toggleOn() { enabled.toggle(); if !enabled { reset() }; updateStatus() }
    @objc func pause() { pausedUntil = Date().addingTimeInterval(3600); reset(); updateStatus() }
    @objc func resume() { pausedUntil = nil; updateStatus() }
    @objc func fixParagraphMenu() { fixParagraph() }
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
