#if canImport(Metal) && canImport(ImageIO)
import Foundation
import ImageIO
import Metal
import Testing
import UniformTypeIdentifiers
import simd
@testable import AtomifyKit

/// Renders the nanoporous silica glass demo with the billboard
/// renderer into PNG files, to judge how it looks without a headset. Runs
/// only when ATOMIFY_PREVIEW_DIR names an output folder:
///
///     ATOMIFY_PREVIEW_DIR=/tmp/preview swift test --filter RenderPreview
struct RenderPreviewTests {
    static let outputDirectory = ProcessInfo.processInfo.environment["ATOMIFY_PREVIEW_DIR"]
    static let demos = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Demos")

    @Test(.enabled(if: outputDirectory != nil && MTLCreateSystemDefaultDevice() != nil),
          .timeLimit(.minutes(10)))
    func nanoporousSilica() async throws {
        let output = URL(fileURLWithPath: try #require(Self.outputDirectory))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // The demo's own script, stopped right after the structure is built.
        let source = Self.demos.appendingPathComponent("nanoporous_silica")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("atomify-preview-\(UUID())")
        try FileManager.default.copyItem(at: source, to: work)
        defer { try? FileManager.default.removeItem(at: work) }
        var script = try String(contentsOf: work.appendingPathComponent("nanoporous_sio2.in"), encoding: .utf8)
        script = script.replacingOccurrences(of: "run 1000000", with: "run 1")
        try script.write(to: work.appendingPathComponent("preview.in"), atomically: true, encoding: .utf8)

        // Keeps running after the script so a snapshot stays available.
        let simulation = try LammpsSimulation()
        simulation.setPublishInterval(0.5)
        simulation.start(script: work.appendingPathComponent("preview.in"), directory: work,
                         continueAfterScript: true) { _ in }
        defer { simulation.cancel() }
        var latest: SimulationSnapshot?
        let deadline = ContinuousClock.now + .seconds(300)
        while latest == nil && ContinuousClock.now < deadline {
            if let next = simulation.takeNewSnapshot(), next.atomCount > 0 { latest = next }
            try await Task.sleep(for: .milliseconds(200))
        }
        let snapshot = try #require(latest)
        #expect(snapshot.atomCount > 150_000)

        let styles = AtomStyleTable(directives: ScriptDirectives.parse(script), typeCount: snapshot.typeCount,
                                    units: snapshot.units)
        // What the app's background builder does for each snapshot.
        var started = ContinuousClock.now
        let ambient = ImpostorFrame.ambientOcclusion(snapshot: snapshot, styles: styles)
        let hidden = ImpostorFrame.buriedAtoms(snapshot: snapshot, styles: styles)
        print("PREVIEW occlusion + buried: \(ContinuousClock.now - started)")
        started = ContinuousClock.now
        let frame = ImpostorFrame.build(snapshot: snapshot, styles: styles, atomScale: 1, bondRadius: 0,
                                        includeBonds: false, ambient: ambient, hidden: hidden)
        print("PREVIEW build: \(ContinuousClock.now - started); drawing \(frame.atoms.count) of \(snapshot.atomCount) atoms")

        let low = SIMD3<Float>(snapshot.boxLow), high = SIMD3<Float>(snapshot.boxHigh)
        let center = (low + high) / 2
        let longest = (high - low).max()
        // The app draws the glass as 3 x 3 x 3 periodic copies around the
        // simulated box; the region of all copies is what gets placed.
        var images: [SIMD3<Float>] = []
        for z in -1...1 {
            for y in -1...1 {
                for x in -1...1 { images.append((high - low) * SIMD3(Float(x), Float(y), Float(z))) }
            }
        }
        let region = 3 * longest
        let budget = 800_000    // ImpostorRenderer.atomBudget

        // Outside: all copies 60 cm across, 1 m in front, as when a demo opens.
        let outside = 0.6 / region
        let outsidePlacement = placement(scale: outside, center: center, at: [0, 0, -1])
        // Closer, turned: 45 cm away, seen from a corner.
        let closePlacement = placement(scale: outside, center: center, at: [0, 0, -0.45],
                                       turn: simd_quatf(angle: 0.6, axis: simd_normalize([1, 1, 0])))
        // Step inside: all copies 4 m across around the head, the eye in the
        // empty space nearest the center of the middle copy, looking along +x.
        let pore = try #require(emptySpot(in: snapshot))
        let insidePlacement = placement(scale: 4 / region, center: pore, at: .zero,
                                        turn: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        let views = [("outside", outsidePlacement), ("close", closePlacement), ("inside-pore", insidePlacement)]
        for (name, transform) in views {
            try render(frame, images: images, budget: budget,
                       output: output.appendingPathComponent("silica-\(name).png"), worldFromSimulation: transform)
            // Every copy at full detail, to judge what thinning far copies costs.
            try render(frame, images: images, budget: .max,
                       output: output.appendingPathComponent("silica-\(name)-full-detail.png"),
                       worldFromSimulation: transform)
        }

        // Headset budget: both eyes at about the display's resolution, 4x
        // multisampled, must fit well inside 11 ms (90 Hz).
        for (name, transform) in views {
            for (label, limit) in [("budget", budget), ("full detail", Int.max)] {
                let (milliseconds, drawn) = try stereoFrameTime(frame, images: images, budget: limit,
                                                                worldFromSimulation: transform)
                print("PREVIEW GPU stereo frame, \(name), \(label): \(String(format: "%.2f", milliseconds)) ms, "
                      + "\(drawn) atoms drawn per eye")
            }
        }
    }

    /// Median GPU time of a stereo frame (two 1920 x 1824 views, 4x MSAA,
    /// eyes 6.4 cm apart) after a warm-up, in milliseconds, and the atoms
    /// drawn for the left eye.
    private func stereoFrameTime(_ frame: ImpostorFrame, images: [SIMD3<Float>], budget: Int,
                                 worldFromSimulation: simd_float4x4) throws -> (Double, Int) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let width = 1920, height = 1824, samples = 4
        let renderer = try ImpostorRenderer(device: device, colorFormat: .bgra8Unorm_srgb, depthFormat: .depth32Float,
                                            sampleCount: samples)
        func texture(_ format: MTLPixelFormat, samples count: Int) -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                                      height: height, mipmapped: false)
            if count > 1 {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = count
            }
            descriptor.usage = .renderTarget
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)!
        }
        let color = texture(.bgra8Unorm_srgb, samples: samples), depth = texture(.depth32Float, samples: samples)
        let resolved = [texture(.bgra8Unorm_srgb, samples: 1), texture(.bgra8Unorm_srgb, samples: 1)]
        renderer.atomBudget = budget
        let buffers = ImpostorRenderer.makeBuffers(frame, device: device, images: images)
        let queue = device.makeCommandQueue()!
        let near: Float = 0.05, f: Float = 1 / tan(Float(80) * .pi / 360)
        let projection = simd_float4x4(columns: (SIMD4(f * Float(height) / Float(width), 0, 0, 0), SIMD4(0, f, 0, 0),
                                                 SIMD4(0, 0, 0, -1), SIMD4(0, 0, near, 0)))
        var times: [Double] = []
        for _ in 0..<8 {
            let commands = queue.makeCommandBuffer()!
            for eye in 0..<2 {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = color
                pass.colorAttachments[0].resolveTexture = resolved[eye]
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
                pass.colorAttachments[0].storeAction = .multisampleResolve
                pass.depthAttachment.texture = depth
                pass.depthAttachment.loadAction = .clear
                pass.depthAttachment.clearDepth = 0
                pass.depthAttachment.storeAction = .dontCare
                var view = matrix_identity_float4x4
                view.columns.3.x = eye == 0 ? 0.032 : -0.032
                let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
                renderer.encode(buffers, worldFromSimulation: worldFromSimulation, viewFromWorld: view,
                                projection: projection, into: encoder)
                encoder.endEncoding()
            }
            commands.commit()
            commands.waitUntilCompleted()
            times.append((commands.gpuEndTime - commands.gpuStartTime) * 1000)
        }
        let measured = times.dropFirst(2).sorted()
        var leftEye = matrix_identity_float4x4
        leftEye.columns.3.x = 0.032
        return (measured[measured.count / 2], renderer.atomsDrawn(buffers, worldFromSimulation: worldFromSimulation,
                                                                   viewFromWorld: leftEye, projection: projection))
    }

    /// Simulation to world: `center` lands at `position`, scaled and turned.
    private func placement(scale: Float, center: SIMD3<Float>, at position: SIMD3<Float>,
                           turn: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) -> simd_float4x4 {
        let box = BoxPlacement(position: position, orientation: turn, scale: scale)
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(-center, 1)
        return box.worldFromLocal * translate
    }

    /// The middle of an empty 24 Å cube (no atom within 12 Å on a coarse
    /// grid) nearest the box center: somewhere inside a pore.
    private func emptySpot(in snapshot: SimulationSnapshot) -> SIMD3<Float>? {
        let low = SIMD3<Float>(snapshot.boxLow), high = SIMD3<Float>(snapshot.boxHigh)
        let cell: Float = 8
        let n = SIMD3<Int>(Int((high.x - low.x) / cell) + 1, Int((high.y - low.y) / cell) + 1,
                           Int((high.z - low.z) / cell) + 1)
        var occupied = [Bool](repeating: false, count: n.x * n.y * n.z)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { (z * n.y + y) * n.x + x }
        for p in snapshot.positions {
            let c = (p - low) / cell
            let x = min(max(Int(c.x), 0), n.x - 1), y = min(max(Int(c.y), 0), n.y - 1)
            let z = min(max(Int(c.z), 0), n.z - 1)
            occupied[index(x, y, z)] = true
        }
        let center = (low + high) / 2
        var best: SIMD3<Float>?
        for z in 1..<(n.z - 1) {
            for y in 1..<(n.y - 1) {
                for x in 1..<(n.x - 1) {
                    var empty = true
                    for dz in -1...1 { for dy in -1...1 { for dx in -1...1
                        where occupied[index(x + dx, y + dy, z + dz)] { empty = false } } }
                    guard empty else { continue }
                    let p = low + (SIMD3<Float>(Float(x), Float(y), Float(z)) + 0.5) * cell
                    if best.map({ simd_distance(p, center) < simd_distance($0, center) }) ?? true { best = p }
                }
            }
        }
        return best
    }

    /// One eye at the origin looking down -z with a 70 degree field of view,
    /// reverse Z and 4x multisampling like the headset, composited over a
    /// dim grey standing in for the room.
    private func render(_ frame: ImpostorFrame, images: [SIMD3<Float>], budget: Int, output: URL,
                        worldFromSimulation: simd_float4x4) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let size = 1400, samples = 4
        let renderer = try ImpostorRenderer(device: device, colorFormat: .rgba8Unorm_srgb, depthFormat: .depth32Float,
                                            sampleCount: samples)
        func texture(_ format: MTLPixelFormat, multisample: Bool) -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size,
                                                                      mipmapped: false)
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

        let near: Float = 0.05, f = 1 / tan(Float(70) * .pi / 360)
        let projection = simd_float4x4(columns: (SIMD4(f, 0, 0, 0), SIMD4(0, f, 0, 0), SIMD4(0, 0, 0, -1),
                                                 SIMD4(0, 0, near, 0)))
        let queue = device.makeCommandQueue()!
        let commands = queue.makeCommandBuffer()!
        let encoder = commands.makeRenderCommandEncoder(descriptor: pass)!
        renderer.atomBudget = budget
        renderer.encode(ImpostorRenderer.makeBuffers(frame, device: device, images: images),
                        worldFromSimulation: worldFromSimulation,
                        viewFromWorld: matrix_identity_float4x4, projection: projection, into: encoder)
        encoder.endEncoding()
        let readback = device.makeBuffer(length: size * size * 4, options: .storageModeShared)!
        let blit = commands.makeBlitCommandEncoder()!
        blit.copy(from: resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: size, height: size, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: size * 4, destinationBytesPerImage: size * size * 4)
        blit.endEncoding()
        let started = ContinuousClock.now
        commands.commit()
        commands.waitUntilCompleted()
        print("\(output.lastPathComponent): GPU \(ContinuousClock.now - started) for \(frame.atoms.count) atoms")
        #expect(commands.error == nil)

        // Premultiplied sRGB over a dim grey "room".
        let pixels = readback.contents().assumingMemoryBound(to: UInt8.self)
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        for i in 0..<(size * size) {
            let alpha = Float(pixels[i * 4 + 3]) / 255
            for c in 0..<3 {
                rgba[i * 4 + c] = UInt8(min(Float(pixels[i * 4 + c]) + 58 * (1 - alpha), 255))
            }
        }
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
#endif
