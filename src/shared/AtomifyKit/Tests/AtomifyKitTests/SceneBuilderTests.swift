import AtomifyEngine
import AtomifyRender
import Testing
import simd
@testable import AtomifyKit

func isClose(_ a: Float, _ b: Float, _ tolerance: Float = 1e-5) -> Bool { abs(a - b) <= tolerance }

func isClose(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) <= tolerance
}

func isClose(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ tolerance: Float = 1e-5) -> Bool {
    simd_length(a - b) <= tolerance
}

/// Four atoms of two types, tags out of index order on purpose.
func sampleFrame(quantity: String? = nil, values: [Float]? = nil) -> AtomFrame {
    AtomFrame(tags: [2, 5, 9, 11], types: [1, 2, 1, 2],
              positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)],
              bonds: [SIMD2(0, 1), SIMD2(2, 3)], boxLow: SIMD3(-1, -2, -3), boxHigh: SIMD3(4, 5, 6),
              typeCount: 2, units: "lj", perAtomQuantity: quantity, perAtomValues: values)
}

let red = ParticleStyle(radius: 0.4, color: SIMD4(1, 0, 0, 1))
let blue = ParticleStyle(radius: 0.6, color: SIMD4(0, 0, 1, 1))
let sampleStyles = [SceneBuilder.fallbackStyle, red, blue]

@Suite struct AtomFrameTests {
    @Test func indexOfTag() {
        let frame = sampleFrame()
        #expect(frame.count == 4)
        #expect(frame.index(ofTag: 2) == 0)
        #expect(frame.index(ofTag: 9) == 2)
        #expect(frame.index(ofTag: 11) == 3)
        #expect(frame.index(ofTag: 1) == nil)
        #expect(frame.index(ofTag: 6) == nil)
        #expect(frame.index(ofTag: 12) == nil)
        #expect(AtomFrame(tags: [], types: [], positions: []).index(ofTag: 1) == nil)
    }

    @Test func valuesOnlyForTheCarriedQuantity() {
        let frame = sampleFrame(quantity: "vx", values: [1, 2, 3, 4])
        #expect(frame.values(for: "vx") == [1, 2, 3, 4])
        #expect(frame.values(for: "vy") == nil)
        #expect(sampleFrame(quantity: "vx", values: [1, 2]).values(for: "vx") == nil)
        #expect(sampleFrame(quantity: "vx").values(for: "vx") == nil)
    }

    @Test func typeCountDefaultsToHighestType() {
        let frame = AtomFrame(tags: [1, 2], types: [3, 1], positions: [.zero, .zero])
        #expect(frame.typeCount == 3)
        #expect(frame.highestType == 3)
        var declared = sampleFrame()
        declared.typeCount = 5
        #expect(declared.highestType == 5)
        #expect(AtomFrame(tags: [], types: [], positions: []).highestType == 1)
    }
}

