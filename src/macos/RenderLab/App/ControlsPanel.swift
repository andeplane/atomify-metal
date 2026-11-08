import AtomifyRender
import SwiftUI

/// The inspector column: scene parameters, render settings, timing and
/// benchmark, and the selected particle.
struct ControlsPanel: View {
    @Bindable var model: LabModel

    var body: some View {
        Form {
            SceneControls(model: model)
            SelectionInspector(model: model)
            RenderingControls(model: model)
            TimingControls(model: model)
        }
        .formStyle(.grouped)
    }
}

struct SceneControls: View {
    @Bindable var model: LabModel

    var body: some View {
        Section {
            switch model.sceneKind ?? .water {
            case .water:
                EmptyView()
            case .siliconCarbide:
                Stepper("Unit cells: \(model.siliconCarbideCells)×\(model.siliconCarbideCells)×\(model.siliconCarbideCells)",
                        value: $model.siliconCarbideCells, in: 1...12)
            case .performance:
                Picker("Lattice", selection: $model.performance.lattice) {
                    ForEach(PerformanceLattice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Particles", selection: $model.performance.size) {
                    ForEach(PerformanceSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Bonds", isOn: $model.performance.bonds)
                    .disabled(!model.performance.lattice.hasBonds)
                Picker("Periodic images", selection: $model.performance.images) {
                    ForEach(PeriodicImages.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Animate (thermal jitter)", isOn: $model.animate)
                    .help("Moves every particle a little every frame, so each frame uploads the whole scene.")
                LabeledSlider(title: "Jitter amplitude (Å)", value: $model.jitterAmplitude, range: 0...0.5,
                              digits: 3)
                    .disabled(!model.animate)
            case .coloring:
                Picker("Color by", selection: $model.coloring.property) {
                    ForEach(ScalarProperty.allCases) { Text($0.title).tag($0) }
                }
                Picker("Colormap", selection: $model.coloring.colormap) {
                    ForEach(Colormap.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                ColormapStrip(colormap: model.coloring.colormap)
                    .frame(height: 10)
                Toggle("Per-particle colors", isOn: $model.coloring.colorOverrides)
                Picker("Radius", selection: $model.coloring.radiusMode) {
                    ForEach(RadiusMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            case .picking:
                Picker("Layout", selection: $model.pickingLayout) {
                    ForEach(PickingLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if let generated = model.generated, generated.notes.count > 0 {
                ForEach(Array(generated.notes.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(model.sceneKind?.title ?? "Scene")
        }
    }
}

struct SelectionInspector: View {
    let model: LabModel

    var body: some View {
        Section("Selection") {
            if let picked = model.picked {
                LabeledContent("Index", value: "\(picked.index)")
                LabeledContent("Position (Å)", value: Format.vector(picked.position))
                LabeledContent("Style", value: "\(picked.styleIndex) · \(picked.styleName)")
                LabeledContent("Color") {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Format.color(picked.color))
                            .frame(width: 26, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
                        Text("\(picked.srgbHex) \(picked.colorIsOverride ? "per particle" : "style")")
                            .monospaced()
                    }
                }
                LabeledContent("Radius",
                               value: "\(Format.fixed(picked.radius, digits: 3)) \(picked.radiusIsOverride ? "per particle" : "style")")
                LabeledContent("Drawn radius",
                               value: Format.fixed(picked.drawnRadius(radiusScale: model.settings.radiusScale,
                                                                      selected: picked.flags & ParticleFlags.selected != 0),
                                                   digits: 3))
                if let scalar = picked.scalar {
                    LabeledContent(model.generated?.scalarName ?? "Value", value: Format.fixed(scalar, digits: 3))
                }
                if model.isAnimating {
                    Text("Position is the rest position; the drawn one is jittered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Deselect") { model.select(nil) }
            } else {
                Text("Click a particle to select it. Clicking empty space or a bond deselects.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct RenderingControls: View {
    @Bindable var model: LabModel

    var body: some View {
        Section("Rendering") {
            Picker("View", selection: $model.host) {
                ForEach(ViewportHost.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Lab view: RenderLab's own MTKView with full timings. ParticleView: the library's SwiftUI view.")
            Picker("Quality", selection: $model.settings.quality) {
                ForEach(RenderQuality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("MSAA", selection: $model.sampleCount) {
                ForEach(model.supportedSampleCounts, id: \.self) { count in
                    Text(count == 1 ? "Off" : "\(count)×").tag(count)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.host != .lab)
            .help(model.host == .lab ? "Recreates the renderer." : "ParticleView always uses 4× where available.")
            LabeledSlider(title: "Radius scale", value: $model.settings.radiusScale, range: 0.1...2.5)
            LabeledSlider(title: "AO strength", value: $model.settings.ambientOcclusionStrength, range: 0...1.5)
            LabeledSlider(title: "AO radius (0 = auto)", value: $model.settings.ambientOcclusionRadius, range: 0...12)
                .disabled(model.settings.quality != .high)
            LabeledSlider(title: "Outline width (px)", value: $model.settings.outlineWidth, range: 0...4)
                .disabled(model.settings.quality != .high)
            Toggle("Density occlusion", isOn: $model.settings.densityOcclusion)
                .help("Darkens crowded regions; computed on the CPU at upload.")
            Picker("Background", selection: $model.background) {
                ForEach(LabBackground.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show bonds", isOn: $model.showBonds)
            Toggle("Show box", isOn: $model.showBox)
            Button("Reset Camera") { model.resetCamera() }
        }
    }
}

struct TimingControls: View {
    @Bindable var model: LabModel

    var body: some View {
        Section("Benchmark") {
            Picker("Particle budget", selection: $model.particleBudget) {
                ForEach(ParticleBudget.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.host != .lab)
            .help("Most particles drawn per frame with periodic images; farther copies are thinned above it.")
            Picker("Orbit duration", selection: $model.benchmarkSeconds) {
                ForEach([5.0, 10.0, 20.0, 30.0], id: \.self) { seconds in
                    Text("\(Int(seconds)) s").tag(seconds)
                }
            }
            HStack {
                Button(model.isBenchmarkRunning ? "Cancel" : "Run Benchmark") { model.toggleBenchmark() }
                    .disabled(!model.isBenchmarkRunning && !model.canBenchmark)
                if model.host != .lab {
                    Text("Lab view only")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("Orbits the camera once around the scene and reports mean and 95th percentile frame, CPU and GPU times. Frame times are capped by the display's refresh rate; CPU and GPU times are not.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A slider with its title and value on one line above it.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    var digits = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Format.fixed(value, digits: digits))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .labelsHidden()
        }
    }
}

enum Format {
    static func fixed(_ value: Float, digits: Int) -> String {
        fixed(Double(value), digits: digits)
    }

    static func fixed(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "–" }
        return String(format: "%.\(max(digits, 0))f", value)
    }

    static func milliseconds(_ value: Double?) -> String {
        value.map { "\(fixed($0, digits: 2)) ms" } ?? "–"
    }

    static func vector(_ v: SIMD3<Float>) -> String {
        "\(fixed(v.x, digits: 3)), \(fixed(v.y, digits: 3)), \(fixed(v.z, digits: 3))"
    }

    /// A display color from the renderer's linear RGBA.
    static func color(_ linear: SIMD4<Float>) -> Color {
        Color(.sRGBLinear, red: Double(linear.x), green: Double(linear.y), blue: Double(linear.z),
              opacity: Double(linear.w))
    }
}
