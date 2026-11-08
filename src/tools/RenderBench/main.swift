// atomify-render-bench: renders what AtomifyMac shows, offscreen, to time the
// renderer and to save reference screenshots. Scenes come from real LAMMPS
// runs (bundled examples, plus a 1M-atom SiC crystal built by a script), with
// the app's own styles, bonds and camera framing.
//
//   swift run -c release atomify-render-bench                 # timing table
//   swift run -c release atomify-render-bench --shots DIR     # PNGs, fast and high
// Options: --size 2560x1600  --frames 240  --in-flight 1  --scenes water,sic,lj,sic1m,sic1m-zoom
//          --label NAME (PNG suffix)  --msaa 4
// Each timed run turns the camera once around the scene. With one frame in
// flight (the default) GPU time is the frame's own; more frames in flight
// measure throughput.

import AtomifyKit
import AtomifyRender
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

struct Options {
    var width = 2560, height = 1600, frames = 240, inFlight = 1, msaa = 4
    var shotsDirectory: String?
    var label = ""
    var scenes = ["water", "sic", "lj", "sic1m", "sic1m-zoom"]

    init(_ arguments: [String]) {
        var it = arguments.dropFirst().makeIterator()
        while let argument = it.next() {
            switch argument {
            case "--size":
                let parts = (it.next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { width = parts[0]; height = parts[1] }
            case "--frames": frames = Int(it.next() ?? "") ?? frames
            case "--in-flight": inFlight = max(Int(it.next() ?? "") ?? inFlight, 1)
            case "--msaa": msaa = Int(it.next() ?? "") ?? msaa
            case "--shots": shotsDirectory = it.next()
            case "--label": label = it.next() ?? ""
            case "--scenes": scenes = (it.next() ?? "").split(separator: ",").map(String.init)
            default:
                FileHandle.standardError.write(Data("unknown option \(argument)\n".utf8))
                exit(2)
            }
        }
    }
}

struct BenchScene {
    var name: String
    var scene: SceneData
    var camera: OrbitCamera
    var settings: RenderSettings
}

/// A 3C-SiC crystal of 50³ cells (1,000,000 atoms, about 2M bonds), built by LAMMPS.
let siliconCarbideScript = """
#/atom 1 silicon
#/atom 2 carbon
#/bond 1 2 2.0
units metal
boundary p p p
lattice custom 4.3596 a1 1 0 0 a2 0 1 0 a3 0 0 1 &
    basis 0 0 0 basis 0 0.5 0.5 basis 0.5 0 0.5 basis 0.5 0.5 0 &
    basis 0.25 0.25 0.25 basis 0.25 0.75 0.75 basis 0.75 0.25 0.75 basis 0.75 0.75 0.25
region box block 0 50 0 50 0 50
create_box 2 box
create_atoms 1 box basis 5 2 basis 6 2 basis 7 2 basis 8 2
mass 1 28.0855
mass 2 12.011
pair_style zero 3.0
pair_coeff * *
run 0
"""

@MainActor
func capture(example id: String?, script: String?, minimumStep: Int64) async throws -> BenchScene {
    let session = SimulationSession()
    session.continueAfterScript = script == nil
    if let id {
        let directory = ExampleRunner.bundledExamplesDirectory(fromSourceFile: #filePath)!
        let catalog = try ExampleCatalog.load(from: directory)
        guard let example = catalog.example(id: id) else { throw BenchError("no example \(id)") }
        session.load(example, from: catalog)
    } else if let script {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atomify-render-bench-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sic1m.in")
        try script.write(to: url, atomically: true, encoding: .utf8)
        session.load(script: url)
    }
    let deadline = Date().addingTimeInterval(300)
    while Date() < deadline {
        try await Task.sleep(for: .milliseconds(100))
        if let error = session.errorMessage { throw BenchError("\(id ?? "script"): \(error)") }
        let done = session.status != .running && session.status != .paused && session.scene != nil
        if (session.scene != nil && session.stats.timestep >= minimumStep) || done { break }
    }
    session.pause()
    try await Task.sleep(for: .milliseconds(300))    // let the last snapshot land
    guard let scene = session.scene else { throw BenchError("\(id ?? "script") produced no scene") }
    session.stop()
    return BenchScene(name: id ?? "sic1m", scene: scene, camera: session.camera, settings: session.renderSettings)
}

struct BenchError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func loadScenes(_ names: [String]) async throws -> [BenchScene] {
    var scenes: [BenchScene] = []
    for name in names {
        let started = Date()
        var scene: BenchScene
        switch name {
        case "water": scene = try await capture(example: "nanotube_water", script: nil, minimumStep: 200)
        case "sic": scene = try await capture(example: "sic_nanoparticle", script: nil, minimumStep: 100)
        case "lj": scene = try await capture(example: "3D-lj-fluid", script: nil, minimumStep: 500)
        case "sic1m": scene = try await capture(example: nil, script: siliconCarbideScript, minimumStep: 0)
        case "sic1m-zoom":
            // The same crystal seen from close by: most of it is out of view.
            if let full = scenes.first(where: { $0.name == "sic1m" }) {
                scene = full
            } else {
                scene = try await capture(example: nil, script: siliconCarbideScript, minimumStep: 0)
            }
            var camera = scene.camera
            camera.distance *= 0.2
            camera.pitch = 0.3
            camera.yaw = 0.5
            scene = BenchScene(name: name, scene: scene.scene, camera: camera, settings: scene.settings)
        default: throw BenchError("unknown scene \(name)")
        }
        var renamed = scene
        renamed.name = name
        scenes.append(renamed)
        print(String(format: "loaded %@: %d atoms, %d bonds (%.1f s)", name, scene.scene.particles.count,
                     scene.scene.bonds?.pairs.count ?? 0, Date().timeIntervalSince(started)))
    }
    return scenes
}

final class Offscreen {
    let device: any MTLDevice
    let width: Int, height: Int, msaa: Int
    let resolve: any MTLTexture
    let multisample: (any MTLTexture)?
    let depth: any MTLTexture
    let queue: any MTLCommandQueue

    init(device: any MTLDevice, width: Int, height: Int, msaa: Int) {
        self.device = device; self.width = width; self.height = height; self.msaa = msaa
        func texture(_ format: MTLPixelFormat, multisampled: Bool, usage: MTLTextureUsage) -> any MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                             mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if multisampled { d.textureType = .type2DMultisample; d.sampleCount = msaa }
            return device.makeTexture(descriptor: d)!
        }
        resolve = texture(.bgra8Unorm_srgb, multisampled: false, usage: [.renderTarget, .shaderRead])
        multisample = msaa > 1 ? texture(.bgra8Unorm_srgb, multisampled: true, usage: .renderTarget) : nil
        depth = texture(.depth32Float, multisampled: msaa > 1, usage: .renderTarget)
        queue = device.makeCommandQueue()!
    }

    func pass(clear: SIMD4<Float>) -> MTLRenderPassDescriptor {
        let p = MTLRenderPassDescriptor()
        if let multisample {
            p.colorAttachments[0].texture = multisample
            p.colorAttachments[0].resolveTexture = resolve
            p.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            p.colorAttachments[0].texture = resolve
            p.colorAttachments[0].storeAction = .store
        }
        p.colorAttachments[0].loadAction = .clear
        p.colorAttachments[0].clearColor = MTLClearColor(red: Double(clear.x), green: Double(clear.y),
                                                         blue: Double(clear.z), alpha: 1)
        p.depthAttachment.texture = depth
        p.depthAttachment.loadAction = .clear
        p.depthAttachment.clearDepth = 0    // reverse Z
        p.depthAttachment.storeAction = .dontCare
        return p
    }

    /// As ParticleView draws on a Retina display: 2 pixels per point.
    func view(_ camera: OrbitCamera) -> RenderView {
        let size = SIMD2(Float(width), Float(height))
        return ParticleViewMath.renderView(camera: camera, drawableSize: size, boundsSize: size / 2)
    }

    func savePNG(_ path: String) throws {
        let buffer = device.makeBuffer(length: width * height * 4, options: .storageModeShared)!
        let commandBuffer = queue.makeCommandBuffer()!
        let blit = commandBuffer.makeBlitCommandEncoder()!
        blit.copy(from: resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1), to: buffer, destinationOffset: 0,
                  destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let bitmap = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(data: buffer.contents(), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: bitmap),
              let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil)
        else { throw BenchError("could not write \(path)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BenchError("could not write \(path)") }
    }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p / 100).rounded()))]
}

