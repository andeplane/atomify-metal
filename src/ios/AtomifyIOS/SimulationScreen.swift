import AtomifyKit
import Combine
import Foundation
import SwiftUI

/// Keys for settings kept in `UserDefaults`.
enum SettingsKey {
    /// Frames per second, GPU time and steps per second over the atoms.
    static let showPerformance = "showPerformanceOverlay"
}

/// The running simulation, the app's main screen: the Metal view edge to
/// edge, with glass controls floating along its edges.
/// The app is landscape only, as Atomify 2 was.
struct SimulationScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let session = model.session
        ZStack {
            SimulationCanvas(model: model, session: session)
                .ignoresSafeArea()
                .modifier(PanelShift(open: model.panel != nil))

            if session.scene == nil {
                Placeholder(model: model, session: session)
                    .modifier(PanelShift(open: model.panel != nil))
            }

            if !model.chromeHidden && !model.showsWelcome {
                SimulationChrome(model: model, session: session)
                    .transition(.opacity)
            }

            if let panel = model.panel, !model.showsWelcome {
                PanelHost(model: model, panel: panel)
            }

            if model.showsWelcome {
                WelcomeCard { model.showsWelcome = false }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.chromeHidden)
        .animation(.easeInOut(duration: 0.25), value: model.showsWelcome)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: model.panel)
        .background(Color.canvas)
        .readsLayoutMetrics()
        .preferredColorScheme(.dark)
        .persistentSystemOverlays(model.chromeHidden ? .hidden : .automatic)
    }
}

/// The side panel, along the trailing edge inside the safe area and down
/// to 8 pt above the bottom of the screen.
private struct PanelHost: View {
    let model: AppModel
    let panel: SidePanel
    @Environment(\.layoutMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // An explicit size, so the panel's scrolling body always ends on
        // screen: from the inset below the top of the safe area to 8 pt
        // above the bottom of the screen (under the home indicator).
        GeometryReader { proxy in
            let inset = metrics.panelInset
            let width = metrics.overlaysPanel ? proxy.size.width - 2 * inset : metrics.panelWidth
            let height = proxy.size.height + proxy.safeAreaInsets.bottom - inset - 8
            SidePanelView(model: model, tab: panel)
                .frame(width: max(width, 0), height: max(height, 0))
                .padding(.top, inset)
                .padding(.trailing, inset)
                .frame(width: proxy.size.width, alignment: .topTrailing)
        }
        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
    }
}

/// Moves the atoms left by half the panel while it is open, so the system
/// stays centred in the space beside it. (Cheaper than resizing the
/// drawable; taps follow the offset.)
private struct PanelShift: ViewModifier {
    let open: Bool
    @Environment(\.layoutMetrics) private var metrics

