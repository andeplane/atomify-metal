import AtomifyEngine
import Testing
import simd
@testable import AtomifyVision
#if canImport(Metal)
import Metal
#endif

struct ImpostorFrameTests {
    private func snapshot() -> SimulationSnapshot {
        SimulationSnapshot(typeCount: 2, boxLow: .zero, boxHigh: [10, 10, 10], tags: [1, 2, 3], types: [1, 2, 1],
                           positions: [[1, 1, 1], [2, 1, 1], [5, 5, 5]], bonds: [SIMD2(0, 1)])
    }

    @Test func instancesFollowStylesAndBonds() {
        let styles = AtomStyleTable(directives: ScriptDirectives(), typeCount: 2, units: "lj")
        let frame = ImpostorFrame.build(snapshot: snapshot(), styles: styles, atomScale: 2, bondRadius: 0.1,
                                        includeBonds: true)
        #expect(frame.atoms.count == 3)
        #expect(frame.atoms[0].centerRadius == SIMD4(1, 1, 1, Float(styles.style(forType: 1).radius) * 2))
        let rgb = { (c: SIMD4<Float>) in SIMD3(c.x, c.y, c.z) }
        #expect(rgb(frame.atoms[0].color) == rgb(frame.atoms[2].color))
        #expect(rgb(frame.atoms[0].color) != rgb(frame.atoms[1].color))
        #expect(frame.atoms.allSatisfy { $0.color.w == 1 })    // three atoms enclose nothing
        #expect(frame.cylinders.count == 1)
        #expect(frame.cylinders[0].startColor == frame.atoms[0].color)
        #expect(frame.cylinders[0].endColor == frame.atoms[1].color)
        #expect(MemoryLayout<ImpostorAtom>.stride == 32)
        #expect(MemoryLayout<ImpostorCylinder>.stride == 64)

        let noBonds = ImpostorFrame.build(snapshot: snapshot(), styles: styles, atomScale: 1, bondRadius: 0.1,
                                          includeBonds: false)
        #expect(noBonds.cylinders.isEmpty)
    }

    @Test func highlightEnlargesTheGrabbedAtom() {
        let styles = AtomStyleTable(directives: ScriptDirectives(), typeCount: 2, units: "lj")
        let plain = ImpostorFrame.build(snapshot: snapshot(), styles: styles, atomScale: 1, bondRadius: 0,
                                        includeBonds: false)
        let lit = ImpostorFrame.build(snapshot: snapshot(), styles: styles, atomScale: 1, bondRadius: 0,
                                      includeBonds: false, highlightedTags: [3])
        #expect(lit.atoms[2].centerRadius.w > plain.atoms[2].centerRadius.w)
        #expect(lit.atoms[0] == plain.atoms[0])
    }

    @Test func atomsInsideASolidGetLessAmbientLightThanAtomsOnItsSurface() {
        // A 20 x 20 x 20 simple cubic block with spacing 1.
        var positions: [SIMD3<Float>] = []
        for x in 0..<20 {
            for y in 0..<20 {
                for z in 0..<20 {
                    positions.append(SIMD3<Float>(Float(x), Float(y), Float(z)))
                }
            }
        }
        let ambient = ImpostorFrame.ambientOcclusion(positions: positions, spacing: 1)
        #expect(ambient.count == positions.count)
        // Index of the atom at (x, y, z).
        func atom(_ x: Int, _ y: Int, _ z: Int) -> Float { ambient[(x * 20 + y) * 20 + z] }
        let center: Float = atom(10, 10, 10)
        let corner: Float = atom(0, 0, 0)
        let face: Float = atom(10, 10, 0)
        #expect(center < 0.5, "center \(center)")
        #expect(corner == 1, "corner \(corner)")
        #expect(face > center + 0.2, "face \(face), center \(center)")
        #expect(ambient.allSatisfy { $0 >= 0.44 && $0 <= 1 })

        // A gas: too sparse for anything to be enclosed.
        var gas: [SIMD3<Float>] = []
        for i in 0..<200 {
            let x = Float(i % 7), y = Float(i / 7 % 7), z = Float(i / 49)
            gas.append(SIMD3<Float>(x, y, z) * 9)
        }
        #expect(ImpostorFrame.ambientOcclusion(positions: gas, spacing: 1).isEmpty)
    }

    @Test func boxHasTwelveEdgesAndColorsAreLinear() {
        #expect(ImpostorFrame.boxEdges(low: .zero, high: .one, radius: 0.01, color: .one).count == 12)
        let mid = ImpostorFrame.linearColor(RGBColor(red: 0.5, green: 0, blue: 1))
        #expect(abs(mid.x - 0.214) < 0.002)
        #expect(mid.y == 0 && mid.z == 1)
    }
}

