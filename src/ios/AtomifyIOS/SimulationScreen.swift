import AtomifyKit
import Combine
import Foundation
import SwiftUI

/// Keys for settings kept in `UserDefaults`.
enum SettingsKey {
    /// Frames per second, GPU time and steps per second over the atoms.
    static let showPerformance = "showPerformanceOverlay"
}

/// The root screen: the Metal view edge to edge, with glass controls
/// floating on top and everything else in sheets.
struct SimulationScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        @Bindable var model = model
        let session = model.session
        ZStack {
            SimulationCanvas(model: model, session: session)
                .ignoresSafeArea()

            if session.scene == nil {
                Placeholder(model: model, session: session)
            }

            if !model.chromeHidden {
                SimulationChrome(model: model, session: session, landscape: verticalSizeClass == .compact)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.chromeHidden)
        .background(Color(red: 0.08, green: 0.08, blue: 0.1))
        .preferredColorScheme(.dark)
        .statusBarHidden(model.chromeHidden)
        .persistentSystemOverlays(model.chromeHidden ? .hidden : .automatic)
        .sheet(item: $model.sheet) { sheet in
            SheetContent(sheet: sheet, model: model)
        }
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

/// The sheet for an `AppSheet`, at medium height so the atoms stay in view
/// and can still be turned above it.
private struct SheetContent: View {
    let sheet: AppSheet
    let model: AppModel

    var body: some View {
        Group {
            switch sheet {
            case .examples: ExamplesSheet(model: model)
            case .view: ViewOptionsSheet(model: model, session: model.session)
            case .dashboard: DashboardSheet(session: model.session)
            case .about: ExampleAboutSheet(model: model, session: model.session)
            }
        }
        .environment(model)
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .presentationContentInteraction(.scrolls)
    }
}

/// The particle view, paced and scaled for the phone. Reads the atom count
/// and the camera, so it lives apart from the controls that need neither.
struct SimulationCanvas: View {
    let model: AppModel
    @Bindable var session: SimulationSession

    var body: some View {
        // A camera the app sets (reset, center) must wake a paused view, so
        // read it here, where changes reach the view.
        let _ = session.camera
        // The callbacks capture the model, not this view.
        let target = model
        ParticleView(scene: session.scene, camera: $session.camera, settings: session.renderSettings,
                     pacing: model.framePacing, contentScaleLimit: model.contentScaleLimit,
                     onPick: { index in
                         performOnMain { target.handlePick(index) }
                     },
                     onStats: { stats in
                         performOnMain { target.session.recordRenderStats(stats) }
                     },
                     onDoubleTap: {
                         performOnMain { target.session.resetCamera() }
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
            .accessibilityLabel(session.title.map { "Simulation of \($0)" } ?? "Simulation")
            .accessibilityHint("Drag to rotate, pinch to zoom, tap an atom to inspect it.")
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

/// The floating controls: title and reset view on top, messages, the atom
/// card and the toolbar at the bottom. In landscape the bottom row splits
/// into the card on the left and the toolbar on the right.
struct SimulationChrome: View {
    let model: AppModel
    let session: SimulationSession
    let landscape: Bool
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TitleCapsule(session: session) { model.sheet = .about }
                if landscape && showPerformance {
                    PerformanceHUD(session: session)
                }
                Spacer(minLength: 8)
                ResetViewButton(session: session)
            }
            if !landscape && showPerformance {
                HStack {
                    PerformanceHUD(session: session)
                    Spacer()
                }
            }
            Spacer(minLength: 0)
            if landscape {
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        RunMessages(model: model, session: session)
                        SelectedAtomCard(model: model, session: session)
                    }
                    .frame(maxWidth: 380, alignment: .leading)
                    Spacer(minLength: 0)
                    SimulationToolbar(model: model, session: session)
                }
            } else {
                VStack(spacing: 8) {
                    RunMessages(model: model, session: session)
                    SelectedAtomCard(model: model, session: session)
                    SimulationToolbar(model: model, session: session)
                }
            }
        }
        .padding(.horizontal, landscape ? 8 : 16)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.25), value: session.selectedAtom?.tag)
    }
}

/// Frames the system again. Shown only once the camera has moved away from
/// the framed view; it reads the camera, so it is its own small view.
struct ResetViewButton: View {
    let session: SimulationSession

    var body: some View {
        let show = session.scene != nil && !session.isCameraFramed
        RoundGlassButton(systemImage: "viewfinder", label: "Reset View") {
            session.resetCamera()
        }
        .opacity(show ? 1 : 0)
        .scaleEffect(show ? 1 : 0.6)
        .allowsHitTesting(show)
        .accessibilityHidden(!show)
        .animation(.snappy(duration: 0.2), value: show)
    }
}

