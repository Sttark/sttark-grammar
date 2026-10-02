import AppKit
import Security

enum Kind: String {
    case spelling, grammar, capitals

    var label: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .capitals: return "Capitals"
        }
    }

    var color: NSColor {
        switch self {
        case .spelling: return NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        case .grammar: return NSColor(srgbRed: 0.94, green: 0.63, blue: 0.13, alpha: 1)
        case .capitals: return NSColor(srgbRed: 0.24, green: 0.48, blue: 0.98, alpha: 1)
        }
    }
}

struct Issue {
    var id = UUID()
    var range: NSRange          // UTF-16 range, same units the Accessibility API uses
    let original: String
    let suggestion: String
    let kind: Kind
    let reason: String

    var ignoreKey: String { original + "\u{1}" + suggestion }
    var hasFix: Bool { original != suggestion }

    func shifted(by d: Int) -> Issue {
        var c = self
        c.id = UUID()
        c.range.location += d
        return c
    }
}

enum Model: String, CaseIterable {
    case haiku = "claude-haiku-4-5"
    case sonnet = "claude-sonnet-5"

    var label: String { self == .sonnet ? "Sonnet 5 (slower, twice the cost)" : "Haiku 4.5 (fast)" }
    // dollars per million tokens, input and output
    var price: (Double, Double) { self == .sonnet ? (2, 10) : (1, 5) }
}

struct CheckResult {
    let issues: [Issue]         // ranges relative to the start of the paragraph
    let inputTokens: Int
    let outputTokens: Int
}

enum CheckError: Error, CustomStringConvertible {
    case noKey, http(Int, String), badReply(String)
    var description: String {
        switch self {
        case .noKey: return "No API key in Keychain"
        case .http(let code, let msg): return "API error \(code): \(msg)"
        case .badReply(let msg): return "Bad reply: \(msg)"
        }
    }
}

