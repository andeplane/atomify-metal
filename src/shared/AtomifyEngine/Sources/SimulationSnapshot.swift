import CLammps
import simd

/// What LAMMPS is doing when a snapshot is published.
public enum RunMode: Int, Sendable {
    /// Between commands (e.g. after the script, or while a script sets up).
    case idle = 0
    /// A `run`.
    case dynamics = 1
    /// A `minimize`.
    case minimize = 2
}

/// A plane of a `fix wall/*` command (lj93, lj126, harmonic, ...) at a fixed
/// position: on a box face or at a constant coordinate.
public struct WallPlane: Sendable, Equatable {
    /// 0 xlo, 1 xhi, 2 ylo, 3 yhi, 4 zlo, 5 zhi.
    public var face: Int
    /// Coordinate along `axis` in simulation units.
    public var position: Double

    public init(face: Int, position: Double) {
        self.face = face; self.position = position
    }

    /// 0, 1 or 2 for x, y or z.
    public var axis: Int { face / 2 }
    /// True for xhi, yhi and zhi walls.
    public var isUpper: Bool { face % 2 == 1 }
}

/// The block region of a `fix wall/region` command (e.g. the divider in
/// Maxwell's demon), clipped to the simulation box.
public struct WallBlock: Sendable, Equatable {
    public var low: SIMD3<Double>
    public var high: SIMD3<Double>

    public init(low: SIMD3<Double>, high: SIMD3<Double>) {
        self.low = low; self.high = high
    }
}

/// Positions, types and bonds of all atoms at one timestep, sorted by LAMMPS
/// atom ID, with the chosen per-atom quantity and the observables. Index `i`
/// in `tags`, `types`, `positions`, `radii` and `perAtomValues` is the same
/// atom, and bonds refer to these indices. Coordinates are in simulation
/// units and wrapped into the periodic box.
///
/// The box is LAMMPS' (restricted triclinic) box: the origin `boxLow`, the
/// edge lengths `boxHigh - boxLow` and the tilt factors (xy, xz, yz), so its
/// edge vectors are a = (lx, 0, 0), b = (xy, ly, 0), c = (xz, yz, lz).
public struct SimulationSnapshot: Sendable {
    /// Increases with every published snapshot.
    public var sequence: UInt64
    public var timestep: Int64
    /// Simulation time in LAMMPS time units.
    public var time: Double
    /// LAMMPS unit style: "lj", "metal", "real", ...
    public var units: String
    public var typeCount: Int
    public var dimension: Int
    /// Periodic along x, y and z.
    public var periodic: [Bool]
    public var minimizing: Bool
    public var boxLow: SIMD3<Double>
    public var boxHigh: SIMD3<Double>
    /// Triclinic tilt (xy, xz, yz); zero for orthogonal boxes.
    public var tilt: SIMD3<Double>
    public var temperature: Double
    public var kineticEnergy: Double
    /// Total potential energy, when LAMMPS has tallied it.
    public var potentialEnergy: Double?
    public var stepsPerSecond: Double
    /// True while the simulation is frozen (see `Simulation.setFrozen`).
    public var frozen: Bool
    /// The grabbed atom's tag, or nil.
    public var grabTag: Int64?
    /// Force on the grabbed atom from the other atoms; only while frozen.
    public var grabForce: SIMD3<Double>
    public var tags: [Int64]                 // sorted
    public var types: [Int32]                // 1-based
    public var positions: [SIMD3<Float>]
    /// Per-atom radii for atom styles that have them (granular spheres).
    public var radii: [Float]?
    public var bonds: [SIMD2<UInt32>]        // indices into the arrays above
    /// Values of the quantity chosen with `Simulation.setPerAtomQuantity`,
    /// per atom (NaN where unknown), or nil.
    public var perAtomValues: [Float]?
    /// The quantity chosen with `Simulation.setPerAtomQuantity`, or nil.
    public var perAtomQuantity: String?
    /// Why the chosen quantity has no values (e.g. an unknown compute), or nil.
    public var perAtomError: String?
    /// Global scalars and vectors of computes, fixes, variables and thermo keywords.
    public var observables: [Observable]
    /// The step the observables were last sampled on, or nil.
    public var observablesTimestep: Int64?
    /// Whether a run or minimization is in progress.
    public var runMode: RunMode
    /// Steps done in the current run or minimization; 0 when idle.
    public var runStep: Int64
    /// Steps the current run will take (the N of `run N`); 0 when idle.
    public var runSteps: Int64
    /// The input line LAMMPS is executing, e.g. "run 10000", or nil.
    public var inputLine: String?
    /// Planes of `fix wall/*` commands.
    public var walls: [WallPlane]
    /// Blocks of `fix wall/region` commands.
    public var wallBlocks: [WallBlock]

