#if canImport(Metal) && canImport(ImageIO)
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd
@testable import AtomifyKit

/// Renders the picture on each demo's library card: runs the demo for a few
/// seconds and draws the newest snapshot with the billboard renderer into
/// Demos/<folder>/thumbnail.jpg. Runs only when asked:
///
///     ATOMIFY_THUMBNAILS=1 swift test -c release -Xswiftc -enable-testing --filter DemoThumbnail
///
/// ATOMIFY_THUMBNAIL_ONLY=<demo id> renders just one.
struct DemoThumbnailTests {
    static let environment = ProcessInfo.processInfo.environment
    static let demos = RenderPreviewTests.demos

    @Test(.enabled(if: environment["ATOMIFY_THUMBNAILS"] != nil && MTLCreateSystemDefaultDevice() != nil),
          .timeLimit(.minutes(30)))
    func renderThumbnails() async throws {
        let catalog = try DemoCatalog.load(from: Self.demos)
        let only = Self.environment["ATOMIFY_THUMBNAIL_ONLY"]
        for demo in catalog.demos where only == nil || only == demo.id {
            do {
                try await thumbnail(for: demo)
            } catch {
                Issue.record("\(demo.id): \(error)")
            }
        }
    }

    private func thumbnail(for demo: Demo) async throws {
        let copy = try DemoCatalog.makeWorkingCopy(of: demo, from: Self.demos)
        defer { try? FileManager.default.removeItem(at: copy.folder) }
        let script = try String(contentsOf: copy.script, encoding: .utf8)
        let directives = ScriptDirectives.parse(script)

        let simulation = try LammpsSimulation()
        simulation.setBondRules(directives.bondRules)
        simulation.setPublishInterval(0.25)
        simulation.start(script: copy.script, directory: copy.folder, continueAfterScript: true) { _ in }
        defer { simulation.cancel() }

        // The newest snapshot after the system has had a few seconds to
        // move, once its atoms exist (large systems take a while to build).
        var latest: SimulationSnapshot?
        var firstAtoms: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + .seconds(180)
        while ContinuousClock.now < deadline {
            if let next = simulation.takeNewSnapshot(), next.atomCount > 0 {
                latest = next
                if firstAtoms == nil { firstAtoms = .now }
            }
            if let firstAtoms, ContinuousClock.now - firstAtoms > .seconds(6) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let snapshot = try #require(latest, "\(demo.id) produced no atoms")

        let styles = AtomStyleTable(directives: directives, typeCount: snapshot.typeCount, units: snapshot.units)
        let frame = ImpostorFrame.build(snapshot: snapshot, styles: styles, atomScale: 1,
                                        bondRadius: InstanceBuilder.bondRadius(styles: styles, atomScale: 1),
                                        includeBonds: true,
                                        ambient: ImpostorFrame.ambientOcclusion(snapshot: snapshot, styles: styles))

        // Framed on the atoms, not the box: many demos hold a small molecule
        // or particle in a large box. The outermost 2 percent on each
        // axis is left out so a few stray atoms (vapor, sputtered atoms)
        // don't shrink the system to a dot.
        var (low, high) = Self.bounds(of: snapshot.positions, padding: frame.atoms.map { $0.centerRadius.w }.max() ?? 0)
        // Periodic copies around the box, as the app draws them.
        let copies = max(demo.copies ?? 1, 1)
        let shifts = (-(copies - 1) / 2)...(copies / 2)
        let boxSize = SIMD3<Float>(snapshot.boxHigh - snapshot.boxLow)
        var images: [SIMD3<Float>] = []
        for z in shifts {
            for y in shifts {
                for x in shifts { images.append(boxSize * SIMD3(Float(x), Float(y), Float(z))) }
            }
        }
        low += boxSize * Float(shifts.lowerBound)
        high += boxSize * Float(shifts.upperBound)
        let center = (low + high) / 2
        let flat = snapshot.dimension == 2
        let size = high - low
        let radius = max(simd_length(flat ? SIMD3(size.x, size.y, 0) : size) / 2, 1e-3)
        // 3D systems from a raised corner; flat ones straight on.
        let turn = flat ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            : simd_quatf(angle: 0.35, axis: [1, 0, 0]) * simd_quatf(angle: -0.6, axis: [0, 1, 0])
        // A sphere around the atoms fills the 50 degree vertical view, with
        // a little margin; the wider horizontal view leaves room either side.
        let distance = 1.04 / sin(Float(25) * .pi / 180)
        let box = BoxPlacement(position: [0, 0, -distance], orientation: turn, scale: 1 / radius)
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(-center, 1)
        let output = Self.demos.appendingPathComponent(demo.folder).appendingPathComponent("thumbnail.jpg")
        try render(frame, images: images, worldFromSimulation: box.worldFromLocal * translate, to: output)
        print("THUMBNAIL \(demo.id): \(snapshot.atomCount) atoms at step \(snapshot.timestep)")
    }

    /// Low and high corners around the atoms, each axis trimmed to its
    /// 2nd to 98th percentile, then grown by `padding`.
    static func bounds(of positions: [SIMD3<Float>], padding: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        guard !positions.isEmpty else { return (.zero, .zero) }
        var low = SIMD3<Float>(), high = SIMD3<Float>()
        for axis in 0..<3 {
            let values = positions.map { $0[axis] }.sorted()
            let cut = values.count / 50
            low[axis] = values[cut] - padding
            high[axis] = values[values.count - 1 - cut] + padding
        }
        return (low, high)
    }

    /// 640 x 400, 50 degree vertical field of view, 4x multisampled, over a
    /// dark grey.
    private func render(_ frame: ImpostorFrame, images: [SIMD3<Float>], worldFromSimulation: simd_float4x4, to output: URL) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let width = 640, height = 400, samples = 4
        let renderer = try ImpostorRenderer(device: device, colorFormat: .rgba8Unorm_srgb, depthFormat: .depth32Float,
                                            sampleCount: samples)
        func texture(_ format: MTLPixelFormat, multisample: Bool) -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                      height: height, mipmapped: false)
            if multisample {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = samples
            }
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)!
        }
        let resolved = texture(.rgba8Unorm_srgb, multisample: false)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture(.rgba8Unorm_srgb, multisample: true)
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = texture(.depth32Float, multisample: true)
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .dontCare

        let near: Float = 0.05, f = 1 / tan(Float(50) * .pi / 360)
        let projection = simd_float4x4(columns: (SIMD4(f * Float(height) / Float(width), 0, 0, 0), SIMD4(0, f, 0, 0),
                                                 SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        // Every atom of every copy: a still picture has time to spare.
        renderer.atomBudget = .max
        let commands = device.makeCommandQueue()!.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        renderer.encode(ImpostorRenderer.makeBuffers(frame, device: device, images: images), worldFromSimulation: worldFromSimulation,
                        viewFromWorld: matrix_identity_float4x4, projection: projection, into: encoder)
        encoder.endEncoding()
        let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        #expect(commands.error == nil)

        // Premultiplied sRGB over a dark grey that lightens toward the top.
        let pixels = readback.contents().assumingMemoryBound(to: UInt8.self)
        var rgb = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let background = 30 + 22 * (1 - Float(y) / Float(height))
            for x in 0..<width {
                let i = y * width + x
                let alpha = Float(pixels[i * 4 + 3]) / 255
                for c in 0..<3 {
                    rgb[i * 4 + c] = UInt8(min(Float(pixels[i * 4 + c]) + background * (1 - alpha), 255))
                }
            }
        }
        let provider = CGDataProvider(data: Data(rgb) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1,
                                                          nil)!
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }
}
#endif
