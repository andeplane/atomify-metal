import AtomifyEngine
import AtomifyRender
import Foundation
import Observation

/// Where a run is in its life.
public enum RunStatus: Equatable, Sendable {
    /// Nothing loaded, or stopped.
    case idle
    case running
    case paused
    /// The script ended (and the run was not set to continue).
    case finished
    case failed(String)

    /// A run that can be paused, resumed or sent commands.
    public var isActive: Bool { self == .running || self == .paused }

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .paused: "Paused"
        case .finished: "Finished"
        case .failed: "Failed"
        }
    }

    /// The status after the engine reports how a run ended.
    public static func after(_ outcome: Simulation.Outcome) -> RunStatus {
        switch outcome {
        case .finished, .cancelled: .finished
        case .failed(let message): .failed(message)
        }
    }
}

/// Numbers for an overlay, refreshed a few times a second.
public struct SessionStats: Equatable, Sendable {
    public var atoms = 0
    public var bonds = 0
    public var timestep: Int64 = 0
    public var time = 0.0
    public var units = ""
    public var temperature = 0.0
    public var stepsPerSecond = 0.0
    public var minimizing = false
    /// Frames the renderer drew per second (from `recordRenderStats`).
    public var framesPerSecond = 0.0
    public var gpuTimeMs = 0.0
    public var particlesDrawn = 0

    public init() {}
}

/// One running simulation for a SwiftUI app: owns the engine `Simulation`,
/// polls its snapshots on a display-rate tick, turns them into render
/// scenes, keeps plot history and the LAMMPS console, and applies the
/// script's `#/atom`, `#/bond` and `#/camera` directives.
///
/// The logic lives in plain types (`SceneBuilder`, `AtomPicking`,
/// `PlotCatalog`, `ConsoleLog`, `CameraFraming`, `ExampleCatalog`); this
/// class only sequences them.
@MainActor @Observation.Observable
public final class SimulationSession {
    // MARK: Run state

    public private(set) var example: Example?
    /// Title of what is loaded (the example, or the script's file name).
    public private(set) var title: String?
    public private(set) var status: RunStatus = .idle
    public private(set) var errorMessage: String?
    /// Problems with the script's `#/` directives.
    public private(set) var directiveWarnings: [String] = []
    /// Keep integrating when the script's last command is done.
    public var continueAfterScript = true

    // MARK: View state

    /// What the renderer draws; nil before the first snapshot.
    public private(set) var scene: SceneData?
    public var camera = OrbitCamera()
    public var renderSettings = RenderSettings()
    /// Bumped whenever a new scene is published.
    public private(set) var sceneRevision = 0

    /// Per-atom quantity that colors the atoms, or nil to color by type.
    public var colorQuantity: String? {
        get { storedColorQuantity }
        set {
            guard newValue != storedColorQuantity else { return }
            storedColorQuantity = newValue
            run?.simulation.setPerAtomQuantity(newValue)
            rangeTracker.reset()
            rebuildScene()
        }
    }

    public var colormap: Colormap {
        get { storedColormap }
        set { storedColormap = newValue; rebuildScene() }
    }

    /// Fixed color range; nil follows the values (min and max over the run).
    public var customColorRange: ClosedRange<Float>? {
        get { storedCustomRange }
        set { storedCustomRange = newValue; rebuildScene() }
    }

    public var showBonds: Bool {
        get { storedShowBonds }
        set {
            guard newValue != storedShowBonds else { return }
            storedShowBonds = newValue
            applyBondSettings()
            rebuildScene()
        }
    }

    public var showBox: Bool {
        get { storedShowBox }
        set { storedShowBox = newValue; rebuildScene() }
    }

    /// The color range of the current scene in per-atom mode (for a legend).
    public private(set) var colorRange: ClosedRange<Float>?
    /// Quantities the color picker offers.
    public private(set) var availableQuantities: [String] = PerAtomQuantities.builtIn

    public var colorMode: ColorMode {
        guard let quantity = storedColorQuantity else { return .type }
        return .perAtom(quantity: quantity, colormap: storedColormap, range: storedCustomRange ?? rangeTracker.range)
    }

    // MARK: Selection

    /// The clicked atom, refreshed as it moves.
    public private(set) var selectedAtom: AtomInfo?

    // MARK: Stats, plots, console

    public private(set) var stats = SessionStats()
    /// Everything that can be plotted, from the run's computes, fixes, variables and thermo.
    public private(set) var plotOptions: [PlotOption] = []
    /// The plotted series, in display order.
    public private(set) var plottedSeries: [PlotSeriesKey] = []
    /// (time, value) points of each plotted series, downsampled.
    public private(set) var plotData: [PlotSeriesKey: [SIMD2<Double>]] = [:]
    public private(set) var console = ConsoleLog()

