import AtomifyEngine
#if canImport(Metal)
import Foundation
import Metal
import simd

/// Draws an `ImpostorFrame` with Metal: one instanced draw for all atoms and
/// one for all cylinders, whatever the number of atom types. Cost per atom is
/// four vertices, so hundreds of thousands of atoms stay interactive.
///
/// Not thread safe; use it from the render thread only.
public final class ImpostorRenderer {
    public let device: any MTLDevice
    private let atomPipeline: any MTLRenderPipelineState
    private let cylinderPipeline: any MTLRenderPipelineState
    private let depthState: any MTLDepthStencilState

    /// GPU copies of one frame's atoms and cylinders. Immutable once made,
    /// so they can be built on one thread and drawn on another.
    public final class Buffers: @unchecked Sendable {
        public let generation: UInt64
        fileprivate let atoms: (any MTLBuffer)?
        public let atomCount: Int
        fileprivate let cylinders: (any MTLBuffer)?
        fileprivate let cylinderCount: Int
        /// Atoms grouped into spatial blocks, so each view can skip blocks
        /// outside it and draw the rest nearest first.
        fileprivate let blocks: [AtomBlock]
        /// Offsets (simulation units) at which the atoms are drawn: one
        /// zero offset, or periodic copies of the box, the zero one first.
        /// Cylinders are drawn once, unshifted.
        fileprivate let images: [SIMD3<Float>]

        fileprivate init(generation: UInt64, atoms: (any MTLBuffer)?, atomCount: Int,
                         cylinders: (any MTLBuffer)?, cylinderCount: Int, blocks: [AtomBlock],
                         images: [SIMD3<Float>]) {
            self.generation = generation
            self.atoms = atoms; self.atomCount = atomCount
            self.cylinders = cylinders; self.cylinderCount = cylinderCount
            self.blocks = blocks
            self.images = images
        }

        /// Atoms drawn when every copy is in view.
        public var drawnAtomCount: Int { atomCount * images.count }
    }

    /// A run of atoms in the buffer and the box (simulation units, radii
    /// included) that holds them.
    struct AtomBlock: Equatable {
        var start: Int
        var count: Int
        var low: SIMD3<Float>
        var high: SIMD3<Float>
    }

    /// Small frames are drawn in one call; above this, atoms are blocked.
    static let blockingThreshold = 20_000

    public enum RendererError: Error { case missingFunction(String), depthState }

