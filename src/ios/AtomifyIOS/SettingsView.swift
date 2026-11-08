import AtomifyKit
import SwiftUI

/// Settings, pushed from the gallery: who made Atomify on the leading side,
/// playback, the performance overlay, the welcome and the
/// acknowledgements on the trailing side.
struct SettingsView: View {
    let model: AppModel
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                AboutColumn()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .contentMargins(.bottom, 24, for: .scrollContent)
            .frame(width: metrics.detailLeading)
            .frame(maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)

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
                    .pickerStyle(.menu)
                    Toggle("Performance overlay", isOn: $showPerformance)
                } header: {
                    Text("Simulation")
                } footer: {
                    Text("Speed is relative to each example's own pace, as in Atomify 2.")
                }

                Section("About") {
                    Button("Show Welcome") {
                        model.showsWelcome = true
                        model.returnToSimulation()
                    }
                    NavigationLink("Acknowledgements", value: ExampleRoute.acknowledgements)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 42)
            .contentMargins(.top, 8, for: .scrollContent)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .scrollIndicatorsFlash(onAppear: true)
            .frame(maxWidth: 420, maxHeight: .infinity)
            // Rows scroll under the home indicator and end above it.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .safeAreaPadding(.horizontal, metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "5.0 (1)" from the bundle.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

/// The app, its version, who made it and links.
private struct AboutColumn: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image("WaterMolecule")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(9)
                    .frame(width: 60, height: 60)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Atomify")
                        .font(.title2.bold())
                    Text("Version \(SettingsView.version)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Text("""
                Atomify simulates atoms and molecules with LAMMPS, the molecular dynamics code from \
                Sandia National Laboratories, and draws them with Metal. The examples come from \
                Atomify 2 by Anders Hafreager and Svenn-Arne Dragly at the University of Oslo.
                """)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Link(destination: URL(string: "https://www.lammps.org")!) {
                    Text("LAMMPS \(Image(systemName: "arrow.up.right"))")
                }
                Link(destination: URL(string: "https://github.com/ovilab/atomify")!) {
                    Text("Atomify on GitHub \(Image(systemName: "arrow.up.right"))")
                }
            }
            .font(.subheadline)
        }
    }
}

/// What Atomify is built on, with licenses.
struct AcknowledgementsView: View {
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
