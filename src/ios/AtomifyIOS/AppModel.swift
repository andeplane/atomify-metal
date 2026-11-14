import AtomifyKit
import Foundation
import Observation

/// The tabs of the side panel beside the simulation.
enum SidePanel: String, Identifiable, CaseIterable {
    /// About the running example, from the title capsule.
    case info
    case dashboard
    case view

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: "Info"
        case .dashboard: "Dashboard"
        case .view: "View"
        }
    }
}

/// App-wide state: the bundled example catalog, the one simulation session
/// the screen shows, whether the gallery or the welcome is over it, and
/// which panel and controls are up.
@MainActor @Observation.Observable
final class AppModel {
    /// What runs when the app starts, as in Atomify 2.
    static let firstExampleID = "singlewater"

    let catalog: ExampleCatalog
    let catalogError: String?
    /// The examples by topic, in the gallery's order.
    let sections: [ExampleSection]
    let session = SimulationSession()

    /// Render quality for the system size; the view options change its mode.
    var qualityPolicy = QualityPolicy() {
        didSet { applyQuality() }
    }

    /// How often the particle view draws: fast while touched, at the
    /// simulation's pace while it runs, not at all while nothing changes.
    let framePacing = FramePacing()

    /// The examples gallery is up over the simulation.
    var showsGallery = false
    /// Where the gallery is: empty at its root, where Examples always opens it.
    var galleryPath: [ExampleRoute] = []
    /// Atomify 2's welcome over the running simulation, on every launch.
    var showsWelcome = true
    /// The side panel shown beside the simulation, if any.
    var panel: SidePanel?
    /// All floating controls hidden, for a clean view of the atoms.
    var chromeHidden = false

    /// Set when the app paused a running simulation on its way to the background.
    @ObservationIgnored private var pausedForBackground = false
    /// Set when the app paused a running simulation to show the gallery.
    @ObservationIgnored private var pausedForGallery = false

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
        sections = ExampleSections.sections(for: catalog.examples,
                                            definitions: catalog.sections ?? ExampleSections.curated)
        // Play the examples at Atomify 2's pace, `#/speed` lines included.
        session.appliesScriptSpeed = true
    }

    /// Launch argument that opens one example with no welcome and no
    /// controls and no simulation box, for taking its gallery picture:
    /// `xcrun simctl launch booted <bundle id> -AtomifyCapture <example id>`.
    static let captureArgument = "AtomifyCapture"

    /// Launch argument that opens a screen straight away, with no welcome, for
    /// checking layouts in the simulator: `gallery`, `info`, `dashboard`,
    /// `view` or `detail:<example id>`. With `-AtomifyCapture <id>` any other
    /// value (say `play`) shows that example with its controls.
    static let screenArgument = "AtomifyScreen"

    /// Starts the first example, once: the app opens on a running simulation.
    /// With the capture argument it opens that example with a bare view.
    func start(captureID: String? = UserDefaults.standard.string(forKey: AppModel.captureArgument),
               screen: String? = UserDefaults.standard.string(forKey: AppModel.screenArgument)) {
        guard session.title == nil else { return }
        if let captureID, let example = catalog.example(id: captureID) {
            showsWelcome = false
            chromeHidden = screen == nil
            // The box's white lines clutter the small gallery pictures.
            session.showBox = false
            session.load(example, from: catalog)
            show(screen: screen)
            return
        }
        guard let example = catalog.example(id: Self.firstExampleID) ?? catalog.examples.first else { return }
        session.load(example, from: catalog)
        show(screen: screen)
    }

    /// Opens the screen the launch argument names.
    private func show(screen: String?) {
        guard let screen else { return }
        showsWelcome = false
        if screen == "gallery" {
            showsGallery = true
        } else if screen.hasPrefix("detail:"), let example = catalog.example(id: String(screen.dropFirst(7))) {
            galleryPath = [.detail(example)]
            showsGallery = true
        } else if let panel = SidePanel(rawValue: screen) {
            self.panel = panel
        }
    }

    /// Runs the example with this id, replacing the current run.
    func open(_ id: Example.ID) {
        guard let example = catalog.example(id: id) else { return }
        run(example)
    }

    /// Runs an example, replacing the current run, and shows it with the
    /// controls.
    func run(_ example: Example) {
        session.load(example, from: catalog)
        pausedForGallery = false
        panel = nil
        chromeHidden = false
        showsGallery = false
    }

    /// Back to the gallery. A running simulation pauses until it is shown again.
    func showGallery() {
        panel = nil
        galleryPath = []
        if session.status == .running {
            session.pause()
            pausedForGallery = true
        }
        showsGallery = true
    }

    /// Shows the simulation again, resuming it if the gallery paused it.
    func returnToSimulation() {
        chromeHidden = false
        showsGallery = false
        if pausedForGallery {
            pausedForGallery = false
            if session.status == .paused { session.resume() }
        }
    }

    /// Restarts the loaded example and shows it.
    func restartAndShow() {
        pausedForGallery = false
        session.restart()
        chromeHidden = false
        showsGallery = false
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
