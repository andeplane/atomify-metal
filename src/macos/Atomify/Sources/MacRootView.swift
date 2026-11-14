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
