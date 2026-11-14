import AtomifyEngine
import AtomifyRender
import simd

/// The parts of a `SimulationSnapshot` that drawing, coloring and picking
/// use. Arrays are shared with the snapshot (copy on write), so making one is
/// cheap. Exists so the scene logic can be built and tested from plain values.
public struct AtomFrame: Sendable {
    /// LAMMPS atom IDs, sorted ascending; index i is the same atom in every array.
    public var tags: [Int64]
    /// 1-based LAMMPS types.
    public var types: [Int32]
    public var positions: [SIMD3<Float>]
    /// Per-atom radii (granular spheres), or nil.
    public var radii: [Float]?
    /// Index pairs into the arrays above.
    public var bonds: [SIMD2<UInt32>]
    /// LAMMPS boxlo / boxhi; for a triclinic box, the corners before tilting.
    public var boxLow: SIMD3<Double>
    public var boxHigh: SIMD3<Double>
    /// Triclinic tilt factors (xy, xz, yz).
    public var tilt: SIMD3<Double>
    public var dimension: Int
    /// Periodic along x, y, z.
    public var periodic: [Bool]
    public var typeCount: Int
    public var units: String
    public var perAtomQuantity: String?
    public var perAtomValues: [Float]?
    /// Planes of `fix wall/*` commands.
    public var walls: [WallPlane]
    /// Blocks of `fix wall/region` commands.
    public var wallBlocks: [WallBlock]

    public init(tags: [Int64], types: [Int32], positions: [SIMD3<Float>], radii: [Float]? = nil,
                bonds: [SIMD2<UInt32>] = [], boxLow: SIMD3<Double> = .zero, boxHigh: SIMD3<Double> = SIMD3(repeating: 1),
                tilt: SIMD3<Double> = .zero, dimension: Int = 3, periodic: [Bool] = [true, true, true],
                typeCount: Int? = nil, units: String = "lj",
                perAtomQuantity: String? = nil, perAtomValues: [Float]? = nil,
                walls: [WallPlane] = [], wallBlocks: [WallBlock] = []) {
        self.tags = tags
        self.types = types
        self.positions = positions
        self.radii = radii
        self.bonds = bonds
        self.boxLow = boxLow
        self.boxHigh = boxHigh
        self.tilt = tilt
        self.dimension = dimension
        self.periodic = periodic
        self.typeCount = typeCount ?? Int(types.max() ?? 1)
        self.units = units
        self.perAtomQuantity = perAtomQuantity
        self.perAtomValues = perAtomValues
        self.walls = walls
        self.wallBlocks = wallBlocks
    }

    public init(_ snapshot: SimulationSnapshot) {
        self.init(tags: snapshot.tags, types: snapshot.types, positions: snapshot.positions, radii: snapshot.radii,
                  bonds: snapshot.bonds, boxLow: snapshot.boxLow, boxHigh: snapshot.boxHigh, tilt: snapshot.tilt,
                  dimension: snapshot.dimension, periodic: snapshot.periodic, typeCount: snapshot.typeCount,
                  units: snapshot.units,
                  perAtomQuantity: snapshot.perAtomQuantity, perAtomValues: snapshot.perAtomValues,
                  walls: snapshot.walls, wallBlocks: snapshot.wallBlocks)
    }

    public var count: Int { positions.count }

    /// Index of the atom with this ID (binary search over the sorted tags).
    public func index(ofTag tag: Int64) -> Int? {
        var low = 0, high = tags.count
        while low < high {
            let mid = (low + high) / 2
            if tags[mid] < tag { low = mid + 1 } else { high = mid }
        }
        return low < tags.count && tags[low] == tag ? low : nil
    }

    /// The per-atom values of `quantity`, when this frame carries them for every atom.
    public func values(for quantity: String) -> [Float]? {
        guard perAtomQuantity == quantity, let values = perAtomValues, values.count == count else { return nil }
        return values
    }

    /// The largest type present or declared, at least 1.
    var highestType: Int { max(typeCount, Int(types.max() ?? 1), 1) }
}

/// Builds the renderer's input from a snapshot. Pure and cheap enough to run
/// for every new snapshot.
public enum SceneBuilder {
    /// Simulation box edges, linear RGB.
    public static let boxColor = SIMD4<Float>(0.55, 0.57, 0.62, 1)
    public static let boxLineWidth: Float = 1.5
    /// Wall edges, linear RGB: lighter than the box, so a divider reads.
    public static let wallEdgeColor = SIMD4<Float>(0.72, 0.76, 0.84, 1)
    /// Wall faces: linear RGB and the face-on opacity (glass-like).
    public static let wallFaceColor = SIMD4<Float>(0.5, 0.6, 0.8, 0.05)
    /// Style for types with no entry in the table (index 0 of `particleStyles`).
    public static let fallbackStyle = ParticleStyle(radius: 0.5, color: SIMD4(0.8, 0.8, 0.8, 1))
    /// `ParticleData.flags` bit for the selected atom.
    public static let selectedFlag: UInt8 = 1

