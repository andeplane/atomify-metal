import AtomifyKit
import SwiftUI

/// Numbers while the simulation runs. A short first version; plots and
/// controls follow.
struct DashboardSheet: View {
    let session: SimulationSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                let stats = session.stats
                Section("Overview") {
                    LabeledContent("Status", value: session.status.label)
                    LabeledContent("Atoms", value: stats.atoms.formatted())
                    if stats.bonds > 0 {
                        LabeledContent("Bonds", value: stats.bonds.formatted())
                    }
                    LabeledContent("Temperature", value: Format.temperature(stats.temperature, units: stats.units))
                    LabeledContent("Timestep", value: stats.timestep.formatted())
                    LabeledContent("Steps per second", value: Format.count(stats.stepsPerSecond))
                    if !stats.units.isEmpty {
                        LabeledContent("Units", value: stats.units)
                    }
                }
            }
            .monospacedDigit()
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
