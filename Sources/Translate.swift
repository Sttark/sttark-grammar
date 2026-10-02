import AppKit
import SwiftUI

/// "Translate to Chinese with Claude" in the right-click menu (a macOS Service, declared in Info.plist).
/// Shows the translation next to the mouse with an English back-translation to check it,
/// and puts the translation on the clipboard. Chinese text gets translated to English instead.
final class Translator: NSObject {
    let panel = makePanel(mouse: true)
    var original = ""
    var result = ""
    var anchor = CGPoint.zero
    var clickMonitor: Any?
    var busy = false
    var visible: Bool { panel.isVisible }

    static let system = """
    Translate the user's text into Simplified Chinese, the way a native speaker would write it in a business message. Keep names, model numbers, file types and numbers as they are. Keep line breaks.
    Then translate your Chinese back into English, staying close to its meaning, so the user can check it.
    If the text is already mostly Chinese, translate it into natural English instead: put the original text in "chinese" and your translation in "english".
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["chinese", "english"],
        "properties": ["chinese": ["type": "string"], "english": ["type": "string"]],
    ]

    static func isMostlyChinese(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let han = letters.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
        return !letters.isEmpty && Double(han.count) / Double(letters.count) > 0.3
    }

    // MARK: the two ways in

    /// Right-click > Translate to Chinese with Claude (a macOS Service).
    @objc(translateToChinese:userData:error:)
    func translateToChinese(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        run(text, editable: selectionIs(text), anchor: NSEvent.mouseLocation)
    }

    /// Menu bar > Translate selection to Chinese. Works in apps without the right-click item, like the Claude app.
    func translateSelection(anchor: CGPoint) {
        if let el = AX.focused(), AX.pid(el) != getpid(),
           let sel = AX.string(el, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty {
            run(sel, editable: isEditable(el), anchor: anchor)
            return
        }
        // the app won't say what's selected: copy it
        let pb = NSPasteboard.general
        let count = pb.changeCount
        postKey(8, .maskCommand)                                   // Command-C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard pb.changeCount != count, let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                self.anchor = anchor
                self.show(.failed(title: "Nothing selected", "Select some text, then choose Translate again."))
                return
            }
            self.run(text, editable: false, anchor: anchor)
        }
    }

    func isEditable(_ el: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        let role = AX.string(el, kAXRoleAttribute) ?? ""
        return settable.boolValue || ["AXTextArea", "AXTextField", "AXComboBox"].contains(role)
    }

    /// The text is still selected in a box you can type in.
    func selectionIs(_ text: String) -> Bool {
        guard let el = AX.focused(), AX.pid(el) != getpid(), isEditable(el) else { return false }
        return AX.string(el, kAXSelectedTextAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) == text
    }

    /// Translate, copy the result, and swap it in for the selection when the selection can be edited.
    func run(_ text: String, editable: Bool, anchor: CGPoint) {
        original = text
        self.anchor = anchor
        busy = true
        show(.working)
        Task {
            do {
                let (zh, en) = try await Self.translate(String(text.prefix(20000)))
                await MainActor.run {
                    self.busy = false
                    let toEnglish = Self.isMostlyChinese(text)
                    self.result = toEnglish ? en : zh
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.result, forType: .string)
                    let check = toEnglish ? nil : en
                    guard editable, self.selectionIs(text) else {
                        self.show(.done(main: self.result, check: check, toEnglish: toEnglish, replaced: false))
                        return
                    }
                    self.replaceSelection { ok in
                        self.show(.done(main: self.result, check: check, toEnglish: toEnglish, replaced: ok))
                        if ok { self.closeSoon() }
                    }
                }
            } catch {
                await MainActor.run { self.busy = false; self.show(.failed(title: "Translation failed", "\(error)")) }
            }
        }
    }

    static func translate(_ text: String) async throws -> (String, String) {
        guard let key = Checker.apiKey else { throw CheckError.noKey }
        let body: [String: Any] = [
            "model": "claude-opus-5",
            "max_tokens": 16000,
            "system": system,
            "messages": [["role": "user", "content": text]],
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": schema]],
            "fallbacks": "default",
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            throw CheckError.http(status, String(msg.prefix(200)))
        }
        guard json["stop_reason"] as? String == "end_turn",
              let blocks = json["content"] as? [[String: Any]],
              let txt = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let reply = (try? JSONSerialization.jsonObject(with: Data(txt.utf8))) as? [String: Any],
              let zh = reply["chinese"] as? String, let en = reply["english"] as? String else {
            throw CheckError.badReply("stop_reason \(json["stop_reason"] ?? "none")")
        }
        return (zh, en)
    }

    // MARK: replace the selected text in place

    func postKey(_ code: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    func replaceSelection(done: @escaping (Bool) -> Void) {
        guard let el = AX.focused() else { done(false); return }
        let before = AX.string(el, kAXValueAttribute)
        let ok = AX.setSelectedText(el, result)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if ok && AX.string(el, kAXValueAttribute) != before { done(true); return }
            // the app ignored the Accessibility API; the original is still selected and the result is on the clipboard
            guard self.selectionIs(self.original) else { done(false); return }
            self.postKey(9, .maskCommand)                          // Command-V
            done(true)
        }
    }

    func closeSoon() {
        let shown = panel.contentView
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.panel.contentView === shown, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.close()
        }
    }

    // MARK: card

    enum State {
        case working
        case done(main: String, check: String?, toEnglish: Bool, replaced: Bool)
        case failed(title: String, String)
    }

    func show(_ state: State) {
        let view = TranslateCard(state: state, close: { [weak self] in self?.close() })
        let host = ClickThroughHostingView(rootView: view)
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) }?.visibleFrame ?? NSScreen.main!.visibleFrame
        var origin = CGPoint(x: anchor.x + 8, y: anchor.y - 12 - size.height)
        if origin.y < screen.minY { origin.y = min(anchor.y + 12, screen.maxY - size.height) }
        origin.x = min(max(origin.x, screen.minX + 6), screen.maxX - size.width - 6)
        panel.contentView = host
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self, !self.busy, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
    }

    func close() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}

struct TranslateCard: View {
    let state: Translator.State
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch state {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating with Claude…").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .padding(14)
            case .failed(let title, let msg):
                Text(title).font(.system(size: 13, weight: .semibold)).padding([.horizontal, .top], 14)
                Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)
                footer
            case .done(let main, let check, let toEnglish, let replaced):
                HStack {
                    Text(replaced ? (toEnglish ? "REPLACED WITH ENGLISH" : "REPLACED WITH CHINESE") : (toEnglish ? "ENGLISH" : "CHINESE"))
                        .font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                    Spacer()
                    Text(replaced ? "Also copied" : "Copied").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).padding(.top, 12)
                ScrollView {
                    Text(main).font(.system(size: 15)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: 260).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 6)
                if let check {
                    Text("Back in English, to check it:").font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 14).padding(.top, 10)
                    ScrollView {
                        Text(check).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxHeight: 160).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 2)
                }
                Spacer().frame(height: 12)
                footer
            }
        }
        .frame(width: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 2) {
                Spacer()
                FootButton(title: "Close", key: "Esc", action: close)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
    }
}