    public static func scene(from snapshot: SimulationSnapshot, styles: AtomStyleTable, colorMode: ColorMode,
                             selectedTag: Int64?, showBox: Bool, bondRadius: Float) -> SceneData {
        scene(from: AtomFrame(snapshot), styles: styles, colorMode: colorMode, selectedTag: selectedTag,
              showBox: showBox, bondRadius: bondRadius)
    }

    public static func scene(from frame: AtomFrame, styles: AtomStyleTable, colorMode: ColorMode,
                             selectedTag: Int64?, showBox: Bool, bondRadius: Float) -> SceneData {
        scene(from: frame, typeStyles: particleStyles(from: styles, typeCount: frame.highestType),
              colorMode: colorMode, selectedTag: selectedTag, showBox: showBox, bondRadius: bondRadius)
    }

    /// The scene for a frame. `typeStyles[t]` is the style of type t (index 0
    /// is the fallback). Bonds are left out when `bondRadius` is 0. In
    /// per-atom mode, atoms keep their type colors until the frame carries
    /// values of the chosen quantity. In type mode, `colorRamp` shades the
    /// type colors by position.
    public static func scene(from frame: AtomFrame, typeStyles: [ParticleStyle], colorMode: ColorMode,
                             selectedTag: Int64?, showBox: Bool, bondRadius: Float,
                             colorRamp: ColorRamp? = nil, imageCounts: SIMD3<Int>? = nil) -> SceneData {
        let styles = typeStyles.isEmpty ? [fallbackStyle] : typeStyles
        let styleCount = styles.count
        let styleIndices = frame.types.map { type -> UInt16 in
            let t = Int(type)
            return t > 0 && t < styleCount ? UInt16(t) : 0
        }

        var colors: [SIMD4<Float>]?
        if case .perAtom(let quantity, let colormap, let range) = colorMode, let values = frame.values(for: quantity) {
            let lookup = ColorLookup(colormap: colormap, range: range ?? finiteRange(of: values) ?? 0...1)
            colors = lookup.colors(for: values)
        } else if case .type = colorMode, let colorRamp {
            colors = colorRamp.colors(for: frame, styleIndices: styleIndices, styles: styles)
        }

        let radii = frame.radii.flatMap { $0.count == frame.count ? $0 : nil }

        var flags: [UInt8]?
        if let selectedTag, let index = frame.index(ofTag: selectedTag), index < frame.count {
            var f = [UInt8](repeating: 0, count: frame.count)
            f[index] = selectedFlag
            flags = f
        }

        let particles = ParticleData(positions: frame.positions, styleIndices: styleIndices, styles: styles,
                                     colors: colors, radii: radii, flags: flags)

        var bonds: BondData?
        if bondRadius > 0, !frame.bonds.isEmpty {
            let count = UInt32(frame.count)
            let valid = frame.bonds.allSatisfy { $0.x < count && $0.y < count }
            let pairs = valid ? frame.bonds : frame.bonds.filter { $0.x < count && $0.y < count }
            if !pairs.isEmpty {
                var data = BondData(pairs: pairs, radius: bondRadius)
                data.maxLength = maxBondLength(boxLow: frame.boxLow, boxHigh: frame.boxHigh,
                                               periodic: frame.periodic, dimension: frame.dimension)
                bonds = data
            }
        }

        var lines: [LineData] = []
        if showBox {
            // With periodic images, one box around all the copies.
            let box = imageCounts.map { replicatedBox(counts: $0, low: frame.boxLow, high: frame.boxHigh, tilt: frame.tilt) }
                ?? (low: frame.boxLow, high: frame.boxHigh, tilt: frame.tilt)
            lines.append(LineData(segments: boxEdges(low: box.low, high: box.high, tilt: box.tilt,
                                                     dimension: frame.dimension),
                                  color: boxColor, width: boxLineWidth))
        }
        let walls = wallGeometry(for: frame)
        if !walls.edges.isEmpty {
            lines.append(LineData(segments: walls.edges, color: wallEdgeColor, width: boxLineWidth))
        }
        let panels = walls.faces.isEmpty ? [] : [PanelData(quads: walls.faces, color: wallFaceColor)]
        return SceneData(particles: particles, bonds: bonds, lines: lines, panels: panels, images: [.zero])
    }

