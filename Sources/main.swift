import AppKit

Migrate.settings()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller()
controller.start()
Migrate.loginItem()
app.run()
