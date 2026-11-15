// Draws the Mac app's screens to PNGs without showing anything: each screen
// is hosted in a window that is never put on screen, in an app that never
// activates (no Dock icon, no menu bar). The Metal view is left out (it only
// draws on screen), so the simulation screens show the canvas colour where
// the atoms would be, and Liquid Glass falls back to materials, which are
// what an offscreen window can draw. Buttons look inactive (the window is
// never key).
//
//   xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme AtomifySnapshots \
//     -derivedDataPath build/macos-dd build
//   build/macos-dd/Build/Products/Debug/AtomifySnapshots.app/Contents/MacOS/AtomifySnapshots \
//     build/screens [screen name prefix]
//
// With --store DIR [name prefix] it makes the Mac App Store screenshots
// instead: 1440x900 points at 2x (2880x1800 RGB PNGs), each example run for
// a few seconds, its atoms rendered offscreen as the Metal view would draw
// them and the controls drawn on top (see storeShots below).
import AppKit
import AtomifyKit
import AtomifyRender
import MetalKit
import SwiftUI

struct Shot {
    let name: String
    /// Sets up the model before the window is drawn.
    let setUp: @MainActor (AppModel) -> Void
}

@MainActor
func screens() -> [Shot] {
    func example(_ model: AppModel, _ id: String) -> Example { model.catalog.example(id: id)! }
    return [
        Shot(name: "gallery") { $0.start(screen: "gallery") },
        Shot(name: "detail") { m in m.start(); m.galleryPath = [.detail(example(m, "h2_explosion"))]; m.showsWelcome = false; m.showsGallery = true },
        Shot(name: "script") { m in m.start(); m.galleryPath = [.detail(example(m, "h2_explosion")), .script(example(m, "h2_explosion"))]; m.showsWelcome = false; m.showsGallery = true },
        Shot(name: "files") { m in m.start(); m.galleryPath = [.detail(example(m, "h2_explosion")), .files(example(m, "h2_explosion"))]; m.showsWelcome = false; m.showsGallery = true },
        Shot(name: "settings") { $0.start(screen: "settings") },
        Shot(name: "acknowledgements") { m in m.start(); m.galleryPath = [.settings, .acknowledgements]; m.showsWelcome = false; m.showsGallery = true },
        Shot(name: "launch-welcome") { $0.start() },
        Shot(name: "play-explosion") { $0.start(captureID: "h2_explosion", screen: "play") },
        Shot(name: "play-trails") { $0.start(captureID: "surface_diffusion", screen: "play") },
        Shot(name: "panel-info") { $0.start(captureID: "h2_explosion", screen: "info") },
        Shot(name: "panel-dashboard") { $0.start(captureID: "h2_explosion", screen: "dashboard") },
        Shot(name: "panel-view") { $0.start(captureID: "h2_explosion", screen: "view") },
    ]
}

let sizes: [(label: String, size: CGSize)] = [("1280x800", CGSize(width: 1280, height: 800)),
                                              ("960x620", CGSize(width: 960, height: 620))]

@MainActor
func hideMetalViews(in view: NSView) {
    for subview in view.subviews {
        if subview is MTKView { subview.isHidden = true } else { hideMetalViews(in: subview) }
    }
}