    public init(sequence: UInt64 = 0, timestep: Int64 = 0, time: Double = 0, units: String = "lj",
                typeCount: Int, dimension: Int = 3, periodic: [Bool] = [true, true, true],
                minimizing: Bool = false, boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>,
                tilt: SIMD3<Double> = .zero, temperature: Double = 0, kineticEnergy: Double = 0,
                potentialEnergy: Double? = nil, stepsPerSecond: Double = 0, frozen: Bool = false,
                grabTag: Int64? = nil, grabForce: SIMD3<Double> = .zero,
                tags: [Int64], types: [Int32], positions: [SIMD3<Float>], radii: [Float]? = nil,
                bonds: [SIMD2<UInt32>] = [], perAtomValues: [Float]? = nil, perAtomQuantity: String? = nil,
                perAtomError: String? = nil, observables: [Observable] = [], observablesTimestep: Int64? = nil,
                runMode: RunMode = .idle, runStep: Int64 = 0, runSteps: Int64 = 0, inputLine: String? = nil,
                walls: [WallPlane] = [], wallBlocks: [WallBlock] = []) {
        self.sequence = sequence; self.timestep = timestep; self.time = time; self.units = units
        self.typeCount = typeCount; self.dimension = dimension; self.periodic = periodic
        self.minimizing = minimizing; self.boxLow = boxLow; self.boxHigh = boxHigh; self.tilt = tilt
        self.temperature = temperature; self.kineticEnergy = kineticEnergy; self.potentialEnergy = potentialEnergy
        self.stepsPerSecond = stepsPerSecond; self.frozen = frozen; self.grabTag = grabTag
        self.grabForce = grabForce
        self.tags = tags; self.types = types; self.positions = positions; self.radii = radii; self.bonds = bonds
        self.perAtomValues = perAtomValues; self.perAtomQuantity = perAtomQuantity
        self.perAtomError = perAtomError
        self.observables = observables; self.observablesTimestep = observablesTimestep
        self.runMode = runMode; self.runStep = runStep; self.runSteps = runSteps; self.inputLine = inputLine
        self.walls = walls; self.wallBlocks = wallBlocks
    }

    /// Fraction of the current run done (0...1), or nil when idle.
    public var runProgress: Double? {
        guard runMode != .idle, runSteps > 0 else { return nil }
        return min(1, max(0, Double(runStep) / Double(runSteps)))
    }

    public var atomCount: Int { tags.count }

    /// Index of the atom with this LAMMPS ID, if present.
    public func index(ofTag tag: Int64) -> Int? {
        var low = 0, high = tags.count
        while low < high {
            let mid = (low + high) / 2
            if tags[mid] < tag { low = mid + 1 } else { high = mid }
        }
        return low < tags.count && tags[low] == tag ? low : nil
    }

    /// The observable with this id ("c_msd", "thermo_temp", ...).
    public func observable(id: String) -> Observable? {
        observables.first { $0.id == id }
    }

    public var isTriclinic: Bool { tilt != .zero }

    /// Edge vectors a, b, c of the box.
    public var boxVectors: (a: SIMD3<Double>, b: SIMD3<Double>, c: SIMD3<Double>) {
        let length = boxHigh - boxLow
        return (SIMD3(length.x, 0, 0), SIMD3(tilt.x, length.y, 0), SIMD3(tilt.y, tilt.z, length.z))
    }

    /// Axis aligned bounding box of the (possibly tilted) box.
    public var bounds: (low: SIMD3<Double>, high: SIMD3<Double>) {
        let (xy, xz, yz) = (tilt.x, tilt.y, tilt.z)
        let low = boxLow + SIMD3(min(0, xy, xz, xy + xz), min(0, yz), 0)
        let high = boxHigh + SIMD3(max(0, xy, xz, xy + xz), max(0, yz), 0)
        return (low, high)
    }