    /// `reverseZ` matches Vision Pro, where depth 1 is near and 0 is far.
    /// With `sampleCount` above 1, edges are antialiased through
    /// alpha-to-coverage; render into multisample targets and resolve.
    public init(device: any MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat,
                sampleCount: Int = 1, reverseZ: Bool = true) throws {
        self.device = device
        // The proxies are in front of the surfaces: farther means smaller
        // depth with reverse Z, larger without.
        let source = reverseZ ? ImpostorShaders.source
            : ImpostorShaders.source.replacingOccurrences(of: "[[depth(less)]]", with: "[[depth(greater)]]")
        let library = try device.makeLibrary(source: source, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> any MTLRenderPipelineState {
            guard let vertexFunction = library.makeFunction(name: vertex) else {
                throw RendererError.missingFunction(vertex)
            }
            guard let fragmentFunction = library.makeFunction(name: fragment) else {
                throw RendererError.missingFunction(fragment)
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            descriptor.rasterSampleCount = sampleCount
            // Alpha carries edge coverage; covered samples are opaque.
            descriptor.isAlphaToCoverageEnabled = sampleCount > 1
            descriptor.isAlphaToOneEnabled = sampleCount > 1
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        atomPipeline = try pipeline("atomVertex", "atomFragment")
        cylinderPipeline = try pipeline("cylinderVertex", "cylinderFragment")

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = reverseZ ? .greater : .less
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw RendererError.depthState
        }
        self.depthState = depthState
    }

    /// Atoms drawn per view, at most, when periodic copies are drawn:
    /// above it, the copies farthest from the eye are drawn with a quarter
    /// (then a sixteenth) of their atoms, each larger to fill the same space.
    public var atomBudget = 800_000

    /// Copies a frame's instances to the GPU. The returned buffers stay
    /// valid until released; command buffers retain what they use.
    public func upload(_ frame: ImpostorFrame) -> Buffers {
        Self.makeBuffers(frame, device: device)
    }

    /// `upload` without a renderer, for building buffers off the render
    /// thread. Metal devices may be used from any thread. `images` are the
    /// offsets of periodic copies to draw the atoms at (simulation units).
    public static func makeBuffers(_ frame: ImpostorFrame, device: any MTLDevice,
                                   images: [SIMD3<Float>] = [.zero]) -> Buffers {
        func buffer<T>(_ items: [T]) -> (any MTLBuffer)? {
            guard !items.isEmpty else { return nil }
            return items.withUnsafeBytes { bytes in
                device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
        }
        // The unshifted atoms come first, so drawing starts without an offset.
        let images = [SIMD3<Float>.zero] + images.filter { $0 != .zero }
        // Coarser blocks with copies, so draw calls stay in the thousands.
        let (atoms, blocks) = blocked(frame.atoms, divisions: images.count > 1 ? 4 : 8,
                                      sampled: images.count > 1)
        return Buffers(generation: frame.generation, atoms: buffer(atoms), atomCount: atoms.count,
                       cylinders: buffer(frame.cylinders), cylinderCount: frame.cylinders.count, blocks: blocks,
                       images: images)
    }

    /// Reorders atoms into up to 8×8×8 spatial blocks (a counting sort,
    /// linear in the atom count). Small frames stay as one block unless
    /// `sampled`, which also orders each block so that any first part of it
    /// is an even sample of the whole block, the same atoms frame after frame.
    static func blocked(_ atoms: [ImpostorAtom], divisions: Int = 8,
                        sampled: Bool = false) -> ([ImpostorAtom], [AtomBlock]) {
        guard atoms.count > blockingThreshold || (sampled && atoms.count > 1), divisions > 1 else {
            return (atoms, atoms.isEmpty ? [] : [bounds(atoms[...], start: 0)])
        }
        var low = atoms[0].center, high = atoms[0].center
        for atom in atoms {
            low = simd_min(low, atom.center)
            high = simd_max(high, atom.center)
        }
        let size = simd_max(high - low, SIMD3(repeating: 1e-6))
        let n = divisions
        let cellOf = { (atom: ImpostorAtom) -> Int in
            let c = (atom.center - low) / size * Float(n)
            let x = min(max(Int(c.x), 0), n - 1), y = min(max(Int(c.y), 0), n - 1), z = min(max(Int(c.z), 0), n - 1)
            return (z * n + y) * n + x
        }
        var counts = [Int](repeating: 0, count: n * n * n)
        let cells = atoms.map(cellOf)
        for cell in cells { counts[cell] += 1 }
        var starts = [Int](repeating: 0, count: counts.count)
        var running = 0
        for i in counts.indices {
            starts[i] = running
            running += counts[i]
        }
        var next = starts
        var order = [Int](repeating: 0, count: atoms.count)
        for (index, cell) in cells.enumerated() {
            order[next[cell]] = index
            next[cell] += 1
        }
        if sampled {
            // A fixed scramble of each atom's index: the atoms with the
            // smallest keys are spread evenly and stay the same as atoms move.
            for i in counts.indices where counts[i] > 1 {
                order[starts[i]..<(starts[i] + counts[i])].sort { scramble($0) < scramble($1) }
            }
        }
        let sorted = order.map { atoms[$0] }
        var blocks: [AtomBlock] = []
        for i in counts.indices where counts[i] > 0 {
            blocks.append(bounds(sorted[starts[i]..<(starts[i] + counts[i])], start: starts[i]))
        }
        return (sorted, blocks)
    }

    /// A 32-bit integer hash (the murmur3 finalizer).
    private static func scramble(_ index: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: index)
        h ^= h >> 16; h &*= 0x85eb_ca6b
        h ^= h >> 13; h &*= 0xc2b2_ae35
        h ^= h >> 16
        return h
    }

    private static func bounds(_ atoms: ArraySlice<ImpostorAtom>, start: Int) -> AtomBlock {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for atom in atoms {
            let r = SIMD3<Float>(repeating: atom.centerRadius.w)
            low = simd_min(low, atom.center - r)
            high = simd_max(high, atom.center + r)
        }
        return AtomBlock(start: start, count: atoms.count, low: low, high: high)
    }

    /// Blocks inside the view, nearest first, so hidden atoms behind them
    /// fail the early depth test before shading.
    static func visibleBlocks(_ blocks: [AtomBlock], modelView: simd_float4x4,
                              projection: simd_float4x4) -> [AtomBlock] {
        guard blocks.count > 1 else { return blocks }
        return visibleDraws(blocks, images: [.zero], modelView: modelView, projection: projection).map(\.block)
    }

    /// One instanced draw: the first `count` atoms of `block`, shifted to
    /// periodic copy `image`. `detail` 0 draws every atom, 1 a quarter, 2 a
    /// sixteenth.
    struct Draw: Equatable {
        var block: AtomBlock
        var image: Int
        var detail: Int
        var count: Int { max(block.count >> (2 * detail), 1) }
        /// Fewer atoms are drawn larger so they cover the same area: a
        /// quarter of the atoms at twice the radius block as much of the
        /// view as all of them. Scaling to keep the volume instead (4^1/3)
        /// let thinned copies turn see-through and speckled.
        static func radiusScale(detail: Int) -> Float { pow(2, Float(detail)) }
    }

    /// `visibleBlocks` for every periodic copy: each block at each offset
    /// that is in view, nearest first across all copies. While more than
    /// `budget` atoms are in view, the copies farthest from the eye drop to
    /// lower detail first.
    static func visibleDraws(_ blocks: [AtomBlock], images: [SIMD3<Float>], modelView: simd_float4x4,
                             projection: simd_float4x4, budget: Int = .max) -> [Draw] {
        let clipFromModel = projection * modelView
        var visible: [(depth: Float, block: AtomBlock, image: Int)] = []
        visible.reserveCapacity(blocks.count * images.count)
        var inView = [Int](repeating: 0, count: images.count)
        for (image, offset) in images.enumerated() {
            for block in blocks {
                let low = block.low + offset, high = block.high + offset
                // Outside if all eight corners are beyond one clip plane.
                var inside = (left: false, right: false, bottom: false, top: false, front: false)
                for corner in 0..<8 {
                    let p = SIMD3(corner & 1 == 0 ? low.x : high.x,
                                  corner & 2 == 0 ? low.y : high.y,
                                  corner & 4 == 0 ? low.z : high.z)
                    let c = clipFromModel * SIMD4(p, 1)
                    if c.x >= -c.w { inside.left = true }
                    if c.x <= c.w { inside.right = true }
                    if c.y >= -c.w { inside.bottom = true }
                    if c.y <= c.w { inside.top = true }
                    if c.w > 0 { inside.front = true }
                }
                guard inside.left, inside.right, inside.bottom, inside.top, inside.front else { continue }
                let center = modelView * SIMD4((low + high) / 2, 1)
                visible.append((-center.z, block, image))
                inView[image] += block.count
            }
        }
        visible.sort { $0.depth < $1.depth }
        let detail = details(inView: inView, images: images, blocks: blocks, modelView: modelView, budget: budget)
        return visible.map { Draw(block: $0.block, image: $0.image, detail: detail[$0.image]) }
    }

    /// Detail per copy: all full while the atoms in view fit `budget`;
    /// otherwise copies drop a level, farthest from the eye first, until
    /// they fit or all are at the lowest.
    private static func details(inView: [Int], images: [SIMD3<Float>], blocks: [AtomBlock],
                                modelView: simd_float4x4, budget: Int) -> [Int] {
        var detail = [Int](repeating: 0, count: images.count)
        var total = inView.reduce(0, +)
        guard total > budget, images.count > 1, let first = blocks.first else { return detail }
        var low = first.low, high = first.high
        for block in blocks {
            low = simd_min(low, block.low)
            high = simd_max(high, block.high)
        }
        let eye = simd_inverse(modelView) * SIMD4(0, 0, 0, 1)
        let eyePosition = SIMD3(eye.x, eye.y, eye.z)
        // Distance from the eye to each copy's box; zero inside it.
        let distance = images.map { offset -> Float in
            let gap = simd_max(simd_max(low + offset - eyePosition, eyePosition - high - offset), .zero)
            return simd_length(gap)
        }
        let farthestFirst = images.indices.filter { inView[$0] > 0 }.sorted { distance[$0] > distance[$1] }
        for level in 1...2 {
            for image in farthestFirst where total > budget {
                total -= (inView[image] >> (2 * detail[image])) - (inView[image] >> (2 * level))
                detail[image] = level
            }
        }
        return detail
    }

    /// Encodes one view. `viewFromWorld` is the inverse of the camera's
    /// transform (camera looking down -z), `projection` maps view space to
    /// clip space.
    public func encode(_ buffers: Buffers, worldFromSimulation: simd_float4x4, viewFromWorld: simd_float4x4,
                       projection: simd_float4x4, into encoder: any MTLRenderCommandEncoder,
                       lightDirection: SIMD3<Float> = simd_normalize(SIMD3(0.3, 1, 0.45))) {
        let modelView = viewFromWorld * worldFromSimulation
        let scale = simd_length(SIMD3(modelView.columns.0.x, modelView.columns.0.y, modelView.columns.0.z))
        let light = viewFromWorld * SIMD4(lightDirection, 0)
        let uniforms = Uniforms(modelView: modelView, projection: projection, lightDirection: light,
                                params: SIMD4(scale, 1, 0, 0))
        let length = MemoryLayout<Uniforms>.stride
        func set(image: Int, detail: Int) {
            // Each periodic copy is the same atoms, shifted.
            var shifted = uniforms
            shifted.modelView = modelView * Self.translation(buffers.images[image])
            shifted.params.y = Draw.radiusScale(detail: detail)
            encoder.setVertexBytes(&shifted, length: length, index: 1)
            encoder.setFragmentBytes(&shifted, length: length, index: 1)
        }

        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        if let atoms = buffers.atoms, buffers.atomCount > 0 {
            encoder.setRenderPipelineState(atomPipeline)
            encoder.setVertexBuffer(atoms, offset: 0, index: 0)
            var current: (image: Int, detail: Int)?
            for draw in Self.visibleDraws(buffers.blocks, images: buffers.images, modelView: modelView,
                                          projection: projection,
                                          budget: buffers.images.count > 1 ? atomBudget : .max) {
                if current?.image != draw.image || current?.detail != draw.detail {
                    current = (draw.image, draw.detail)
                    set(image: draw.image, detail: draw.detail)
                }
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: draw.count, baseInstance: draw.block.start)
            }
        }
        if let cylinders = buffers.cylinders, buffers.cylinderCount > 0 {
            encoder.setRenderPipelineState(cylinderPipeline)
            encoder.setVertexBuffer(cylinders, offset: 0, index: 0)
            // Once, unshifted: the box edges and arrows already span the
            // copies, and systems drawn with copies have no bonds.
            set(image: 0, detail: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 36,
                                   instanceCount: buffers.cylinderCount)
        }
    }

    /// Atoms `encode` draws for one view, after skipping blocks out of view
    /// and thinning far copies.
    func atomsDrawn(_ buffers: Buffers, worldFromSimulation: simd_float4x4, viewFromWorld: simd_float4x4,
                    projection: simd_float4x4) -> Int {
        Self.visibleDraws(buffers.blocks, images: buffers.images, modelView: viewFromWorld * worldFromSimulation,
                          projection: projection, budget: buffers.images.count > 1 ? atomBudget : .max)
            .reduce(0) { $0 + $1.count }
    }

    private static func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4(offset, 1)
        return matrix
    }

    /// Matches `Uniforms` in the shader source.
    private struct Uniforms {
        var modelView: simd_float4x4
        var projection: simd_float4x4
        var lightDirection: SIMD4<Float>
        var params: SIMD4<Float>
    }
}
private extension ImpostorAtom {
    var center: SIMD3<Float> { SIMD3(centerRadius.x, centerRadius.y, centerRadius.z) }
}
#endif
