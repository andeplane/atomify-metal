import CLammps
import simd

/// Positions, types and bonds of all atoms at one timestep, sorted by LAMMPS
/// atom ID. Index `i` in `tags`, `types` and `positions` is the same atom,
/// and bonds refer to these indices. Coordinates are in simulation units and
/// wrapped into the periodic box.
public struct SimulationSnapshot: Sendable {
    public var sequence: UInt64
    public var timestep: Int64
    public var time: Double
    public var units: String
    public var typeCount: Int
    public var dimension: Int
    /// Periodic along x, y and z.
    public var periodic: [Bool]
    public var minimizing: Bool
    public var boxLow: SIMD3<Double>
    public var boxHigh: SIMD3<Double>
    public var temperature: Double
    public var kineticEnergy: Double
    /// Total potential energy, when LAMMPS has tallied it.
    public var potentialEnergy: Double?
    public var stepsPerSecond: Double
    /// True while the simulation is frozen (see `LammpsSimulation.setFrozen`).
    public var frozen = false
    /// The grabbed atom's tag, or nil.
    public var grabTag: Int64?
    /// Force on the grabbed atom from the other atoms; only while frozen.
    public var grabForce = SIMD3<Double>.zero
    public var tags: [Int64]
    public var types: [Int32]
    public var positions: [SIMD3<Float>]
    /// Per-atom radii for atom styles that have them (granular spheres).
    public var radii: [Float]?
    public var bonds: [SIMD2<UInt32>]

    public init(sequence: UInt64 = 0, timestep: Int64 = 0, time: Double = 0, units: String = "lj",
                typeCount: Int, dimension: Int = 3, periodic: [Bool] = [true, true, true],
                minimizing: Bool = false, boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>,
                temperature: Double = 0, kineticEnergy: Double = 0, potentialEnergy: Double? = nil,
                stepsPerSecond: Double = 0,
                tags: [Int64], types: [Int32], positions: [SIMD3<Float>], radii: [Float]? = nil,
                bonds: [SIMD2<UInt32>] = []) {
        self.sequence = sequence; self.timestep = timestep; self.time = time; self.units = units
        self.typeCount = typeCount; self.dimension = dimension; self.periodic = periodic
        self.minimizing = minimizing; self.boxLow = boxLow; self.boxHigh = boxHigh
        self.temperature = temperature; self.kineticEnergy = kineticEnergy; self.potentialEnergy = potentialEnergy
        self.stepsPerSecond = stepsPerSecond
        self.tags = tags; self.types = types; self.positions = positions; self.radii = radii; self.bonds = bonds
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

    init(_ raw: atomify_snapshot) {
        let natoms = Int(raw.natoms), nbonds = Int(raw.nbonds)
        sequence = raw.sequence
        timestep = raw.timestep
        time = raw.time
        units = withUnsafeBytes(of: raw.units) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        typeCount = Int(raw.ntypes)
        dimension = Int(raw.dimension)
        periodic = [raw.periodic.0 != 0, raw.periodic.1 != 0, raw.periodic.2 != 0]
        minimizing = raw.minimizing != 0
        boxLow = SIMD3(raw.box_lo.0, raw.box_lo.1, raw.box_lo.2)
        boxHigh = SIMD3(raw.box_hi.0, raw.box_hi.1, raw.box_hi.2)
        temperature = raw.temperature
        kineticEnergy = raw.kinetic_energy
        potentialEnergy = raw.has_potential_energy != 0 ? raw.potential_energy : nil
        frozen = raw.frozen != 0
        grabTag = raw.grab_tag > 0 ? raw.grab_tag : nil
        grabForce = SIMD3(raw.grab_force.0, raw.grab_force.1, raw.grab_force.2)
        stepsPerSecond = raw.steps_per_second
        tags = natoms > 0 ? Array(UnsafeBufferPointer(start: raw.tags, count: natoms)) : []
        types = natoms > 0 ? Array(UnsafeBufferPointer(start: raw.types, count: natoms)) : []
        positions = [SIMD3<Float>](unsafeUninitializedCapacity: natoms) { buffer, count in
            if let source = raw.positions {
                for i in 0..<natoms {
                    buffer[i] = SIMD3(source[3 * i], source[3 * i + 1], source[3 * i + 2])
                }
            }
            count = raw.positions == nil ? 0 : natoms
        }
        radii = raw.radii.map { Array(UnsafeBufferPointer(start: $0, count: natoms)) }
        bonds = [SIMD2<UInt32>](unsafeUninitializedCapacity: nbonds) { buffer, count in
            if let source = raw.bonds {
                for b in 0..<nbonds { buffer[b] = SIMD2(source[2 * b], source[2 * b + 1]) }
            }
            count = raw.bonds == nil ? 0 : nbonds
        }
    }
}
