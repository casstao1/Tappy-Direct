import AppKit
import SwiftUI

final class TappyAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: KeyboardSoundController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = KeyboardSoundController()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.handleAppDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        controller?.handleAppDidResignActive()
    }
}

@main
struct TappyApp: App {
    @NSApplicationDelegateAdaptor(TappyAppDelegate.self) private var appDelegate

    var body: some Scene {
        // Tappy is a pure menu-bar app — all UI lives in the NSStatusItem
        // popover managed by KeyboardSoundController.setupMenuBarItem().
        // The Settings scene is kept as a no-op so SwiftUI has a valid scene
        // to satisfy the App protocol; it is never opened.
        Settings {
            EmptyView()
        }
    }
}