    func body(content: Content) -> some View {
        let shift = open && !metrics.overlaysPanel ? -(metrics.panelWidth + metrics.panelInset) / 2 : 0
        content.offset(x: shift)
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

/// The floating controls, in four groups along the edges so the middle
/// stays on the atoms: the Examples button and the title top leading with
/// the script's messages under them, the panels top trailing, time bottom
/// trailing and the selected atom bottom leading.
struct SimulationChrome: View {
    let model: AppModel
    let session: SimulationSession
    @Environment(\.layoutMetrics) private var metrics
    /// The width between the margins, measured, for the atom card.
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        let atomShown = session.selectedAtom != nil
        ZStack {
            LeadingCluster(model: model, session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if model.panel == nil {
                PanelRail(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
            }
            SelectedAtomCard(model: model, session: session, maxWidth: atomCardMaxWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            // Above the card, which never reaches it.
            TimeRail(session: session)
                .offset(x: timeRailShift)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            if session.status == .finished && !atomShown {
                FinishedBanner(session: session)
                    .offset(x: timeRailShift / 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
        }
        .safeAreaPadding(.horizontal, metrics.margin)
        .padding(.top, metrics.margin)
        .padding(.bottom, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .animation(.snappy(duration: 0.25), value: session.selectedAtom?.tag)
        .animation(.easeInOut(duration: 0.2), value: session.status == .finished)
    }

    /// With a panel open, the time rail sits 8 pt left of it so Play stays
    /// in reach.
    private var timeRailShift: CGFloat {
        guard model.panel != nil, !metrics.overlaysPanel else { return 0 }
        return -(metrics.panelWidth + metrics.panelInset + 8 - metrics.margin)
    }

    /// From the leading margin to a margin short of the time rail, wherever
    /// the rail is.
    private var atomCardMaxWidth: CGFloat {
        guard contentWidth > 0 else { return AtomCard.fullWidth }
        return max(contentWidth + timeRailShift - TimeRail.width - metrics.margin, 0)
    }
}

/// Top leading: Simulations (the gallery), what is running, Reset View; under them the
/// script's label, warnings and errors, the color legend and the
/// performance numbers.
struct LeadingCluster: View {
    let model: AppModel
    let session: SimulationSession
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false
    /// Warnings dismissed this run; kept here because both layouts below
    /// show the same messages.
    @State private var dismissedWarnings: Set<String> = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 8) {
                LabeledGlassButton(systemImage: "square.grid.2x2", title: "Simulations") {
                    model.showGallery()
                }
                TitleCapsule(session: session) {
                    model.panel = model.panel == .info ? nil : .info
                }
                ResetViewButton(session: session)
            }
            // Down to the vertical centre at most: the legend goes first
            // when there is no room (the View options show it too).
            ViewThatFits(in: .vertical) {
                messages(legend: true)
                messages(legend: false)
            }
            .frame(maxWidth: 340, alignment: .topLeading)
            .containerRelativeFrame(.vertical, alignment: .topLeading) { height, _ in
                max(height / 2 - 64, 0)
            }
            .padding(.top, 52)
        }
        .onChange(of: session.title) { dismissedWarnings = [] }
    }

    private func messages(legend: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ScriptLabelBanner(session: session)
            RunMessages(model: model, session: session, dismissed: $dismissedWarnings)
            if legend && session.colorQuantity != nil {
                ColorLegend(session: session, compact: true)
                    .frame(width: 170)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .glass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onTapGesture { model.panel = .view }
                    .accessibilityAddTraits(.isButton)
            }
            if showPerformance {
                PerformanceHUD(session: session)
            }
        }
    }
}

/// Top trailing: Info, Dashboard and View, one glass capsule.
struct PanelRail: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            RailButton(systemImage: "info.circle", label: "Info", isSelected: model.panel == .info) {
                model.panel = .info
            }
            RailButton(systemImage: "chart.xyaxis.line", label: "Dashboard", isSelected: model.panel == .dashboard) {
                model.panel = .dashboard
            }
            RailButton(systemImage: "slider.horizontal.3", label: "View", isSelected: model.panel == .view) {
                model.panel = .view
            }
        }
        .padding(2)
        .glass(in: Capsule())
    }
}

/// Bottom trailing: speed, Restart and Play or Pause, one glass capsule.
struct TimeRail: View {
    let session: SimulationSession
    /// Three 44 pt buttons and the capsule's 2 pt padding.
    static let width: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            SpeedMenu(session: session)
            RailButton(systemImage: "arrow.counterclockwise", label: "Restart") {
                session.restart()
            }
            .disabled(session.title == nil)
            PlayPauseButton(session: session)
        }
        .padding(2)
        .glass(in: Capsule())
    }
}

/// How fast the simulation plays, relative to the example's own speed
/// (Atomify 2's: one timestep per frame unless the script says otherwise).
/// The choices open in a popover beside the rail, which the system places
/// so all seven fit; a menu from the bottom rail ran off the top.
struct SpeedMenu: View {
    let session: SimulationSession
    @State private var showsChoices = false

    static let choices: [(label: String, factor: Double)] = [
        ("¼×", 0.25), ("½×", 0.5), ("1×", 1), ("2×", 2), ("4×", 4), ("10×", 10), ("Max", .infinity),
    ]

