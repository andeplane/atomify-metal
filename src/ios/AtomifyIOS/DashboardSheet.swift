import AtomifyKit
import Charts
import SwiftUI

/// The example's dashboard, as Atomify 2 showed it: a card per controller
/// (summary, charts of temperature, pressure, angles and more, and the
/// thermostat and force controls), in the example's order.
struct DashboardSheet: View {
    let session: SimulationSession

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(session.dashboard.enumerated()), id: \.offset) { _, panel in
                DashboardPanelView(session: session, panel: panel)
            }
        }
    }
}

/// One panel: a chart, the summary, or a control.
private struct DashboardPanelView: View {
    let session: SimulationSession
    let panel: DashboardPanel

    var body: some View {
        switch panel.panelKind {
        case .summary:
            SummaryCard(session: session)
        case .thermostat:
            ThermostatCard(session: session)
        case .gravity:
            GravityCard(session: session)
        case .some:
            if let chart = DashboardLayout.chart(for: panel) {
                ChartCard(chart: chart, data: session.dashboardData)
            }
        case nil:
            EmptyView()
        }
    }
}

/// A titled rounded card.
private struct DashboardCard<Content: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title)
            } icon: {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.tint) }
            }
            .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Atomify 2's summary: size, atoms, types, steps and speed.
private struct SummaryCard: View {
    let session: SimulationSession

