import AtomifyEngine
import Foundation
import simd

/// The Atomify 2 dashboard controllers the app shows.
public enum DashboardPanelKind: String, Sendable, CaseIterable {
    case summary, thermometer, pressure, thermostat, angle, gravity, atomPosition
    case diffusionCoefficient, meanSquareDisplacement, volume
}

extension DashboardPanel {
    public var panelKind: DashboardPanelKind? { DashboardPanelKind(rawValue: kind) }

    public func string(_ key: String) -> String? {
        guard let value = parameters?[key], !value.isEmpty else { return nil }
        return value
    }

    /// A finite number setting ("341.53026").
    public func number(_ key: String) -> Double? {
        guard let text = parameters?[key], let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite else { return nil }
        return value
    }

    /// A "true" or "false" setting.
    public func flag(_ key: String) -> Bool? {
        switch parameters?[key]?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true"?: true
        case "false"?: false
        default: nil
        }
    }

    /// A list setting written as a JSON array of strings ("[\"blue\", \"red\"]").
    public func list(_ key: String) -> [String]? {
        guard let text = parameters?[key], let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
    }
}

/// Where a dashboard line's points come from. x is simulation time in the
/// run's units, y the value in the run's units.
public indirect enum DashboardSource: Hashable, Sendable {
    /// A component of a LAMMPS compute, fix, variable or thermo keyword.
    case observable(PlotSeriesKey)
    /// The angle at atom `tags.x` between atoms `tags.y` and `tags.z`, in
    /// degrees, measured by the app from each snapshot.
    case angle(SIMD3<Int64>)
    /// The box volume (area in 2D), from each snapshot.
    case volume
    /// The diffusion coefficient from a mean square displacement:
    /// MSD / (2 · dimension · time since the MSD started).
    case diffusion(msd: PlotSeriesKey)
    /// The mean of another source so far (Atomify 2's "Average" lines).
    case average(DashboardSource)

    /// The sources measured from snapshots rather than read from LAMMPS.
    public var isMeasured: Bool {
        switch self {
        case .angle, .volume: true
        case .observable, .diffusion: false
        case .average(let source): source.isMeasured
        }
    }

    /// The source without averaging.
    public var base: DashboardSource {
        if case .average(let source) = self { return source.base }
        return self
    }
}

/// One line of a dashboard chart.
public struct DashboardLine: Hashable, Sendable {
    public var title: String
    public var source: DashboardSource
    /// A color name from the example ("blue"), or nil for the default palette.
    public var color: String?

    public init(title: String, source: DashboardSource, color: String? = nil) {
        self.title = title
        self.source = source
        self.color = color
    }
}

/// A chart of an Atomify 2 controller, with its axis settings. Values are
/// shown multiplied by `xScale` and `yScale` (e.g. 1000 for ps → fs).
public struct DashboardChart: Hashable, Sendable {
    public var title: String
    public var xLabel: String
    public var yLabel: String
    public var xScale: Double
    public var yScale: Double
    /// The newest stretch of x shown, in scaled units; all of it when nil.
    public var xRange: Double?
    /// A fixed y axis in scaled units; automatic when nil.
    public var yDomain: ClosedRange<Double>?
    public var lines: [DashboardLine]
    /// A sentence under the chart, such as Atomify 2's angle title.
    public var note: String?

    public init(title: String, xLabel: String, yLabel: String, xScale: Double = 1, yScale: Double = 1,
                xRange: Double? = nil, yDomain: ClosedRange<Double>? = nil, lines: [DashboardLine],
                note: String? = nil) {
        self.title = title
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.xScale = xScale
        self.yScale = yScale
        self.xRange = xRange
        self.yDomain = yDomain
        self.lines = lines
        self.note = note
    }

    /// `points` scaled for display, keeping only the last `xRange`.
    public func displayed(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let scale = SIMD2(xScale, yScale)
        var scaled = points.map { $0 * scale }
        if let xRange, xRange > 0, let last = scaled.last?.x {
            let start = last - xRange
            if let first = scaled.firstIndex(where: { $0.x >= start }), first > 0 {
                scaled.removeFirst(first)
            }
        }
        return scaled
    }
}

/// Atomify 2's controllers as charts, controls and the LAMMPS commands they need.
public enum DashboardLayout {
    /// The mean square displacement compute the MSD and diffusion panels add.
    public static let msdComputeID = "atomify_msd"
    /// Its r² component (`c_atomify_msd[4]`).
    public static let msdKey = PlotSeriesKey(observableID: "c_\(msdComputeID)", component: 3)
    public static let temperatureKey = PlotSeriesKey(observableID: "c_thermo_temp")
    public static let pressureKey = PlotSeriesKey(observableID: "c_thermo_press")

    /// The panels for a run without its own: summary and temperature.
    public static let fallback = [DashboardPanel(kind: DashboardPanelKind.summary.rawValue),
                                  DashboardPanel(kind: DashboardPanelKind.thermometer.rawValue)]

