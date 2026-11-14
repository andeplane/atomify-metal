import SwiftUI

/// The app's root, as in Atomify 2: a running simulation from launch, with
/// the welcome over it, and the examples gallery full screen over it when
/// asked for.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        SimulationScreen()
            .fullWindowCover(isPresented: $model.showsGallery) {
                GalleryScreen(model: model)
                    .environment(model)
            }
            // The Mac draws its covers (gallery, script) here, over the whole window.
            .hostsFullWindowCovers()
            .task { model.start() }
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