    var body: some View {
        let stats = session.stats
        DashboardCard(title: "Summary", systemImage: "info.circle") {
            VStack(spacing: 6) {
                row("Status", session.status.label)
                row("System size", sizeText(stats))
                row(stats.dimension == 2 ? "Area" : "Volume", Format.number(stats.volume))
                row("Atoms", stats.atoms.formatted())
                if stats.bonds > 0 { row("Bonds", stats.bonds.formatted()) }
                row("Atom types", stats.typeCount.formatted())
                row("Timesteps", stats.timestep.formatted())
                row("Temperature", Format.temperature(stats.temperature, units: stats.units))
                row("Performance", "\(Format.count(stats.stepsPerSecond)) steps/s")
                if !stats.units.isEmpty { row("Units", stats.units) }
            }
            .font(.callout)
            .monospacedDigit()
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func sizeText(_ stats: SessionStats) -> String {
        let size = stats.boxSize
        let parts = (stats.dimension == 2 ? [size.x, size.y] : [size.x, size.y, size.z]).map { Format.number($0) }
        return "(" + parts.joined(separator: ", ") + ")"
    }
}

/// A chart of one controller, with the latest value of each line.
private struct ChartCard: View {
    let chart: DashboardChart
    let data: [DashboardSource: [SIMD2<Double>]]

    private struct Point: Identifiable {
        let id: Int
        let line: String
        let x: Double
        let y: Double
    }

    var body: some View {
        let series = chart.lines.map { (line: $0, points: chart.displayed(data[$0.source] ?? [])) }
        let points = Self.points(series)
        DashboardCard(title: chart.title, systemImage: "chart.xyaxis.line") {
            if points.isEmpty {
                Text("Waiting for data…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                HStack(spacing: 14) {
                    ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                        if let last = entry.points.last {
                            HStack(spacing: 5) {
                                Circle().fill(color(index)).frame(width: 8, height: 8)
                                Text(entry.line.title).foregroundStyle(.secondary)
                                Text(Format.decimal(last.y)).monospacedDigit()
                            }
                        }
                    }
                }
                .font(.caption)
                Chart(points) { point in
                    LineMark(x: .value(chart.xLabel, point.x), y: .value(chart.yLabel, point.y))
                        .foregroundStyle(by: .value("Line", point.line))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartForegroundStyleScale(domain: chart.lines.map(\.title),
                                           range: chart.lines.indices.map { color($0) })
                .chartLegend(.hidden)
                .chartXScale(domain: Self.domain(points.map(\.x), fixed: nil))
                .chartYScale(domain: Self.domain(points.map(\.y), fixed: chart.yDomain))
                .chartXAxisLabel(chart.xLabel)
                .chartYAxisLabel(chart.yLabel)
                .frame(height: 180)
            }
            if let note = chart.note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ index: Int) -> Color {
        if index < chart.lines.count, let name = chart.lines[index].color, let named = Self.named[name.lowercased()] {
            return named
        }
        return Self.palette[index % Self.palette.count]
    }

    private static let palette: [Color] = [.cyan, .orange, .green, .pink]
    private static let named: [String: Color] = [
        "blue": .blue, "red": .red, "green": .green, "orange": .orange, "yellow": .yellow,
        "purple": .purple, "white": .white, "cyan": .cyan, "pink": .pink,
    ]

    private static func points(_ series: [(line: DashboardLine, points: [SIMD2<Double>])]) -> [Point] {
        var result: [Point] = []
        for entry in series {
            for point in entry.points where point.x.isFinite && point.y.isFinite {
                result.append(Point(id: result.count, line: entry.line.title, x: point.x, y: point.y))
            }
        }
        return result
    }

    /// The fixed range, or the data's range with a little room, never empty.
    private static func domain(_ values: [Double], fixed: ClosedRange<Double>?) -> ClosedRange<Double> {
        if let fixed { return fixed }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = high - low
        let pad = span > 0 ? span * 0.08 : max(abs(high) * 0.05, 1e-6)
        return (low - pad)...(high + pad)
    }
}

/// Atomify 2's thermostat: on or off and a target, in the panel's units.
private struct ThermostatCard: View {
    let session: SimulationSession
    /// The target while the slider is dragged; applied on release, since
    /// each change replaces the LAMMPS fix.
    @State private var draft: Double?

    var body: some View {
        let thermostat = session.thermostat
        let scale = session.thermostatPanel?.unitScale ?? 1
        let range = session.thermostatRange
        let units = session.stats.units
        DashboardCard(title: "Thermostat", systemImage: "thermometer.medium") {
            Toggle("Enabled", isOn: Binding(
                get: { session.thermostat.isEnabled },
                set: { session.thermostat.isEnabled = $0 }
            ))
            .disabled(!session.status.isActive)
            HStack {
                Text("Target")
                Spacer()
                Text(display(draft ?? thermostat.target, scale: scale, units: units))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { draft ?? session.thermostat.target },
                set: { draft = $0 }
            ), in: range) {
                Text("Target temperature")
            } minimumValueLabel: {
                Text(display(range.lowerBound, scale: scale, units: units)).font(.caption2)
            } maximumValueLabel: {
                Text(display(range.upperBound, scale: scale, units: units)).font(.caption2)
            } onEditingChanged: { editing in
                guard !editing, let value = draft else { return }
                session.thermostat.target = value
                draft = nil
            }
        }
    }

    /// With a unit scale the panel shows kelvin; otherwise the run's units.
    private func display(_ value: Double, scale: Double, units: String) -> String {
        if scale != 1 { return "\(Format.number(value * scale)) K" }
        return Format.temperature(value, units: units)
    }
}

/// Atomify 2's force panel: gravity along z on the moving atoms.
private struct GravityCard: View {
    let session: SimulationSession
    /// The magnitude while the slider is dragged; applied on release.
    @State private var draft: Double?

    var body: some View {
        if let gravity = session.gravity {
            DashboardCard(title: "Force", systemImage: "arrow.up.circle") {
                Toggle("Enabled", isOn: Binding(
                    get: { session.gravity?.isEnabled ?? false },
                    set: { enabled in
                        if var gravity = session.gravity {
                            gravity.isEnabled = enabled
                            session.gravity = gravity
                        }
                    }
                ))
                .disabled(!session.status.isActive)
                HStack {
                    Text("Magnitude")
                    Spacer()
                    Text(Format.decimal(draft ?? gravity.magnitude))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { draft ?? session.gravity?.magnitude ?? 0 },
                    set: { draft = $0 }
                ), in: gravity.range, step: 0.05) {
                    Text("Magnitude")
                } onEditingChanged: { editing in
                    guard !editing, let value = draft else { return }
                    if var gravity = session.gravity {
                        gravity.magnitude = value
                        session.gravity = gravity
                    }
                    draft = nil
                }
                Text("Pushes the atoms along +z; negative values pull them back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
