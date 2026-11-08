import AtomifyEngine
import Foundation
import simd

/// One atom for the billboard renderer: a camera-facing square that the
/// fragment shader turns into a ray-traced sphere, with real depth. The
/// layout matches `Atom` in `ImpostorShaders.source` (32 bytes).
public struct ImpostorAtom: Sendable, Equatable {
    /// Center in simulation units (xyz) and radius (w).
    public var centerRadius: SIMD4<Float>
    /// Linear RGB (xyz) and ambient light reaching the atom (w, 0...1):
    /// lower inside dense material, so pores and surfaces stand out.
    public var color: SIMD4<Float>

    public init(center: SIMD3<Float>, radius: Float, color: SIMD4<Float>) {
        centerRadius = SIMD4(center, radius)
        self.color = color
    }
}

/// A ray-traced cylinder from `start` to `end`, drawn in `startColor` up to
/// `split` (a fraction of its length) and `endColor` after it, so one
/// instance draws a bond in the colors of both its atoms. The layout matches
/// `Bond` in `ImpostorShaders.source` (64 bytes).
public struct ImpostorCylinder: Sendable, Equatable {
    /// Start in simulation units (xyz) and radius (w).
    public var startRadius: SIMD4<Float>
    /// End (xyz) and split fraction (w).
    public var endSplit: SIMD4<Float>
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>

    public init(from start: SIMD3<Float>, to end: SIMD3<Float>, radius: Float, startColor: SIMD4<Float>,
                endColor: SIMD4<Float>, split: Float = 0.5) {
        startRadius = SIMD4(start, radius)
        endSplit = SIMD4(end, split)
        self.startColor = startColor
        self.endColor = endColor
    }
}

/// Everything the billboard renderer draws for one snapshot, in simulation
/// units. `worldFromSimulation` places it in the room.
public struct ImpostorFrame: Sendable {
    public var atoms: [ImpostorAtom] = []
    public var cylinders: [ImpostorCylinder] = []
    public var worldFromSimulation = matrix_identity_float4x4
    /// Changes whenever `atoms` or `cylinders` change, so the renderer only
    /// uploads new data when there is some.
    public var generation: UInt64 = 0

    public init() {}

    /// Atoms and bonds of a snapshot. `highlightedTags` brightens and enlarges
    /// atoms (the grabbed ones, one per hand). `ambient` reuses occlusion computed for
    /// an earlier snapshot of the same atoms; it is computed when nil.
    ///
    /// `hidden` (from `buriedAtoms`) leaves out atoms that cannot be seen
    /// because they sit deep inside solid material.
    public static func build(snapshot: SimulationSnapshot, styles: AtomStyleTable, atomScale: Float,
                             bondRadius: Float, includeBonds: Bool, highlightedTags: Set<Int64> = [],
                             ambient: [Float]? = nil, hidden: [Bool]? = nil) -> ImpostorFrame {
        var frame = ImpostorFrame()
        var colorByType: [Int32: SIMD4<Float>] = [:]
        var radiusByType: [Int32: Float] = [:]
        for type in Set(snapshot.types) {
            let style = styles.style(forType: Int(type))
            colorByType[type] = linearColor(style.color)
            radiusByType[type] = Float(style.radius) * atomScale
        }
        let highlighted = Set(highlightedTags.compactMap { snapshot.index(ofTag: $0) })
        let ambient = ambient ?? ambientOcclusion(snapshot: snapshot, styles: styles)

        frame.atoms.reserveCapacity(snapshot.atomCount)
        let hidden = hidden.flatMap { $0.count == snapshot.positions.count ? $0 : nil }
        for i in snapshot.positions.indices {
            if let hidden, hidden[i], !highlighted.contains(i) { continue }
            let type = snapshot.types[i]
            var radius = snapshot.radii.map { $0[i] * atomScale } ?? radiusByType[type] ?? 0
            var color = colorByType[type] ?? SIMD4(1, 1, 1, 1)
            color.w = i < ambient.count ? ambient[i] : 1
            if highlighted.contains(i) {
                radius *= 1.3
                color = SIMD4(simd_min(SIMD3(color.x, color.y, color.z) * 1.6 + 0.25, SIMD3(repeating: 1)), 1)
            }
            frame.atoms.append(ImpostorAtom(center: snapshot.positions[i], radius: radius, color: color))
        }

        if includeBonds && bondRadius > 0 {
            frame.cylinders.reserveCapacity(snapshot.bonds.count)
            for bond in snapshot.bonds {
                let i = Int(bond.x), j = Int(bond.y)
                guard i < snapshot.positions.count, j < snapshot.positions.count else { continue }
                frame.cylinders.append(ImpostorCylinder(
                    from: snapshot.positions[i], to: snapshot.positions[j], radius: bondRadius,
                    startColor: colorByType[snapshot.types[i]] ?? SIMD4(1, 1, 1, 1),
                    endColor: colorByType[snapshot.types[j]] ?? SIMD4(1, 1, 1, 1)))
            }
        }
        return frame
    }