    // MARK: Tuning

    /// How often the session polls for snapshots.
    @ObservationIgnored public var tickInterval: Duration = .milliseconds(16)
    /// How often stats, plots, console and selection refresh.
    @ObservationIgnored public var refreshInterval: Duration = .milliseconds(200)
    /// Most points drawn per plotted series.
    @ObservationIgnored public var maxPlotPoints = 600
    /// Seconds between snapshots the engine publishes.
    @ObservationIgnored public var publishInterval = 1.0 / 60.0

    // MARK: Private

    private enum Launch {
        case example(Example, ExampleCatalog)
        case script(URL, workingDirectory: URL)
    }

    private struct Run {
        let id = UUID()
        let simulation: Simulation
        let directives: ScriptDirectives
    }

    private var storedColorQuantity: String?
    private var storedColormap: Colormap = .viridis
    private var storedCustomRange: ClosedRange<Float>?
    private var storedShowBonds = true
    private var storedShowBox = true

    @ObservationIgnored private var run: Run?
    @ObservationIgnored private var launch: Launch?
    /// Cancelled simulations kept alive until the engine reports they ended.
    @ObservationIgnored private var retiring: [UUID: Simulation] = [:]
    @ObservationIgnored private var history = ObservableHistory()
    @ObservationIgnored private var frame: AtomFrame?
    @ObservationIgnored private var pendingStats = SessionStats()
    @ObservationIgnored private var styleTable: AtomStyleTable?
    @ObservationIgnored private var styleKey: StyleKey?
    @ObservationIgnored private var typeStyles: [ParticleStyle] = [SceneBuilder.fallbackStyle]
    @ObservationIgnored private var bondRadius: Float = 0.15
    @ObservationIgnored private var rangeTracker = ColorRangeTracker()
    @ObservationIgnored private var selectedTag: Int64?
    @ObservationIgnored private var cameraFramed = false
    @ObservationIgnored private var observableKey: [String] = []
    @ObservationIgnored private var observables: [ObservableInfo] = []
    @ObservationIgnored private var userChosePlots = false
    @ObservationIgnored private var historyChanged = false
    @ObservationIgnored private var pendingOutput = ""
    @ObservationIgnored private var frameMeter = RateMeter()
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    private let clock = ContinuousClock()
    private let origin = ContinuousClock.now
    @ObservationIgnored private var lastRefresh = ContinuousClock.now

    private struct StyleKey: Equatable {
        var typeCount: Int
        var units: String
    }

    public init() {}

    // MARK: Running

    /// Copies the example into a scratch folder and runs it, replacing any
    /// current run.
    public func load(_ example: Example, from catalog: ExampleCatalog) {
        start(.example(example, catalog))
    }

    /// Runs a script in place (its folder must be writable), replacing any current run.
    public func load(script: URL, workingDirectory: URL? = nil) {
        start(.script(script, workingDirectory: workingDirectory ?? script.deletingLastPathComponent()))
    }

    /// Runs what was loaded last again, from the original files.
    public func restart() {
        guard let launch else { return }
        start(launch)
    }

    /// Ends the current run. The last picture stays on screen.
    public func stop() {
        guard let run else { return }
        run.simulation.cancel()
        retiring[run.id] = run.simulation
        self.run = nil
        pollTask?.cancel()
        pollTask = nil
        if status.isActive { status = .idle }
    }

    public func pause() {
        guard let run, status == .running else { return }
        run.simulation.setPaused(true)
        status = .paused
    }

    public func resume() {
        guard let run, status == .paused else { return }
        run.simulation.setPaused(false)
        status = .running
    }

    public func togglePause() {
        if status == .paused { resume() } else { pause() }
    }

    /// Queues a LAMMPS command, run between timesteps, and echoes it in the console.
    public func enqueue(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, let run, status.isActive else { return }
        run.simulation.enqueue(command: command)
        console.append("> \(command)\n")
    }

    public func clearConsole() { console.clear() }

    /// Frames the box again, using the script's camera hint.
    public func resetCamera() {
        guard let frame else { return }
        camera = CameraFraming.camera(hint: run?.directives.camera, boxLow: frame.boxLow, boxHigh: frame.boxHigh,
                                      tilt: frame.tilt, base: camera)
    }

    /// Forgets the color range seen so far.
    public func resetColorRange() {
        rangeTracker.reset()
        rebuildScene()
    }