@Suite struct SceneBuilderTests {
    @Test func colorsByType() {
        let scene = SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                       selectedTag: nil, showBox: false, bondRadius: 0.1)
        let particles = scene.particles
        #expect(particles.count == 4)
        #expect(particles.positions == sampleFrame().positions)
        #expect(particles.styleIndices == [1, 2, 1, 2])
        #expect(particles.styles == sampleStyles)
        #expect(particles.colors == nil)
        #expect(particles.radii == nil)
        #expect(particles.flags == nil)
        #expect(scene.lines.isEmpty)
        #expect(scene.images == [.zero])
        let bonds = scene.bonds
        #expect(bonds?.pairs == [SIMD2(0, 1), SIMD2(2, 3)])
        #expect(bonds?.radius == 0.1)
        #expect(bonds?.colors == nil)
        #expect(bonds?.maxLength == 2.5)    // half the shortest periodic length (5)
    }

    @Test func maxBondLengthFollowsPeriodicAxes() {
        let low = SIMD3<Double>(0, 0, -0.5), high = SIMD3<Double>(10, 6, 0.5)
        #expect(SceneBuilder.maxBondLength(boxLow: low, boxHigh: high, periodic: [true, true, true]) == 0.5)
        #expect(SceneBuilder.maxBondLength(boxLow: low, boxHigh: high, periodic: [true, true, true],
                                           dimension: 2) == 3)
        #expect(SceneBuilder.maxBondLength(boxLow: low, boxHigh: high, periodic: [true, false, false]) == 5)
        #expect(SceneBuilder.maxBondLength(boxLow: low, boxHigh: high, periodic: [false, false, false]) == .infinity)
        #expect(SceneBuilder.maxBondLength(boxLow: low, boxHigh: high, periodic: []) == .infinity)
        #expect(SceneBuilder.maxBondLength(boxLow: high, boxHigh: low, periodic: [true, true, true]) == .infinity)
    }

    @Test func unknownTypesUseTheFallbackStyle() {
        var frame = sampleFrame()
        frame.types = [0, 7, -1, 2]
        let scene = SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                       showBox: false, bondRadius: 0)
        #expect(scene.particles.styleIndices == [0, 0, 0, 2])
        let empty = SceneBuilder.scene(from: frame, typeStyles: [], colorMode: .type, selectedTag: nil,
                                       showBox: false, bondRadius: 0)
        #expect(empty.particles.styles == [SceneBuilder.fallbackStyle])
        #expect(empty.particles.styleIndices == [0, 0, 0, 0])
    }

    @Test func bondsOffWithZeroRadiusAndInvalidPairsDropped() {
        var frame = sampleFrame()
        #expect(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0).bonds == nil)
        frame.bonds = [SIMD2(0, 1), SIMD2(3, 4), SIMD2(9, 0)]
        let scene = SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                       showBox: false, bondRadius: 0.2)
        #expect(scene.bonds?.pairs == [SIMD2(0, 1)])
        frame.bonds = [SIMD2(3, 4)]
        #expect(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0.2).bonds == nil)
        frame.bonds = []
        #expect(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0.2).bonds == nil)
    }

    @Test func perAtomRadiiPassThroughWhenComplete() {
        var frame = sampleFrame()
        frame.radii = [0.1, 0.2, 0.3, 0.4]
        #expect(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0).particles.radii == [0.1, 0.2, 0.3, 0.4])
        frame.radii = [0.1]
        #expect(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                   showBox: false, bondRadius: 0).particles.radii == nil)
    }

    @Test func selectionSetsOneFlag() {
        let scene = SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                       selectedTag: 9, showBox: false, bondRadius: 0)
        #expect(scene.particles.flags == [0, 0, SceneBuilder.selectedFlag, 0])
        let missing = SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                         selectedTag: 3, showBox: false, bondRadius: 0)
        #expect(missing.particles.flags == nil)
    }

    @Test func perAtomColorsWithAutomaticRange() throws {
        let frame = sampleFrame(quantity: "c_ke", values: [2, 4, 6, 3])
        let mode = ColorMode.perAtom(quantity: "c_ke", colormap: .viridis, range: nil)
        let scene = SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: mode, selectedTag: nil,
                                       showBox: false, bondRadius: 0)
        let colors = try #require(scene.particles.colors)
        #expect(colors.count == 4)
        #expect(isClose(colors[0], Colormap.viridis.color(at: 0)))
        #expect(isClose(colors[2], Colormap.viridis.color(at: 1)))
        #expect(isClose(colors[1], Colormap.viridis.color(at: 0.5), 0.02))
        #expect(SceneBuilder.colorRange(for: frame, colorMode: mode) == 2...6)
        // Type styles stay, for the radius.
        #expect(scene.particles.styleIndices == [1, 2, 1, 2])
    }

    @Test func perAtomColorsWithFixedRangeClamp() throws {
        let frame = sampleFrame(quantity: "vx", values: [-10, 0, 10, .nan])
        let mode = ColorMode.perAtom(quantity: "vx", colormap: .grayscale, range: -1...1)
        let colors = try #require(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: mode,
                                                     selectedTag: nil, showBox: false, bondRadius: 0).particles.colors)
        #expect(isClose(colors[0], Colormap.grayscale.color(at: 0)))
        #expect(isClose(colors[1], Colormap.grayscale.color(at: 0.5), 0.02))
        #expect(isClose(colors[2], Colormap.grayscale.color(at: 1)))
        #expect(isClose(colors[3], Colormap.grayscale.color(at: 0.5), 0.02))
        #expect(SceneBuilder.colorRange(for: frame, colorMode: mode) == -1...1)
    }

    @Test func perAtomFallsBackToTypesUntilValuesArrive() {
        let mode = ColorMode.perAtom(quantity: "vx", colormap: .jet, range: nil)
        let waiting = SceneBuilder.scene(from: sampleFrame(quantity: "vy", values: [1, 2, 3, 4]),
                                         typeStyles: sampleStyles, colorMode: mode, selectedTag: nil, showBox: false,
                                         bondRadius: 0)
        #expect(waiting.particles.colors == nil)
        #expect(SceneBuilder.colorRange(for: sampleFrame(), colorMode: mode) == nil)
        #expect(SceneBuilder.colorRange(for: sampleFrame(quantity: "vx", values: [1, 1, 1, 1]), colorMode: .type) == nil)
    }

    @Test func constantValuesGetTheMiddleColor() throws {
        let frame = sampleFrame(quantity: "q", values: [1, 1, 1, 1])
        let mode = ColorMode.perAtom(quantity: "q", colormap: .plasma, range: nil)
        let colors = try #require(SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: mode,
                                                     selectedTag: nil, showBox: false, bondRadius: 0).particles.colors)
        #expect(colors.allSatisfy { isClose($0, Colormap.plasma.color(at: 0.5), 0.02) })
    }

    @Test func boxLinesWhenShown() throws {
        let scene = SceneBuilder.scene(from: sampleFrame(), typeStyles: sampleStyles, colorMode: .type,
                                       selectedTag: nil, showBox: true, bondRadius: 0)
        let line = try #require(scene.lines.first)
        #expect(scene.lines.count == 1)
        #expect(line.segments.count == 12)
        #expect(line.color == SceneBuilder.boxColor)
        #expect(line.width == SceneBuilder.boxLineWidth)
    }

    @Test func stylesFromScriptDirectives() {
        let directives = ScriptDirectives.parse("#/atom 1 1.0 #ff0000\n#/atom 2 2.0 #0000ff\n")
        let table = AtomStyleTable(directives: directives, typeCount: 3, units: "lj")
        let styles = SceneBuilder.particleStyles(from: table, typeCount: 3)
        #expect(styles.count == 4)
        #expect(styles[0] == SceneBuilder.fallbackStyle)
        for type in 1...3 {
            let style = table.style(forType: type)
            #expect(styles[type].radius == Float(style.radius))
            #expect(isClose(styles[type].color, style.color.linear))
        }
        #expect(isClose(styles[1].color, SIMD4(1, 0, 0, 1)))
        #expect(isClose(styles[2].color, SIMD4(0, 0, 1, 1)))
        #expect(styles[2].radius > styles[1].radius)

        let scene = SceneBuilder.scene(from: sampleFrame(), styles: table, colorMode: .type, selectedTag: nil,
                                       showBox: false, bondRadius: 0)
        #expect(scene.particles.styles.count == 3)   // fallback + the frame's 2 types
        #expect(SceneBuilder.particleStyles(from: table, typeCount: 0) == [SceneBuilder.fallbackStyle])
    }

    @Test func defaultBondRadiusFollowsTheSmallestAtom() {
        let directives = ScriptDirectives.parse("#/atom 1 1.0 #ff0000\n#/atom 2 2.0 #0000ff\n")
        let table = AtomStyleTable(directives: directives, typeCount: 2, units: "lj")
        let smallest = Float(min(table.style(forType: 1).radius, table.style(forType: 2).radius))
        #expect(isClose(SceneBuilder.defaultBondRadius(styles: table, typeCount: 2), 0.35 * smallest))
    }
}