    var body: some View {
        let factor = session.speedFactor
        Button {
            showsChoices = true
        } label: {
            Text(Self.label(for: factor))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(session.stepsPerFrame == nil)
        .accessibilityLabel("Speed")
        .accessibilityValue(Self.label(for: factor))
        .popover(isPresented: $showsChoices, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) {
            choiceList(selected: factor)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func choiceList(selected: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(Self.choices.indices, id: \.self) { index in
                let choice = Self.choices[index]
                Button {
                    session.speedFactor = choice.factor
                    showsChoices = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .opacity(choice.factor == selected ? 1 : 0)
                        Text(choice.label)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(choice.factor == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(width: 112)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    static func label(for factor: Double) -> String {
        if let choice = choices.first(where: { $0.factor == factor }) { return choice.label }
        return "\(factor.formatted(.number.precision(.fractionLength(0...2))))×"
    }
}

/// The script's `#/label` text, such as "Waiting for pattern".
struct ScriptLabelBanner: View {
    let session: SimulationSession

    var body: some View {
        ZStack(alignment: .leading) {
            if let label = session.scriptLabel {
                Text(label)
                    .font(.subheadline)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 34)
                    .glass(in: Capsule())
                    .transition(.opacity)
                    .id(label)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: session.scriptLabel)
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

/// What is running, and how it is going. Opens and closes the Info panel.
struct TitleCapsule: View {
    let session: SimulationSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
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
            .padding(.leading, 16)
            .padding(.trailing, 36)
            .frame(height: 44)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 13)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glass(in: Capsule())
        .widthCap(300)
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
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .tintedGlass(.accentColor, in: Circle())
        .accessibilityLabel(running ? "Pause" : session.status == .paused ? "Resume" : "Run Again")
        .disabled(session.title == nil)
        .sensoryFeedback(.selection, trigger: running)
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
    var maxWidth = AtomCard.fullWidth

    var body: some View {
        if let atom = session.selectedAtom {
            AtomCard(atom: atom, units: session.stats.units, maxWidth: maxWidth,
                     onCenter: { model.centerOnSelectedAtom() },
                     onClose: { session.clearSelection() })
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// What the tapped atom is and where it is, in one row. The swatch is the
/// color the atom is drawn in; the renderer rings the atom itself.
struct AtomCard: View {
    static let fullWidth: CGFloat = 404

    let atom: AtomInfo
    let units: String
    /// Narrower than `fullWidth` (a side panel is open), the card drops
    /// the coordinates and keeps the name and its buttons.
    var maxWidth = AtomCard.fullWidth
    let onCenter: () -> Void
    let onClose: () -> Void

    var body: some View {
        let width = min(Self.fullWidth, maxWidth)
        HStack(spacing: 10) {
            Circle()
                .fill(swatch)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("ID \(atom.tag.formatted()) · type \(atom.type)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            if width >= 380 {
                HStack(spacing: 0) {
                    coordinate("x", atom.position.x)
                    coordinate("y", atom.position.y)
                    coordinate("z", atom.position.z)
                }
            }
            circleButton("scope", label: "Center", action: onCenter)
                .accessibilityHint("Turns the camera around this atom.")
            circleButton("xmark", label: "Deselect", action: onClose)
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(width: width, height: 56)
        .glass(in: Capsule())
    }

    private var name: String {
        atom.elementName ?? atom.typeName ?? "Type \(atom.type)"
    }

    private var swatch: Color {
        guard let c = atom.color else { return .gray }
        return Color(.sRGB, red: Double(c.x), green: Double(c.y), blue: Double(c.z))
    }

    private func coordinate(_ axis: String, _ value: Float) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Format.axis(axis, units: units))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(Format.number(Double(value)))
                .font(.footnote.monospacedDigit())
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(width: 48, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func circleButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Errors and script warnings, as glass banners under the title. Tapping a
/// warning dismisses it for this run.
struct RunMessages: View {
    let model: AppModel
    let session: SimulationSession
    @Binding var dismissed: Set<String>

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
        }
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// "The script finished · Run Again", bottom centre.
struct FinishedBanner: View {
    let session: SimulationSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text("The script finished")
            Text("·")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Button("Run Again") { session.restart() }
                .fontWeight(.semibold)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .glass(in: Capsule())
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
                Text("Starting \(session.title ?? "simulation")…")
                    .foregroundStyle(.secondary)
            } else if case .failed = session.status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("\(session.title ?? "The simulation") could not start.")
                    .foregroundStyle(.secondary)
                Button("Choose an Example") { model.showGallery() }
                    .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "atom")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                if session.title == nil && model.catalogError == nil {
                    Button("Choose an Example") { model.showGallery() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}