    /// The atom nearest to `point` within `radius`, as an index.
    public func nearestAtom(to point: SIMD3<Float>, within radius: Float) -> Int? {
        var best: Int?
        var bestDistance = radius * radius
        for (i, position) in positions.enumerated() {
            let d = simd_distance_squared(position, point)
            if d <= bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    /// The atom a ray hits first, as an index: the one whose sphere of
    /// `radius(i) + tolerance` the ray enters at the smallest distance
    /// along it. Atoms behind the origin are skipped; one whose sphere
    /// holds the origin counts as hit at distance 0. All in simulation
    /// units; `direction` need not be normalized. Nil on a miss.
    public func atomHit(rayOrigin: SIMD3<Float>, direction: SIMD3<Float>, radius: (Int) -> Float,
                        tolerance: Float) -> Int? {
        let length = simd_length(direction)
        guard length > 0, length.isFinite else { return nil }
        let unit = direction / length
        var best: Int?
        var bestDistance = Float.infinity
        for (i, position) in positions.enumerated() {
            let r = radius(i) + tolerance
            guard r > 0 else { continue }
            let offset = rayOrigin - position
            let along = simd_dot(offset, unit)
            let outside = simd_length_squared(offset) - r * r
            let distance: Float
            if outside <= 0 {
                distance = 0
            } else {
                // Outside and heading away, or passing beside it.
                let discriminant = along * along - outside
                guard along < 0, discriminant >= 0 else { continue }
                distance = -along - discriminant.squareRoot()
            }
            if distance < bestDistance {
                bestDistance = distance
                best = i
            }
        }
        return best
    }

    /// Why the snapshot cannot be shown, or nil. Checked before a snapshot
    /// reaches the app.
    public var validationIssue: String? {
        guard time.isFinite, temperature.isFinite, temperature >= 0,
              kineticEnergy.isFinite, kineticEnergy >= 0,
              potentialEnergy?.isFinite ?? true,
              stepsPerSecond.isFinite, stepsPerSecond >= 0,
              grabForce.x.isFinite, grabForce.y.isFinite, grabForce.z.isFinite else {
            return "The simulation produced invalid energy or time."
        }
        for axis in 0..<3 {
            guard boxLow[axis].isFinite, boxHigh[axis].isFinite, tilt[axis].isFinite,
                  boxHigh[axis] > boxLow[axis],
                  Float(boxLow[axis]).isFinite, Float(boxHigh[axis]).isFinite,
                  Float(boxHigh[axis] - boxLow[axis]).isFinite else {
                return "The simulation box is invalid."
            }
        }
        guard types.count == atomCount, positions.count == atomCount,
              radii == nil || radii?.count == atomCount,
              perAtomValues == nil || perAtomValues?.count == atomCount else {
            return "The simulation returned incomplete atoms."
        }
        var previous = Int64.min
        for i in tags.indices {
            let p = positions[i]
            guard tags[i] > previous, types[i] > 0, Int(types[i]) <= typeCount,
                  p.x.isFinite, p.y.isFinite, p.z.isFinite else {
                return "The simulation produced an invalid atom."
            }
            previous = tags[i]
        }
        if let radii, !radii.allSatisfy({ $0.isFinite && $0 >= 0 }) {
            return "The simulation produced an invalid atom size."
        }
        guard bonds.allSatisfy({ Int($0.x) < atomCount && Int($0.y) < atomCount && $0.x != $0.y }) else {
            return "The simulation returned an invalid bond."
        }
        return nil
    }
}

extension SimulationSnapshot {
    /// Copies a snapshot out of the engine (while it is locked).
    init(_ raw: atomify_snapshot) {
        let natoms = max(0, Int(raw.natoms)), nbonds = max(0, Int(raw.nbonds))
        let units = withUnsafeBytes(of: raw.units) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        let positions = [SIMD3<Float>](unsafeUninitializedCapacity: natoms) { buffer, count in
            if let source = raw.positions {
                for i in 0..<natoms {
                    buffer[i] = SIMD3(source[3 * i], source[3 * i + 1], source[3 * i + 2])
                }
                count = natoms
            } else {
                count = 0
            }
        }
        let bonds = [SIMD2<UInt32>](unsafeUninitializedCapacity: nbonds) { buffer, count in
            if let source = raw.bonds {
                for b in 0..<nbonds { buffer[b] = SIMD2(source[2 * b], source[2 * b + 1]) }
                count = nbonds
            } else {
                count = 0
            }
        }
        var observables: [Observable] = []
        if let base = raw.observables, raw.nobservables > 0 {
            observables.reserveCapacity(Int(raw.nobservables))
            for i in 0..<Int(raw.nobservables) {
                if let observable = Observable(base[i]) { observables.append(observable) }
            }
        }
        let quantity = raw.per_atom_name.map { String(cString: $0) } ?? ""
        let problem = raw.per_atom_error.map { String(cString: $0) } ?? ""
        let line = raw.input_line.map { String(cString: $0) } ?? ""
        var walls: [WallPlane] = []
        if let base = raw.walls, raw.nwalls > 0 {
            for i in 0..<Int(raw.nwalls) {
                let face = Int(base[i].face), position = base[i].position
                if (0...5).contains(face) && position.isFinite {
                    walls.append(WallPlane(face: face, position: position))
                }
            }
        }
        var wallBlocks: [WallBlock] = []
        if let base = raw.wall_blocks, raw.nwall_blocks > 0 {
            for i in 0..<Int(raw.nwall_blocks) {
                let block = base[i]
                let low = SIMD3(block.lo.0, block.lo.1, block.lo.2), high = SIMD3(block.hi.0, block.hi.1, block.hi.2)
                if all(low .<= high) { wallBlocks.append(WallBlock(low: low, high: high)) }
            }
        }

        self.init(
            sequence: raw.sequence, timestep: raw.timestep, time: raw.time, units: units,
            typeCount: Int(raw.ntypes), dimension: Int(raw.dimension),
            periodic: [raw.periodic.0 != 0, raw.periodic.1 != 0, raw.periodic.2 != 0],
            minimizing: raw.minimizing != 0,
            boxLow: SIMD3(raw.box_lo.0, raw.box_lo.1, raw.box_lo.2),
            boxHigh: SIMD3(raw.box_hi.0, raw.box_hi.1, raw.box_hi.2),
            tilt: SIMD3(raw.tilt.0, raw.tilt.1, raw.tilt.2),
            temperature: raw.temperature, kineticEnergy: raw.kinetic_energy,
            potentialEnergy: raw.has_potential_energy != 0 ? raw.potential_energy : nil,
            stepsPerSecond: raw.steps_per_second, frozen: raw.frozen != 0,
            grabTag: raw.grab_tag > 0 ? raw.grab_tag : nil,
            grabForce: SIMD3(raw.grab_force.0, raw.grab_force.1, raw.grab_force.2),
            tags: natoms > 0 && raw.tags != nil ? Array(UnsafeBufferPointer(start: raw.tags, count: natoms)) : [],
            types: natoms > 0 && raw.types != nil ? Array(UnsafeBufferPointer(start: raw.types, count: natoms)) : [],
            positions: positions,
            radii: raw.radii.map { Array(UnsafeBufferPointer(start: $0, count: natoms)) },
            bonds: bonds,
            perAtomValues: raw.per_atom_values.map { Array(UnsafeBufferPointer(start: $0, count: natoms)) },
            perAtomQuantity: quantity.isEmpty ? nil : quantity,
            perAtomError: problem.isEmpty ? nil : problem,
            observables: observables,
            observablesTimestep: raw.observables_timestep >= 0 ? raw.observables_timestep : nil,
            runMode: RunMode(rawValue: Int(raw.run_mode)) ?? .idle,
            runStep: max(0, raw.run_step), runSteps: max(0, raw.run_steps),
            inputLine: line.isEmpty ? nil : line,
            walls: walls, wallBlocks: wallBlocks)
    }
}

extension Observable {
    /// Copies an observable out of a locked engine snapshot.
    init?(_ raw: atomify_observable) {
        let kind: Kind
        switch raw.kind {
        case 0: kind = .thermo      // ATOMIFY_OBSERVABLE_THERMO
        case 1: kind = .compute     // ATOMIFY_OBSERVABLE_COMPUTE
        case 2: kind = .fix         // ATOMIFY_OBSERVABLE_FIX
        case 3: kind = .variable    // ATOMIFY_OBSERVABLE_VARIABLE
        default: return nil
        }
        guard let rawName = raw.name else { return nil }
        let name = String(cString: rawName)
        let style = raw.style.map { String(cString: $0) } ?? ""
        let id = Self.id(kind: kind, name: name)
        let hasScalar = raw.has_scalar != 0
        var values: [Double] = hasScalar ? [raw.scalar] : []
        if raw.vector_length > 0, let vector = raw.vector {
            values += UnsafeBufferPointer(start: vector, count: Int(raw.vector_length))
        }
        var table: ObservableTable?
        if raw.array_rows > 0, raw.array_columns > 0, let array = raw.array {
            let rows = Int(raw.array_rows), columns = Int(raw.array_columns)
            table = ObservableTable(rows: rows, columns: columns,
                                    values: Array(UnsafeBufferPointer(start: array, count: rows * columns)))
        }
        self.init(kind: kind, name: name, style: kind == .thermo || style.isEmpty ? nil : style,
                  values: values, labels: Self.labels(id: id, count: values.count, hasScalar: hasScalar),
                  perAtomNames: raw.has_per_atom != 0 ? Self.perAtomNames(id: id, columns: Int(raw.per_atom_columns)) : [],
                  timestep: raw.timestep >= 0 ? raw.timestep : nil, time: raw.time, table: table)
    }
}
