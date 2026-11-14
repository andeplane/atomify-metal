import Foundation
import Metal

/// A shared MTLBuffer that only grows (see `BufferGrowth`).
final class GrowableBuffer {
    let device: any MTLDevice
    let label: String
    let stride: Int
    private(set) var buffer: (any MTLBuffer)?
    /// Elements that fit in `buffer`.
    private(set) var capacity = 0

    init(device: any MTLDevice, label: String, stride: Int) {
        self.device = device
        self.label = label
        self.stride = stride
    }

    /// The buffer with room for `count` elements, reallocated (larger) when
    /// needed. The old buffer stays alive for command buffers still using it.
    func reserve(_ count: Int) -> (any MTLBuffer)? {
        guard count > capacity || buffer == nil else { return buffer }
        let newCapacity = BufferGrowth.capacity(required: max(count, 1), current: capacity)
        guard let made = device.makeBuffer(length: newCapacity * stride,
                                           options: [.storageModeShared, .cpuCacheModeWriteCombined]) else {
            return nil
        }
        made.label = label
        buffer = made
        capacity = newCapacity
        return made
    }

    /// Typed pointer to the contents, with room for `count` elements.
    func pointer<T>(_ type: T.Type, count: Int) -> UnsafeMutablePointer<T>? {
        precondition(MemoryLayout<T>.stride == stride, "\(label): element stride mismatch")
        guard let buffer = reserve(count) else { return nil }
        return buffer.contents().bindMemory(to: T.self, capacity: max(count, 1))
    }
}

/// One of the renderer's three sets of per-frame buffers. `update` fills
/// the next slot while the GPU may still read the previous ones.
final class FrameSlot {
    let particles: GrowableBuffer
    let radii: GrowableBuffer
    let colors: GrowableBuffer
    let styles: GrowableBuffer
    let bonds: GrowableBuffer
    let bondColors: GrowableBuffer
    let lines: GrowableBuffer
    let panels: GrowableBuffer

    var particleCount = 0
    var styleCount = 0
    var bondCount = 0
    var lineCount = 0
    var panelCount = 0
    var hasRadii = false
    var hasColors = false
    var hasBondColors = false
    var bondRadius: Float = 0
    var bondMaxLength: Float = .greatestFiniteMagnitude
    var blocks: [ParticleBlock] = []
    /// The bonds of each block (see `BondBlocking`); empty draws them all.
    var bondRanges: [BondRange] = []
    /// Sorted → original particle index, nil when unsorted.
    var order: [UInt32]?
    var images: [SIMD3<Float>] = [.zero]
    var styleTable: [ParticleStyle] = []

    private var commandBuffers: [any MTLCommandBuffer] = []

    init(device: any MTLDevice) {
        particles = GrowableBuffer(device: device, label: "AtomifyRender.particles", stride: MemoryLayout<GPUParticle>.stride)
        radii = GrowableBuffer(device: device, label: "AtomifyRender.radii", stride: MemoryLayout<Float>.stride)
        colors = GrowableBuffer(device: device, label: "AtomifyRender.colors", stride: MemoryLayout<UInt32>.stride)
        styles = GrowableBuffer(device: device, label: "AtomifyRender.styles", stride: MemoryLayout<GPUStyle>.stride)
        bonds = GrowableBuffer(device: device, label: "AtomifyRender.bonds", stride: MemoryLayout<GPUBond>.stride)
        bondColors = GrowableBuffer(device: device, label: "AtomifyRender.bondColors", stride: MemoryLayout<UInt32>.stride)
        lines = GrowableBuffer(device: device, label: "AtomifyRender.lines", stride: MemoryLayout<GPULineSegment>.stride)
        panels = GrowableBuffer(device: device, label: "AtomifyRender.panels", stride: MemoryLayout<GPUPanel>.stride)
    }

    /// Remembers a command buffer that reads this slot.
    func track(_ commandBuffer: any MTLCommandBuffer) {
        commandBuffers.removeAll { $0.status == .completed || $0.status == .error }
        commandBuffers.append(commandBuffer)
    }

    /// Blocks until the GPU has finished every committed command buffer
    /// that reads this slot (rare: only when the host runs more than two
    /// frames ahead).
    func waitUntilAvailable() {
        for commandBuffer in commandBuffers {
            switch commandBuffer.status {
            case .committed, .scheduled:
                commandBuffer.waitUntilCompleted()
            default:
                break
            }
        }
        commandBuffers.removeAll()
    }
}