@Suite struct BoxGeometryTests {
    @Test func orthogonalBoxEdges() {
        let edges = SceneBuilder.boxEdges(low: SIMD3(0, 0, 0), high: SIMD3(1, 2, 3), tilt: .zero)
        #expect(edges.count == 12)
        // Every edge is parallel to an axis, with the box's lengths.
        var lengths: [Float] = []
        for (a, b) in edges {
            let d = b - a
            #expect([d.x, d.y, d.z].filter { $0 != 0 }.count == 1)
            lengths.append(simd_length(d))
        }
        #expect(lengths.sorted() == [1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3])
        // Corners 0 and 7 are low and high.
        let corners = SceneBuilder.boxCorners(low: SIMD3(0, 0, 0), high: SIMD3(1, 2, 3), tilt: .zero)
        #expect(corners[0] == SIMD3(0, 0, 0))
        #expect(corners[7] == SIMD3(1, 2, 3))
        #expect(Set(edges.flatMap { [$0.0, $0.1] }) == Set(corners))
    }

    @Test func triclinicTiltShiftsTheUpperCorners() {
        // tilt = (xy, xz, yz)
        let corners = SceneBuilder.boxCorners(low: SIMD3(0, 0, 0), high: SIMD3(10, 10, 10), tilt: SIMD3(2, 3, 4))
        #expect(corners[1] == SIMD3(10, 0, 0))          // a
        #expect(corners[2] == SIMD3(2, 10, 0))          // b = (xy, ly, 0)
        #expect(corners[4] == SIMD3(3, 4, 10))          // c = (xz, yz, lz)
        #expect(corners[7] == SIMD3(15, 14, 10))        // a + b + c
        let edges = SceneBuilder.boxEdges(low: SIMD3(0, 0, 0), high: SIMD3(10, 10, 10), tilt: SIMD3(2, 3, 4))
        #expect(edges.count == 12)
        #expect(edges.contains { $0.0 == corners[0] && $0.1 == corners[4] })
        #expect(edges.contains { $0.0 == corners[3] && $0.1 == corners[7] })

        let bounds = SceneBuilder.bounds(low: SIMD3(0, 0, 0), high: SIMD3(10, 10, 10), tilt: SIMD3(2, 3, 4))
        #expect(bounds.low == SIMD3(0, 0, 0))
        #expect(bounds.high == SIMD3(15, 14, 10))
        let negative = SceneBuilder.bounds(low: SIMD3(0, 0, 0), high: SIMD3(10, 10, 10), tilt: SIMD3(-2, 0, 0))
        #expect(negative.low == SIMD3(-2, 0, 0))
        #expect(negative.high == SIMD3(10, 10, 10))
    }

