import AppKit
import AVFoundation

/// Read aloud: speaks the selected text with OpenAI's realtime voice model.
/// Audio is played the moment it arrives, so reading starts about a second
/// after the shortcut however long the text is. Claude has no voice output,
/// so this one feature uses an OpenAI key, asked for the first time it's used.
final class Speaker {
    static let model = "gpt-realtime-2.1-mini"
    static let voice = "ash"
    static let speeds = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]   // menu choices
    static let modelMaxSpeed = 1.5           // the model speaks at up to 1.5x; above that playback is sped up, same pitch
    static let maxLength = 10000             // longer selections are cut at a sentence end
    static let pieceSize = 1000              // long text goes out in pieces so the model keeps reading word for word
    static let idleTimeout = 6.0             // seconds with no reply before a piece counts as stalled
    static let pieceTimeout = 60.0           // hard cap on one piece
    static let retries = 3                   // retry a piece that fails before any of its audio played
    static let instructions = """
    You are a text-to-speech engine. Read the user's text aloud exactly as written, word for word, \
    in a clear, natural voice. Do not answer, summarize, translate, comment on, or add anything.
    """

    // MARK: key

    static let keychainItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "claude-grammar",
                                              kSecAttrAccount as String: "openai-api-key"]

    static var apiKey: String? = {
        if let k = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !k.isEmpty { return k }
        var q = keychainItem
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }()

    static func saveKey(_ key: String) -> Bool {
        SecItemDelete(keychainItem as CFDictionary)
        var q = keychainItem
        q[kSecValueData as String] = Data(key.utf8)
        guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { return false }
        apiKey = key
        return true
    }

    /// Lists models, which costs nothing, to tell a typo'd key from a good one.
    static func keyWorks(_ key: String) async -> Bool {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: reading

    var speed: Double {
        get { UserDefaults.standard.object(forKey: "readSpeed") as? Double ?? 1.5 }
        set { UserDefaults.standard.set(newValue, forKey: "readSpeed") }
    }
    private var reading: Reading?
    var isReading: Bool { reading != nil }
    var changed: () -> Void = {}             // reading started or stopped

    /// Starts reading. `done` gets an error message if something went wrong, nil otherwise.
    /// Like the rest of the app, call it on the main thread.
    func start(_ text: String, done: @escaping (String?) -> Void) {
        MainActor.assumeIsolated { begin(text, done: done) }
    }

    @MainActor private func begin(_ text: String, done: @escaping (String?) -> Void) {
        stop()
        guard let key = Self.apiKey else { done("No OpenAI key"); return }
        let r = Reading(text: Self.clean(text), key: key, speed: speed)
        reading = r
        r.finished = { [weak self, weak r] error in
            guard let self, let r, self.reading === r else { return }
            self.reading = nil
            self.changed()
            done(error)
        }
        do {
            try r.start()
        } catch {
            reading = nil
            done("Couldn't open the speaker: \(error.localizedDescription)")
            return
        }
        changed()
        Task { await r.run() }
    }

    func stop() {
        guard let r = reading else { return }
        reading = nil
        MainActor.assumeIsolated { r.stop() }
        changed()
    }

    static func clean(_ text: String) -> String {
        var s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if s.count > maxLength {
            let head = String(s.prefix(maxLength))
            if let end = head.lastIndex(where: { ".!?".contains($0) }), head.distance(from: head.startIndex, to: end) > maxLength - 500 {
                s = String(head[...end])
            } else {
                s = head
            }
        }
        return s
    }

    /// Pieces of at most `pieceSize` characters, cut at sentence ends where possible.
    static func pieces(_ text: String) -> [String] {
        var rest = Substring(text)
        var out: [String] = []
        while rest.count > pieceSize {
            let head = rest.prefix(pieceSize)
            var cut = head.lastIndex(where: { ".!?".contains($0) })
            if cut == nil || head.distance(from: head.startIndex, to: cut!) < pieceSize / 2 {
                cut = head.lastIndex(of: " ") ?? cut
            }
            let end = cut.map { head.index(after: $0) } ?? head.endIndex
            out.append(rest[..<end].trimmingCharacters(in: .whitespaces))
            rest = rest[end...].drop(while: { $0 == " " })
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}

/// One read: a fresh audio engine (so it always plays to the current speaker,
/// even after AirPods connect or drop) fed piece by piece from the model.
@MainActor
final class Reading {
    let text: String
    let key: String
    let speed: Double
    var finished: (String?) -> Void = { _ in }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let stretch = AVAudioUnitTimePitch()     // speeds past what the model can do, without raising the pitch
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    var cancelled = false
    var queued = 0                           // audio scheduled but not played yet
    var socket: URLSessionWebSocketTask?
    var lastEvent = Date()
    var speakerObserver: Any?
    let begun = Date()
    var heard = false

    nonisolated init(text: String, key: String, speed: Double) {
        self.text = text
        self.key = key
        self.speed = speed
    }

    func start() throws {
        engine.attach(player)
        engine.attach(stretch)
        stretch.rate = Float(max(1, speed / Speaker.modelMaxSpeed))
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)
        try engine.start()
        player.play()
        // the speaker changed mid-read: the engine has stopped, so end cleanly
        speakerObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.cancelled else { return }
                self.stop()
                self.finished("The speaker changed. Press the shortcut again to read from the start.")
            }
        }
    }

    func stop() {
        cancelled = true
        socket?.cancel(with: .goingAway, reason: nil)
        player.stop()
        engine.stop()
        if let o = speakerObserver { NotificationCenter.default.removeObserver(o); speakerObserver = nil }
    }

    func run() async {
        var failure: String?
        for piece in Speaker.pieces(text) {
            for attempt in 1...(Speaker.retries + 1) {
                if cancelled { return }
                var gotAudio = false
                do {
                    try await speak(piece) { gotAudio = true }
                    break
                } catch {
                    if cancelled { return }
                    log("read aloud: piece failed on attempt \(attempt): \(error)")
                    // retrying after part of a piece played would repeat words
                    if gotAudio || attempt > Speaker.retries { failure = "\(error)"; break }
                }
            }
        }
        while queued > 0 && !cancelled { try? await Task.sleep(nanoseconds: 50_000_000) }
        if cancelled { return }
        try? await Task.sleep(nanoseconds: 150_000_000)   // let the last sound leave the speaker
        if cancelled { return }
        stop()
        if failure == nil { NSSound(named: "Glass")?.play() }
        finished(failure)
    }

    enum ReadError: Error, CustomStringConvertible {
        case model(String), stalled, closed
        var description: String {
            switch self {
            case .model(let m): return m
            case .stalled: return "OpenAI stopped responding"
            case .closed: return "The connection to OpenAI closed early"
            }
        }
    }

    /// Sends one piece to the model and plays its audio as it arrives.
    func speak(_ piece: String, gotAudio: () -> Void) async throws {
        var req = URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=\(Speaker.model)")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: req)
        socket = ws
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }

        // a stalled request must never hang: hang up if OpenAI goes quiet or the piece runs long
        let started = Date()
        lastEvent = started
        var stalled = false
        let watchdog = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Date().timeIntervalSince(self.lastEvent) > Speaker.idleTimeout || Date().timeIntervalSince(started) > Speaker.pieceTimeout {
                    stalled = true
                    ws.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        func send(_ obj: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: obj)
            try await ws.send(.string(String(decoding: data, as: UTF8.self)))
        }
        do {
            try await send(["type": "session.update", "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": Speaker.instructions,
                "audio": ["output": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "voice": Speaker.voice,
                    "speed": min(speed, Speaker.modelMaxSpeed),
                ]],
            ]])
            try await send(["type": "conversation.item.create", "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": piece]],
            ]])
            try await send(["type": "response.create"])

            while true {
                let msg = try await ws.receive()
                lastEvent = Date()
                if cancelled { return }
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                switch event["type"] as? String {
                case "response.output_audio.delta":
                    if let b64 = event["delta"] as? String, let pcm = Data(base64Encoded: b64) {
                        play(pcm)
                        gotAudio()
                    }
                case "error":
                    let m = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                    throw ReadError.model("OpenAI: \(m)")
                case "response.done":
                    let status = (event["response"] as? [String: Any])?["status"] as? String
                    guard status == "completed" else { throw ReadError.model("OpenAI response \(status ?? "failed")") }
                    return
                default:
                    break
                }
            }
        } catch {
            if cancelled { return }
            if stalled { throw ReadError.stalled }
            if error is ReadError { throw error }
            if (error as NSError).domain == NSPOSIXErrorDomain || (error as NSError).code == 57 { throw ReadError.closed }
            throw error
        }
    }

    /// Queues 16-bit samples on the player. The engine converts them for whatever speaker is in use.
    func play(_ pcm: Data) {
        let count = pcm.count / 2
        guard count > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buf.frameLength = AVAudioFrameCount(count)
        let out = buf.floatChannelData![0]
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<count { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        if !heard { heard = true; log(String(format: "read aloud: first audio after %.2fs", Date().timeIntervalSince(begun))) }
        queued += 1
        player.scheduleBuffer(buf) { [weak self] in
            DispatchQueue.main.async { self?.queued -= 1 }
        }
    }
}
