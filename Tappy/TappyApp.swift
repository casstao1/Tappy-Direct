import AppKit
import SwiftUI

@main
struct TappyApp: App {
    @StateObject private var controller = KeyboardSoundController()

    var body: some Scene {
        // Tappy is a pure menu-bar app — all UI lives in the NSStatusItem
        // popover managed by KeyboardSoundController.setupMenuBarItem().
        // The Settings scene is kept as a no-op so SwiftUI has a valid scene
        // to satisfy the App protocol; it is never opened.
        Settings {
            EmptyView()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    controller.handleAppDidBecomeActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                    controller.handleAppDidResignActive()
                }
        }
    }
}