    /// `ambientOcclusion(positions:spacing:)` with a spacing of one atom
    /// diameter (the largest type's).
    public static func ambientOcclusion(snapshot: SimulationSnapshot, styles: AtomStyleTable) -> [Float] {
        let radius = Set(snapshot.types).map { Float(styles.style(forType: Int($0)).radius) }.max() ?? 0
        return ambientOcclusion(positions: snapshot.positions, spacing: max(radius, 1e-3) * 2)
    }

    /// `buriedAtoms(positions:cell:)` with cells two atom diameters wide.
    public static func buriedAtoms(snapshot: SimulationSnapshot, styles: AtomStyleTable) -> [Bool] {
        let radius = Set(snapshot.types).map { Float(styles.style(forType: Int($0)).radius) }.max() ?? 0
        return buriedAtoms(positions: snapshot.positions, cell: max(radius, 1e-3) * 4)
    }

    /// Atoms nobody can see: every grid cell within one cell of theirs holds
    /// atoms, so they are wrapped in at least a cell's thickness (several
    /// atomic layers) of material on all sides. Cells outside the atoms'
    /// bounds count as empty, so the outer surface stays. `cell` should
    /// hold several atoms in a dense region, so gaps between atoms are not
    /// mistaken for empty space. Linear in the atom count; empty when
    /// nothing is buried.
    public static func buriedAtoms(positions: [SIMD3<Float>], cell requested: Float) -> [Bool] {
        guard positions.count > 64, requested > 0, requested.isFinite else { return [] }
        var low = positions[0], high = positions[0]
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        var cell = requested
        var dims = SIMD3<Int>(1, 1, 1)
        while true {
            let span = (high - low) / cell
            dims = SIMD3(Int(span.x) + 1, Int(span.y) + 1, Int(span.z) + 1)
            if dims.x * dims.y * dims.z <= 4_000_000 { break }
            cell *= 1.26
        }
        let nx = dims.x, ny = dims.y, nz = dims.z
        guard nx >= 3, ny >= 3, nz >= 3 else { return [] }
        @inline(__always) func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * ny + y) * nx + x }
        func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let c = (p - low) / cell
            return SIMD3(min(max(Int(c.x), 0), nx - 1), min(max(Int(c.y), 0), ny - 1), min(max(Int(c.z), 0), nz - 1))
        }
        var occupied = [Bool](repeating: false, count: nx * ny * nz)
        for p in positions {
            let c = cellOf(p)
            occupied[index(c.x, c.y, c.z)] = true
        }
        // A cell is solid when it and its 26 neighbours all hold atoms.
        var solid = [Bool](repeating: false, count: nx * ny * nz)
        var anySolid = false
        for z in 1..<(nz - 1) {
            for y in 1..<(ny - 1) {
                for x in 1..<(nx - 1) where occupied[index(x, y, z)] {
                    var all = true
                    search: for dz in -1...1 {
                        for dy in -1...1 {
                            for dx in -1...1 where !occupied[index(x + dx, y + dy, z + dz)] {
                                all = false
                                break search
                            }
                        }
                    }
                    if all {
                        solid[index(x, y, z)] = true
                        anySolid = true
                    }
                }
            }
        }
        guard anySolid else { return [] }
        return positions.map { p in
            let c = cellOf(p)
            return solid[index(c.x, c.y, c.z)]
        }
    }

    /// How much ambient light reaches each atom, from how crowded its
    /// surroundings are: atoms deep inside a solid get about half, atoms on
    /// a surface or in a gas get all of it. Counts atoms in a cube seven
    /// `spacing`s wide around each one, with a summed-volume table so the
    /// cost is linear in the atom count. Empty for sparse systems.
    public static func ambientOcclusion(positions: [SIMD3<Float>], spacing: Float) -> [Float] {
        guard positions.count > 64, spacing > 0, spacing.isFinite else { return [] }
        var low = positions[0], high = positions[0]
        for p in positions {
            low = simd_min(low, p)
            high = simd_max(high, p)
        }
        // Grid cells of about two atom radii, at most 4 million of them.
        var cell = spacing
        var dims = SIMD3<Int>(1, 1, 1)
        while true {
            let span = (high - low) / cell
            dims = SIMD3(Int(span.x) + 1, Int(span.y) + 1, Int(span.z) + 1)
            if dims.x * dims.y * dims.z <= 4_000_000 { break }
            cell *= 1.26
        }
        let nx = dims.x, ny = dims.y, nz = dims.z
        func cellIndex(_ p: SIMD3<Float>) -> SIMD3<Int> {
            let c = (p - low) / cell
            return SIMD3(min(max(Int(c.x), 0), nx - 1), min(max(Int(c.y), 0), ny - 1), min(max(Int(c.z), 0), nz - 1))
        }

        // Summed-volume table with a zero border: sums[x+1, y+1, z+1] counts
        // the atoms in cells [0...x] x [0...y] x [0...z].
        let sx = nx + 1, sy = ny + 1, sz = nz + 1
        var sums = [Int32](repeating: 0, count: sx * sy * sz)
        @inline(__always) func at(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * sy + y) * sx + x }
        for p in positions {
            let c = cellIndex(p)
            sums[at(c.x + 1, c.y + 1, c.z + 1)] += 1
        }
        for z in 1..<sz {
            for y in 1..<sy {
                for x in 1..<sx {
                    sums[at(x, y, z)] += sums[at(x - 1, y, z)] + sums[at(x, y - 1, z)] + sums[at(x, y, z - 1)]
                        - sums[at(x - 1, y - 1, z)] - sums[at(x - 1, y, z - 1)] - sums[at(x, y - 1, z - 1)]
                        + sums[at(x - 1, y - 1, z - 1)]
                }
            }
        }

        let reach = 3
        var counts = [Int32](repeating: 0, count: positions.count)
        var histogram = [Int](repeating: 0, count: 4096)
        for (i, p) in positions.enumerated() {
            let c = cellIndex(p)
            let x0 = max(c.x - reach, 0), x1 = min(c.x + reach + 1, nx)
            let y0 = max(c.y - reach, 0), y1 = min(c.y + reach + 1, ny)
            let z0 = max(c.z - reach, 0), z1 = min(c.z + reach + 1, nz)
            let count = sums[at(x1, y1, z1)] - sums[at(x0, y1, z1)] - sums[at(x1, y0, z1)] - sums[at(x1, y1, z0)]
                + sums[at(x0, y0, z1)] + sums[at(x0, y1, z0)] + sums[at(x1, y0, z0)] - sums[at(x0, y0, z0)]
            counts[i] = count
            histogram[min(Int(count), histogram.count - 1)] += 1
        }

        // Normalize by a crowded-but-not-extreme count: the 95th percentile.
        var seen = 0, reference = 0
        for (count, atoms) in histogram.enumerated() {
            seen += atoms
            if seen * 20 >= positions.count * 19 {
                reference = count
                break
            }
        }
        guard reference >= 24 else { return [] }    // a gas: nothing is enclosed
        return counts.map { count in
            let crowding = min(max((Float(count) / Float(reference) - 0.45) / 0.55, 0), 1)
            return 1 - 0.55 * crowding * crowding * (3 - 2 * crowding)
        }
    }

    /// The twelve edges of an axis aligned box, as thin cylinders.
    public static func boxEdges(low: SIMD3<Float>, high: SIMD3<Float>, radius: Float,
                                color: SIMD4<Float>) -> [ImpostorCylinder] {
        var corners: [SIMD3<Float>] = []
        for k in 0..<8 {
            corners.append(SIMD3(k & 1 == 0 ? low.x : high.x, k & 2 == 0 ? low.y : high.y,
                                 k & 4 == 0 ? low.z : high.z))
        }
        var edges: [ImpostorCylinder] = []
        for a in 0..<8 {
            for bit in [1, 2, 4] where a & bit == 0 {
                edges.append(ImpostorCylinder(from: corners[a], to: corners[a | bit], radius: radius,
                                              startColor: color, endColor: color))
            }
        }
        return edges
    }

    /// sRGB color components to linear light, which the renderer shades in.
    public static func linearColor(_ color: RGBColor) -> SIMD4<Float> {
        func linear(_ c: Double) -> Float {
            Float(c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
        return SIMD4(linear(color.red), linear(color.green), linear(color.blue), 1)
    }
}