    /// The chart a panel draws, or nil for panels that are controls or text.
    public static func chart(for panel: DashboardPanel) -> DashboardChart? {
        guard let kind = panel.panelKind else { return nil }
        func make(_ title: String, x: String, y: String, lines: [DashboardLine],
                  yDomain: ClosedRange<Double>? = nil, note: String? = nil) -> DashboardChart {
            DashboardChart(title: title, xLabel: panel.string("xLabel") ?? x, yLabel: panel.string("yLabel") ?? y,
                           xScale: positive(panel.number("xScale")) ?? 1, yScale: positive(panel.number("yScale")) ?? 1,
                           xRange: positive(panel.number("xRange")), yDomain: yDomain, lines: lines, note: note)
        }
        func instantaneousAndAverage(_ source: DashboardSource) -> [DashboardLine] {
            [DashboardLine(title: "Instantaneous", source: source),
             DashboardLine(title: "Average", source: .average(source))]
        }
        switch kind {
        case .summary, .thermostat, .gravity:
            return nil
        case .thermometer:
            return make("Temperature", x: "Time", y: "Temperature",
                        lines: instantaneousAndAverage(.observable(temperatureKey)))
        case .pressure:
            return make("Pressure", x: "Time", y: "Pressure [bar]",
                        lines: instantaneousAndAverage(.observable(pressureKey)))
        case .volume:
            return make("Volume", x: "t [ps]", y: "Volume [Å³]", lines: [DashboardLine(title: "Volume", source: .volume)])
        case .angle:
            guard let tags = angleTags(of: panel) else { return nil }
            let title = panel.string("title")
            return make("Angle", x: "t", y: "Angle θ [°]", lines: instantaneousAndAverage(.angle(tags)),
                        yDomain: 90...120, note: title == "Angle" ? nil : title)
        case .atomPosition:
            let colors = panel.list("colors") ?? []
            let lines = ["Left", "Right"].enumerated().map { index, title in
                DashboardLine(title: title,
                              source: .observable(PlotSeriesKey(observableID: "v_atomify_\(title.lowercased())")),
                              color: index < colors.count ? colors[index] : nil)
            }
            return make("Counter", x: "Time", y: "Count", lines: lines, yDomain: 0...100)
        case .meanSquareDisplacement:
            return make("Mean square displacement", x: "Time [ps]", y: "⟨r²(t)⟩ [Å²]",
                        lines: [DashboardLine(title: "MSD", source: .observable(msdKey))])
        case .diffusionCoefficient:
            return make("Diffusion coefficient", x: "Time [ps]", y: "Diffusion coefficient [Å²/time]",
                        lines: [DashboardLine(title: "D", source: .diffusion(msd: msdKey))])
        }
    }

    /// The three atom ids of an angle panel (vertex first), if valid.
    public static func angleTags(of panel: DashboardPanel) -> SIMD3<Int64>? {
        let ids = ["atom1", "atom2", "atom3"].compactMap { panel.number($0) }
        guard ids.count == 3, ids.allSatisfy({ $0 >= 1 && $0 == $0.rounded() && $0 < 1e15 }) else { return nil }
        return SIMD3(Int64(ids[0]), Int64(ids[1]), Int64(ids[2]))
    }

    /// Commands that set up what the panels read, run once the system has
    /// atoms (a compute needs the box).
    public static func setupCommands(for panels: [DashboardPanel]) -> [String] {
        let kinds = Set(panels.compactMap(\.panelKind))
        if kinds.contains(.meanSquareDisplacement) || kinds.contains(.diffusionCoefficient) {
            return ["compute \(msdComputeID) all msd"]
        }
        return []
    }

    /// Every source the panels draw, without duplicates, in order.
    public static func sources(for panels: [DashboardPanel]) -> [DashboardSource] {
        var seen = Set<DashboardSource>()
        var result: [DashboardSource] = []
        for chart in panels.compactMap(chart(for:)) {
            for line in chart.lines where seen.insert(line.source).inserted {
                result.append(line.source)
            }
        }
        return result
    }

    /// The thermostat panel's settings, if the panels have one.
    public static func thermostat(in panels: [DashboardPanel]) -> ThermostatPanel? {
        panels.first { $0.panelKind == .thermostat }.map { ThermostatPanel(panel: $0) }
    }