/// What is running, and how it is going. Opens the about sheet.
struct TitleCapsule: View {
    let session: SimulationSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? "Atomify")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule())
        .disabled(session.title == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows what this simulation is about.")
    }

    private var statusColor: Color {
        switch session.status {
        case .running: .green
        case .paused: .orange
        case .failed: .red
        case .finished: .blue
        case .idle: .gray
        }
    }

    private var statusLine: String {
        if session.status.isActive && session.scene == nil {
            return "Starting…"
        }
        let stats = session.stats
        var parts = [session.status.label]
        if stats.atoms > 0 {
            parts.append("\(stats.atoms.formatted()) atoms")
            if stats.temperature.isFinite && stats.temperature > 0 {
                parts.append(Format.temperature(stats.temperature, units: stats.units))
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Examples, Restart, Play or Pause, View and Dashboard.
struct SimulationToolbar: View {
    let model: AppModel
    let session: SimulationSession

    var body: some View {
        HStack(spacing: 2) {
            ToolbarButton(systemImage: "square.grid.2x2", label: "Examples") {
                model.sheet = .examples
            }
            ToolbarButton(systemImage: "arrow.counterclockwise", label: "Restart") {
                session.restart()
            }
            .disabled(session.title == nil)

            PlayPauseButton(session: session)
                .padding(.horizontal, 4)

            ToolbarButton(systemImage: "slider.horizontal.3", label: "View") {
                model.sheet = .view
            }
            ToolbarButton(systemImage: "chart.xyaxis.line", label: "Dashboard") {
                model.sheet = .dashboard
            }
        }
        .padding(6)
        .glass(in: Capsule())
    }
}

/// The one tinted control: pauses a running simulation, resumes a paused
/// one and runs a finished or failed one again.
struct PlayPauseButton: View {
    let session: SimulationSession

    var body: some View {
        let running = session.status == .running
        Button {
            if session.status.isActive {
                session.togglePause()
            } else {
                session.restart()
            }
        } label: {
            Image(systemName: running ? "pause.fill" : "play.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tintedGlass(.accentColor, in: Circle())
        .accessibilityLabel(running ? "Pause" : session.status == .paused ? "Resume" : "Run Again")
        .disabled(session.title == nil)
        .sensoryFeedback(.selection, trigger: running)
    }
}

struct ToolbarButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }
}

/// Frames per second, GPU time, steps per second and quality, for the
/// curious (Settings turns it on).
struct PerformanceHUD: View {
    let session: SimulationSession

    var body: some View {
        let stats = session.stats
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Format.count(stats.framesPerSecond)) fps · \(Format.decimal(stats.gpuTimeMs)) ms GPU")
            Text("\(Format.count(stats.stepsPerSecond)) steps/s · \(session.renderSettings.quality.rawValue.capitalized)")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The atom card for the selected atom, if any.
struct SelectedAtomCard: View {
    let model: AppModel
    let session: SimulationSession

    var body: some View {
        if let atom = session.selectedAtom {
            AtomCard(atom: atom, units: session.stats.units,
                     onCenter: { model.centerOnSelectedAtom() },
                     onClose: { session.clearSelection() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// What the tapped atom is and where it is.
struct AtomCard: View {
    let atom: AtomInfo
    let units: String
    let onCenter: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Circle()
                    .fill(swatch)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.headline)
                    Text("ID \(atom.tag.formatted()) · type \(atom.type)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.quaternary, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Deselect")
            }

            HStack(spacing: 8) {
                coordinate("x", atom.position.x)
                coordinate("y", atom.position.y)
                coordinate("z", atom.position.z)
            }

            HStack(spacing: 8) {
                Button(action: onCenter) {
                    Label("Center", systemImage: "scope")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint("Turns the camera around this atom.")

                if let radius = atom.radius, radius.isFinite, radius > 0 {
                    pill("Radius \(Format.length(Double(radius), units: units))")
                }
                if let quantity = atom.quantity, let value = atom.value {
                    pill("\(quantity) \(Format.number(Double(value)))")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 420)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var name: String {
        atom.elementName ?? atom.typeName ?? "Type \(atom.type)"
    }

    private var swatch: Color {
        guard let c = atom.color else { return .gray }
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    private func coordinate(_ axis: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.axis(axis, units: units))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Format.number(Double(value)))
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

/// Errors, script warnings and the end of a run, as glass banners above the
/// toolbar. Tapping a warning dismisses it for this run.
struct RunMessages: View {
    let model: AppModel
    let session: SimulationSession
    @State private var dismissed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let catalogError = model.catalogError {
                banner(catalogError, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            if let error = session.errorMessage {
                banner(error, systemImage: "exclamationmark.octagon.fill", tint: .red)
            }
            ForEach(session.directiveWarnings.filter { !dismissed.contains($0) }, id: \.self) { warning in
                banner(warning, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
                    .onTapGesture { dismissed.insert(warning) }
                    .accessibilityHint("Dismisses the warning.")
            }
            if session.status == .finished {
                HStack(spacing: 10) {
                    Label {
                        Text("The script finished.")
                    } icon: {
                        Image(systemName: "flag.checkered").foregroundStyle(.green)
                    }
                    Spacer(minLength: 8)
                    Button("Run Again") { session.restart() }
                        .font(.callout.weight(.semibold))
                }
                .font(.callout)
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 10)
                .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .frame(maxWidth: 500)
        .onChange(of: session.title) { dismissed = [] }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shown before the first picture: starting, failed or nothing loaded.
struct Placeholder: View {
    let model: AppModel
    let session: SimulationSession

    var body: some View {
        VStack(spacing: 14) {
            if session.status.isActive {
                ProgressView()
                    .controlSize(.large)
                Text("Starting \(session.title ?? "simulation")…")
                    .foregroundStyle(.secondary)
            } else if case .failed = session.status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("\(session.title ?? "The simulation") could not start.")
                    .foregroundStyle(.secondary)
                Button("Choose an Example") { model.sheet = .examples }
                    .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "atom")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                if session.title == nil && model.catalogError == nil {
                    Button("Choose an Example") { model.sheet = .examples }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
