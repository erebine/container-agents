// SPDX-License-Identifier: MIT
import SwiftUI

@main
struct XerotierAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Xerotier Agent", id: "main") {
            RootView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 620)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarContent()
                .environment(model)
        } label: {
            // A dedicated view so @Observable changes re-tint the menu bar icon.
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}

/// Makes the prototype behave like a normal app (Dock icon + foreground window)
/// in addition to the menu bar item, and shows the window on launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Notifier.requestAuthorization()
    }
}
