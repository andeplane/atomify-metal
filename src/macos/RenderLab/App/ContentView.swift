import AtomifyRender
import SwiftUI

/// Sidebar of test scenes, the 3D view with overlays, and the controls.
struct ContentView: View {
    @Bindable var model: LabModel

    var body: some View {
        NavigationSplitView {
            SceneSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            ViewportContainer(model: model)
                .inspector(isPresented: $model.showInspector) {
                    ControlsPanel(model: model)
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
                }
        }
        .navigationTitle(model.sceneKind?.title ?? "RenderLab")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Quality", selection: $model.settings.quality) {
                    ForEach(RenderQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue.capitalized).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                .help("Fast: one pass. High: SSAO and outlines.")
                Toggle(isOn: $model.showBonds) {
                    Label("Bonds", systemImage: "line.diagonal")
                }
                .help("Show bonds")
                Toggle(isOn: $model.showBox) {
                    Label("Box", systemImage: "cube.transparent")
                }
                .help("Show the box")
                Button {
                    model.resetCamera()
                } label: {
                    Label("Reset Camera", systemImage: "camera.metering.center.weighted")
                }
                .help("Reset the camera (⌘0)")
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Controls", systemImage: "sidebar.right")
                }
                .help("Show or hide the controls")
            }
        }
        .task(id: model.request) {
            await model.loadCurrentRequest()
        }
        .onChange(of: model.host) {
            model.hostChanged()
        }
    }
}

struct SceneSidebar: View {
    @Bindable var model: LabModel

    var body: some View {
        List(selection: $model.sceneKind) {
            Section("Test scenes") {
                ForEach(LabSceneKind.allCases) { kind in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kind.title)
                            Text(kind.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: kind.systemImage)
                    }
                    .padding(.vertical, 2)
                    .tag(kind)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// The 3D view (lab view or ParticleView) with statistics, legend and
/// benchmark overlays.
struct ViewportContainer: View {
    @Bindable var model: LabModel

    var body: some View {
        ZStack {
            viewport
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    StatsOverlay(model: model)
                    Spacer()
                    if let legend = model.generated?.legend {
                        ColorBarLegend(info: legend)
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    BenchmarkPanel(model: model)
                    Spacer()
                }
            }
            .padding(12)

            if model.isGenerating {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Generating scene…")
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .allowsHitTesting(false)
            }

            if let error = model.rendererError {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task(id: model.isParticleViewAnimating) {
            await model.runParticleViewAnimation()
        }
    }

    @ViewBuilder
    private var viewport: some View {
        switch model.host {
        case .lab:
            LabViewport(model: model, sampleCount: model.sampleCount)
        case .particleView:
            ParticleViewHost(model: model)
        }
    }
}

/// The library's SwiftUI view, as the apps use it.
struct ParticleViewHost: View {
    @Bindable var model: LabModel

    var body: some View {
        // The callbacks capture the model, not this view.
        let target = model
        ParticleView(scene: model.particleViewScene, camera: $model.camera, settings: model.renderSettings,
                     onPick: { index in
                         performOnMain { target.select(index) }
                     },
                     onStats: { stats in
                         performOnMain { target.recordParticleViewStats(stats) }
                     })
    }
}