/// Offscreen textures for the high quality path, sized to the target.
final class HighQualityTargets {
    let width: Int
    let height: Int
    let sampleCount: Int
    /// Lit color, resolved.
    let color: any MTLTexture
    /// View normal (xyz) and inverse view depth (w), resolved.
    let normalDepth: any MTLTexture
    let multisampleColor: (any MTLTexture)?
    let multisampleNormalDepth: (any MTLTexture)?
    let depth: any MTLTexture
    /// Ambient light (r) and view depth (g) at half resolution.
    let occlusion: any MTLTexture

    init?(device: any MTLDevice, width: Int, height: Int, colorFormat: MTLPixelFormat, sampleCount: Int) {
        self.width = width
        self.height = height
        self.sampleCount = sampleCount
        let transient: MTLStorageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, samples: Int, storage: MTLStorageMode,
                     usage: MTLTextureUsage) -> (any MTLTexture)? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(w, 1), height: max(h, 1),
                                                             mipmapped: false)
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            d.storageMode = storage
            d.usage = usage
            return device.makeTexture(descriptor: d)
        }
        let readable: MTLTextureUsage = [.renderTarget, .shaderRead]
        guard let color = texture(colorFormat, width, height, samples: 1, storage: .private, usage: readable),
              let normalDepth = texture(.rgba16Float, width, height, samples: 1, storage: .private, usage: readable),
              let depth = texture(.depth32Float, width, height, samples: sampleCount, storage: transient,
                                  usage: .renderTarget),
              let occlusion = texture(.rg16Float, (width + 1) / 2, (height + 1) / 2, samples: 1, storage: .private,
                                      usage: readable)
        else { return nil }
        self.color = color
        self.normalDepth = normalDepth
        self.depth = depth
        self.occlusion = occlusion
        if sampleCount > 1 {
            guard let mc = texture(colorFormat, width, height, samples: sampleCount, storage: transient,
                                   usage: .renderTarget),
                  let mn = texture(.rgba16Float, width, height, samples: sampleCount, storage: transient,
                                   usage: .renderTarget)
            else { return nil }
            multisampleColor = mc
            multisampleNormalDepth = mn
        } else {
            multisampleColor = nil
            multisampleNormalDepth = nil
        }
    }
}

/// 1×1 targets for the picking pass.
final class PickTargets {
    let id: any MTLTexture
    let depth: any MTLTexture

    init?(device: any MTLDevice) {
        let idDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Uint, width: 1, height: 1,
                                                                    mipmapped: false)
        idDescriptor.usage = [.renderTarget, .shaderRead]
        idDescriptor.storageMode = .private
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: 1, height: 1,
                                                                       mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let id = device.makeTexture(descriptor: idDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor) else { return nil }
        self.id = id
        self.depth = depth
    }
}

/// Depth/stencil facts about pixel formats.
enum PixelFormats {
    static func hasDepth(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .depth16Unorm, .depth32Float, .depth32Float_stencil8:
            return true
        default:
            #if os(macOS)
            return format == .depth24Unorm_stencil8
            #else
            return false
            #endif
        }
    }

    static func hasStencil(_ format: MTLPixelFormat) -> Bool {
        switch format {
        case .stencil8, .depth32Float_stencil8, .x32_stencil8:
            return true
        default:
            #if os(macOS)
            return format == .depth24Unorm_stencil8 || format == .x24_stencil8
            #else
            return false
            #endif
        }
    }

    /// Sets the pipeline's depth and stencil formats to match a combined
    /// depth/stencil attachment format.
    static func apply(_ format: MTLPixelFormat, to descriptor: MTLRenderPipelineDescriptor) {
        descriptor.depthAttachmentPixelFormat = hasDepth(format) ? format : .invalid
        descriptor.stencilAttachmentPixelFormat = hasStencil(format) ? format : .invalid
    }
}

/// A value shared with command buffer completion handlers.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}

/// Carries a non-Sendable Metal object into a completion handler that runs
/// after the GPU is done with it.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
}

/// Maps the value read from the ID buffer to a particle index.
enum PickResolver {
    /// `raw` is the sorted particle index plus one (0 for nothing);
    /// `order` maps sorted to original indices.
    static func particleIndex(raw: UInt32, order: [UInt32]?, count: Int) -> Int? {
        guard raw > 0 else { return nil }
        let sorted = Int(raw - 1)
        guard sorted < count else { return nil }
        guard let order else { return sorted }
        guard sorted < order.count else { return nil }
        return Int(order[sorted])
    }
}