    /// Faces and edges of the frame's walls, as the web app shows them:
    /// translucent faces, plus edges where they are not on the box already.
    /// A `fix wall/region` block is drawn as its box (in 2D, its outline at
    /// the atoms' plane). A `fix wall/*` plane spans the box; planes are left
    /// out in 2D and for triclinic boxes, where they do not line up with it.
    public static func wallGeometry(for frame: AtomFrame) -> (faces: [PanelData.Quad],
                                                               edges: [(SIMD3<Float>, SIMD3<Float>)]) {
        var faces: [PanelData.Quad] = []
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        let low = frame.boxLow, high = frame.boxHigh
        for block in frame.wallBlocks {
            if frame.dimension == 2 {
                edges += boxEdges(low: block.low, high: block.high, tilt: .zero, dimension: 2)
                continue
            }
            let blockLow = SIMD3<Float>(block.low), blockHigh = SIMD3<Float>(block.high)
            faces += PanelData.box(low: blockLow, high: blockHigh, color: .zero).quads
            edges += LineData.box(low: blockLow, high: blockHigh, color: .zero).segments
        }
        guard frame.dimension == 3, frame.tilt == .zero else { return (faces, edges) }
        for wall in frame.walls {
            let axis = wall.axis
            guard (0..<3).contains(axis), wall.position >= low[axis], wall.position <= high[axis] else { continue }
            var planeLow = low, planeHigh = high
            planeLow[axis] = wall.position
            planeHigh[axis] = wall.position
            let plane = PanelData.box(low: SIMD3<Float>(planeLow), high: SIMD3<Float>(planeHigh), color: .zero).quads
            faces += plane
            if wall.position != low[axis] && wall.position != high[axis] {
                // Inside the box: the plane's own outline.
                for quad in plane {
                    let corners = [quad.origin, quad.origin + quad.u, quad.origin + quad.u + quad.v, quad.origin + quad.v]
                    for k in 0..<4 { edges.append((corners[k], corners[(k + 1) % 4])) }
                }
            }
        }
        return (faces, edges)
    }

    /// The range the colors of a per-atom mode span for this frame: the
    /// mode's own range, or the values' min and max. Nil for type coloring
    /// and until the frame carries the quantity.
    public static func colorRange(for frame: AtomFrame, colorMode: ColorMode) -> ClosedRange<Float>? {
        guard case .perAtom(let quantity, _, let range) = colorMode, let values = frame.values(for: quantity) else {
            return nil
        }
        return range ?? finiteRange(of: values)
    }

    /// Styles indexed by type: element 0 is `fallbackStyle`, element t is type t.
    public static func particleStyles(from table: AtomStyleTable, typeCount: Int) -> [ParticleStyle] {
        [fallbackStyle] + (0..<max(typeCount, 0)).map { i in
            let style = table.style(forType: i + 1)
            return ParticleStyle(radius: Float(style.radius), color: style.color.linear)
        }
    }

    /// Bonds longer than half the shortest periodic box length join atoms on
    /// opposite faces (LAMMPS wraps positions into the box), so they are
    /// hidden. Infinite for a box with no periodic axis.
    public static func maxBondLength(boxLow: SIMD3<Double>, boxHigh: SIMD3<Double>, periodic: [Bool],
                                     dimension: Int = 3) -> Float {
        let length = boxHigh - boxLow
        var shortest = Double.infinity
        for axis in 0..<min(periodic.count, dimension == 2 ? 2 : 3) where periodic[axis] {
            if length[axis] > 0, length[axis].isFinite { shortest = min(shortest, length[axis]) }
        }
        return Float(shortest / 2)
    }

    /// A bond radius that suits the atoms: 0.35 of the smallest type radius.
    public static func defaultBondRadius(styles: AtomStyleTable, typeCount: Int) -> Float {
        let radii = (0..<max(typeCount, 1)).map { Float(styles.style(forType: $0 + 1).radius) }
        return 0.35 * (radii.filter { $0 > 0 }.min() ?? 0.5)
    }

    /// The box that holds all the copies `imageOffsets` makes: the same
    /// corner offsets as the copies, edge vectors `counts` times as long.
    public static func replicatedBox(counts: SIMD3<Int>, low: SIMD3<Double>, high: SIMD3<Double>,
                                     tilt: SIMD3<Double>) -> (low: SIMD3<Double>, high: SIMD3<Double>,
                                                              tilt: SIMD3<Double>) {
        let n = SIMD3(max(counts.x, 1), max(counts.y, 1), max(counts.z, 1))
        let length = high - low
        let a = SIMD3<Double>(length.x, 0, 0)
        let b = SIMD3<Double>(tilt.x, length.y, 0)
        let c = SIMD3<Double>(tilt.y, tilt.z, length.z)
        let first = SIMD3<Double>(Double(-(n.x - 1) / 2), Double(-(n.y - 1) / 2), Double(-(n.z - 1) / 2))
        let origin = low + first.x * a + first.y * b + first.z * c
        let scale = SIMD3<Double>(Double(n.x), Double(n.y), Double(n.z))
        return (origin, origin + length * scale, SIMD3(tilt.x * scale.y, tilt.y * scale.z, tilt.z * scale.z))
    }