    @Test func twoDimensionalBoxIsARectangleAtZeroOrInside() {
        let edges = SceneBuilder.boxEdges(low: SIMD3(0, 0, -0.5), high: SIMD3(4, 2, 0.5), tilt: SIMD3(1, 0, 0),
                                          dimension: 2)
        #expect(edges.count == 4)
        #expect(edges.allSatisfy { $0.0.z == 0 && $0.1.z == 0 })
        let points = Set(edges.flatMap { [$0.0, $0.1] })
        #expect(points == [SIMD3(0, 0, 0), SIMD3(4, 0, 0), SIMD3(1, 2, 0), SIMD3(5, 2, 0)])

        let above = SceneBuilder.boxEdges(low: SIMD3(0, 0, 1), high: SIMD3(1, 1, 2), tilt: .zero, dimension: 2)
        #expect(above.allSatisfy { $0.0.z == 1 && $0.1.z == 1 })
    }

    @Test func frameScenesUseTheFrameDimension() throws {
        var frame = sampleFrame()
        frame.dimension = 2
        let scene = SceneBuilder.scene(from: frame, typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                       showBox: true, bondRadius: 0)
        #expect(try #require(scene.lines.first).segments.count == 4)
    }
}

@Suite struct WallGeometryTests {
    /// The box of `sampleFrame`: (-1, -2, -3) to (4, 5, 6).
    func frame(walls: [WallPlane] = [], blocks: [WallBlock] = []) -> AtomFrame {
        var frame = sampleFrame()
        frame.walls = walls
        frame.wallBlocks = blocks
        return frame
    }

