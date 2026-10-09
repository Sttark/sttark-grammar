import AppKit

Migrate.settings()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
note("started \(Updater.version), Accessibility \(AXIsProcessTrusted() ? "on" : "off")")
Migrate.loginItem()
app.run()
