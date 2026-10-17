import AppKit
import InkRelayCore
import SwiftUI

/// InkRelay in the menu bar: the sync engine runs inside the app, so macOS asks once, for this app,
/// for Notes, Calendar, Reminders and folder access.
@main
struct InkRelayBarApp: App {
    @StateObject private var model = BarModel()

    init() {
        // Bundled builds set LSUIElement; this keeps `swift run` out of the Dock too.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.symbol)
                .accessibilityLabel("InkRelay: \(model.statusLine)")
        }
        .menuBarExtraStyle(.window)

        Window("Set Up InkRelay", id: "setup") {
            SetupView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
