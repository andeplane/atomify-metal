import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Pictures made without a window: a scene drawn as `ParticleView` would
/// draw it, and that picture put together with a snapshot of the controls.
/// Used by the Mac's store screenshots.
public enum OffscreenImage {
    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    /// Draws `scene` as a `ParticleView` of `pointSize` points at `scale`
    /// pixels per point shows it: the same camera math, settings, reverse Z
    /// and 4x multisampling where the GPU has it. A few frames are drawn
    /// first so per-frame state (ambient occlusion) settles.
    public static func render(scene: SceneData, camera: OrbitCamera, settings: RenderSettings,
                              pointSize: CGSize, scale: CGFloat,
                              device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws -> CGImage {
        guard let device else { throw Failure("No Metal device") }
        let width = Int((pointSize.width * scale).rounded()), height = Int((pointSize.height * scale).rounded())
        guard width > 0, height > 0 else { throw Failure("Empty size \(pointSize)") }
        let samples = device.supportsTextureSampleCount(4) ? 4 : 1
        func texture(_ format: MTLPixelFormat, multisampled: Bool,
                     usage: MTLTextureUsage) throws -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                             mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if multisampled { d.textureType = .type2DMultisample; d.sampleCount = samples }
            guard let t = device.makeTexture(descriptor: d) else { throw Failure("No \(width)x\(height) texture") }
            return t
        }
        let resolve = try texture(.bgra8Unorm_srgb, multisampled: false, usage: [.renderTarget, .shaderRead])
        let multisample = samples > 1 ? try texture(.bgra8Unorm_srgb, multisampled: true, usage: .renderTarget) : nil
        let depth = try texture(.depth32Float, multisampled: samples > 1, usage: .renderTarget)
        guard let queue = device.makeCommandQueue() else { throw Failure("No command queue") }

        let renderer = try ParticleRenderer(device: device, colorFormat: .bgra8Unorm_srgb, depthFormat: .depth32Float,
                                            sampleCount: samples, reverseZ: true)
        renderer.settings = settings
        renderer.update(scene)
        let view = ParticleViewMath.renderView(camera: camera, drawableSize: SIMD2(Float(width), Float(height)),
                                               boundsSize: SIMD2(Float(pointSize.width), Float(pointSize.height)))
        let pass = MTLRenderPassDescriptor()
        if let multisample {
            pass.colorAttachments[0].texture = multisample
            pass.colorAttachments[0].resolveTexture = resolve
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = resolve
            pass.colorAttachments[0].storeAction = .store
        }
        let b = settings.background
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(b.x), green: Double(b.y), blue: Double(b.z),
                                                            alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0    // reverse Z
        pass.depthAttachment.storeAction = .dontCare
        for _ in 0..<10 {
            guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure("No command buffer") }
            renderer.encodeFrame(commandBuffer: commandBuffer, target: pass, view: view)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }

        let bytesPerRow = width * 4
        guard let buffer = device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { throw Failure("No readback buffer") }
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: info),
              let image = context.makeImage() else { throw Failure("Could not read the frame back") }
        return image
    }

    /// The pixel rectangle of a view, from its frame in window points
    /// (AppKit's bottom-left origin, as `convert(_:to: nil)` gives it), in
    /// a picture of the window at `scale`. Core Graphics shares the origin,
    /// so only the scale and rounding to whole pixels apply.
    public static func pixelRect(windowRect: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: (windowRect.minX * scale).rounded(), y: (windowRect.minY * scale).rounded(),
               width: (windowRect.width * scale).rounded(), height: (windowRect.height * scale).rounded())
    }

    /// One opaque picture of `size` pixels: `background` everywhere, each
    /// layer in its rectangle (bottom-left origin), and `overlay` over the
    /// whole picture, blended by its alpha. The result has no alpha channel,
    /// as the App Store wants.
    public static func composite(size: CGSize, background: CGColor, layers: [(image: CGImage, rect: CGRect)],
                                 overlay: CGImage?) throws -> CGImage {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure("Could not make a \(width)x\(height) picture") }
        let all = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.setFillColor(background)
        context.fill(all)
        for layer in layers { context.draw(layer.image, in: layer.rect) }
        if let overlay { context.draw(overlay, in: all) }
        guard let image = context.makeImage() else { throw Failure("Could not finish the picture") }
        return image
    }

    /// PNG data of `image`.
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure("No PNG encoder") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure("Could not encode the PNG") }
        return data as Data
    }
}
