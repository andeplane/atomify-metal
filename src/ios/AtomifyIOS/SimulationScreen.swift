import AtomifyKit
import Combine
import Foundation
import SwiftUI

/// The root screen: the Metal view edge to edge, a title capsule on top and
/// the run controls at the bottom.
struct SimulationScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let session = model.session
        ZStack {
            SimulationCanvas(model: model, session: session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack(alignment: .top) {
                    TitleCapsule(session: session)
                    Spacer(minLength: 12)
                    RoundGlassButton(systemImage: "viewfinder", label: "Reset View") {
                        session.resetCamera()
                    }
                }
                Spacer()
                RunMessages(session: session, catalogError: model.catalogError)
                ControlBar(session: session)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if session.scene == nil {
                Placeholder(session: session)
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .preferredColorScheme(.dark)
        .task { model.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.enterForeground()
            case .background: model.enterBackground()
            default: break
            }
        }
    }
}

/// The particle view, paced and scaled for the phone. Reads the atom count,
/// so it lives apart from the chrome that does not need to redraw with it.
struct SimulationCanvas: View {
    let model: AppModel
    @Bindable var session: SimulationSession

    var body: some View {
        // The callbacks capture the session, not this view.
        let target = session
        ParticleView(scene: session.scene, camera: $session.camera, settings: session.renderSettings,
                     pacing: model.framePacing, contentScaleLimit: model.contentScaleLimit,
                     onPick: { index in
                         performOnMain { target.selectParticle(index) }
                     },
                     onStats: { stats in
                         performOnMain { target.recordRenderStats(stats) }
                     })
            .onChange(of: session.stats.atoms, initial: true) { model.applyQuality() }
            // Both notifications are posted on arbitrary threads; deliver them on
            // the main thread, where this view's closures run.
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
                .receive(on: DispatchQueue.main)) { _ in
                model.applyQuality()
            }
            .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
                .receive(on: DispatchQueue.main)) { _ in
                model.applyQuality()
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

/// What is running, and how it is going.
struct TitleCapsule: View {
    let session: SimulationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.title ?? "Atomify")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            HStack(spacing: 5) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLine)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glass(in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .green
        case .paused: .orange
        case .failed: .red
        case .idle, .finished: .gray
        }
    }

    private var statusLine: String {
        let stats = session.stats
        var parts = [session.status.label]
        if stats.atoms > 0 {
            parts.append("\(stats.atoms.formatted()) atoms")
            parts.append(Format.temperature(stats.temperature, units: stats.units))
        }
        return parts.joined(separator: " · ")
    }
}

/// Restart, play or pause, and selection.
struct ControlBar: View {
    let session: SimulationSession

    var body: some View {
        HStack(spacing: 6) {
            BarButton(systemImage: "arrow.counterclockwise", label: "Restart") {
                session.restart()
            }
            .disabled(session.title == nil)

            Button {
                if session.status.isActive {
                    session.togglePause()
                } else {
                    session.restart()
                }
            } label: {
                Image(systemName: session.status == .running ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.status == .running ? "Pause" : "Play")
            .disabled(session.title == nil)

            BarButton(systemImage: "xmark.circle", label: "Deselect Atom") {
                session.clearSelection()
            }
            .disabled(session.selectedAtom == nil)
        }
        .padding(6)
        .glass(in: Capsule())
    }
}

struct BarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 52, height: 52)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct RoundGlassButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle())
        .accessibilityLabel(label)
    }
}

/// Errors, directive warnings, the selected atom and the end of a run.
struct RunMessages: View {
    let session: SimulationSession
    let catalogError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let catalogError {
                message(catalogError, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            if let error = session.errorMessage {
                message(error, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            ForEach(session.directiveWarnings, id: \.self) { warning in
                message(warning, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
            }
            if session.status == .finished {
                message("The script finished. Restart to run it again.", systemImage: "flag.checkered", tint: .green)
            }
            if let atom = session.selectedAtom {
                let name = atom.typeName.map { "\($0), type \(atom.type)" } ?? "Type \(atom.type)"
                message("Atom \(atom.tag) · \(name)", systemImage: "scope", tint: .yellow)
            }
        }
        .frame(maxWidth: 500)
    }

    private func message(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text).lineLimit(4)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct Placeholder: View {
    let session: SimulationSession

    var body: some View {
        VStack(spacing: 10) {
            if session.status.isActive {
                ProgressView()
                Text("Starting \(session.title ?? "simulation")…")
            } else if session.title == nil {
                Image(systemName: "atom").font(.system(size: 48))
            }
        }
        .foregroundStyle(.secondary)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Liquid Glass on iOS 26, a material on earlier systems.
    @ViewBuilder
    func glass(in shape: some Shape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}

enum Format {
    /// "312 K" for real units, "T 1.20" for reduced Lennard-Jones units.
    static func temperature(_ value: Double, units: String) -> String {
        guard value.isFinite else { return "–" }
        if units == "lj" {
            return "T " + value.formatted(.number.precision(.fractionLength(2)).grouping(.never))
        }
        return value.formatted(.number.precision(.fractionLength(0))) + " K"
    }
}
