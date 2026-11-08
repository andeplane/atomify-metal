/// A global array of a compute or fix (e.g. compute rdf), row major.
public struct ObservableTable: Sendable, Equatable {
    public var rows: Int
    public var columns: Int
    public var values: [Double]

    public init(rows: Int, columns: Int, values: [Double]) {
        self.rows = rows; self.columns = columns; self.values = values
    }

    public subscript(row: Int, column: Int) -> Double { values[row * columns + column] }

    /// One column for all rows, or [] if out of range.
    public func column(_ column: Int) -> [Double] {
        guard column >= 0, column < columns, values.count >= rows * columns else { return [] }
        return (0..<rows).map { values[$0 * columns + column] }
    }
}

/// A compute, fix, variable or thermo keyword of the running simulation with
/// its current global values (for live plots), and the per-atom quantities
/// it provides (for coloring).
public struct Observable: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case thermo, compute, fix, variable

        /// The prefix LAMMPS uses for references ("c_", "f_", "v_"), or "thermo_".
        public var prefix: String {
            switch self {
            case .thermo: "thermo_"
            case .compute: "c_"
            case .fix: "f_"
            case .variable: "v_"
            }
        }
    }

    /// "c_temp", "f_ave", "v_msd", "thermo_temp".
    public var id: String
    public var kind: Kind
    /// LAMMPS ID, variable name or thermo keyword.
    public var name: String
    /// Compute or fix style ("msd") or variable style ("equal"); nil for thermo keywords.
    public var style: String?
    /// The global scalar (if any) followed by the global vector (if any).
    public var values: [Double]
    /// One label per value: the id for the scalar, "id[n]" (1-based) for vector components.
    public var labels: [String]
    /// Names of per-atom quantities this provides, e.g. ["c_ke"] or ["c_stress[1]", ...],
    /// usable with `Simulation.setPerAtomQuantity`.
    public var perAtomNames: [String]
    /// The step the values were computed on; nil if they never were.
    public var timestep: Int64?
    /// Simulation time at `timestep`.
    public var time: Double
    /// The global array, if any.
    public var table: ObservableTable?

    public init(kind: Kind, name: String, style: String? = nil, values: [Double] = [], labels: [String]? = nil,
                perAtomNames: [String] = [], timestep: Int64? = nil, time: Double = 0,
                table: ObservableTable? = nil) {
        let id = Self.id(kind: kind, name: name)
        self.id = id
        self.kind = kind
        self.name = name
        self.style = style
        self.values = values
        self.labels = labels ?? Self.labels(id: id, count: values.count, hasScalar: values.count == 1)
        self.perAtomNames = perAtomNames
        self.timestep = timestep
        self.time = time
        self.table = table
    }

    /// The identifier for an observable of this kind and name.
    public static func id(kind: Kind, name: String) -> String { kind.prefix + name }

    /// Labels for a scalar (the id) followed by vector components id[1]...
    public static func labels(id: String, count: Int, hasScalar: Bool) -> [String] {
        guard count > 0 else { return [] }
        let vectorCount = hasScalar ? count - 1 : count
        return (hasScalar ? [id] : []) + (0..<vectorCount).map { "\(id)[\($0 + 1)]" }
    }

    /// Per-atom quantity names for an ID with this many per-atom columns
    /// (0 for a per-atom vector).
    public static func perAtomNames(id: String, columns: Int) -> [String] {
        columns > 0 ? (1...columns).map { "\(id)[\($0)]" } : [id]
    }

    /// The scalar, if the observable has one and it was computed.
    public var scalar: Double? {
        guard let first = labels.first, first == id, let value = values.first else { return nil }
        return value
    }

    /// Whether the observable has values to plot.
    public var hasValues: Bool { timestep != nil && !values.isEmpty }
}

/// Records observables over time for plotting: one point per observable
/// each time it was computed on a new step. Not thread safe.
public final class ObservableHistory {
    private struct Series {
        var labels: [String]
        var times: [Double] = []
        var components: [[Double]]
        var lastTimestep: Int64

        init(labels: [String], count: Int, timestep: Int64) {
            self.labels = labels
            self.components = Array(repeating: [], count: count)
            self.lastTimestep = timestep
        }
    }

    /// Points kept per observable; the oldest are dropped first.
    public let capacity: Int
    private var storage: [String: Series] = [:]
    private var order: [String] = []

    public init(capacity: Int = 10_000) {
        self.capacity = max(1, capacity)
    }

    /// Adds a point for every observable computed on a step not recorded yet.
    public func record(_ snapshot: SimulationSnapshot) {
        for observable in snapshot.observables {
            guard let timestep = observable.timestep, !observable.values.isEmpty else { continue }
            if var series = storage[observable.id] {
                // Same step as last time: nothing new (values are carried between samples).
                guard series.lastTimestep != timestep else { continue }
                if series.components.count != observable.values.count {
                    // The vector changed length (e.g. a redefined compute): start over.
                    series = Series(labels: observable.labels, count: observable.values.count, timestep: timestep)
                }
                append(observable, to: &series, timestep: timestep)
                storage[observable.id] = series
            } else {
                var series = Series(labels: observable.labels, count: observable.values.count, timestep: timestep)
                append(observable, to: &series, timestep: timestep)
                storage[observable.id] = series
                order.append(observable.id)
            }
        }
    }

    private func append(_ observable: Observable, to series: inout Series, timestep: Int64) {
        series.lastTimestep = timestep
        series.labels = observable.labels
        series.times.append(observable.time)
        for (index, value) in observable.values.enumerated() { series.components[index].append(value) }
        // Trim in batches so recording stays cheap at capacity.
        let excess = series.times.count - capacity
        if excess >= max(1, capacity / 8) {
            series.times.removeFirst(excess)
            for index in series.components.indices { series.components[index].removeFirst(excess) }
        }
    }

    /// (time, value) points of one component (0 is the first value), oldest first.
    public func series(id: String, component: Int = 0) -> [SIMD2<Double>] {
        guard let series = storage[id], component >= 0, component < series.components.count else { return [] }
        let values = series.components[component]
        let count = min(series.times.count, values.count, capacity)
        let start = series.times.count - count
        return (0..<count).map { SIMD2(series.times[start + $0], values[values.count - count + $0]) }
    }

    /// Labels of the components of an observable, as last recorded.
    public func labels(id: String) -> [String] { storage[id]?.labels ?? [] }

    /// Ids with recorded points, in the order they first appeared.
    public var ids: [String] { order }

    public func reset() {
        storage.removeAll()
        order.removeAll()
    }
}
