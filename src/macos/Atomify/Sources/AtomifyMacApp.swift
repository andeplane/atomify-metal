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
        .commands { AtomifyCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One window is the whole app: closing it quits.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The menu bar: Settings… in the app menu, and a Simulation menu with the
/// controls that float over the atoms, each with its key.
struct AtomifyCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { model.showSettings() }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu("Simulation") {
            let session = model.session
            let onSimulation = !model.showsGallery
            // Space has no modifier, so it is off while the gallery (and its
            // search field) is up.
            Button(session.status == .running ? "Pause" : "Play") { session.togglePause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!onSimulation || !session.status.isActive)
            Button("Restart") { model.restartAndShow() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.example == nil && session.title == nil)
            Divider()
            Button("Faster") { model.stepSpeed(by: 1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(session.stepsPerFrame == nil)
            Button("Slower") { model.stepSpeed(by: -1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(session.stepsPerFrame == nil)
            Divider()
            Button("Simulations") { model.showGallery() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(model.showsGallery)
            Button("Reset View") { session.resetCamera() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!onSimulation)
            Divider()
            panelButton(.info, key: "i")
            panelButton(.dashboard, key: "d")
            Button(model.panel == .view ? "Hide View Options" : "View Options") { model.togglePanel(.view) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!onSimulation)
            Button(model.chromeHidden ? "Show Controls" : "Hide Controls") { model.chromeHidden.toggle() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!onSimulation)
            Divider()
            Button("Back") { model.escape() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model.escapeAction == .none)
        }
    }

    private func panelButton(_ panel: SidePanel, key: KeyEquivalent) -> some View {
        Button(model.panel == panel ? "Hide \(panel.title)" : panel.title) { model.togglePanel(panel) }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(model.showsGallery)
    }
}
