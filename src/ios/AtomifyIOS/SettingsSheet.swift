import AtomifyKit
import SwiftUI

/// App settings and about: playback, the performance overlay, the welcome,
/// and who made Atomify with what.
struct SettingsSheet: View {
    let model: AppModel
    /// Set when the welcome should show once this sheet is gone.
    @Binding var wantsWelcome: Bool
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Playback speed", selection: Binding(
                        get: { SpeedMenu.choices.firstIndex { $0.factor == model.session.speedFactor } ?? 2 },
                        set: { model.session.speedFactor = SpeedMenu.choices[$0].factor }
                    )) {
                        ForEach(SpeedMenu.choices.indices, id: \.self) { index in
                            Text(SpeedMenu.choices[index].label).tag(index)
                        }
                    }
                    Toggle("Performance overlay", isOn: $showPerformance)
                } header: {
                    Text("Simulation")
                } footer: {
                    Text("Speed is relative to each example's own pace, as in Atomify 2 (Max runs as fast as the "
                         + "device can). The overlay shows frames and steps per second over the atoms.")
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    Button("Show Welcome") {
                        wantsWelcome = true
                        dismiss()
                    }
                    NavigationLink("Acknowledgements") {
                        AcknowledgementsView()
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Atomify")
                            .font(.headline)
                        Text("""
                            Atomify simulates atoms and molecules with LAMMPS, the molecular dynamics code from \
                            Sandia National Laboratories, and draws them with Metal. The examples come from \
                            Atomify 2 by Anders Hafreager and Svenn-Arne Dragly at the University of Oslo.
                            """)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                    Link(destination: URL(string: "https://www.lammps.org")!) {
                        Label("LAMMPS", systemImage: "arrow.up.right.square")
                    }
                    Link(destination: URL(string: "https://github.com/ovilab/atomify")!) {
                        Label("Atomify 2 on GitHub", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// "5.0 (1)" from the bundle.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// What Atomify is built on, with licenses.
private struct AcknowledgementsView: View {
    var body: some View {
        List {
            entry("LAMMPS",
                  "Large-scale Atomic/Molecular Massively Parallel Simulator, Sandia National Laboratories. "
                  + "GNU General Public License, version 2.",
                  link: "https://www.lammps.org")
            entry("Atomify 2",
                  "The examples, their descriptions, cameras and dashboards, by Anders Hafreager and "
                  + "Svenn-Arne Dragly, University of Oslo. GNU General Public License, version 3.",
                  link: "https://github.com/ovilab/atomify")
            entry("Potentials",
                  "The examples' force fields (ReaxFF, Tersoff, Vashishta, SW and others) come from the "
                  + "LAMMPS potentials folder and the papers cited in each file.",
                  link: nil)
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func entry(_ title: String, _ text: String, link: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let link, let url = URL(string: link) {
                Link(link, destination: url)
                    .font(.callout)
            }
        }
        .padding(.vertical, 4)
    }
}
