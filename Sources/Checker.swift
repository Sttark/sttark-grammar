import AppKit
import Security

enum Kind: String {
    case spelling, grammar, capitals, layout

    var label: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .capitals: return "Capitals"
        case .layout: return "Layout"
        }
    }

    var color: NSColor {
        switch self {
        case .spelling: return NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: 1)
        case .grammar: return NSColor(srgbRed: 0.94, green: 0.63, blue: 0.13, alpha: 1)
        case .capitals: return NSColor(srgbRed: 0.24, green: 0.48, blue: 0.98, alpha: 1)
        case .layout: return NSColor(srgbRed: 0.64, green: 0.38, blue: 0.92, alpha: 1)
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
    var layout: Layout? = nil

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

/// A change to how a message is laid out, found by the text it applies to so it survives typing elsewhere.
struct Layout {
    enum Change: String { case split, blankLine = "blank_line", list, bold, underline }
    var styling: Bool { change == .bold || change == .underline }
    let change: Change
    let at: [String]            // the start of the sentence or line, or the phrase to style
    let numbered: Bool
    var lead = ""               // a list: the sentence's start rewritten to introduce it, ending in a colon
    var items: [String] = []    // a list: its parts, one per line

    var label: String {
        switch change {
        case .split: return "Start a new paragraph here"
        case .blankLine: return "Add a blank line above this line"
        case .list:
            let lines = items.enumerated().map { (numbered ? "\($0.offset + 1). " : "\u{2022} ") + $0.element }
            return "Make this sentence a list:\n" + ([lead] + lines).joined(separator: "\n")
        case .bold: return "Make \u{201C}\(at[0])\u{201D} bold"
        case .underline: return "Underline \u{201C}\(at[0])\u{201D}"
        }
    }

    /// Where each mark goes: the first word of the sentence or line. nil once the text no longer matches.
    func locate(in v: NSString) -> [NSRange]? {
        func starts(_ t: String) -> [Int] {
            var out: [Int] = [], from = 0
            while from < v.length {
                let r = v.range(of: t, options: [.caseInsensitive], range: NSRange(location: from, length: v.length - from))
                guard r.location != NSNotFound else { break }
                out.append(r.location); from = r.location + 1
            }
            return out
        }
        func lineStart(_ i: Int) -> Bool { i == 0 || v.character(at: i - 1) == 10 }
        func word(_ i: Int) -> NSRange {
            var j = i
            while j < v.length && Diff.isWordChar(v.character(at: j)) { j += 1 }
            return NSRange(location: i, length: max(1, j - i))
        }
        guard let first = at.first, !first.isEmpty else { return nil }
        switch change {
        case .split:
            // mid-line, after a space; Claude sometimes quotes the sentence before it too, so try each
            for t in at {
                if let i = starts(t).first(where: { $0 > 1 && v.character(at: $0 - 1) == 32 && !lineStart($0) }) { return [word(i)] }
            }
            return nil
        case .blankLine:
            guard let i = starts(first).first(where: { $0 > 0 && lineStart($0) }) else { return nil }
            return [word(i)]
        case .bold, .underline:
            // the whole phrase; the first copy of it
            guard let i = starts(first).first else { return nil }
            return [NSRange(location: i, length: (first as NSString).length)]
        case .list:
            // the whole sentence, from its start to its end mark. Claude sometimes quotes a later part of it,
            // so go back to the end of the sentence before, or the line start.
            guard var i = starts(first).first else { return nil }
            while i > 0, v.character(at: i - 1) != 10,
                  !(i > 1 && v.character(at: i - 1) == 32 && [46, 63, 33].contains(v.character(at: i - 2))) { i -= 1 }
            var j = i
            while j < v.length {
                let c = v.character(at: j)
                if c == 10 { break }
                if c == 46 || c == 63 || c == 33, j + 1 == v.length || [10, 32].contains(v.character(at: j + 1)) { j += 1; break }
                j += 1
            }
            return [NSRange(location: i, length: j - i)]
        }
    }
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
    First write "corrected": the full text with only clear mistakes fixed. Fix misspellings, wrong grammar, wrong word forms, missing hyphens, and words that need a capital letter (names, brands, products, short forms like HVAC, PDF and USB, the word I, sentence starts). Keep the user's words, tone and casual style. Leave web addresses, email addresses, file paths and code exactly as typed. Sttark is the user's company and is spelled right, as are its addresses like sttark.com. Do not reword, shorten, or improve style. Treat the text as finished: if the last sentence has no period, question mark or exclamation point at the end, add one, unless the text is a list item (it starts with a marker like "1.", "-" or "•"). Only leave it off when the text clearly stops partway, like ending on "the", "to" or "and". Keep punctuation that is already correct. Keep all spacing and line breaks.
    Then list every change you made in "issues", in the order they appear. For each: "original" is the exact wrong text copied character for character from the input, as short as possible (only the wrong word or words). "suggestion" is what replaces it. "kind" is spelling, grammar, or capitals. "reason" is at most 12 plain words. If the same mistake appears more than once, list each one. If a word is not a real word and you can't tell what was meant, like "somnerhqw", leave it as is in "corrected" and still list it, with "suggestion" the same as "original". If nothing is wrong, return the text unchanged and an empty list.
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

    static func check(_ text: String, model: Model, words: [String] = []) async throws -> CheckResult {
        let sys = words.isEmpty ? system : system + "\nThe user's dictionary. These are spelled right, never change them: " + words.prefix(500).joined(separator: ", ")
        let (reply, inTokens, outTokens) = try await ask(system: sys, schema: schema, text: text, model: model)
        guard let corrected = reply["corrected"] as? String else { throw CheckError.badReply("no corrected copy") }
        let notes = (reply["issues"] as? [[String: Any]] ?? []).compactMap { d -> (String, String, Kind, String)? in
            guard let o = d["original"] as? String, let s = d["suggestion"] as? String,
                  let k = Kind(rawValue: d["kind"] as? String ?? ""), let r = d["reason"] as? String else { return nil }
            return (o, s, k, r)
        }
        var issues = Diff.issues(original: text, corrected: corrected, notes: notes)
        issues += Diff.unknownWords(text, notes: notes, besides: issues)
        return CheckResult(issues: issues.sorted { $0.range.location < $1.range.location }, inputTokens: inTokens, outputTokens: outTokens)
    }

    /// One request to Claude with a JSON reply. Returns the reply and the tokens used.
    static func ask(system: String, schema: [String: Any], text: String, model: Model) async throws -> ([String: Any], Int, Int) {
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
              let reply = (try? JSONSerialization.jsonObject(with: Data(txt.utf8))) as? [String: Any] else {
            throw CheckError.badReply("stop_reason \(json["stop_reason"] ?? "none")")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return (reply, usage["input_tokens"] as? Int ?? 0, usage["output_tokens"] as? Int ?? 0)
    }
}

/// A second check on the whole message: paragraph splits, blank lines and lists. Never wording.
enum LayoutChecker {
    static let system = """
    You look at the layout of a message the user is typing in another app, never its wording. Each line break in the text is a real line break, and an empty line is a blank line.
    Suggest a change only when it clearly makes the message easier to read. Most messages need nothing, so an empty list is the usual answer.
    - "split": a paragraph that runs two separate points together, or a long paragraph (about 80 words or more) with a clear turn in it. "at" is the sentence that should start the new paragraph.
    - "list": one sentence that runs three or more separate things together with commas, like steps, tasks, options or parts to order, where a reader would take them in faster as a list. Not a sentence that tells what happened, and not a few simple words like "red, green and blue". "at" holds one string: the first six words of that sentence, copied exactly. "lead" is the start of the sentence rewritten to introduce the list, ending with a colon, like "Before the install we need to:". "items" are the parts in order, each able to stand alone and starting with a capital letter, keeping the user's words, with spelling fixed, no "and" at the start and no period at the end. Set "numbered" when the order matters.
    - "bold": the one or two details in a long message a reader must not miss, like a deadline, a required action or a warning. "at" is just that phrase, 2 to 6 words, copied exactly. At most two per message, and none in a short or casual message.
    - "underline": only the name of a document, form or section the reader has to go find. "at" is that name, copied exactly. Prefer bold for anything else.
    Never suggest anything for a message under three sentences.
    In "at", copy the first six or so words of each sentence or line exactly as typed, enough to find it. "reason" is at most 10 plain words.
    """

    static let schema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["suggestions"],
        "properties": [
            "suggestions": ["type": "array", "items": [
                "type": "object", "additionalProperties": false,
                "required": ["change", "at", "numbered", "lead", "items", "reason"],
                "properties": [
                    "change": ["type": "string", "enum": ["split", "list", "bold", "underline"]],
                    "at": ["type": "array", "items": ["type": "string"]],
                    "numbered": ["type": "boolean"],
                    "lead": ["type": "string"],
                    "items": ["type": "array", "items": ["type": "string"]],
                    "reason": ["type": "string"],
                ],
            ]],
        ],
    ]

    /// Also returns Claude's answer as it came, for the log.
    static func check(_ text: String, model: Model) async throws -> ([Issue], Int, Int, String) {
        let (reply, inTokens, outTokens) = try await Checker.ask(system: system, schema: schema, text: text, model: model)
        let found = (reply["suggestions"] as? [[String: Any]] ?? []).compactMap { d -> Issue? in
            let c = Layout.Change(rawValue: d["change"] as? String ?? "")
            // the first 4 words are enough to find a line, and less likely to hold a typo that Fix all then changes;
            // a phrase to style is kept whole
            let keep = c == .bold || c == .underline ? 8 : 4
            // Claude sometimes splits a quote into single words; only a split may quote more than one sentence
            var raw = (d["at"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            if raw.count > 1 && (c != .split || raw.allSatisfy { !$0.contains(" ") }) { raw = [raw.joined(separator: " ")] }
            let at = raw.map { $0.split(separator: " ").prefix(keep).joined(separator: " ") }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;: ")) }.filter { !$0.isEmpty }
            let lead = (d["lead"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let items = (d["items"] as? [String] ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .;,")) }.filter { !$0.isEmpty }
            guard let c, !at.isEmpty, c != .list || (items.count >= 3 && !lead.isEmpty) else { return nil }
            var l = Layout(change: c, at: at, numbered: d["numbered"] as? Bool ?? false)
            if c == .list { l.lead = lead.hasSuffix(":") ? lead : lead + ":"; l.items = items }
            return Issue(range: NSRange(location: 0, length: 0), original: at.joined(separator: " | "), suggestion: l.label,
                         kind: .layout, reason: d["reason"] as? String ?? "", layout: l)
        }
        let blanks = blankLines(text).filter { b in !found.contains { $0.layout?.at.first == b.layout?.at.first } }
        let raw = (try? JSONSerialization.data(withJSONObject: reply)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return (found + blanks, inTokens, outTokens, raw)
    }

    /// Claude never suggests these, so the app finds them: three or more lines in a row that are each a
    /// paragraph (6+ words ending in . ? or !, not a list item) get a blank line above each after the first.
    static func blankLines(_ text: String) -> [Issue] {
        let lines = text.components(separatedBy: "\n")
        func paragraph(_ l: String) -> Bool {
            let t = l.trimmingCharacters(in: .whitespaces)
            guard t.split(separator: " ").count >= 6, t.range(of: #"^([-*•]|\d+[.)])\s"#, options: .regularExpression) == nil else { return false }
            return t.range(of: #"[.?!]["'”’)]*$"#, options: .regularExpression) != nil
        }
        var out: [Issue] = [], run: [String] = []
        func flush() {
            if run.count >= 3 {
                for l in run.dropFirst() {
                    let start = l.trimmingCharacters(in: .whitespaces).split(separator: " ").prefix(6).joined(separator: " ")
                    let lay = Layout(change: .blankLine, at: [start], numbered: false)
                    out.append(Issue(range: NSRange(location: 0, length: 0), original: start, suggestion: lay.label,
                                     kind: .layout, reason: "Paragraphs read easier with space between them.", layout: lay))
                }
            }
            run = []
        }
        for l in lines { if paragraph(l) { run.append(l) } else { flush() } }
        flush()
        return out
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

    /// Web and email addresses and file paths: docs.sttark.com, dan@sttark.com, ~/src/app. Nothing in them gets flagged.
    static func links(in s: String) -> [NSRange] {
        (try? NSRegularExpression(pattern: #"\S*(?:://|@|/)\S*|\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}\b"#))?
            .matches(in: s, range: NSRange(location: 0, length: (s as NSString).length)).map(\.range) ?? []
    }

    static let abbreviations: Set<String> = ["e.g", "i.e", "etc", "vs", "approx", "a.m", "p.m", "fig", "mr", "mrs", "ms", "dr", "st"]

    /// Claude misses a lowercase sentence start now and then, so the app checks it too.
    /// Only plain lowercase words: "iPhone" and addresses are left alone, as are words after "e.g." or "...".
    static func capitalIssues(_ text: String, besides claude: [Issue]) -> [Issue] {
        let ns = text as NSString
        let links = links(in: text)
        guard let re = try? NSRegularExpression(pattern: #"(?:^|[.!?]["'”’)\]]*\s+)([a-z]+(?:['’][a-z]+)?)(?=[\s,;:.!?"'”’)\]]|$)"#) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let r = m.range(at: 1)
            // the match starts at the period, so the word before it plus "." is "e.g." or "thinking..."
            if m.range.location > 0, ns.substring(with: m.range).hasPrefix(".") {
                let prev = (ns.substring(to: m.range.location).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? "").lowercased() + "."
                if prev.hasSuffix("..") || abbreviations.contains(String(prev.dropLast())) { return nil }
            }
            if links.contains(where: { NSIntersectionRange($0, r).length > 0 }) { return nil }
            if claude.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { return nil }
            let word = ns.substring(with: r)
            return Issue(range: r, original: word, suggestion: word.prefix(1).uppercased() + word.dropFirst(),
                         kind: .capitals, reason: "Start the sentence with a capital letter.")
        }
    }

    /// Words Claude marked as not real and had no fix for ("somnerhqw"). They aren't in the corrected copy's
    /// changes, so they're found in the text by name. Addresses are skipped.
    static func unknownWords(_ text: String, notes: [(String, String, Kind, String)], besides found: [Issue]) -> [Issue] {
        let ns = text as NSString
        let links = links(in: text)
        var out: [Issue] = []
        for (o, s, _, reason) in notes where o == s && !o.isEmpty && !o.contains(" ") {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: o) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                if (found + out).contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { continue }
                if links.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                out.append(Issue(range: r, original: o, suggestion: o, kind: .spelling, reason: reason))
            }
        }
        return out
    }

    /// The smallest change that does the fix, never starting or ending with a space. Some boxes (Asana, for
    /// one) drop spaces at the ends of pasted text, which would join two words. So only the part that changes is
    /// replaced, and a neighboring letter is taken along on any side that would start or end with a space.
    static func tighten(_ r: NSRange, _ suggestion: String, in v: NSString) -> (NSRange, String) {
        let o = Array(v.substring(with: r).utf16), s = Array(suggestion.utf16)
        // leave text with emoji and other paired characters alone rather than risk splitting one
        if (o + s).contains(where: { UTF16.isLeadSurrogate($0) || UTF16.isTrailSurrogate($0) }) { return (r, suggestion) }
        var p = 0
        while p < o.count && p < s.count && o[p] == s[p] { p += 1 }
        var q = 0
        while q < o.count - p && q < s.count - p && o[o.count - 1 - q] == s[s.count - 1 - q] { q += 1 }
        var lo = r.location + p, hi = r.upperBound - q
        var mid = Array(s[p..<(s.count - q)])
        if hi - lo == 0 && mid.isEmpty { return (r, suggestion) }
        func space(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 0xA0 }
        // never a bare cursor: at a line end it can land on the next line. Keep a letter selected.
        if hi == lo {
            if lo > 0 && v.character(at: lo - 1) != 10 { lo -= 1; mid.insert(v.character(at: lo), at: 0) }
            else if hi < v.length && v.character(at: hi) != 10 { mid.append(v.character(at: hi)); hi += 1 }
        }
        func edgeLeft() -> Bool { mid.first.map(space) ?? true }
        func edgeRight() -> Bool { mid.last.map(space) ?? true }
        // take letters from the left while the text would start with a space (or is empty, a deletion)
        while edgeLeft() && lo > 0 && v.character(at: lo - 1) != 10 { lo -= 1; mid.insert(v.character(at: lo), at: 0); if !space(mid[0]) { break } }
        while edgeRight() && hi < v.length && v.character(at: hi) != 10 { mid.append(v.character(at: hi)); hi += 1; if !space(mid.last!) { break } }
        // at a line start, the left can't be widened: take from the right
        while edgeLeft() && hi < v.length && v.character(at: hi) != 10 { mid.append(v.character(at: hi)); hi += 1; if !space(mid.last!) { break } }
        return (NSRange(location: lo, length: hi - lo), String(utf16CodeUnits: mid, count: mid.count))
    }

    /// Words a sentence can't end on, so text ending on one is still being typed.
    static let unfinished: Set<String> = ["a", "an", "the", "to", "and", "or", "but", "nor", "of", "for", "with", "in", "on", "at",
        "from", "by", "into", "onto", "about", "as", "so", "because", "than", "that", "which", "who", "whose", "if", "when",
        "while", "whether", "where", "like", "can", "could", "would", "should", "will", "shall", "may", "might", "must",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had", "my", "your", "our",
        "their", "his", "her", "its", "this", "these", "those", "some", "any", "every", "each", "no", "not", "very", "i", "we",
        "you", "they", "he", "she", "it's", "i'm", "we're", "you're", "they're", "there's", "let's", "per", "via", "vs"]
    static let questionStarts: Set<String> = ["can", "could", "would", "will", "should", "shall", "do", "does", "did", "is",
        "are", "was", "were", "have", "has", "had", "what", "why", "how", "when", "where", "who", "which", "whose", "am"]

    /// Claude misses a missing period at the end now and then, so the app checks it too.
    static func endIssues(_ text: String, besides claude: [Issue]) -> [Issue] {
        // a list item ("1. Order the units", "- Book the crane") doesn't take a period
        if text.range(of: #"^\s*(\d+[.)]|[-*•])\s"#, options: .regularExpression) != nil { return [] }
        let ns = text as NSString
        guard let last = text.unicodeScalars.reversed().first(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }),
              CharacterSet.alphanumerics.contains(last) else { return [] }
        let r = ns.range(of: #"[\p{L}\p{N}'’]+(?=\s*$)"#, options: .regularExpression)
        guard r.location != NSNotFound else { return [] }
        let word = ns.substring(with: r)
        if unfinished.contains(word.lowercased().replacingOccurrences(of: "’", with: "'")) { return [] }
        if claude.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) { return [] }
        let start = ns.range(of: #"[.!?]\s+"#, options: [.regularExpression, .backwards], range: NSRange(location: 0, length: r.location))
        let sentence = ns.substring(from: start.location == NSNotFound ? 0 : start.upperBound)
        let first = sentence.split(whereSeparator: { !($0.isLetter || $0 == "'") }).first.map { $0.lowercased() } ?? ""
        let mark = questionStarts.contains(first) ? "?" : "."
        return [Issue(range: r, original: word, suggestion: word + mark, kind: .grammar,
                      reason: mark == "?" ? "End the question with a question mark." : "End the sentence with a period.")]
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

        // Claude may "fix" a name inside an address, like sttark in docs.sttark.com
        let links = links(in: original)

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
            // Punctuation between them, like the period in "once.)", is taken along.
            if !a[as_..<ae].contains(where: { $0.isWord }) {
                let inserted = as_ == ae
                let punct = { (t: Token) in !t.isWord && !t.text.allSatisfy(\.isWhitespace) }
                var l = as_
                while l > 0 && punct(a[l - 1]) { l -= 1 }
                let left = l > 0 && a[l - 1].isWord
                if left { bs -= as_ - (l - 1); as_ = l - 1 }
                if !inserted || !left {
                    var r = ae
                    while r < n && punct(a[r]) { r += 1 }
                    if r < n && a[r].isWord { be += r + 1 - ae; ae = r + 1 }
                }
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
            // a change inside an address is dropped; a period added after one still counts
            if links.contains(where: { NSIntersectionRange($0, range).length > 0 }) && !sugg.hasPrefix(orig) { continue }

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
