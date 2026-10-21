import AppKit

final class MockAnthropic: URLProtocol {
    static var responseText = "Write an email explaining that the website launch moves from May 1 to May 8 because the payment integration needs more testing."
    static var purpose: PromptRewriter.Purpose = .prompt
    static var status = 200
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        assert(request.value(forHTTPHeaderField: "x-api-key") != nil)
        var requestData = request.httpBody ?? Data()
        if requestData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                requestData.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        let body = try! JSONSerialization.jsonObject(with: requestData) as! [String: Any]
        assert((body["system"] as? String) == Self.purpose.system)
        assert((body["output_config"] as? [String: Any])?["format"] != nil)
        let text = try! JSONSerialization.data(withJSONObject: [Self.purpose.responseKey: Self.responseText])
        let data = try! JSONSerialization.data(withJSONObject: ["stop_reason": "end_turn", "content": [["type": "text", "text": String(data: text, encoding: .utf8)!]], "usage": ["input_tokens": 120, "output_tokens": 40]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
setenv("ANTHROPIC_API_KEY", "local-test-placeholder", 1)
URLProtocol.registerClass(MockAnthropic.self)
let rewriter = PromptRewriter()
let originalShortcut = UserDefaults.standard.object(forKey: "shortcut-rewritePrompt")
defer {
    if let originalShortcut { UserDefaults.standard.set(originalShortcut, forKey: "shortcut-rewritePrompt") }
    else { UserDefaults.standard.removeObject(forKey: "shortcut-rewritePrompt") }
}
UserDefaults.standard.removeObject(forKey: "shortcut-rewritePrompt")
assert(Action.rewritePrompt.shortcut?.display == "⌘4")
let key = CGEvent(keyboardEventSource: nil, virtualKey: 21, keyDown: true)!
key.flags = .maskCommand
assert(Action.rewritePrompt.shortcut!.matches(key))
Action.rewritePrompt.shortcut = nil
assert(Action.rewritePrompt.shortcut == nil)
let custom = Shortcut(code: 20, mods: CGEventFlags.maskControl.rawValue, key: "3")
Action.rewritePrompt.shortcut = custom
assert(Action.rewritePrompt.shortcut == custom)
print("PASS default Command-4, event matching, disable, custom shortcut persistence")
var finished = false
var usageRecorded = false
rewriter.used = { input, output, _ in
    assert(input == 120 && output == 40)
    usageRecorded = true
}
rewriter.run("write an email about our website delay", selection: nil, model: .haiku)
let timeout = Date().addingTimeInterval(5)
while !usageRecorded && Date() < timeout { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(usageRecorded && rewriter.visible)
print("PASS Anthropic request, structured response, usage, noneditable result card")
rewriter.close()
assert(!rewriter.visible)
MockAnthropic.responseText = ""
rewriter.run("hello", selection: nil, model: .haiku)
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
assert(rewriter.visible)
rewriter.close()
let requestCount = MockAnthropic.requests
rewriter.run(String(repeating: "a", count: 20001), selection: nil, model: .haiku)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
assert(MockAnthropic.requests == requestCount)
rewriter.close()
MockAnthropic.responseText = "Write an email."
usageRecorded = false
rewriter.run("email", selection: nil, model: .haiku)
rewriter.close()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
assert(!rewriter.visible && !usageRecorded)
print("PASS empty response error, oversized selection rejection, cancellation prevents stale UI")

let communication = PromptRewriter(purpose: .communication)
assert(Action.clarifyMessage.defaultShortcut?.display == "⌘3")
let zero = CGEvent(keyboardEventSource: nil, virtualKey: 20, keyDown: true)!
zero.flags = .maskCommand
assert(Action.clarifyMessage.defaultShortcut!.matches(zero))
assert(PromptRewriter.Purpose.communication.responseKey == "message")
MockAnthropic.purpose = .communication
MockAnthropic.responseText = "Hi Sam, please confirm the quantities: 500 blue labels and 250 green labels."
var humanUsage = false
communication.used = { _, _, _ in humanUsage = true }
communication.run("sam check 500 blue 250 green", selection: nil, model: .haiku)
let humanDeadline = Date().addingTimeInterval(5)
while !humanUsage && Date() < humanDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(humanUsage)
if communication.presentation == "result" {
    print("FAIL: Command-3 opens a full suggestion window when Accessibility cannot resolve the selection")
    exit(1)
}
communication.close()
assert(Action.rewritePrompt.defaultShortcut?.display == "⌘4")
print("PASS Command-3, human message request/response routing, usage, Command-4 preserved")

let clipboardEditor = PromptRewriter(purpose: .communication)
let originalText = "rough draft for a colleague"
let targetPID: pid_t = 77777
let selection = PromptRewriter.Selection(element: nil, text: originalText, range: nil, value: nil, processID: targetPID)
var pasteCount = 0
var copiedText: String? = originalText
var activePID: pid_t? = targetPID
clipboardEditor.access = .init(currentPID: { activePID }, copy: { done in done(copiedText) }, paste: { text, _, done in
    assert(text == MockAnthropic.responseText)
    pasteCount += 1
    copiedText = nil // successful paste collapses the selected text
    done(true)
})
func waitForRewrite(_ editor: PromptRewriter) {
    let deadline = Date().addingTimeInterval(5)
    while editor.presentation == "working" && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    assert(editor.presentation != "working")
}
clipboardEditor.run(originalText, selection: selection, model: .haiku)
waitForRewrite(clipboardEditor)
assert(pasteCount == 1 && clipboardEditor.presentation == "notice")
assert(clipboardEditor.panel.frame.height < 80)
assert((clipboardEditor.panel.contentView as? ClickThroughHostingView<PromptNotice>)?.rootView.canUndo == true)
clipboardEditor.close()
copiedText = "different user selection"
clipboardEditor.run(originalText, selection: selection, model: .haiku)
waitForRewrite(clipboardEditor)
assert(pasteCount == 1 && clipboardEditor.presentation == "notice", "Changed selection must not be pasted over")
clipboardEditor.close()
copiedText = originalText
activePID = 88888
clipboardEditor.run(originalText, selection: selection, model: .haiku)
waitForRewrite(clipboardEditor)
assert(pasteCount == 1, "Switching apps must not paste into another app")
assert(clipboardEditor.presentation == "notice")
clipboardEditor.close()
print("PASS clipboard-only editor replaces directly; changed selection/app never pasted; no Command-3 result window")

activePID = targetPID
copiedText = originalText
clipboardEditor.access.paste = { _, _, done in pasteCount += 1; done(true) } // read-only selection ignores paste
clipboardEditor.run(originalText, selection: selection, model: .haiku)
waitForRewrite(clipboardEditor)
assert(clipboardEditor.presentation == "notice")
assert((clipboardEditor.panel.contentView as? ClickThroughHostingView<PromptNotice>)?.rootView.canUndo == false)
assert(NSPasteboard.general.string(forType: .string) == MockAnthropic.responseText)
clipboardEditor.close()
print("PASS read-only selection copies result with compact notice and no misleading Undo")