    /// The gravity panel's settings, if the panels have one.
    public static func gravity(in panels: [DashboardPanel]) -> GravityControl? {
        panels.first { $0.panelKind == .gravity }.map { GravityControl(panel: $0) }
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

/// An Atomify 2 thermostat panel: its slider range, display scale and
/// starting state, applied to the session's `Thermostat`.
public struct ThermostatPanel: Hashable, Sendable {
    /// The target's range in the run's units.
    public var range: ClosedRange<Double>
    /// Displayed values are run values times this (119.6 shows LJ units as K).
    public var unitScale: Double
    /// Damping time in the run's time units, or nil for the default.
    public var dampingTime: Double?
    public var startsEnabled: Bool
    /// The starting target in the run's units, or nil for the default.
    public var startTarget: Double?

    public init(range: ClosedRange<Double>, unitScale: Double = 1, dampingTime: Double? = nil,
                startsEnabled: Bool = false, startTarget: Double? = nil) {
        self.range = range
        self.unitScale = unitScale
        self.dampingTime = dampingTime
        self.startsEnabled = startsEnabled
        self.startTarget = startTarget
    }

    /// Atomify 2's settings: minimumValue and maximumValue are in displayed
    /// units (divided by unitScale for the run), the rest in run units.
    public init(panel: DashboardPanel) {
        let scale = panel.number("unitScale").flatMap { $0 > 0 ? $0 : nil } ?? 1
        let low = (panel.number("minimumValue") ?? 1) / scale
        let high = (panel.number("maximumValue") ?? 100) / scale
        self.init(range: min(low, high)...max(low, high), unitScale: scale,
                  dampingTime: panel.number("temperatureDampening").flatMap { $0 > 0 ? $0 : nil },
                  startsEnabled: panel.flag("nvtEnabled") ?? false,
                  startTarget: panel.number("targetTemperature"))
    }

    /// The target a run starts with: the panel's, else the session default, within the range.
    public func initialTarget(default value: Double) -> Double {
        let target = startTarget ?? value
        return min(max(target, range.lowerBound), range.upperBound)
    }
}

/// Atomify 2's gravity panel: a force along +z on the group `mobile`, which
/// the app adds, changes and removes with `fix gravity`.
public struct GravityControl: Hashable, Sendable {
    public static let fixID = "atomify_gravity"
    public static let removeCommand = "unfix \(fixID)"

    public var isEnabled: Bool
    /// Force per mass, in the run's units; negative pulls toward −z.
    public var magnitude: Double
    public var range: ClosedRange<Double>
    public var group: String

    public init(isEnabled: Bool = false, magnitude: Double = 1, range: ClosedRange<Double> = -1...1,
                group: String = "mobile") {
        self.isEnabled = isEnabled
        self.magnitude = magnitude
        self.range = range
        self.group = group
    }

    public init(panel: DashboardPanel) {
        let low = panel.number("minimumValue") ?? -1, high = panel.number("maximumValue") ?? 1
        let range = min(low, high)...max(low, high)
        let magnitude = panel.number("initialValue") ?? 1
        self.init(isEnabled: panel.flag("enabled") ?? false,
                  magnitude: min(max(magnitude, range.lowerBound), range.upperBound), range: range)
    }

    public var addCommand: String {
        "fix \(Self.fixID) \(group) gravity \(Thermostat.commandNumber(magnitude)) vector 0 0 1"
    }

    /// Commands that take a run with `old` applied to `new`.
    public static func commands(from old: GravityControl, to new: GravityControl) -> [String] {
        switch (old.isEnabled, new.isEnabled) {
        case (false, false): return []
        case (false, true): return [new.addCommand]
        case (true, false): return [removeCommand]
        case (true, true): return old.addCommand == new.addCommand ? [] : [removeCommand, new.addCommand]
        }
    }
}

/// What the dashboard measures from snapshots and derives from series.
public enum DashboardMeasure {
    /// The angle in degrees at atom `tags.x` between `tags.y` and `tags.z`,
    /// with periodic distances taken to the nearest image; nil when an atom
    /// is missing or two coincide.
    public static func angle(_ tags: SIMD3<Int64>, in frame: AtomFrame) -> Double? {
        guard let a = frame.index(ofTag: tags.x), let b = frame.index(ofTag: tags.y),
              let c = frame.index(ofTag: tags.z),
              [a, b, c].allSatisfy({ frame.positions.indices.contains($0) }) else { return nil }
        let size = frame.boxHigh - frame.boxLow
        func delta(_ from: Int, _ to: Int) -> SIMD3<Double> {
            var d = SIMD3<Double>(frame.positions[to]) - SIMD3<Double>(frame.positions[from])
            for axis in 0..<3 where axis < frame.periodic.count && frame.periodic[axis] && size[axis] > 0 {
                d[axis] -= size[axis] * (d[axis] / size[axis]).rounded()
            }
            return d
        }
        let u = delta(a, b), v = delta(a, c)
        let lengths = simd_length(u) * simd_length(v)
        guard lengths > 0, lengths.isFinite else { return nil }
        return acos(min(max(simd_dot(u, v) / lengths, -1), 1)) * 180 / .pi
    }

    /// The mean of the points so far at each time; non-finite values are skipped.
    public static func cumulativeAverage(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        var sum = 0.0, count = 0.0
        return points.map { point in
            if point.y.isFinite {
                sum += point.y
                count += 1
            }
            return SIMD2(point.x, count > 0 ? sum / count : .nan)
        }
    }

    /// D(t) = MSD / (2 · dimension · (t − t₀)), t₀ the first point's time;
    /// the first point (no time elapsed) is left out.
    public static func diffusion(fromMSD points: [SIMD2<Double>], dimension: Int) -> [SIMD2<Double>] {
        guard let start = points.first?.x else { return [] }
        let factor = 2 * Double(dimension == 2 ? 2 : 3)
        return points.compactMap { point in
            let elapsed = point.x - start
            guard elapsed > 0 else { return nil }
            return SIMD2(point.x, point.y / (factor * elapsed))
        }
    }
}
