import AppKit
import AtomifyKit
import SwiftUI

/// Atomify for the Mac: pick an example, run it, look at it. The app is a
/// test bench for the Metal renderer, not a script editor.
@main
struct AtomifyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Atomify") {
            ContentView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 600)
        }
        .commands {
            SimulationCommands(session: model.session)
        }
    }
}

/// `swift run AtomifyMac` starts a bare executable, which macOS treats as a
/// background tool: no Dock icon, no menu bar, windows behind others. Make
/// it a regular app and bring it to the front.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        // Lets LAMMPS stop and the working copy be removed.
        AppModelRegistry.current?.session.stop()
    }
}

struct SimulationCommands: Commands {
    @Bindable var session: SimulationSession

    var body: some Commands {
        CommandMenu("Simulation") {
            Button(session.status == .paused ? "Resume" : "Pause") { session.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!session.status.isActive)
            Button("Restart") { session.restart() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(session.title == nil)
            Button("Stop") { session.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!session.status.isActive)
            Divider()
            Button("Reset Camera") { session.resetCamera() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Deselect Atom") { session.clearSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(session.selectedAtom == nil)
            Divider()
            Toggle("Keep Running After Script", isOn: $session.continueAfterScript)
        }
    }
}