    @Test func noWallsNoPanels() {
        let scene = SceneBuilder.scene(from: frame(), typeStyles: sampleStyles, colorMode: .type, selectedTag: nil,
                                       showBox: true, bondRadius: 0)
        #expect(scene.panels.isEmpty)
        #expect(scene.lines.count == 1)    // the box
    }

    @Test func blockIsAGlassBoxWithEdges() throws {
        let divider = WallBlock(low: SIMD3(-1, 1, -3), high: SIMD3(4, 1.02, 2))
        let scene = SceneBuilder.scene(from: frame(blocks: [divider]), typeStyles: sampleStyles, colorMode: .type,
                                       selectedTag: nil, showBox: false, bondRadius: 0)
        let panels = try #require(scene.panels.first)
        #expect(scene.panels.count == 1)
        #expect(panels.quads.count == 6)
        #expect(panels.color == SceneBuilder.wallFaceColor)
        let edges = try #require(scene.lines.first)    // walls show without the box
        #expect(scene.lines.count == 1)
        #expect(edges.segments.count == 12)
        #expect(edges.color == SceneBuilder.wallEdgeColor)
        let points = edges.segments.flatMap { [$0.0, $0.1] }
        #expect(points.allSatisfy { $0.y == 1 || isClose($0.y, 1.02) })
        #expect(points.contains(SIMD3(4, 1, 2)))
    }

    @Test func blockIn2DIsAnOutline() {
        var flat = frame(blocks: [WallBlock(low: SIMD3(0, 0, -0.5), high: SIMD3(1, 2, 0.5))])
        flat.dimension = 2
        let walls = SceneBuilder.wallGeometry(for: flat)
        #expect(walls.faces.isEmpty)
        #expect(walls.edges.count == 4)
        #expect(walls.edges.allSatisfy { $0.0.z == 0 && $0.1.z == 0 })
    }

    @Test func planesSpanTheBox() throws {
        // zlo on the box face: a face, no extra edges. x = 2 inside: a face and its outline.
        let walls = SceneBuilder.wallGeometry(for: frame(walls: [WallPlane(face: 4, position: -3),
                                                                 WallPlane(face: 1, position: 2)]))
        #expect(walls.faces.count == 2)
        let floor = walls.faces[0]
        #expect(floor.origin == SIMD3(-1, -2, -3))
        #expect(isClose(simd_length(simd_cross(floor.u, floor.v)), 5 * 7))
        let inner = walls.faces[1]
        #expect(inner.origin.x == 2)
        #expect(isClose(simd_length(simd_cross(inner.u, inner.v)), 7 * 9))
        #expect(walls.edges.count == 4)
        #expect(walls.edges.allSatisfy { $0.0.x == 2 && $0.1.x == 2 })
    }

    @Test func planesOutsideTheBoxIn2DOrTriclinicAreLeftOut() {
        #expect(SceneBuilder.wallGeometry(for: frame(walls: [WallPlane(face: 5, position: 7)])).faces.isEmpty)
        var flat = frame(walls: [WallPlane(face: 0, position: 0)])
        flat.dimension = 2
        #expect(SceneBuilder.wallGeometry(for: flat).faces.isEmpty)
        var tilted = frame(walls: [WallPlane(face: 0, position: 0)])
        tilted.tilt = SIMD3(1, 0, 0)
        #expect(SceneBuilder.wallGeometry(for: tilted).faces.isEmpty)
    }

    @Test func snapshotWallsReachTheFrame() {
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: .zero, boxHigh: SIMD3(repeating: 4), tags: [], types: [],
                                          positions: [], walls: [WallPlane(face: 0, position: 0)],
                                          wallBlocks: [WallBlock(low: .zero, high: .one)])
        let frame = AtomFrame(snapshot)
        #expect(frame.walls == snapshot.walls)
        #expect(frame.wallBlocks == snapshot.wallBlocks)
    }
}
