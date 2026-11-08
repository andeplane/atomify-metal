import AtomifyVision
import SwiftUI

/// The compact panel beside the lab: what is running, its temperature, the
/// few controls that matter and one line on what to try. No scrolling,
/// menus or hidden sections.
struct ControlsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    static let width: CGFloat = 840

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .center, spacing: 24) {
                heading.layoutPriority(1)
                Spacer(minLength: 0)
                backButton
            }
            controls
            status
            tip
        }
        .padding(32)
        .frame(width: Self.width, alignment: .leading)
        .animation(.default, value: model.tips.current)
        // The Digital Crown recenters the experiment as well as the panel.
        .onWorldRecenter { phase in if phase == .ended { model.requestRecenter() } }
    }

    /// The in-context tip while there is one to learn, then the short
    /// reminder of what hands do.
    @ViewBuilder private var tip: some View {
        if let tip = model.tips.current {
            Label(tip.text, systemImage: tip.systemImage)
                .font(.title3.weight(.medium))
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.thinMaterial, in: .capsule)
                .transition(.opacity)
                .id(tip.text)
        } else {
            Text("One hand: pinch an atom to pull it. Two hands: pinch to move, turn and resize.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.run?.title ?? "")
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(model.temperatureText ?? " ")
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityLabel(model.temperatureText.map { "Temperature \($0)" } ?? "")
        }
    }

    private var controls: some View {
        @Bindable var model = model
        return HStack(spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    model.isPaused.toggle()
                } label: {
                    Label(model.isPaused ? "Play" : "Pause", systemImage: model.isPaused ? "play.fill" : "pause.fill")
                        .frame(width: 28)
                }
                .help(model.isPaused ? "Play" : "Pause")
                .disabled(model.hasFinished || model.errorMessage != nil || model.isStopping)

                Button {
                    model.restart()
                } label: {
                    Label("Restart", systemImage: "arrow.counterclockwise")
                        .frame(width: 28)
                }
                .help("Restart")
                .disabled(model.isStopping)
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)

            Picker("Speed", selection: $model.speed) {
                ForEach(AppModel.Speed.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Simulation speed")

            Button("Recenter", systemImage: "scope") { model.requestRecenter() }
                .help("Place the experiment in front of you again")
        }
        .controlSize(.large)
    }

    private var backButton: some View {
        Button("Back to Experiences", systemImage: "chevron.backward") {
            Task { await close() }
        }
        .controlSize(.large)
        .help("Leave the lab and return to the experiences")
    }

    /// One line: what to try, that the experiment is getting ready, or what
    /// went wrong and how to recover.
    @ViewBuilder private var status: some View {
        HStack(spacing: 16) {
            if let error = model.errorMessage {
                Label {
                    Text([error, model.recoveryMessage].compactMap { $0 }.joined(separator: " "))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .foregroundStyle(.orange)
                Spacer(minLength: 0)
                restartButton
            } else if model.hasFinished {
                Label(model.recoveryMessage ?? "The experiment has ended.", systemImage: "checkmark.circle")
                Spacer(minLength: 0)
                restartButton
            } else if model.isPreparing {
                Label("Preparing…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if let hint = model.run?.demo.hint ?? model.run?.demo.summary {
                Text(hint)
            }
        }
        .font(.title3.weight(.regular))
        .lineLimit(2)
        .frame(minHeight: 44, alignment: .leading)
    }

    private var restartButton: some View {
        Button("Restart", systemImage: "arrow.counterclockwise") { model.restart() }
            .disabled(model.isStopping)
    }

    /// Dismissing the space runs the lab's one exit path: stop the run,
    /// reopen the experiences and close this panel.
    private func close() async {
        if model.labIsOpen {
            await dismissImmersiveSpace()
        } else {
            model.stop()
            openWindow(id: AppModel.windowID)
            dismissWindow(id: AppModel.controlsWindowID)
        }
    }
}
