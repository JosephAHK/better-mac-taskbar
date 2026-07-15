import AppKit

@main
enum BetterMacTaskbarMain {
    static func main() {
        AppLog.bootstrap()
        AppLog.info("main entering run loop")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        AppLog.shutdown("NSApplication.run returned")
    }
}
