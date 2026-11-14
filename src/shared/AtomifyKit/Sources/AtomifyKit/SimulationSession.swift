import AtomifyEngine
import AtomifyRender
import Foundation
import Observation
import simd

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
    /// Edge lengths of the simulation box (for a triclinic box, the lengths
    /// lx, ly, lz before tilting).
    public var boxSize: SIMD3<Double> = .zero
    /// 2 or 3.
    public var dimension = 3
    /// Box volume, or its area in 2D.
    public var volume = 0.0
    /// Atom types the script declares.
    public var typeCount = 0
    /// Frames the renderer drew per second (from `recordRenderStats`).
    public var framesPerSecond = 0.0
    public var gpuTimeMs = 0.0
    public var particlesDrawn = 0

    public init() {}

    /// Edge lengths from the box corners; zero for a box that is not finite.
    public static func boxSize(low: SIMD3<Double>, high: SIMD3<Double>) -> SIMD3<Double> {
        let size = high - low
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite else { return .zero }
        return simd_max(size, .zero)
    }

    /// Volume of a box with these edge lengths, or the xy area in 2D. Tilt
    /// does not change it: LAMMPS's triclinic edge vectors (lx,0,0),
    /// (xy,ly,0), (xz,yz,lz) span lx·ly·lz.
    public static func volume(boxSize: SIMD3<Double>, dimension: Int) -> Double {
        dimension == 2 ? boxSize.x * boxSize.y : boxSize.x * boxSize.y * boxSize.z
    }
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
    /// Whether runs follow the example's `stepsPerFrame` and the script's
    /// `#/speed` lines (Atomify 2's pacing, for the iOS app). Off, as the
    /// Mac app runs, they are ignored and the console shows `#/speed` and
    /// `#/label` lines as written. Takes effect from the next run.
    public var appliesScriptSpeed = false

    // MARK: View state

    /// What the renderer draws; nil before the first snapshot.
    public private(set) var scene: SceneData?
    public var camera = OrbitCamera()
    /// The selected atom keeps its color inside a ring, so an inspector's
    /// swatch matches it.
    public var renderSettings: RenderSettings = {
        var settings = RenderSettings()
        settings.selectionRing = true
        return settings
    }()
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

    /// Most timesteps per second, or nil to run as fast as the device can.
    /// Zero, negative and non-finite limits mean no limit. With
    /// `stepsPerFrame` the lower of the two limits applies.
    public var maxStepsPerSecond: Double? {
        get { storedMaxStepsPerSecond }
        set {
            storedMaxStepsPerSecond = Self.speedLimit(newValue)
            applySpeed()
        }
    }

    /// Timesteps per displayed frame at normal speed: the example's
    /// `stepsPerFrame`, then the script's latest `#/speed`. Nil (examples
    /// without either) runs as fast as the device can.
    public private(set) var stepsPerFrame: Double?

    /// How fast to play relative to normal: 0.5 is half the example's
    /// speed, `.infinity` as fast as the device can. Kept across runs.
    public var speedFactor: Double {
        get { storedSpeedFactor }
        set {
            storedSpeedFactor = newValue.isNaN || newValue <= 0 ? 1 : newValue
            applySpeed()
        }
    }

    /// Frames per second the speeds refer to, Atomify 2's display rate.
    nonisolated public static let referenceFrameRate = 60.0

    /// The limit the engine runs at: `stepsPerFrame` at the reference frame
    /// rate times `speedFactor`, and `maxStepsPerSecond`, whichever is lower.
    public var effectiveMaxStepsPerSecond: Double? {
        Self.effectiveLimit(stepsPerFrame: stepsPerFrame, speedFactor: storedSpeedFactor,
                            maxStepsPerSecond: storedMaxStepsPerSecond)
    }

    nonisolated public static func effectiveLimit(stepsPerFrame: Double?, speedFactor: Double,
                                                  maxStepsPerSecond: Double?) -> Double? {
        let paced = stepsPerFrame.flatMap { speedLimit($0 * referenceFrameRate * speedFactor) }
        switch (paced, speedLimit(maxStepsPerSecond)) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    /// The script's latest `#/label` line, e.g. "Dissolving by entropy".
    public private(set) var scriptLabel: String?

    /// The app's heat bath (see `Thermostat`). Setting it queues the LAMMPS
    /// commands that add, change or remove the fix and echoes them in the
    /// console. It can only be switched on while a run is active, and it is
    /// off again when the run ends or another starts; the target is kept,
    /// limited to `Thermostat.targetRange`, and reset to the default when the
    /// unit style changes.
    public var thermostat: Thermostat {
        get { storedThermostat }
        set {
            var thermostat = newValue
            thermostat.target = clampedThermostatTarget(thermostat.target)
            if let panel = thermostatPanel { thermostat.dampingTime = panel.dampingTime }
            if run == nil || !status.isActive { thermostat.isEnabled = false }
            guard thermostat != storedThermostat else { return }
            let commands = Thermostat.commands(from: storedThermostat, to: thermostat)
            storedThermostat = thermostat
            for command in commands { enqueue(command) }
        }
    }

    /// The example's dashboard panels (Atomify 2's controllers), or
    /// `DashboardLayout.fallback` for runs without them.
    public private(set) var dashboard: [DashboardPanel] = DashboardLayout.fallback
    /// The example's thermostat panel, which sets the target's range.
    public private(set) var thermostatPanel: ThermostatPanel?
    /// Points of every line the dashboard draws, downsampled like plots.
    public private(set) var dashboardData: [DashboardSource: [SIMD2<Double>]] = [:]

    /// The example's gravity panel's force, nil without one. Setting it
    /// queues the commands that add, change or remove the fix; it can only
    /// be switched on while a run is active.
    public var gravity: GravityControl? {
        get { storedGravity }
        set {
            guard var gravity = newValue, let old = storedGravity else { return }
            gravity.magnitude = min(max(gravity.magnitude.isFinite ? gravity.magnitude : 0, gravity.range.lowerBound),
                                    gravity.range.upperBound)
            if run == nil || !status.isActive { gravity.isEnabled = false }
            guard gravity != old else { return }
            let commands = GravityControl.commands(from: old, to: gravity)
            storedGravity = gravity
            for command in commands { enqueue(command) }
        }
    }

    /// The thermostat's target range: the panel's, else `Thermostat.targetRange`.
    public var thermostatRange: ClosedRange<Double> {
        thermostatPanel?.range ?? Thermostat.targetRange(units: thermostatUnits ?? "")
    }

    private func clampedThermostatTarget(_ target: Double) -> Double {
        guard let range = thermostatPanel?.range else {
            return Thermostat.clampedTarget(target, units: thermostatUnits ?? "")
        }
        guard target.isFinite else { return range.lowerBound }
        return min(max(target, range.lowerBound), range.upperBound)
    }

    /// The camera that frames the run (after the first snapshot, or the
    /// last reset); nil before the first snapshot.
    public private(set) var framedCamera: OrbitCamera?

    /// Whether the view is still the framed one, so a "reset view" control
    /// has nothing to do.
    public var isCameraFramed: Bool {
        guard let framedCamera else { return true }
        return CameraFraming.isSameView(camera, framedCamera)
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

    /// The example's visual effects (tracers, trails), new for every run.
    private var effects = EffectPipeline()
    /// The example's small live chart, if it asks for one: the plotted
    /// series to show, matched against plot titles.
    public var miniChartSeries: String? { example?.atomifyMetal?.effects?.first { $0.kind == .chart }?.series }

    /// The dashboard chart the example's small live chart shows: the one
    /// whose title is its `series` ("Temperature"), if there is one.
    public var miniChart: DashboardChart? {
        guard let series = miniChartSeries else { return nil }
        return dashboard.compactMap(DashboardLayout.chart(for:))
            .first { $0.title.caseInsensitiveCompare(series) == .orderedSame }
    }
    private var storedColorQuantity: String?
    private var storedColormap: Colormap = .viridis
    private var storedCustomRange: ClosedRange<Float>?
    private var storedShowBonds = true
    private var storedShowBox = true
    private var storedMaxStepsPerSecond: Double?
    private var storedSpeedFactor = 1.0
    @ObservationIgnored private var eventFilter = ScriptEventFilter()
    private var storedThermostat = Thermostat()
    private var storedGravity: GravityControl?
    @ObservationIgnored private var dashboardSources: [DashboardSource] = []
    /// Series the app measures from snapshots (angles, volume), by source.
    @ObservationIgnored private var measured: [DashboardSource: [SIMD2<Double>]] = [:]
    @ObservationIgnored private var lastMeasuredTimestep: Int64?
    /// The panels' commands and starting controls were applied for this run.
    @ObservationIgnored private var dashboardStarted = false
    /// Points kept per measured series.
    static let measuredCapacity = 10_000
    /// Unit style the thermostat target was chosen for.
    @ObservationIgnored private var thermostatUnits: String?

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
    @ObservationIgnored private var ticker: DisplayTicker?
    @ObservationIgnored private var lastGrant: ContinuousClock.Instant?
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
        stopPolling()
        storedThermostat.isEnabled = false
        storedGravity?.isEnabled = false
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

    /// A speed limit the engine understands: nil unless positive and finite.
    nonisolated public static func speedLimit(_ steps: Double?) -> Double? {
        guard let steps, steps.isFinite, steps > 0 else { return nil }
        return steps
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
        framedCamera = camera
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
        if !Self.isSame(launch, previous) { applyExampleColoring(of: launch) }
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
            let options = example?.atomifyMetal
            var directives = ScriptDirectives.parse(text, dialect: options?.dialect ?? .web)
            if let camera = options?.camera { directives.camera = camera.hint }
            directiveWarnings = directives.warnings
            effects = EffectPipeline(effects: options?.effects ?? [])
            stepsPerFrame = appliesScriptSpeed ? options?.stepsPerFrame.flatMap { Self.speedLimit($0) } : nil
            eventFilter = ScriptEventFilter(echoesEvents: !appliesScriptSpeed)
            configureDashboard(options?.dashboard ?? [])
            let simulation = try Simulation()
            let run = Run(simulation: simulation, directives: directives)
            self.run = run
            applyBondSettings()
            simulation.setPublishInterval(publishInterval)
            applySpeed()
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

    /// A new example's own coloring (see `ExampleOptions.color`), or the
    /// color-by-type default.
    private func applyExampleColoring(of launch: Launch) {
        guard case .example(let example, _) = launch, let color = example.atomifyMetal?.color else {
            if case .example = launch {
                storedColorQuantity = nil
                storedCustomRange = nil
            }
            return
        }
        storedColorQuantity = color.quantity
        storedColormap = color.colormap.flatMap(Colormap.init(rawValue:)) ?? .viridis
        storedCustomRange = color.colorRange
    }

    private func resetForNewRun(keepingPlots: Bool) {
        history.reset()
        effects = EffectPipeline()
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
        framedCamera = nil
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
        eventFilter = ScriptEventFilter()
        scriptLabel = nil
        stepsPerFrame = nil
        configureDashboard([])
        stats = SessionStats()
        pendingStats = SessionStats()
        errorMessage = nil
        directiveWarnings = []
    }

    private func finished(_ id: UUID, _ outcome: Simulation.Outcome) {
        retiring[id] = nil
        guard let run, run.id == id else { return }
        drain(run, flushing: true)
        publish()
        status = RunStatus.after(outcome)
        storedThermostat.isEnabled = false
        storedGravity?.isEnabled = false
        if case .failed(let message) = outcome { errorMessage = message }
        self.run = nil
        stopPolling()
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        ticker?.stop()
        ticker = nil
    }

    private func startPolling() {
        stopPolling()
        // On the display's own clock where there is one, so every displayed
        // frame gets its share of the steps.
        if let ticker = DisplayTicker(tick: { [weak self] in
            guard let self else { return false }
            self.tick()
            return true
        }) {
            self.ticker = ticker
            return
        }
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
        if let run {
            grantSteps(run)
            drain(run)
        }
        if clock.now - lastRefresh >= refreshInterval { publish() }
    }

    private func drain(_ run: Run, flushing: Bool = false) {
        let output = run.simulation.takeOutput()
        var filtered = eventFilter.filter(output)
        if flushing {
            let rest = eventFilter.flush()
            filtered.text += rest.text
            filtered.events += rest.events
        }
        if !filtered.text.isEmpty { pendingOutput += filtered.text }
        for event in filtered.events { apply(event) }
        if let snapshot = run.simulation.takeNewSnapshot() { process(snapshot, run: run) }
    }

    private func process(_ snapshot: SimulationSnapshot, run: Run) {
        history.record(snapshot)
        historyChanged = true
        let frame = AtomFrame(snapshot)
        self.frame = frame
        if !effects.isEmpty { effects.record(frame) }

        pendingStats.atoms = snapshot.atomCount
        pendingStats.bonds = snapshot.bonds.count
        pendingStats.timestep = snapshot.timestep
        pendingStats.time = snapshot.time
        pendingStats.units = snapshot.units
        pendingStats.temperature = snapshot.temperature
        pendingStats.stepsPerSecond = snapshot.stepsPerSecond
        pendingStats.minimizing = snapshot.minimizing
        pendingStats.boxSize = SessionStats.boxSize(low: snapshot.boxLow, high: snapshot.boxHigh)
        pendingStats.dimension = snapshot.dimension
        pendingStats.volume = SessionStats.volume(boxSize: pendingStats.boxSize, dimension: snapshot.dimension)
        pendingStats.typeCount = snapshot.typeCount

        if thermostatUnits != snapshot.units {
            thermostatUnits = snapshot.units
            if !storedThermostat.isEnabled {
                storedThermostat.target = Thermostat.defaultTarget(units: snapshot.units)
            }
        }

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

        measureDashboard(frame: frame, snapshot: snapshot)
        if !dashboardStarted && snapshot.atomCount > 0 && status.isActive {
            dashboardStarted = true
            startDashboard()
        }

        if !cameraFramed {
            cameraFramed = true
            camera = CameraFraming.camera(hint: run.directives.camera, boxLow: snapshot.boxLow,
                                          boxHigh: snapshot.boxHigh, tilt: snapshot.tilt, base: camera)
            framedCamera = camera
        }
        rebuildScene()
    }

    private func apply(_ event: ScriptEvent) {
        switch event {
        case .speed(let steps):
            guard appliesScriptSpeed else { return }
            stepsPerFrame = Self.speedLimit(steps)
            applySpeed()
        case .label(let text):
            scriptLabel = text.isEmpty ? nil : text
        }
    }

    /// A speed limit paces the engine by frames: every tick grants the steps
    /// due since the last one, as Atomify 2 ran its steps per frame, so each
    /// displayed scene moves on by the same amount. Without a limit it runs
    /// as fast as it can.
    private func applySpeed() {
        guard let run else { return }
        run.simulation.setMaxStepsPerSecond(nil)
        run.simulation.setFramePaced(effectiveMaxStepsPerSecond != nil)
        lastGrant = nil
    }

    /// Grants a frame-paced run the steps due since the last tick.
    private func grantSteps(_ run: Run) {
        let now = clock.now
        defer { lastGrant = now }
        guard status == .running, let rate = effectiveMaxStepsPerSecond else { return }
        guard let last = lastGrant else { return }
        let grant = Self.stepGrant(rate: rate, elapsed: now - last)
        if grant.steps > 0 { run.simulation.grantSteps(grant.steps, maxBudget: grant.maxBudget) }
    }

    /// Steps for one tick at `rate` steps per second: the elapsed time's
    /// worth, at most two reference frames', and never more pending than two
    /// reference frames' (at least one step), so a run that falls behind
    /// does not race to catch up after a hitch.
    nonisolated static func stepGrant(rate: Double, elapsed: Duration) -> (steps: Double, maxBudget: Double) {
        let frames = 2.0 / referenceFrameRate
        let seconds = min(max(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
                              0), frames)
        return (rate * seconds, max(1, rate * frames))
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
        var built = SceneBuilder.scene(from: frame, typeStyles: typeStyles, colorMode: mode, selectedTag: selectedTag,
                                       showBox: storedShowBox, bondRadius: storedShowBonds ? bondRadius : 0,
                                       colorRamp: example?.atomifyMetal?.colorRamp)
        if let counts = example?.atomifyMetal?.imageCounts {
            built.images = SceneBuilder.imageOffsets(counts: counts, low: frame.boxLow, high: frame.boxHigh,
                                                     tilt: frame.tilt)
        }
        if !effects.isEmpty { effects.apply(to: &built, frame: frame) }
        scene = built
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
        rebuildScene()
        selectedAtom = withDrawnColor(info)
    }

    /// Selects an atom by its LAMMPS ID.
    public func selectAtom(tag: Int64) {
        selectedTag = tag
        rebuildScene()
        refreshSelection()
    }

    public func clearSelection() {
        guard selectedTag != nil || selectedAtom != nil else { return }
        selectedTag = nil
        selectedAtom = nil
        rebuildScene()
    }

    private func refreshSelection() {
        guard let selectedTag, let frame else { return }
        let info = withDrawnColor(AtomPicking.atom(withTag: selectedTag, in: frame, styles: styleTable))
        if info != selectedAtom { selectedAtom = info }
    }

    /// `info` with the color its atom is drawn in on screen when that is
    /// not the type's (a quantity's colormap, an example's color ramp), so
    /// a swatch next to it matches the atom.
    private func withDrawnColor(_ info: AtomInfo?) -> AtomInfo? {
        guard var info, let particles = scene?.particles, let colors = particles.colors,
              colors.count == particles.count, info.index < colors.count else { return info }
        let linear = colors[info.index]
        info.color = SIMD3(Self.srgb(linear.x), Self.srgb(linear.y), Self.srgb(linear.z))
        return info
    }

    private static func srgb(_ linear: Float) -> Float {
        let c = min(max(linear, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
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
        refreshDashboard()
    }

    // MARK: Dashboard

    private func configureDashboard(_ examplePanels: [DashboardPanel]) {
        let panels = examplePanels.isEmpty ? DashboardLayout.fallback : examplePanels
        dashboard = panels
        dashboardSources = DashboardLayout.sources(for: panels)
        thermostatPanel = DashboardLayout.thermostat(in: panels)
        storedGravity = DashboardLayout.gravity(in: panels).map { panel in
            var gravity = panel
            gravity.isEnabled = false
            return gravity
        }
        storedThermostat.dampingTime = thermostatPanel?.dampingTime
        measured = [:]
        lastMeasuredTimestep = nil
        dashboardStarted = false
        dashboardData = [:]
    }

    /// Once the system has atoms: the panels' computes, and the thermostat
    /// and force they switch on.
    private func startDashboard() {
        for command in DashboardLayout.setupCommands(for: dashboard) { enqueue(command) }
        if let panel = thermostatPanel {
            var thermostat = storedThermostat
            thermostat.target = panel.initialTarget(default: Thermostat.defaultTarget(units: thermostatUnits ?? ""))
            thermostat.isEnabled = panel.startsEnabled
            self.thermostat = thermostat
        }
        if let start = DashboardLayout.gravity(in: dashboard), start.isEnabled, var gravity = storedGravity {
            gravity.isEnabled = true
            self.gravity = gravity
        }
    }

    private func measureDashboard(frame: AtomFrame, snapshot: SimulationSnapshot) {
        guard dashboardSources.contains(where: \.isMeasured), lastMeasuredTimestep != snapshot.timestep else { return }
        lastMeasuredTimestep = snapshot.timestep
        for source in dashboardSources {
            let value: Double?
            switch source {
            case .angle(let tags): value = DashboardMeasure.angle(tags, in: frame)
            case .volume: value = pendingStats.volume
            default: continue
            }
            guard let value, value.isFinite else { continue }
            var points = measured[source, default: []]
            points.append(SIMD2(snapshot.time, value))
            if points.count > Self.measuredCapacity { points.removeFirst(points.count - Self.measuredCapacity) }
            measured[source] = points
        }
        historyChanged = true
    }

    private func refreshDashboard() {
        guard !dashboardSources.isEmpty else { return }
        var data: [DashboardSource: [SIMD2<Double>]] = [:]
        for source in dashboardSources {
            data[source] = PlotCatalog.downsample(points(for: source), maxPoints: maxPlotPoints)
        }
        dashboardData = data
    }

    private func points(for source: DashboardSource) -> [SIMD2<Double>] {
        switch source {
        case .observable(let key):
            return history.series(id: key.observableID, component: key.component)
        case .angle, .volume:
            return measured[source] ?? []
        case .diffusion(let msd):
            return DashboardMeasure.diffusion(fromMSD: history.series(id: msd.observableID, component: msd.component),
                                              dimension: pendingStats.dimension)
        case .average(let inner):
            return DashboardMeasure.cumulativeAverage(points(for: inner))
        }
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