enum Checker {
    static let system = """
    You proofread text the user is typing in another app.
    First write "corrected": the full text with only clear mistakes fixed. Fix misspellings, wrong grammar, wrong word forms, missing hyphens, and words that need a capital letter (names, brands, products, the word I, sentence starts). Keep the user's words, tone and casual style. Do not reword, shorten, or improve style. If the last sentence is complete but has no period, question mark or exclamation point at the end, add one. If it is still being typed, leave the end alone. Keep punctuation that is already correct. Keep all spacing and line breaks.
    Then list every change you made in "issues", in the order they appear. For each: "original" is the exact wrong text copied character for character from the input, as short as possible (only the wrong word or words). "suggestion" is what replaces it. "kind" is spelling, grammar, or capitals. "reason" is at most 12 plain words. If the same mistake appears more than once, list each one. If nothing is wrong, return the text unchanged and an empty list.
    The text may be unfinished: ignore a cut-off last word.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["corrected", "issues"],
        "properties": [
            "corrected": ["type": "string"],
            "issues": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "required": ["original", "suggestion", "kind", "reason"],
                "properties": [
                    "original": ["type": "string"],
                    "suggestion": ["type": "string"],
                    "kind": ["type": "string", "enum": ["spelling", "grammar", "capitals"]],
                    "reason": ["type": "string"],
                ],
            ]],
        ],
    ]

    static let keychainItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                              kSecAttrService as String: "claude-grammar",
                                              kSecAttrAccount as String: "anthropic-api-key"]

    static var apiKey: String? = {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty { return k }
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
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    static func check(_ text: String, model: Model) async throws -> CheckResult {
        guard let key = apiKey else { throw CheckError.noKey }
        var outputConfig: [String: Any] = ["format": ["type": "json_schema", "schema": schema]]
        var body: [String: Any] = [
            "model": model.rawValue,
            "max_tokens": 8000,
            "system": system,
            "messages": [["role": "user", "content": "<text>\n\(text)\n</text>"]],
        ]
        if model == .sonnet {
            outputConfig["effort"] = "low"
            body["thinking"] = ["type": "disabled"]
        }
        body["output_config"] = outputConfig

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
              let corrected = reply["corrected"] as? String else {
            throw CheckError.badReply("stop_reason \(json["stop_reason"] ?? "none")")
        }
        let notes = (reply["issues"] as? [[String: Any]] ?? []).compactMap { d -> (String, String, Kind, String)? in
            guard let o = d["original"] as? String, let s = d["suggestion"] as? String,
                  let k = Kind(rawValue: d["kind"] as? String ?? ""), let r = d["reason"] as? String else { return nil }
            return (o, s, k, r)
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return CheckResult(issues: Diff.issues(original: text, corrected: corrected, notes: notes),
                           inputTokens: usage["input_tokens"] as? Int ?? 0,
                           outputTokens: usage["output_tokens"] as? Int ?? 0)
    }
}

/// Positions come from comparing the text with Claude's corrected copy word by word,
/// so underlines land on exactly the right characters. Claude's own list supplies the reasons.
enum Diff {
    struct Token { let range: NSRange; let text: String; let isWord: Bool }

    static func isWordChar(_ c: unichar) -> Bool {
        if c == 0x27 || c == 0x2019 { return true }                     // ' and ’
        if UTF16.isLeadSurrogate(c) || UTF16.isTrailSurrogate(c) { return true }
        guard let s = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(s)
    }

    static func tokenize(_ str: String) -> [Token] {
        let ns = str as NSString
        var out: [Token] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            var j = i + 1
            let word = isWordChar(c)
            let space = !word && CharacterSet.whitespaces.contains(Unicode.Scalar(c) ?? " ")
            if word { while j < ns.length && isWordChar(ns.character(at: j)) { j += 1 } }
            else if space {
                while j < ns.length, let s = Unicode.Scalar(ns.character(at: j)), CharacterSet.whitespaces.contains(s) { j += 1 }
            }
            let r = NSRange(location: i, length: j - i)
            out.append(Token(range: r, text: ns.substring(with: r), isWord: word))
            i = j
        }
        return out
    }

    static func issues(original: String, corrected: String, notes: [(String, String, Kind, String)]) -> [Issue] {
        // Claude sometimes ends its copy with a space or line break the text doesn't have, even when it
        // adds a period. Give the copy the text's own spacing at both ends so "outside." -> "outside. " never shows.
        func edge(_ x: String, _ fromEnd: Bool) -> String {
            String(fromEnd ? x.reversed().prefix { $0.isWhitespace }.reversed() : Array(x.prefix { $0.isWhitespace }))
        }
        let core = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = core.isEmpty ? corrected : edge(original, false) + core + edge(original, true)
        let a = tokenize(original), b = tokenize(corrected)
        let n = a.count, m = b.count
        guard n > 0, n <= 2000, m <= 2400 else { return [] }

        // longest common subsequence over tokens
        var dp = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i].text == b[j].text ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // walk it into hunks of changed tokens: (aStart, aEnd, bStart, bEnd)
        var hunks: [(Int, Int, Int, Int)] = []
        var i = 0, j = 0
        var open: (Int, Int)? = nil
        while i < n || j < m {
            if i < n && j < m && a[i].text == b[j].text {
                if let o = open { hunks.append((o.0, i, o.1, j)); open = nil }
                i += 1; j += 1
            } else {
                if open == nil { open = (i, j) }
                if j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j]) { j += 1 } else { i += 1 }
            }
        }
        if let o = open { hunks.append((o.0, n, o.1, m)) }
        // "mac os" -> "macOS" comes out as two changes split by a space; join changes that only spaces separate
        var merged: [(Int, Int, Int, Int)] = []
        for h in hunks {
            let oneSided = { (x: (Int, Int, Int, Int)) in x.0 == x.1 || x.2 == x.3 }
            if let last = merged.last, h.0 > last.1, oneSided(h) || oneSided(last),
               a[last.1..<h.0].allSatisfy({ !$0.isWord && $0.text.allSatisfy(\.isWhitespace) }) {
                merged[merged.count - 1] = (last.0, h.1, last.2, h.3)
            } else {
                merged.append(h)
            }
        }
        hunks = merged

        // Claude rewrote the paragraph instead of proofreading it: show nothing.
        let changed = hunks.reduce(0) { $0 + ($1.1 - $1.0) }
        if changed > max(8, n / 2) { return [] }

        var used = Set<Int>()
        var result: [Issue] = []
        for h in hunks {
            var (as_, ae, bs, be) = h
            // Claude added or dropped spaces or line breaks at the start or end, or swapped one run of
            // spacing for another: not a mistake. A space added between "test,ok" still counts.
            if (a[as_..<ae].map(\.text) + b[bs..<be].map(\.text)).joined().allSatisfy(\.isWhitespace),
               as_ == 0 || ae == n || (as_ < ae && bs < be) { continue }
            // A change with no word in it (a hyphen, a comma) is shown on the words around it:
            // an added comma on the word before it, a changed space on the words either side.
            if !a[as_..<ae].contains(where: { $0.isWord }) {
                let inserted = as_ == ae
                let left = as_ > 0 && a[as_ - 1].isWord
                if left { as_ -= 1; bs -= 1 }
                if (!inserted || !left) && ae < n && a[ae].isWord { ae += 1; be += 1 }
            }
            // trim leading and trailing spaces that did not change
            while as_ < ae && bs < be && a[as_].text == b[bs].text && !a[as_].isWord { as_ += 1; bs += 1 }
            while as_ < ae && bs < be && a[ae - 1].text == b[be - 1].text && !a[ae - 1].isWord { ae -= 1; be -= 1 }
            guard as_ < ae else { continue }
            let start = a[as_].range.location
            let range = NSRange(location: start, length: a[ae - 1].range.upperBound - start)
            let orig = (original as NSString).substring(with: range)
            let sugg = b[bs..<be].map(\.text).joined()
            guard orig != sugg else { continue }

            let note = notes.indices.first { k in
                guard !used.contains(k) else { return false }
                let o = notes[k].0.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
                return !o.isEmpty && (orig.contains(o) || o.contains(orig))
            }
            var kind: Kind, reason: String
            if let k = note {
                used.insert(k)
                kind = notes[k].2
                reason = notes[k].3
            } else if orig.lowercased() == sugg.lowercased() {
                kind = .capitals; reason = "Needs a capital letter."
            } else if !orig.contains(" ") && !sugg.contains(" ") && a[as_..<ae].allSatisfy({ $0.isWord }) {
                kind = .spelling; reason = "Spelling."
            } else {
                kind = .grammar; reason = "Grammar."
            }
            if orig.lowercased() == sugg.lowercased() && kind == .grammar { kind = .capitals }
            result.append(Issue(range: range, original: orig, suggestion: sugg, kind: kind, reason: reason))
        }
        return result
    }
}
