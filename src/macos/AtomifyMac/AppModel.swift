import AtomifyKit
import Foundation
import Observation

/// App-wide state: the bundled example catalog, the sidebar's search, and
/// the one simulation session the window shows.
@MainActor @Observation.Observable
final class AppModel {
    let catalog: ExampleCatalog
    let catalogError: String?
    let session = SimulationSession()

    var searchText = ""
    /// Only examples with this keyword, or all.
    var keyword: String?
    /// The example picked in the sidebar; picking one runs it.
    var selectedExampleID: Example.ID?

    init(examplesDirectory: URL? = Bundle.module.url(forResource: "Examples", withExtension: nil)) {
        var catalog = ExampleCatalog(directory: URL(fileURLWithPath: "/"), examples: [])
        var catalogError: String?
        if let examplesDirectory {
            do {
                catalog = try ExampleCatalog.load(from: examplesDirectory)
            } catch {
                catalogError = "The bundled examples could not be read: \(error.localizedDescription)"
            }
        } else {
            catalogError = "The bundled examples folder is missing."
        }
        self.catalog = catalog
        self.catalogError = catalogError
        AppModelRegistry.current = self
    }

    var visibleExamples: [Example] {
        catalog.filtered(query: searchText, keyword: keyword)
    }

    /// Runs the example with this id, replacing the current run.
    func open(_ id: Example.ID?) {
        guard let id, let example = catalog.example(id: id) else { return }
        session.load(example, from: catalog)
    }
}

/// The model of the running app, for the app delegate (kept outside the
/// observable class so the Observation macro leaves it alone).
@MainActor
enum AppModelRegistry {
    static weak var current: AppModel?
}
