import AppKit
import AtomifyKit
import SwiftUI

/// The Mac window's content: the running simulation, or the gallery in its
/// place. On iOS the gallery is a full-screen cover; a Mac window instead
/// switches between the two, so each owns the window's toolbar: the gallery
/// a real one (back, title, search, settings), the simulation none, with the
/// atoms under a transparent title bar and the controls below it.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if model.showsGallery {
                GalleryScreen(model: model)
                    .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
                    .transition(.opacity)
            } else {
                SimulationScreen()
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsGallery)
        // Over the simulation the title bar is see-through, so the atoms go
        // edge to edge under the traffic lights; the gallery keeps a bar.
        .background(WindowTitlebar(transparent: !model.showsGallery))
        // The Info panel's script, over the whole window.
        .hostsFullWindowCovers()
        .task { model.start() }
        // Only when the app is hidden or the window minimized: a Mac window
        // that merely loses focus keeps running.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.enterForeground()
            case .background: model.enterBackground()
            default: break
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Sets the hosting window's title bar transparent or not. SwiftUI's
/// toolbar background setting covers the toolbar; this covers a title bar
/// with no toolbar items, which would otherwise draw its own strip.
private struct WindowTitlebar: NSViewRepresentable {
    let transparent: Bool

    func makeNSView(context: Context) -> NSView { WindowObserver() }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? WindowObserver)?.transparent = transparent
    }

    private final class WindowObserver: NSView {
        var transparent = true {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, window.titlebarAppearsTransparent != transparent else { return }
            window.titlebarAppearsTransparent = transparent
        }
    }
}
