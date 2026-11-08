import AtomifyEngine

/// One plottable line: a component of an observable's global value.
public struct PlotSeriesKey: Hashable, Sendable, Comparable {
    /// `Observable.id`, e.g. "thermo_temp", "c_msd", "v_diffusion".
    public var observableID: String
    /// Index into the observable's values.
    public var component: Int

    public init(observableID: String, component: Int = 0) {
        self.observableID = observableID
        self.component = component
    }

    public static func < (lhs: PlotSeriesKey, rhs: PlotSeriesKey) -> Bool {
        (lhs.observableID, lhs.component) < (rhs.observableID, rhs.component)
    }
}

/// The parts of an `Observable` the plot list needs, as a plain value.
public struct ObservableInfo: Sendable, Equatable {
    public var id: String
    public var kind: AtomifyEngine.Observable.Kind
    public var name: String
    public var style: String?
    public var labels: [String]
    public var valueCount: Int

    public init(id: String, kind: AtomifyEngine.Observable.Kind, name: String, style: String? = nil,
                labels: [String] = [], valueCount: Int = 1) {
        self.id = id
        self.kind = kind
        self.name = name
        self.style = style
        self.labels = labels
        self.valueCount = valueCount
    }

    public init(_ observable: AtomifyEngine.Observable) {
        self.init(id: observable.id, kind: observable.kind, name: observable.name, style: observable.style,
                  labels: observable.labels, valueCount: observable.values.count)
    }
}

/// An entry in the "add plot" list.
public struct PlotOption: Hashable, Sendable, Identifiable {
    public var key: PlotSeriesKey
    /// "Temperature", "c_msd[4]", "v_diffusion"
    public var title: String
    /// "Thermo", "Computes", "Fixes" or "Variables".
    public var group: String
    public var id: PlotSeriesKey { key }

    public init(key: PlotSeriesKey, title: String, group: String) {
        self.key = key
        self.title = title
        self.group = group
    }
}

public enum PlotCatalog {
    /// Readable names for common thermo keywords.
    public static let thermoTitles: [String: String] = [
        "temp": "Temperature", "pe": "Potential energy", "ke": "Kinetic energy", "etotal": "Total energy",
        "press": "Pressure", "vol": "Volume", "enthalpy": "Enthalpy", "evdwl": "Van der Waals energy",
        "ecoul": "Coulomb energy", "epair": "Pair energy", "ebond": "Bond energy", "eangle": "Angle energy",
        "edihed": "Dihedral energy", "elong": "Long-range energy", "density": "Density",
    ]

    /// Plotted when a run starts, if the run has them: temperature and energies.
    public static let defaultThermo = ["temp", "pe", "ke", "etotal"]

    public static let groups = ["Thermo", "Computes", "Fixes", "Variables"]

    public static func group(of kind: AtomifyEngine.Observable.Kind) -> String {
        switch kind {
        case .thermo: "Thermo"
        case .compute: "Computes"
        case .fix: "Fixes"
        case .variable: "Variables"
        }
    }

    /// One option per component of each observable, grouped by kind in
    /// `groups` order, otherwise in the given order.
    public static func options(from observables: [ObservableInfo]) -> [PlotOption] {
        var options: [PlotOption] = []
        for group in groups {
            for observable in observables where Self.group(of: observable.kind) == group {
                for component in 0..<max(observable.valueCount, 0) {
                    options.append(PlotOption(key: PlotSeriesKey(observableID: observable.id, component: component),
                                              title: title(of: observable, component: component), group: group))
                }
            }
        }
        return options
    }

    /// "Temperature" for thermo temp, "c_msd[4]" for a vector component
    /// (LAMMPS numbers components from 1), with its label when it has one.
    public static func title(of observable: ObservableInfo, component: Int) -> String {
        let base = observable.kind == .thermo ? (thermoTitles[observable.name] ?? observable.name) : observable.id
        let label = component < observable.labels.count ? observable.labels[component] : ""
        if observable.valueCount <= 1 {
            return base
        }
        let indexed = "\(base)[\(component + 1)]"
        return label.isEmpty || label == indexed ? indexed : "\(indexed) \(label)"
    }

    /// The default plots among `options`: thermo temperature and energies.
    public static func defaultSelection(from observables: [ObservableInfo]) -> [PlotSeriesKey] {
        defaultThermo.compactMap { name in
            observables.first { $0.kind == .thermo && $0.name == name && $0.valueCount > 0 }
                .map { PlotSeriesKey(observableID: $0.id) }
        }
    }

    /// The mean of each point and the `window - 1` before it (fewer at the
    /// start), at the same times: an average line to draw over a noisy
    /// series. Non-finite values are left out of the means; a window of 1 or
    /// less returns the points unchanged.
    public static func runningAverage(_ points: [SIMD2<Double>], window: Int) -> [SIMD2<Double>] {
        guard window > 1 else { return points }
        var result: [SIMD2<Double>] = []
        result.reserveCapacity(points.count)
        var sum = 0.0
        var count = 0
        for i in points.indices {
            let value = points[i].y
            if value.isFinite {
                sum += value
                count += 1
            }
            if i >= window {
                let old = points[i - window].y
                if old.isFinite {
                    sum -= old
                    count -= 1
                }
            }
            result.append(SIMD2(points[i].x, count > 0 ? sum / Double(count) : .nan))
        }
        return result
    }

    /// At most `maxPoints` evenly strided points, always keeping the last one,
    /// so a long history stays cheap to draw.
    public static func downsample<Point>(_ points: [Point], maxPoints: Int) -> [Point] {
        guard maxPoints > 0 else { return [] }
        guard points.count > maxPoints else { return points }
        if maxPoints == 1 { return [points[points.count - 1]] }
        let step = Int((Double(points.count - 1) / Double(maxPoints - 1)).rounded(.up))
        var result = Swift.stride(from: 0, to: points.count - 1, by: step).map { points[$0] }
        result.append(points[points.count - 1])
        return result
    }
}

/// LAMMPS output for a console, keeping the last `maxLines` lines.
public struct ConsoleLog: Sendable, Equatable {
    public let maxLines: Int
    public private(set) var lines: [String] = []
    /// Text after the last newline, shown as the last line.
    public private(set) var pending = ""
    /// Bumped on every change, so views can scroll to the end.
    public private(set) var revision = 0

    public init(maxLines: Int = 2000) {
        self.maxLines = max(maxLines, 1)
    }

    public mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        // "\r\n" is a single Character in Swift, so split on it explicitly.
        let parts = (pending + text).split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        pending = String(parts[parts.count - 1])
        lines.append(contentsOf: parts.dropLast().map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) })
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        revision += 1
    }

    public mutating func clear() {
        lines = []
        pending = ""
        revision += 1
    }

    public var text: String {
        pending.isEmpty ? lines.joined(separator: "\n") : (lines + [pending]).joined(separator: "\n")
    }
}

/// Events per second over a sliding window (frames, snapshots).
public struct RateMeter: Sendable, Equatable {
    public let window: Double
    private var times: [Double] = []

    public init(window: Double = 1) {
        self.window = window
    }

    /// Records an event at `time` seconds (monotonic).
    public mutating func tick(at time: Double) {
        times.append(time)
        let cutoff = time - window
        if let first = times.firstIndex(where: { $0 >= cutoff }), first > 0 {
            times.removeFirst(first)
        }
    }

    /// Events per second, 0 until two events are in the window.
    public var rate: Double {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }
}
