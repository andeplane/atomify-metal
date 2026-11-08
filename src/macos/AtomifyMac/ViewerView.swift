import AtomifyKit
import Foundation
import SwiftUI

/// The 3D view with a statistics overlay, a color legend and run messages.
struct ViewerView: View {
    @Bindable var session: SimulationSession

    var body: some View {
        // The callbacks capture the session, not this view.
        let target = session
        ZStack {
            ParticleView(scene: session.scene, camera: $session.camera, settings: session.renderSettings,
                         onPick: { index in
                             performOnMain { target.selectParticle(index) }
                         },
                         onStats: { stats in
                             performOnMain { target.recordRenderStats(stats) }
                         })
                .ignoresSafeArea()

            VStack(alignment: .leading) {
                HStack(alignment: .top) {
                    StatsOverlay(session: session)
                    Spacer()
                    ColorLegend(session: session)
                }
                Spacer()
                RunMessages(session: session)
            }
            .padding(12)

            if session.scene == nil {
                Placeholder(session: session)
            }
        }
    }
}

/// Runs `work` on the main actor: now when already on the main thread,
/// otherwise soon. The renderer's callbacks are not documented to arrive on
/// the main thread.
func performOnMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        Task { @MainActor in work() }
    }
}

struct StatsOverlay: View {
    let session: SimulationSession

    var body: some View {
        let stats = session.stats
        VStack(alignment: .leading, spacing: 2) {
            row("fps", Format.fixed(stats.framesPerSecond, digits: 0))
            row("gpu", "\(Format.fixed(stats.gpuTimeMs, digits: 1)) ms")
            row("atoms", stats.atoms.formatted())
            if stats.bonds > 0 { row("bonds", stats.bonds.formatted()) }
            row("step", stats.timestep.formatted())
            row("time", Format.number(stats.time))
            row("steps/s", Format.fixed(stats.stepsPerSecond, digits: 0))
            row("T", "\(Format.number(stats.temperature)) \(Format.temperatureUnit(stats.units))")
            if stats.minimizing { Text("minimizing").foregroundStyle(.yellow) }
        }
        .font(.system(.caption, design: .monospaced))
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .opacity(stats.atoms > 0 ? 1 : 0)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(value)
        }
    }
}

/// Gradient and range of the per-atom coloring.
struct ColorLegend: View {
    let session: SimulationSession

    var body: some View {
        if let quantity = session.colorQuantity {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Text(quantity).font(.caption.monospaced())
                    Button("Reset range") { session.resetColorRange() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                let colormap = session.colormap
                LinearGradient(colors: (0...16).map { Format.color(colormap.color(at: Float($0) / 16)) },
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: 180, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                if let range = session.colorRange {
                    HStack {
                        Text(Format.number(Double(range.lowerBound)))
                        Spacer()
                        Text(Format.number(Double(range.upperBound)))
                    }
                    .font(.caption2.monospaced())
                    .frame(width: 180)
                } else {
                    Text("waiting for values…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// Errors, directive warnings and the end of a run.
struct RunMessages: View {
    let session: SimulationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = session.errorMessage {
                message(error, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            ForEach(session.directiveWarnings, id: \.self) { warning in
                message(warning, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
            }
            if session.status == .finished {
                message("The script finished. Restart to run it again.", systemImage: "flag.checkered", tint: .green)
            }
        }
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).textSelection(.enabled).lineLimit(4)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Placeholder: View {
    let session: SimulationSession

    var body: some View {
        VStack(spacing: 8) {
            if session.status.isActive {
                ProgressView()
                Text("Starting \(session.title ?? "simulation")…")
            } else if session.title == nil {
                Image(systemName: "atom").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Pick an example in the sidebar.")
            }
        }
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}

enum Format {
    /// Four significant digits, switching to scientific notation for very
    /// large or small magnitudes.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "nan" : (value > 0 ? "inf" : "-inf") }
        let magnitude = abs(value)
        if magnitude != 0 && (magnitude < 1e-3 || magnitude >= 1e6) {
            return value.formatted(.number.notation(.scientific).precision(.significantDigits(4)))
        }
        return value.formatted(.number.precision(.significantDigits(1...5)).grouping(.never))
    }

    static func fixed(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return "–" }
        return value.formatted(.number.precision(.fractionLength(digits)).grouping(.never))
    }

    static func temperatureUnit(_ units: String) -> String {
        switch units {
        case "lj": "(reduced)"
        case "": ""
        default: "K"
        }
    }

    /// A display color from the renderer's linear RGB.
    static func color(_ linear: SIMD4<Float>) -> Color {
        Color(.sRGBLinear, red: Double(linear.x), green: Double(linear.y), blue: Double(linear.z),
              opacity: Double(linear.w))
    }
}