    /// The eight corners of a (possibly triclinic) LAMMPS box, corner k
    /// adding edge vector a, b, c for bits 1, 2, 4 of k.
    ///
    /// LAMMPS edge vectors: a = (lx, 0, 0), b = (xy, ly, 0), c = (xz, yz, lz)
    /// from boxlo, with tilt = (xy, xz, yz).
    /// Offsets that draw the box `counts` times along each box vector, as
    /// Atomify 2's periodic images: copies at −(n−1)/2 ... n/2 (integer
    /// division), the original (offset zero) first.
    public static func imageOffsets(counts: SIMD3<Int>, low: SIMD3<Double>, high: SIMD3<Double>,
                                    tilt: SIMD3<Double>) -> [SIMD3<Float>] {
        let length = high - low
        let vectors = [SIMD3<Double>(length.x, 0, 0), SIMD3<Double>(tilt.x, length.y, 0),
                       SIMD3<Double>(tilt.y, tilt.z, length.z)]
        guard vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return [.zero] }
        let n = SIMD3(max(counts.x, 1), max(counts.y, 1), max(counts.z, 1))
        var offsets: [SIMD3<Float>] = [.zero]
        for i in -(n.x - 1) / 2...n.x / 2 {
            for j in -(n.y - 1) / 2...n.y / 2 {
                for k in -(n.z - 1) / 2...n.z / 2 where i != 0 || j != 0 || k != 0 {
                    let offset = Double(i) * vectors[0] + Double(j) * vectors[1] + Double(k) * vectors[2]
                    offsets.append(SIMD3<Float>(offset))
                }
            }
        }
        return offsets
    }

    public static func boxCorners(low: SIMD3<Double>, high: SIMD3<Double>, tilt: SIMD3<Double>) -> [SIMD3<Float>] {
        let length = high - low
        let a = SIMD3<Double>(length.x, 0, 0)
        let b = SIMD3<Double>(tilt.x, length.y, 0)
        let c = SIMD3<Double>(tilt.y, tilt.z, length.z)
        return (0..<8).map { k in
            var corner = low
            if k & 1 != 0 { corner += a }
            if k & 2 != 0 { corner += b }
            if k & 4 != 0 { corner += c }
            return SIMD3<Float>(corner)
        }
    }

    /// Edges of the simulation box as line segments: the 12 edges of the
    /// parallelepiped in 3D; in 2D, the 4 edges of the xy face at z = 0
    /// (clamped into the box), where the atoms are.
    public static func boxEdges(low: SIMD3<Double>, high: SIMD3<Double>, tilt: SIMD3<Double>,
                                dimension: Int = 3) -> [(SIMD3<Float>, SIMD3<Float>)] {
        if dimension == 2 {
            var flatLow = low, flatHigh = high
            let z = min(max(0, low.z), high.z)
            flatLow.z = z
            flatHigh.z = z
            let corners = boxCorners(low: flatLow, high: flatHigh, tilt: SIMD3(tilt.x, 0, 0))
            return [(corners[0], corners[1]), (corners[1], corners[3]), (corners[3], corners[2]),
                    (corners[2], corners[0])]
        }
        let corners = boxCorners(low: low, high: high, tilt: tilt)
        var edges: [(SIMD3<Float>, SIMD3<Float>)] = []
        edges.reserveCapacity(12)
        for k in 0..<8 {
            for bit in [1, 2, 4] where k & bit == 0 {
                edges.append((corners[k], corners[k | bit]))
            }
        }
        return edges
    }

    /// Axis-aligned bounds of the box, tilt included (for camera framing).
    public static func bounds(low: SIMD3<Double>, high: SIMD3<Double>,
                              tilt: SIMD3<Double>) -> (low: SIMD3<Float>, high: SIMD3<Float>) {
        let corners = boxCorners(low: low, high: high, tilt: tilt)
        let low = corners.dropFirst().reduce(corners[0]) { pointwiseMin($0, $1) }
        let high = corners.dropFirst().reduce(corners[0]) { pointwiseMax($0, $1) }
        return (low, high)
    }
}
