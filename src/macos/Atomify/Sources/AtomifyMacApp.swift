import AppKit
import AtomifyKit
import SwiftUI

/// Atomify for Mac: the iPhone and iPad app in one window. The views,
/// model and examples are the iOS app's (src/ios); this is only the shell.
@main
struct AtomifyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Atomify", id: "main") {
            MacRootView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 620)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.session.stop()
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One window is the whole app: closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
