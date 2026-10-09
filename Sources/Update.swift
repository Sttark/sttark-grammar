import AppKit
import ServiceManagement
import UserNotifications

/// Where the dictionary and the API keys live. A copy that used the old name, ClaudeGrammar, is moved over on first run.
let supportDir: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let u = base.appendingPathComponent("SttarkGrammar"), old = base.appendingPathComponent("ClaudeGrammar")
    if !FileManager.default.fileExists(atPath: u.path) && FileManager.default.fileExists(atPath: old.path) {
        try? FileManager.default.moveItem(at: old, to: u)
    }
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)   // also a folder moved from the old name
    return u
}()

/// The API keys, in a file only this Mac account can read. Not the Keychain: macOS ties a Keychain item to the
/// exact build that saved it, so every update would stop and ask for the Mac password before the app could check again.
enum Keys {
    static var file: URL { supportDir.appendingPathComponent("keys.json") }

    static func all() -> [String: String] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: String] ?? [:]
    }

    static func get(_ name: String) -> String? {
        if let k = all()[name], !k.isEmpty { return k }
        // a key saved by ClaudeGrammar, in the Keychain; macOS asks for the password once to hand it over
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "claude-grammar",
                                kSecAttrAccount as String: name + "-api-key", kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let k = String(data: d, encoding: .utf8), !k.isEmpty else { return nil }
        _ = set(name, k)
        return k
    }

    static func set(_ name: String, _ key: String) -> Bool {
        var keys = all()
        keys[name] = key
        guard let d = try? JSONSerialization.data(withJSONObject: keys, options: [.prettyPrinted, .sortedKeys]),
              (try? d.write(to: file, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return true
    }
}

enum Migrate {
    /// Settings saved under the old name come along, once, before anything reads them.
    static func settings() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromClaudeGrammar") else { return }
        for (k, v) in d.persistentDomain(forName: "com.sttark.claude-grammar") ?? [:] where d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migratedFromClaudeGrammar")
    }

    /// Start at login. Set once, so turning it off in System Settings > General > Login Items sticks.
    static func loginItem() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginItemSet"), Bundle.main.bundlePath.hasSuffix(".app") else { return }
        try? SMAppService.mainApp.register()
        d.set(true, forKey: "loginItemSet")
    }
}

/// Looks for a newer version on GitHub, says so once, and installs it in place with one click.
/// Settings, the dictionary and the keys live outside the app, so they stay as they are.
final class Updater: NSObject, UNUserNotificationCenterDelegate {
    static let repo = "Sttark/sttark-grammar"
    static let asset = "SttarkGrammar.zip"

    struct Release { let build: Int; let version: String; let url: URL }
    private(set) var available: Release?
    private(set) var installing = false
    private var lastCheck = Date.distantPast
    var changed: () -> Void = {}

    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Also called when the menu opens; at most once an hour unless asked.
    func check(force: Bool = false, done: ((String) -> Void)? = nil) {
        guard force || Date().timeIntervalSince(lastCheck) > 3600 else { return }
        lastCheck = Date()
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let tag = (j?["tag_name"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let build = Int(tag.split(separator: ".").last ?? "") ?? 0
            let link = (j?["assets"] as? [[String: Any]] ?? []).first { $0["name"] as? String == Self.asset }?["browser_download_url"] as? String
            DispatchQueue.main.async {
                guard j != nil else { done?("Couldn't reach GitHub. Try again later."); return }
                if build > Self.build, let link, let url = URL(string: link) {
                    self.available = Release(build: build, version: tag, url: url)
                    self.notifyOnce()
                    done?("Version \(tag) is ready.")
                } else {
                    self.available = nil
                    done?("You have the latest version (\(Self.version)).")
                }
                self.changed()
            }
        }.resume()
    }

    private func notifyOnce() {
        guard let r = available, UserDefaults.standard.integer(forKey: "notifiedBuild") < r.build else { return }
        UserDefaults.standard.set(r.build, forKey: "notifiedBuild")
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert]) { ok, _ in
            guard ok else { return }
            let n = UNMutableNotificationContent()
            n.title = "Sttark Grammar \(r.version) is ready"
            n.body = "Click to update. It takes a few seconds and keeps your settings."
            c.add(UNNotificationRequest(identifier: "update", content: n, trigger: nil))
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.install() }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner])
    }

    /// Download, check it's signed by us, swap it in where this copy sits, and start it.
    func install() {
        guard let r = available, !installing else { return }
        installing = true
        changed()
        note("update: downloading \(r.version)")
        URLSession.shared.downloadTask(with: r.url) { zip, _, error in
            let result: String? = {
                guard let zip else { return "The download failed: \(error?.localizedDescription ?? "no file")" }
                let fm = FileManager.default
                let tmp = fm.temporaryDirectory.appendingPathComponent("SttarkGrammar-update-\(r.build)")
                try? fm.removeItem(at: tmp)
                try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, tmp.path]).0 == 0 else { return "Couldn't unpack the download." }
                let new = tmp.appendingPathComponent("SttarkGrammar.app")
                guard Self.signedLikeThisApp(new) else { return "The download isn't signed by Sttark, so it wasn't installed." }
                let here = URL(fileURLWithPath: Bundle.main.bundlePath)
                let old = tmp.appendingPathComponent("previous.app")
                do {
                    try fm.moveItem(at: here, to: old)
                    do { try fm.moveItem(at: new, to: here) } catch { try? fm.moveItem(at: old, to: here); throw error }
                } catch {
                    return "Couldn't replace the app in \(here.deletingLastPathComponent().path): \(error.localizedDescription)"
                }
                return nil
            }()
            DispatchQueue.main.async {
                if let result {
                    note("update failed: \(result)")
                    self.installing = false
                    self.changed()
                    let a = NSAlert()
                    a.messageText = "Update didn't install"
                    a.informativeText = result + "\n\nYou can also download it from github.com/\(Self.repo)/releases."
                    NSApp.activate(ignoringOtherApps: true)
                    a.runModal()
                    return
                }
                note("update: installed \(r.version), restarting")
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
                try? p.run()
                NSApp.terminate(nil)
            }
        }.resume()
    }

    /// The new copy has to pass the same signature rule as this one (the Sttark certificate and this app's ID).
    /// A build made on someone's own Mac has no certificate, so for that one only a valid signature and the ID are checked.
    static func signedLikeThisApp(_ app: URL) -> Bool {
        let (_, out) = run("/usr/bin/codesign", ["-d", "-r-", Bundle.main.bundlePath])
        guard let rule = out.split(separator: "\n").first(where: { $0.hasPrefix("designated => ") })?.dropFirst(14) else { return false }
        let id = Bundle.main.bundleIdentifier ?? ""
        let req = rule.contains("cdhash") ? "identifier \"\(id)\"" : String(rule)
        return run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + req, app.path]).0 == 0
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
    }
}