func makeRenderer(_ offscreen: Offscreen, _ scene: BenchScene, quality: RenderQuality) throws -> ParticleRenderer {
    let renderer = try ParticleRenderer(device: offscreen.device, colorFormat: .bgra8Unorm_srgb,
                                        depthFormat: .depth32Float, sampleCount: offscreen.msaa, reverseZ: true)
    renderer.settings = scene.settings
    renderer.settings.quality = quality
    renderer.update(scene.scene)
    return renderer
}

func time(_ scene: BenchScene, quality: RenderQuality, offscreen: Offscreen, options: Options) throws -> String {
    let renderer = try makeRenderer(offscreen, scene, quality: quality)
    var camera = scene.camera
    let startYaw = camera.yaw
    let clear = renderer.settings.background
    // Warm up: pipelines, first touch of buffers, occlusion.
    for _ in 0..<3 {
        let commandBuffer = offscreen.queue.makeCommandBuffer()!
        renderer.encodeFrame(commandBuffer: commandBuffer, target: offscreen.pass(clear: clear),
                             view: offscreen.view(camera))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    let slots = DispatchSemaphore(value: options.inFlight)
    let lock = NSLock()
    nonisolated(unsafe) var gpu: [Double] = []
    nonisolated(unsafe) var completed: [Double] = []
    var cpu: [Double] = []
    @Sendable func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    let start = now()
    var last: (any MTLCommandBuffer)?
    for frame in 0..<options.frames {
        slots.wait()
        camera.yaw = startYaw + 2 * .pi * Float(frame) / Float(options.frames)
        let encodeStart = now()
        let commandBuffer = offscreen.queue.makeCommandBuffer()!
        renderer.encodeFrame(commandBuffer: commandBuffer, target: offscreen.pass(clear: clear),
                             view: offscreen.view(camera))
        commandBuffer.addCompletedHandler { buffer in
            let finished = now()
            lock.lock()
            gpu.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
            completed.append(finished)
            lock.unlock()
            slots.signal()
        }
        commandBuffer.commit()
        cpu.append((now() - encodeStart) * 1000)
        last = commandBuffer
    }
    last?.waitUntilCompleted()
    for _ in 0..<options.inFlight { slots.wait() }
    for _ in 0..<options.inFlight { slots.signal() }
    let seconds = now() - start
    lock.lock()
    let times = completed.sorted()
    let gpuTimes = gpu
    lock.unlock()
    let intervals = zip(times.dropFirst(), times).map { ($0 - $1) * 1000 }
    let mean = { (values: [Double]) in values.reduce(0, +) / Double(max(values.count, 1)) }
    let stats = renderer.lastFrameStats
    return String(format: "| %@ | %@ | %d | %d | %.2f | %.2f | %.2f | %.2f | %.0f | %.2f |",
                  scene.name, quality.rawValue, scene.scene.particles.count, stats.bondsDrawn,
                  mean(intervals), percentile(intervals, 95), mean(gpuTimes), percentile(gpuTimes, 95),
                  Double(options.frames) / seconds, mean(cpu))
}

func shoot(_ scene: BenchScene, quality: RenderQuality, offscreen: Offscreen, path: String) throws {
    let renderer = try makeRenderer(offscreen, scene, quality: quality)
    // A few frames so per-frame state (occlusion refresh) settles.
    for _ in 0..<10 {
        let commandBuffer = offscreen.queue.makeCommandBuffer()!
        renderer.encodeFrame(commandBuffer: commandBuffer, target: offscreen.pass(clear: renderer.settings.background),
                             view: offscreen.view(scene.camera))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    try offscreen.savePNG(path)
    print("wrote \(path)")
}

@MainActor
func main() async throws {
    let options = Options(CommandLine.arguments)
    guard let device = MTLCreateSystemDefaultDevice() else { throw BenchError("no Metal device") }
    let scenes = try await loadScenes(options.scenes)
    let offscreen = Offscreen(device: device, width: options.width, height: options.height, msaa: options.msaa)
    if let directory = options.shotsDirectory {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let suffix = options.label.isEmpty ? "" : "-\(options.label)"
        for scene in scenes {
            for quality in RenderQuality.allCases {
                try shoot(scene, quality: quality, offscreen: offscreen,
                          path: "\(directory)/\(scene.name)-\(quality.rawValue)\(suffix).png")
            }
        }
        return
    }
    print("\(device.name), \(options.width)×\(options.height), MSAA \(options.msaa)×, "
          + "\(options.frames) frames per orbit, \(options.inFlight) in flight")
    print("| scene | quality | atoms | bonds drawn | frame mean ms | frame p95 ms | GPU mean ms | GPU p95 ms | fps | CPU encode ms |")
    print("| --- | --- | --: | --: | --: | --: | --: | --: | --: | --: |")
    for scene in scenes {
        for quality in RenderQuality.allCases {
            print(try time(scene, quality: quality, offscreen: offscreen, options: options))
        }
    }
}

do {
    try await main()
} catch {
    FileHandle.standardError.write(Data("atomify-render-bench: \(error)\n".utf8))
    exit(1)
}
