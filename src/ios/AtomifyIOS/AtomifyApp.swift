import AtomifyKit
import SwiftUI

/// Atomify for iPhone and iPad: a running simulation, full screen.
@main
struct AtomifyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            SimulationScreen()
                .environment(model)
        }
    }
}
