import AtomifyKit
import SwiftUI

/// How the atoms look. A short first version; the full options follow.
struct ViewOptionsSheet: View {
    @Bindable var model: AppModel
    @Bindable var session: SimulationSession
    @AppStorage(SettingsKey.showPerformance) private var showPerformance = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $model.qualityPolicy.mode) {
                        ForEach(QualityPolicy.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Quality")
                } footer: {
                    Text("Automatic draws shadows and outlines below 50,000 atoms, and saves battery above.")
                }
                Section {
                    Toggle("Bonds", isOn: $session.showBonds)
                    Toggle("Simulation box", isOn: $session.showBox)
                    Toggle("Performance overlay", isOn: $showPerformance)
                }
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
}
