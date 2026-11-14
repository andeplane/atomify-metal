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
import AppKit
import AtomifyKit
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

Platform.allowsLiquidGlass = false
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/screens")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let only = CommandLine.arguments.dropFirst(2).first
Task { @MainActor in
    for shot in screens() where only == nil || shot.name.hasPrefix(only!) {
        for (_, size) in sizes {
            await snapshot(shot, size: size, to: output)
        }
    }
    exit(0)
}
app.run()
