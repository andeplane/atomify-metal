import AtomifyVision
import CompositorServices
import SwiftUI

@main
struct AtomifyApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // The experiences always open at launch, whatever was open when the
        // app was last closed.
        WindowGroup(id: AppModel.windowID) {
            ContentView()
                .environment(model)
        }
        .defaultSize(LibraryView.defaultSize)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        // A compact panel near the wearer while the lab is open.
        WindowGroup(id: AppModel.controlsWindowID) {
            Group {
                if model.run != nil { ControlsView() }
                else { Text("Choose an experience to begin.").font(.title3).padding(32) }
            }
            .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultWindowPlacement { _, _ in
            #if DEBUG
            // Screenshots in the Simulator: show the panel straight ahead.
            if ProcessInfo.processInfo.arguments.contains("-AtomifyPanelAhead") { return WindowPlacement() }
            #endif
            return WindowPlacement(.utilityPanel)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // The lab: Metal through a compositor layer, both eyes at once,
        // over passthrough with the wearer's hands and arms visible.
        ImmersiveSpace(id: AppModel.labSpaceID) {
            CompositorLayer(configuration: LabLayerConfiguration()) { [model] layerRenderer in
                let layer = LabLayer(renderer: layerRenderer)
                Task { @MainActor in LabSpace.start(layer, model: model) }
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
        .upperLimbVisibility(.visible)
        // Hold dynamics when the app is no longer active.
        .onChange(of: scenePhase) { _, phase in
            // Space dismissal has its own complete return-to-experiences path.
            // Backgrounding alone pauses rather than leaving an empty lab.
            model.setApplicationActive(phase == .active)
        }
    }
}

/// The large window is the experience carousel; controls have their own panel.
struct ContentView: View {
    #if DEBUG
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #endif

    var body: some View {
        LibraryView()
        #if DEBUG
            .task { await autostart() }
        #endif
    }

    #if DEBUG
    /// Debug builds only: `-AtomifyAutostart <demo id>` opens that
    /// experience at launch, for screenshots in the Simulator, which does
    /// not accept synthetic taps. `-AtomifyHidePanel` leaves the panel
    /// closed; `-AtomifyPanelAhead` opens it straight ahead.
    private func autostart() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-AtomifyAutostart"), flag + 1 < arguments.count,
              model.run == nil, !model.labIsOpen,
              let demo = model.catalog.demos.first(where: { $0.id == arguments[flag + 1] }) else { return }
        model.load(demo)
        guard model.run != nil, case .opened = await openImmersiveSpace(id: AppModel.labSpaceID) else {
            model.stop()
            return
        }
        model.restoreLibrary = {
            openWindow(id: AppModel.windowID)
            dismissWindow(id: AppModel.controlsWindowID)
        }
        if !arguments.contains("-AtomifyHidePanel") { openWindow(id: AppModel.controlsWindowID) }
        dismissWindow(id: AppModel.windowID)
    }
    #endif
}
