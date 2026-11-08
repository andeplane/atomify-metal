import AtomifyKit
import SwiftUI

/// How the atoms look: size and color, what else is drawn, render quality
/// and the camera.
struct ViewOptionsSheet: View {
    @Bindable var model: AppModel
    @Bindable var session: SimulationSession
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                atoms
                coloring
                Section("Show") {
                    Toggle("Bonds", isOn: $session.showBonds)
                    Toggle("Simulation box", isOn: $session.showBox)
                    Toggle("Performance overlay", isOn: $showPerformance)
                }
                rendering
                camera
            }
            .navigationTitle("View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var atoms: some View {
        Section("Atoms") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Size")
                    Spacer()
                    Text(session.renderSettings.radiusScale, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.renderSettings.radiusScale, in: 0.25...2) {
                    Text("Atom size")
                } minimumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 7))
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 15))
                }
            }
            if session.renderSettings.radiusScale != 1 {
                Button("Normal Size") { session.renderSettings.radiusScale = 1 }
            }
        }
    }

    @ViewBuilder
    private var coloring: some View {
        Section {
            Picker("Color by", selection: $session.colorQuantity) {
                Text("Atom type").tag(String?.none)
                ForEach(session.availableQuantities, id: \.self) { quantity in
                    Text(QuantityName.title(quantity)).tag(String?.some(quantity))
                }
            }
            if session.colorQuantity != nil {
                Picker("Colormap", selection: $session.colormap) {
                    ForEach(Colormap.allCases, id: \.self) { colormap in
                        Label {
                            Text(colormap.rawValue.capitalized)
                        } icon: {
                            ColormapSwatch(colormap: colormap)
                        }
                        .tag(colormap)
                    }
                }
                ColorLegend(session: session)
                Button("Reset Range") { session.resetColorRange() }
                    .disabled(session.colorRange == nil)
            }
        } header: {
            Text("Color")
        } footer: {
            if session.colorQuantity == nil, session.example?.atomifyMetal?.colorRamp != nil {
                Text("This example shades its atoms by position, as Atomify 2 did.")
            } else if session.colorQuantity != nil {
                Text("The range grows to cover every value seen in this run.")
            }
        }
    }

    private var rendering: some View {
        Section {
            Picker("Quality", selection: $model.qualityPolicy.mode) {
                ForEach(QualityPolicy.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Ambient occlusion")
                    Spacer()
                    Text(session.renderSettings.ambientOcclusionStrength == 0 ? "Off" : String(
                        format: "%.1f×", session.renderSettings.ambientOcclusionStrength))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $session.renderSettings.ambientOcclusionStrength, in: 0...2) {
                    Text("Ambient occlusion")
                }
            }
        } header: {
            Text("Rendering")
        } footer: {
            Text("Automatic draws shadows and outlines below 50,000 atoms, and saves battery above. "
                 + "Ambient occlusion darkens atoms in crowded places.")
        }
    }

    private var camera: some View {
        Section("Camera") {
            Button {
                session.resetCamera()
                dismiss()
            } label: {
                Label("Reset View", systemImage: "viewfinder")
            }
            .disabled(session.scene == nil || session.isCameraFramed)
            Button {
                model.centerOnSelectedAtom()
                dismiss()
            } label: {
                Label("Center on Selected Atom", systemImage: "scope")
            }
            .disabled(session.selectedAtom == nil)
        }
    }
}

/// Readable names for the built-in per-atom quantities.
enum QuantityName {
    static func title(_ quantity: String) -> String {
        switch quantity {
        case "vx": "Velocity x"
        case "vy": "Velocity y"
        case "vz": "Velocity z"
        default: quantity
        }
    }
}

/// A colormap as a small horizontal gradient.
struct ColormapSwatch: View {
    let colormap: Colormap

    var body: some View {
        LinearGradient(colors: Self.colors(colormap), startPoint: .leading, endPoint: .trailing)
            .frame(width: 28, height: 12)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .accessibilityHidden(true)
    }

    static func colors(_ colormap: Colormap, steps: Int = 12) -> [Color] {
        (0...steps).map { step in
            let c = colormap.srgbColor(at: Float(step) / Float(steps))
            return Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))
        }
    }
}

/// The colormap with the range it spans now.
struct ColorLegend: View {
    let session: SimulationSession
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact, let quantity = session.colorQuantity {
                Text(QuantityName.title(quantity))
                    .font(.caption.weight(.semibold))
            }
            LinearGradient(colors: ColormapSwatch.colors(session.colormap), startPoint: .leading, endPoint: .trailing)
                .frame(height: compact ? 8 : 12)
                .clipShape(Capsule())
            HStack {
                if let range = session.colorRange {
                    Text(Format.number(Double(range.lowerBound)))
                    Spacer()
                    Text(Format.number(Double(range.upperBound)))
                } else {
                    Text("Waiting for values…")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