    private func start(_ launch: Launch) {
        let previous = self.launch
        stop()
        self.launch = launch
        resetForNewRun(keepingPlots: Self.isSame(launch, previous))
        var copiedFolder: URL?
        do {
            let prepared: (folder: URL, script: URL)
            switch launch {
            case .example(let example, let catalog):
                prepared = try catalog.workingCopy(of: example)
                copiedFolder = prepared.folder
                self.example = example
                title = example.title
            case .script(let url, let directory):
                prepared = (directory, url)
                example = nil
                title = url.lastPathComponent
            }
            let folder = prepared.folder, script = prepared.script
            let text = try String(contentsOf: script, encoding: .utf8)
            let directives = ScriptDirectives.parse(text)
            directiveWarnings = directives.warnings
            let simulation = try Simulation()
            let run = Run(simulation: simulation, directives: directives)
            self.run = run
            applyBondSettings()
            simulation.setPublishInterval(publishInterval)
            simulation.setPerAtomQuantity(storedColorQuantity)
            status = .running
            let id = run.id
            let removable = copiedFolder
            simulation.start(script: script, workingDirectory: folder, continueAfterScript: continueAfterScript) {
                [weak self] outcome in
                // Remove the copy only once LAMMPS stopped reading it.
                if let removable { try? FileManager.default.removeItem(at: removable) }
                Task { @MainActor [weak self] in self?.finished(id, outcome) }
            }
            startPolling()
        } catch {
            if let copiedFolder { try? FileManager.default.removeItem(at: copiedFolder) }
            run = nil
            status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private static func isSame(_ launch: Launch, _ previous: Launch?) -> Bool {
        switch (launch, previous) {
        case (.example(let a, _), .example(let b, _)?): a.id == b.id
        case (.script(let a, _), .script(let b, _)?): a == b
        default: false
        }
    }

    private func resetForNewRun(keepingPlots: Bool) {
        history.reset()
        frame = nil
        scene = nil
        sceneRevision += 1
        selectedTag = nil
        selectedAtom = nil
        styleTable = nil
        styleKey = nil
        typeStyles = [SceneBuilder.fallbackStyle]
        rangeTracker.reset()
        colorRange = nil
        cameraFramed = false
        observableKey = []
        observables = []
        plotOptions = []
        plotData = [:]
        if !keepingPlots {
            plottedSeries = []
            userChosePlots = false
            if let quantity = storedColorQuantity, !PerAtomQuantities.builtIn.contains(quantity) {
                storedColorQuantity = nil
            }
        }
        availableQuantities = PerAtomQuantities.builtIn
        console.clear()
        pendingOutput = ""
        stats = SessionStats()
        pendingStats = SessionStats()
        errorMessage = nil
        directiveWarnings = []
    }

    private func finished(_ id: UUID, _ outcome: Simulation.Outcome) {
        retiring[id] = nil
        guard let run, run.id == id else { return }
        drain(run)
        publish()
        status = RunStatus.after(outcome)
        if case .failed(let message) = outcome { errorMessage = message }
        self.run = nil
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                let interval = self.tickInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// One display tick: take output and the newest snapshot, refresh the
    /// slower state when due.
    func tick() {
        if let run { drain(run) }
        if clock.now - lastRefresh >= refreshInterval { publish() }
    }

    private func drain(_ run: Run) {
        let output = run.simulation.takeOutput()
        if !output.isEmpty { pendingOutput += output }
        if let snapshot = run.simulation.takeNewSnapshot() { process(snapshot, run: run) }
    }

    private func process(_ snapshot: SimulationSnapshot, run: Run) {
        history.record(snapshot)
        historyChanged = true
        let frame = AtomFrame(snapshot)
        self.frame = frame

        pendingStats.atoms = snapshot.atomCount
        pendingStats.bonds = snapshot.bonds.count
        pendingStats.timestep = snapshot.timestep
        pendingStats.time = snapshot.time
        pendingStats.units = snapshot.units
        pendingStats.temperature = snapshot.temperature
        pendingStats.stepsPerSecond = snapshot.stepsPerSecond
        pendingStats.minimizing = snapshot.minimizing

        let key = StyleKey(typeCount: frame.highestType, units: snapshot.units)
        if key != styleKey {
            let table = AtomStyleTable(directives: run.directives, typeCount: key.typeCount, units: key.units)
            styleTable = table
            styleKey = key
            typeStyles = SceneBuilder.particleStyles(from: table, typeCount: key.typeCount)
            bondRadius = SceneBuilder.defaultBondRadius(styles: table, typeCount: key.typeCount)
        }

        let ids = snapshot.observables.map(\.id)
        if ids != observableKey {
            observableKey = ids
            observables = snapshot.observables.map { ObservableInfo($0) }
            plotOptions = PlotCatalog.options(from: observables)
            if !userChosePlots {
                plottedSeries = PlotCatalog.defaultSelection(from: observables)
            } else {
                let known = Set(plotOptions.map(\.key))
                plottedSeries = plottedSeries.filter { known.contains($0) }
            }
            let quantities = PerAtomQuantities.available(from: snapshot.observables)
            if quantities != availableQuantities { availableQuantities = quantities }
        }

        if let quantity = storedColorQuantity, let values = frame.values(for: quantity) {
            rangeTracker.include(values)
        }

        if !cameraFramed {
            cameraFramed = true
            camera = CameraFraming.camera(hint: run.directives.camera, boxLow: snapshot.boxLow,
                                          boxHigh: snapshot.boxHigh, tilt: snapshot.tilt, base: camera)
        }
        rebuildScene()
    }

    private func applyBondSettings() {
        guard let run else { return }
        run.simulation.setTopologyBonds(storedShowBonds)
        run.simulation.setBondRules(storedShowBonds ? run.directives.bondRules : [])
    }

    private func rebuildScene() {
        guard let frame else {
            if scene != nil { scene = nil }
            return
        }
        let mode = colorMode
        scene = SceneBuilder.scene(from: frame, typeStyles: typeStyles, colorMode: mode, selectedTag: selectedTag,
                                   showBox: storedShowBox, bondRadius: storedShowBonds ? bondRadius : 0)
        sceneRevision += 1
        let range = SceneBuilder.colorRange(for: frame, colorMode: mode)
        if range != colorRange { colorRange = range }
    }

    /// Refreshes what changes at most a few times a second.
    private func publish() {
        lastRefresh = clock.now
        if !pendingOutput.isEmpty {
            console.append(pendingOutput)
            pendingOutput = ""
        }
        if pendingStats != stats { stats = pendingStats }
        if historyChanged {
            historyChanged = false
            refreshPlots()
        }
        refreshSelection()
    }

    // MARK: Selection

    /// Selects the atom drawn as particle `index` of the current scene (from
    /// the renderer's picking). Nil, or the selected atom again, clears it.
    public func selectParticle(_ index: Int?) {
        guard let frame, let info = AtomPicking.atom(atParticle: index, in: frame, styles: styleTable),
              info.tag != selectedTag else {
            clearSelection()
            return
        }
        selectedTag = info.tag
        selectedAtom = info
        rebuildScene()
    }

    /// Selects an atom by its LAMMPS ID.
    public func selectAtom(tag: Int64) {
        selectedTag = tag
        refreshSelection()
        rebuildScene()
    }

    public func clearSelection() {
        guard selectedTag != nil || selectedAtom != nil else { return }
        selectedTag = nil
        selectedAtom = nil
        rebuildScene()
    }

    private func refreshSelection() {
        guard let selectedTag, let frame else { return }
        let info = AtomPicking.atom(withTag: selectedTag, in: frame, styles: styleTable)
        if info != selectedAtom { selectedAtom = info }
    }

    // MARK: Plots

    public func addPlot(_ key: PlotSeriesKey) {
        guard !plottedSeries.contains(key) else { return }
        userChosePlots = true
        plottedSeries.append(key)
        refreshPlots()
    }

    public func removePlot(_ key: PlotSeriesKey) {
        userChosePlots = true
        plottedSeries.removeAll { $0 == key }
        plotData[key] = nil
    }

    public func title(of key: PlotSeriesKey) -> String {
        plotOptions.first { $0.key == key }?.title ?? key.observableID
    }

    private func refreshPlots() {
        var data: [PlotSeriesKey: [SIMD2<Double>]] = [:]
        for key in plottedSeries {
            data[key] = PlotCatalog.downsample(history.series(id: key.observableID, component: key.component),
                                               maxPoints: maxPlotPoints)
        }
        plotData = data
    }

    // MARK: Renderer feedback

    /// Call with every frame's statistics (ParticleView's `onStats`).
    public func recordRenderStats(_ renderStats: RenderStats) {
        recordFrame(particlesDrawn: renderStats.particlesDrawn, gpuTimeMs: renderStats.gpuTimeMs)
    }

    /// Counts one drawn frame for the overlay's frame rate.
    public func recordFrame(particlesDrawn: Int, gpuTimeMs: Double) {
        frameMeter.tick(at: seconds(since: origin))
        pendingStats.framesPerSecond = frameMeter.rate
        pendingStats.gpuTimeMs = gpuTimeMs
        pendingStats.particlesDrawn = particlesDrawn
        if run == nil, clock.now - lastRefresh >= refreshInterval { publish() }
    }

    private func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
    }
}