@MainActor
func snapshot(_ shot: Shot, size: CGSize, to directory: URL) async {
    let model = AppModel()
    UserDefaults.standard.set(true, forKey: SettingsKey.showPerformance)
    shot.setUp(model)
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.title = "Atomify"
    window.appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingController(rootView: MacRootView().environment(model))
    host.sceneBridgingOptions = [.toolbars, .title]
    window.contentViewController = host
    window.setContentSize(size)
    // Let the run start and the views settle (dashboard data, thumbnails).
    try? await Task.sleep(for: .seconds(4))
    guard let frameView = window.contentView?.superview else { return }
    // A Metal view leaves the whole capture blank; it only draws on screen
    // anyway, so take it out and let the canvas colour behind it show.
    hideMetalViews(in: frameView)
    frameView.layoutSubtreeIfNeeded()
    frameView.displayIfNeeded()
    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
    frameView.cacheDisplay(in: frameView.bounds, to: rep)
    let url = directory.appendingPathComponent("\(shot.name)-\(Int(size.width))x\(Int(size.height)).png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print(url.path)
    model.session.stop()
    window.contentViewController = nil
    window.close()
}

// MARK: Store screenshots

struct StoreShot {
    let name: String
    /// Seconds the example runs before the picture, as in the iOS set.
    let seconds: Double
    let setUp: @MainActor (AppModel) -> Void
}

/// The Mac App Store set, mirroring the iPhone and iPad one.
@MainActor
func storeShots() -> [StoreShot] {
    [
        StoreShot(name: "01-gas_hydrates", seconds: 8) { $0.start(captureID: "gas_hydrates", screen: "play") },
        StoreShot(name: "02-singlewater-dashboard", seconds: 8) {
            $0.start(captureID: "singlewater", screen: "dashboard")
        },
        StoreShot(name: "03-gallery", seconds: 3) { $0.start(captureID: nil, screen: "gallery") },
        StoreShot(name: "04-sica_sheet_melt-detail", seconds: 3) {
            $0.start(captureID: nil, screen: "detail:sica_sheet_melt")
        },
        StoreShot(name: "05-h2_explosion-view", seconds: 8) { $0.start(captureID: "h2_explosion", screen: "view") },
        StoreShot(name: "06-flow_pois", seconds: 8) { $0.start(captureID: "flow_pois", screen: "play") },
    ]
}

/// A window that draws as the key, main window (active controls, coloured
/// window buttons) without ever being put on screen or made key.
final class ActiveLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor
func metalViews(in view: NSView) -> [MTKView] {
    view.subviews.flatMap { $0 is MTKView ? [$0 as! MTKView] : metalViews(in: $0) }
}

@MainActor
func storeSnapshot(_ shot: StoreShot, to directory: URL) async throws {
    let points = CGSize(width: 1440, height: 900), scale: CGFloat = 2
    let model = AppModel()
    UserDefaults.standard.set(false, forKey: SettingsKey.showPerformance)
    // Steps on a timer: the run must not wait for a display that is asleep.
    model.session.followsDisplay = false
    shot.setUp(model)
    let window = ActiveLookingWindow(contentRect: CGRect(origin: .zero, size: points),
                                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                     backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.isOpaque = false
    window.backgroundColor = .clear
    window.toolbarStyle = .unified
    window.title = "Atomify"
    window.appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingController(rootView: MacRootView().environment(model))
    host.sceneBridgingOptions = [.toolbars, .title]
    window.contentViewController = host
    window.setContentSize(points)
    try await Task.sleep(for: .seconds(shot.seconds))
    guard let frameView = window.contentView?.superview else { throw OffscreenImage.Failure("No window frame") }
    // The Metal view draws only on screen; its atoms are rendered below
    // instead, and the controls are drawn over a transparent canvas.
    let metal = metalViews(in: frameView).filter { !$0.isHidden && $0.window != nil }
    metal.forEach { $0.isHidden = true }
    frameView.layoutSubtreeIfNeeded()
    frameView.displayIfNeeded()
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(points.width * scale),
                                     pixelsHigh: Int(points.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        throw OffscreenImage.Failure("No bitmap")
    }
    rep.size = points
    frameView.cacheDisplay(in: frameView.bounds, to: rep)

    var layers: [(image: CGImage, rect: CGRect)] = []
    let session = model.session
    if let scene = session.scene, !model.showsGallery {
        for view in metal {
            let atoms = try OffscreenImage.render(scene: scene, camera: session.camera,
                                                  settings: session.renderSettings, pointSize: view.bounds.size,
                                                  scale: scale)
            layers.append((atoms, OffscreenImage.pixelRect(windowRect: view.convert(view.bounds, to: nil),
                                                           scale: scale)))
        }
    }
    let canvas = CGColor(srgbRed: 18 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1)
    let image = try OffscreenImage.composite(size: CGSize(width: points.width * scale, height: points.height * scale),
                                             background: canvas, layers: layers, overlay: rep.cgImage)
    let url = directory.appendingPathComponent("\(shot.name).png")
    try OffscreenImage.png(image).write(to: url)
    print("\(url.path): \(session.stats.atoms) atoms, step \(session.stats.timestep)")
    session.stop()
    window.contentViewController = nil
    window.close()
}

Platform.allowsLiquidGlass = false
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var arguments = Array(CommandLine.arguments.dropFirst())
let store = arguments.first == "--store"
if store {
    arguments.removeFirst()
    Platform.transparentCanvas = true
}
let output = URL(fileURLWithPath: arguments.first ?? (store ? "build/app-store/mac-3.0/screenshots" : "build/screens"))
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let only = arguments.dropFirst().first
Task { @MainActor in
    if store {
        for shot in storeShots() where only == nil || shot.name.hasPrefix(only!) {
            do {
                try await storeSnapshot(shot, to: output)
            } catch {
                FileHandle.standardError.write(Data("\(shot.name): \(error)\n".utf8))
                exit(1)
            }
        }
        exit(0)
    }
    for shot in screens() where only == nil || shot.name.hasPrefix(only!) {
        for (_, size) in sizes {
            await snapshot(shot, size: size, to: output)
        }
    }
    exit(0)
}
app.run()
