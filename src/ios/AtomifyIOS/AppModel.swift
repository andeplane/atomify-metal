import AtomifyKit
import Foundation
import Observation

/// The sheets over the simulation.
enum AppSheet: String, Identifiable {
    case examples
    case view
    case dashboard
    /// About the running example, from the title capsule.
    case about

    var id: String { rawValue }
}

/// App-wide state: the bundled example catalog, the one simulation session
/// the screen shows, and which sheet and controls are up.
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

    /// The sheet shown over the simulation, if any.
    var sheet: AppSheet?
    /// All floating controls hidden, for a clean view of the atoms.
    var chromeHidden = false

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
        // Play the examples at Atomify 2's pace, `#/speed` lines included.
        session.appliesScriptSpeed = true
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
        run(example)
    }

    /// Runs an example, replacing the current run, and shows the controls.
    func run(_ example: Example) {
        session.load(example, from: catalog)
        sheet = nil
        chromeHidden = false
    }

    /// A tap on the atoms: an atom selects it (or deselects it when it was
    /// selected); empty space clears the selection, or with nothing
    /// selected hides or shows the controls.
    func handlePick(_ index: Int?) {
        if index != nil {
            chromeHidden = false
            session.selectParticle(index)
        } else if session.selectedAtom != nil {
            session.clearSelection()
        } else {
            chromeHidden.toggle()
        }
    }

    /// Moves the orbit target onto the selected atom.
    func centerOnSelectedAtom() {
        guard let atom = session.selectedAtom, Self.isFinite(atom.position) else { return }
        session.camera.target = atom.position
    }

    private static func isFinite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

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
