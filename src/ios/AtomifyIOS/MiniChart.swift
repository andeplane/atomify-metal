import AtomifyKit
import Charts
import SwiftUI

/// A small live chart in the corner of the simulation, for an example that
/// asks for one (`"effects": [{"kind": "chart", "series": "Temperature"}]`):
/// the first line of that dashboard chart, so a quantity such as the heat of
/// an explosion is in view without opening the Dashboard.
struct MiniChart: View {
    let chart: DashboardChart
    let data: [DashboardSource: [SIMD2<Double>]]

    private struct Point: Identifiable {
        let id: Int
        let x: Double
        let y: Double
    }

    static let size = CGSize(width: 190, height: 96)

    var body: some View {
        let line = chart.lines.first
        let points = line.map { chart.displayed(data[$0.source] ?? []) } ?? []
        let shown = points.enumerated().compactMap { index, point -> Point? in
            point.x.isFinite && point.y.isFinite ? Point(id: index, x: point.x, y: point.y) : nil
        }
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(chart.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let last = shown.last {
                    Text(Self.value(last.y))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
            if shown.count > 1 {
                Chart(shown) { point in
                    LineMark(x: .value("x", point.x), y: .value("y", point.y))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartXScale(domain: Self.domain(shown.map(\.x)))
                .chartYScale(domain: Self.domain(shown.map(\.y), padding: 0.1))
                .clipped()
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.size.width, height: Self.size.height)
        .glass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.title)
        .accessibilityValue(shown.last.map { Self.value($0.y) } ?? "")
    }

    /// A value for the corner: whole numbers from 100 up, one decimal below.
    static func value(_ value: Double) -> String {
        abs(value) >= 100 ? value.formatted(.number.precision(.fractionLength(0))) : Format.decimal(value)
    }

    /// The range of `values`, widened by `padding` of its span; never empty.
    static func domain(_ values: [Double], padding: Double = 0) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = high - low
        guard span > 0 else { return (low - 1)...(high + 1) }
        return (low - span * padding)...(high + span * padding)
    }
}
