import AppKit

@main
final class TappyAppDelegate: NSObject, NSApplicationDelegate {
    private static var sharedDelegate: TappyAppDelegate?

    private var controller: KeyboardSoundController?

    static func main() {
        let app = NSApplication.shared
        let delegate = TappyAppDelegate()
        sharedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = KeyboardSoundController()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.handleAppDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        controller?.handleAppDidResignActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
