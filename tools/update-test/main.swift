// A stand-in app around the real Sources/Update.swift, for tools/update-test.sh.
// It has its own ID and settings, so it never touches the installed app, its settings, dictionary, keys or log.
// Its settings come from test.json next to the app, because a restart through `open` drops the environment.
import AppKit

let folder = Bundle.main.bundleURL.deletingLastPathComponent()
let cfg = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("test.json")))) as? [String: Any] ?? [:]
let logFile = URL(fileURLWithPath: cfg["log"] as? String ?? "/dev/null")

func note(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) \(s)\n"
    if let h = try? FileHandle(forWritingTo: logFile) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: logFile, atomically: true, encoding: .utf8) }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Updater.feed = URL(string: cfg["feed"] as! String)!
Updater.firstCheck = 1
Updater.retryBusy = 2
let updater = Updater()
updater.notify = { _, title, _ in note("notice: \(title)") }
updater.busy = { FileManager.default.fileExists(atPath: folder.appendingPathComponent("busy").path) }
note("started \(Updater.version)")
updater.start()
if let again = cfg["recheck"] as? Double {   // a second check, as the hourly timer would make
    DispatchQueue.main.asyncAfter(deadline: .now() + again) { note("check again"); updater.check(force: true) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + (cfg["exitAfter"] as? Double ?? 20)) { note("exit \(Updater.version)"); NSApp.terminate(nil) }
app.run()
