import AtomifyKit
import Foundation
import Observation

/// App-wide state: the bundled example catalog and the one simulation
/// session the screen shows.
@MainActor @Observation.Observable
final class AppModel {
    /// What runs when the app starts.
    static let firstExampleID = "singlewater"

    let catalog: ExampleCatalog
    let catalogError: String?
    let session = SimulationSession()

    /// Render quality for the system size; the view options change its mode.
    var qualityPolicy = QualityPolicy() {
        didSet { applyQuality() }
    }

    /// How often the particle view draws: fast while touched, at the
    /// simulation's pace while it runs, not at all while nothing changes.
    let framePacing = FramePacing()

    /// Set when the app paused a running simulation on its way to the background.
    @ObservationIgnored private var pausedForBackground = false

    init(examplesDirectory: URL? = Bundle.main.url(forResource: "Examples", withExtension: nil)) {
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
    }

    /// Runs the first example, once.
    func start() {
        guard session.title == nil,
              let example = catalog.example(id: Self.firstExampleID) ?? catalog.examples.first else { return }
        session.load(example, from: catalog)
    }

    /// Runs the example with this id, replacing the current run.
    func open(_ id: Example.ID) {
        guard let example = catalog.example(id: id) else { return }
        session.load(example, from: catalog)
    }

    /// The most pixels per point to draw the current system at.
    var contentScaleLimit: Double? {
        qualityPolicy.contentScaleLimit(atomCount: session.stats.atoms)
    }

    /// Low Power Mode or thermal pressure.
    var isConstrained: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    /// Sets the session's render quality from the policy, the atom count
    /// and the power state. Called when any of them changes.
    func applyQuality() {
        let quality = qualityPolicy.quality(atomCount: session.stats.atoms, constrained: isConstrained)
        if session.renderSettings.quality != quality {
            session.renderSettings.quality = quality
        }
    }

    /// iOS stops GPU work in the background; pause the run too, and resume
    /// it on return only if the app was the one that paused it.
    func enterBackground() {
        guard session.status == .running else { return }
        session.pause()
        pausedForBackground = true
    }

    func enterForeground() {
        guard pausedForBackground else { return }
        pausedForBackground = false
        session.resume()
    }
}
