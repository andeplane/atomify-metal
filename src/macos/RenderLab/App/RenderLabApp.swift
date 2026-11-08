import AppKit
import SwiftUI

/// RenderLab: the AtomifyRender renderer on synthetic scenes, no LAMMPS.
@main
struct RenderLabApp: App {
    @NSApplicationDelegateAdaptor(RenderLabAppDelegate.self) private var appDelegate
    @State private var model = LabModel()

    var body: some Scene {
        WindowGroup("RenderLab") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .commands {
            LabCommands(model: model)
        }
    }
}

/// `swift run RenderLab` starts a bare executable, which macOS treats as a
/// background tool: no Dock icon, no menu bar, windows behind others. Make
/// it a regular app and bring it to the front.
@MainActor
final class RenderLabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LabCommands: Commands {
    let model: LabModel

    var body: some Commands {
        CommandMenu("Lab") {
            Button("Reset Camera") { model.resetCamera() }
                .keyboardShortcut("0", modifiers: .command)
            Button("Deselect") { model.select(nil) }
                .keyboardShortcut("d", modifiers: .command)
            Divider()
            Button(model.isBenchmarkRunning ? "Cancel Benchmark" : "Run Benchmark") { model.toggleBenchmark() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!model.isBenchmarkRunning && !model.canBenchmark)
        }
    }
}
