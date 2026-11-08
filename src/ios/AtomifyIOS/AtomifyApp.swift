import AtomifyKit
import SwiftUI

/// Atomify for iPhone and iPad: the examples gallery, and the running
/// simulation full screen over it.
@main
struct AtomifyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