#if canImport(Metal)
/// Renders offscreen and reads the depth back: the point of the impostors is
/// that a sphere's depth is its curved surface, not a flat card.
struct ImpostorRenderTests {
    static let size = 64
    static let near: Float = 0.1

    /// Reverse-Z, infinite far plane, 90 degree field of view, square.
    static let projection = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, -1),
                                                    SIMD4(0, 0, near, 0)))

    struct Image {
        var depths: [Float]
        var colors: [UInt8]
        func depth(_ x: Int, _ y: Int) -> Float { depths[y * ImpostorRenderTests.size + x] }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { colors[(y * ImpostorRenderTests.size + x) * 4 + 3] }
        func red(_ x: Int, _ y: Int) -> UInt8 { colors[(y * ImpostorRenderTests.size + x) * 4] }
    }

    /// With `sampleCount` above 1, color is resolved and depth is not read
    /// back (depth resolve needs an Apple GPU family the runners may lack).
    func render(_ frame: ImpostorFrame, device: any MTLDevice, sampleCount: Int = 1) throws -> Image {
        let size = Self.size
        let renderer = try ImpostorRenderer(device: device, colorFormat: .rgba8Unorm, depthFormat: .depth32Float,
                                            sampleCount: sampleCount)
        func texture(_ format: MTLPixelFormat, samples: Int = 1) -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size,
                                                                      mipmapped: false)
            if samples > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = samples
            }
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)!
        }
        let color = texture(.rgba8Unorm), depth = texture(.depth32Float)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        if sampleCount > 1 {
            pass.colorAttachments[0].texture = texture(.rgba8Unorm, samples: sampleCount)
            pass.colorAttachments[0].resolveTexture = color
            pass.colorAttachments[0].storeAction = .multisampleResolve
            pass.depthAttachment.texture = texture(.depth32Float, samples: sampleCount)
            pass.depthAttachment.storeAction = .dontCare
        } else {
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.storeAction = .store
        }

        let queue = device.makeCommandQueue()!
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        renderer.encode(renderer.upload(frame), worldFromSimulation: frame.worldFromSimulation,
                        viewFromWorld: matrix_identity_float4x4, projection: Self.projection, into: encoder)
        encoder.endEncoding()

        let depthBuffer = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
        let colorBuffer = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
        let blit = commands.makeBlitCommandEncoder()!
        for (source, destination) in [(depth, depthBuffer), (color, colorBuffer)] {
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: size, height: size, depth: 1), to: destination,
                      destinationOffset: 0, destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
        }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.error == nil)

        let depthValues = Array(UnsafeBufferPointer(start: depthBuffer.contents().assumingMemoryBound(to: Float.self),
                                                    count: size * size))
        let colorValues = Array(UnsafeBufferPointer(start: colorBuffer.contents().assumingMemoryBound(to: UInt8.self),
                                                    count: size * size * 4))
        return Image(depths: depthValues, colors: colorValues)
    }

    /// Pixel row whose center looks along view-space height `y` at distance `z`.
    func row(y: Float, z: Float) -> Int {
        let ndc = y / -z
        return Int(((1 - ndc) / 2 * Float(Self.size)).rounded(.down))
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func spheresAndCylindersWriteCurvedDepth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var frame = ImpostorFrame()
        frame.atoms = [ImpostorAtom(center: [0, 0.5, -5], radius: 1, color: [1, 0, 0, 1])]
        frame.cylinders = [ImpostorCylinder(from: [-3, -2, -6], to: [3, -2, -6], radius: 0.5,
                                            startColor: [0, 1, 0, 1], endColor: [0, 0, 1, 1])]
        let image = try render(frame, device: device)
        let middle = Self.size / 2

        // Sphere: the front of the surface is 1 unit nearer than its center.
        let sphereRow = row(y: 0.5, z: -5)
        let sphereDepth = image.depth(middle, sphereRow)
        #expect(abs(sphereDepth - Self.near / 4) < 0.0015, "sphere depth \(sphereDepth)")
        #expect(image.alpha(middle, sphereRow) == 255)
        #expect(image.red(middle, sphereRow) > 100)

        // Cylinder: nearer than its axis, farther than the sphere.
        let cylinderDepth = image.depth(middle, row(y: -2, z: -6))
        #expect(cylinderDepth > Self.near / 6 + 0.0005, "cylinder depth \(cylinderDepth)")
        #expect(cylinderDepth < Self.near / 5.4, "cylinder depth \(cylinderDepth)")

        // Empty pixels stay clear with zero depth, as passthrough needs.
        #expect(image.alpha(1, 1) == 0)
        #expect(image.depth(1, 1) == 0)
        #expect(image.depth(Self.size - 2, middle) == 0)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func overlappingSpheresIntersectInsteadOfStacking() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The far sphere is larger, so its front surface pokes through the
        // middle of the near one. Flat cards would hide it completely.
        var frame = ImpostorFrame()
        frame.atoms = [ImpostorAtom(center: [0, 0, -5], radius: 0.6, color: [1, 0, 0, 1]),
                       ImpostorAtom(center: [0, 0, -5.5], radius: 1.2, color: [0, 0, 1, 1])]
        let image = try render(frame, device: device)
        let middle = Self.size / 2
        #expect(abs(image.depth(middle, middle) - Self.near / 4.3) < 0.0015)
        #expect(image.red(middle, middle) < 50)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice()?.supportsTextureSampleCount(4) == true))
    func multisampledEdgesAreSmooth() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var frame = ImpostorFrame()
        frame.atoms = [ImpostorAtom(center: [0, 0, -5], radius: 1.7, color: [1, 1, 1, 1])]
        let image = try render(frame, device: device, sampleCount: 4)
        let middle = Self.size / 2
        #expect(image.alpha(middle, middle) == 255)
        #expect(image.alpha(1, 1) == 0)
        // Walking out from the center along a row, the edge passes through
        // partly covered pixels instead of jumping from opaque to clear.
        let row = (middle..<Self.size).map { image.alpha($0, middle) }
        #expect(row.contains { $0 > 20 && $0 < 235 }, "alpha along the row: \(row)")
    }
}
#endif

