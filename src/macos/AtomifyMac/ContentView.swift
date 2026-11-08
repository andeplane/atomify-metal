import AtomifyKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            ExamplesSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 290, max: 420)
        } detail: {
            ViewerView(session: model.session)
                .toolbar {
                    SessionToolbar(model: model, session: model.session, showInspector: $showInspector)
                }
                .inspector(isPresented: $showInspector) {
                    InspectorView(session: model.session)
                        .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
                }
        }
        .navigationTitle(model.session.title ?? "Atomify")
        .navigationSubtitle(model.session.status.label)
        .onChange(of: model.selectedExampleID) { _, id in
            model.open(id)
        }
        .onChange(of: model.session.stats.atoms, initial: true) { model.applyQuality() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            model.applyQuality()
        }
    }
}

/// Run controls and the look of the atoms.
struct SessionToolbar: ToolbarContent {
    @Bindable var model: AppModel
    @Bindable var session: SimulationSession
    @Binding var showInspector: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            if session.status.isActive {
                Button {
                    session.togglePause()
                } label: {
                    session.status == .paused
                        ? Label("Resume", systemImage: "play.fill")
                        : Label("Pause", systemImage: "pause.fill")
                }
                .help(session.status == .paused ? "Resume the simulation" : "Pause the simulation")
            } else {
                Button {
                    session.restart()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .disabled(session.title == nil)
                .help("Run the example again")
            }
            Button {
                session.restart()
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .disabled(session.title == nil)
            .help("Restart from the original files")
            Button {
                session.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!session.status.isActive)
            .help("Stop the simulation")
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Quality", selection: $model.qualityPolicy.mode) {
                ForEach(QualityPolicy.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Automatic: ambient occlusion below \(model.qualityPolicy.highQualityAtomLimit.formatted()) atoms. "
                + "Fast: impostors only. High: always ambient occlusion and outlines.")

            Picker("Color", selection: $session.colorQuantity) {
                Text("By type").tag(String?.none)
                Divider()
                ForEach(session.availableQuantities, id: \.self) { quantity in
                    Text(quantity).tag(String?.some(quantity))
                }
            }
            .frame(minWidth: 110)
            .help("Color atoms by type or by a per-atom quantity")

            Picker("Colormap", selection: $session.colormap) {
                ForEach(Colormap.allCases, id: \.self) { colormap in
                    Text(colormap.rawValue.capitalized).tag(colormap)
                }
            }
            .frame(minWidth: 100)
            .disabled(session.colorQuantity == nil)
            .help("Colormap for per-atom quantities")

            HStack(spacing: 4) {
                Image(systemName: "circle.circle")
                    .foregroundStyle(.secondary)
                Slider(value: $session.renderSettings.radiusScale, in: 0.1...2.5)
                    .frame(width: 90)
            }
            .help("Atom radius scale")

            Toggle(isOn: $session.showBonds) {
                Label("Bonds", systemImage: "line.diagonal")
            }
            .help("Show bonds")

            Toggle(isOn: $session.showBox) {
                Label("Box", systemImage: "cube")
            }
            .help("Show the simulation box")

            Button {
                session.resetCamera()
            } label: {
                Label("Reset Camera", systemImage: "camera.metering.center.weighted")
            }
            .help("Frame the simulation again")

            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }
}
