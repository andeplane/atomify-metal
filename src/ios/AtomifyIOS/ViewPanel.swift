import AtomifyKit
import SwiftUI

/// The side panel's View tab: how the atoms look (size and color), what
/// else is drawn, render quality and the camera. Changes show at once
/// beside the panel, which stays open. Grouped cards in the panel's own
/// scroll view, as the Dashboard tab is (a Form here did not scroll inside
/// the panel).
struct ViewPanel: View {
    @Bindable var model: AppModel
    @Bindable var session: SimulationSession

    var body: some View {
        PanelScroll {
            VStack(alignment: .leading, spacing: 14) {
                atoms
                coloring
                ViewSection("Show") {
                    Toggle("Bonds", isOn: $session.showBonds)
                    Divider()
                    Toggle("Simulation box", isOn: $session.showBox)
                }
                rendering
                camera
            }
        }
    }

    private var atoms: some View {
        ViewSection("Atoms") {
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
                Divider()
                Button("Normal Size") { session.renderSettings.radiusScale = 1 }
            }
        }
    }

    private var coloring: some View {
        ViewSection("Color", footer: colorFooter) {
            HStack {
                Text("Color by")
                Spacer(minLength: 8)
                Picker("Color by", selection: $session.colorQuantity) {
                    Text("Atom type").tag(String?.none)
                    ForEach(session.availableQuantities, id: \.self) { quantity in
                        Text(QuantityName.title(quantity)).tag(String?.some(quantity))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            if session.colorQuantity != nil {
                Divider()
                HStack {
                    Text("Colormap")
                    Spacer(minLength: 8)
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
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Divider()
                ColorLegend(session: session)
                Divider()
                Button("Reset Range") { session.resetColorRange() }
                    .disabled(session.colorRange == nil)
            }
        }
    }

    private var colorFooter: String? {
        if session.colorQuantity == nil, session.example?.atomifyMetal?.colorRamp != nil {
            return "Shaded by position, as in Atomify 2."
        }
        return session.colorQuantity != nil ? "The range grows with every value seen." : nil
    }

    private var rendering: some View {
        ViewSection("Rendering", footer: "Automatic adds ambient occlusion and outlines below 300,000 atoms.") {
            Picker("Quality", selection: $model.qualityPolicy.mode) {
                ForEach(QualityPolicy.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Divider()
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
        }
    }

    private var camera: some View {
        ViewSection("Camera") {
            Button {
                session.resetCamera()
            } label: {
                Label("Reset View", systemImage: "viewfinder")
            }
            .disabled(session.scene == nil || session.isCameraFramed)
            Divider()
            Button {
                model.centerOnSelectedAtom()
            } label: {
                Label("Center on Selected Atom", systemImage: "scope")
            }
            .disabled(session.selectedAtom == nil)
        }
    }
}

/// A titled group of rows on the panel's lighter fill, like a grouped
/// form section, with an optional one-line footer.
private struct ViewSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
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