struct BuriedAtomTests {
    @Test func onlyAtomsDeepInsideASolidAreBuried() {
        var positions: [SIMD3<Float>] = []
        for z in 0..<20 {
            for y in 0..<20 {
                for x in 0..<20 {
                    positions.append(SIMD3(Float(x), Float(y), Float(z)))
                }
            }
        }
        let buried = ImpostorFrame.buriedAtoms(positions: positions, cell: 2)
        #expect(buried.count == positions.count)
        let index = { (x: Int, y: Int, z: Int) in (z * 20 + y) * 20 + x }
        #expect(buried[index(10, 10, 10)])
        #expect(!buried[index(0, 10, 10)])
        #expect(!buried[index(10, 19, 10)])
        // Most of a solid block is hidden.
        #expect(buried.filter { $0 }.count > positions.count / 3)

        // Hidden atoms are left out of the frame.
        let snapshot = SimulationSnapshot(typeCount: 1, boxLow: .zero, boxHigh: [20, 20, 20],
                                          tags: positions.indices.map { Int64($0 + 1) },
                                          types: [Int32](repeating: 1, count: positions.count),
                                          positions: positions, bonds: [])
        let styles = AtomStyleTable(directives: ScriptDirectives(), typeCount: 1, units: "lj")
        let frame = ImpostorFrame.build(snapshot: snapshot, styles: styles, atomScale: 1, bondRadius: 0.1,
                                        includeBonds: false, hidden: buried)
        #expect(frame.atoms.count == buried.filter { !$0 }.count)
    }

    @Test func aGasHasNothingBuried() {
        var positions: [SIMD3<Float>] = []
        for i in 0..<200 {
            let f = Float(i)
            positions.append(SIMD3(f * 3.1, (f * 7.3).truncatingRemainder(dividingBy: 50), (f * 11.7).truncatingRemainder(dividingBy: 50)))
        }
        #expect(ImpostorFrame.buriedAtoms(positions: positions, cell: 1).isEmpty)
    }
}

#if canImport(Metal)
struct AtomBlockTests {
    private func cube(_ side: Int) -> [ImpostorAtom] {
        var atoms: [ImpostorAtom] = []
        for z in 0..<side {
            for y in 0..<side {
                for x in 0..<side {
                    atoms.append(ImpostorAtom(center: SIMD3(Float(x), Float(y), Float(z)), radius: 0.4,
                                              color: SIMD4(1, 1, 1, 1)))
                }
            }
        }
        return atoms
    }

    @Test func blocksKeepEveryAtomOnceAndBoundTheirAtoms() {
        let atoms = cube(30)
        let (sorted, blocks) = ImpostorRenderer.blocked(atoms)
        #expect(sorted.count == atoms.count)
        #expect(blocks.count == 512)
        #expect(blocks.reduce(0) { $0 + $1.count } == atoms.count)
        #expect(Set(sorted.map { $0.centerRadius }).count == atoms.count)
        for block in blocks {
            for atom in sorted[block.start..<(block.start + block.count)] {
                let c = SIMD3(atom.centerRadius.x, atom.centerRadius.y, atom.centerRadius.z)
                #expect(all(c .>= block.low) && all(c .<= block.high))
            }
        }
        // Small frames are left alone.
        let small = cube(5)
        #expect(ImpostorRenderer.blocked(small).1.count == 1)
        #expect(ImpostorRenderer.blocked(small).0 == small)
    }

    @Test func viewSkipsBlocksBehindAndSortsNearestFirst() {
        let (_, blocks) = ImpostorRenderer.blocked(cube(30))
        // Camera at the cube's centre looking down -z: the half with
        // z above the camera is behind it.
        var modelView = matrix_identity_float4x4
        modelView.columns.3 = SIMD4(-15, -15, -15, 1)
        let f: Float = 1 / tan(0.6), near: Float = 0.01
        let projection = simd_float4x4(columns: (SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1),
                                                 SIMD4(0, 0, near, 0)))
        let visible = ImpostorRenderer.visibleBlocks(blocks, modelView: modelView, projection: projection)
        #expect(!visible.isEmpty && visible.count < blocks.count)
        #expect(visible.allSatisfy { $0.low.z < 15 })
        let depths = visible.map { 15 - ($0.low.z + $0.high.z) / 2 }
        #expect(depths == depths.sorted())
    }

    @Test func sampledBlocksSpreadTheirFirstAtomsAcrossTheBlock() {
        let atoms = cube(16)
        let (sorted, blocks) = ImpostorRenderer.blocked(atoms, divisions: 2, sampled: true)
        #expect(blocks.count == 8)
        #expect(Set(sorted.map { $0.centerRadius }).count == atoms.count)
        // The first quarter of a block (8×8×8 atoms) reaches into each of
        // its octants, rather than filling one corner.
        let block = blocks[0]
        let quarter = sorted[block.start..<(block.start + block.count / 4)]
        let octants = Set(quarter.map { atom in
            Int(atom.centerRadius.x) / 4 + 2 * (Int(atom.centerRadius.y) / 4) + 4 * (Int(atom.centerRadius.z) / 4)
        })
        #expect(octants.count == 8)
        // The order depends only on the atoms' indices, so a moving system
        // keeps the same sample from frame to frame.
        #expect(ImpostorRenderer.blocked(atoms, divisions: 2, sampled: true).0 == sorted)
    }

    @Test func distantCopiesDropDetailToFitTheBudget() {
        let (_, blocks) = ImpostorRenderer.blocked(cube(10), divisions: 2, sampled: true)
        // Three copies along -z, the camera just in front of the first,
        // looking down -z into them.
        let images: [SIMD3<Float>] = [.zero, SIMD3(0, 0, -10), SIMD3(0, 0, -20)]
        var modelView = matrix_identity_float4x4
        modelView.columns.3 = SIMD4(-4.5, -4.5, -30, 1)
        let f: Float = 1 / tan(0.6), near: Float = 0.01
        let projection = simd_float4x4(columns: (SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1),
                                                 SIMD4(0, 0, near, 0)))
        func detail(budget: Int) -> [Int: Int] {
            let draws = ImpostorRenderer.visibleDraws(blocks, images: images, modelView: modelView,
                                                      projection: projection, budget: budget)
            #expect(Set(draws.map(\.image)) == [0, 1, 2])
            return Dictionary(draws.map { ($0.image, $0.detail) }, uniquingKeysWith: { max($0, $1) })
        }
        #expect(detail(budget: .max) == [0: 0, 1: 0, 2: 0])
        // 3000 atoms in view: 2500 fits by thinning only the farthest copy.
        #expect(detail(budget: 2500) == [0: 0, 1: 0, 2: 1])
        #expect(detail(budget: 800) == [0: 1, 1: 1, 2: 1])
        #expect(detail(budget: 700) == [0: 1, 1: 1, 2: 2])
        #expect(detail(budget: 0) == [0: 2, 1: 2, 2: 2])
        // Fewer atoms are drawn, and larger.
        let draw = ImpostorRenderer.Draw(block: blocks[0], image: 0, detail: 1)
        #expect(draw.count == blocks[0].count / 4)
        #expect(ImpostorRenderer.Draw.radiusScale(detail: 1) == 2)
    }
}
#endif
