import AtomifyEngine
import Foundation
import Testing
import simd
@testable import AtomifyKit

/// Waits on the main actor (letting the session's tick run) until `condition` holds.
@MainActor
func waitUntil(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Runs the real engine (needs CLammps.xcframework), so it is one test per
/// behavior chain rather than many small ones.
@MainActor @Suite(.serialized) struct SimulationSessionTests {
    @Test(.timeLimit(.minutes(2))) func runsAnExampleEndToEnd() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "lj"))
        let session = SimulationSession()
        session.continueAfterScript = true
        #expect(session.isCameraFramed && session.framedCamera == nil)
        session.maxStepsPerSecond = 5000            // applied when the run starts
        session.load(example, from: catalog)
        #expect(session.status == .running)
        #expect(session.example == example)
        #expect(session.title == "Lennard-Jones liquid")

        try await waitUntil("first scene") { session.scene != nil }
        let scene = try #require(session.scene)
        #expect(scene.particles.count == 256)
        #expect(scene.lines.count == 1)                       // the box
        #expect(isClose(scene.particles.styles[1].color, SIMD4(1, 0, 0, 1)))   // #/atom 1 ... #ff0000
        #expect(isClose(scene.particles.styles[2].color, SIMD4(0, 0, 1, 1)))
        #expect(isClose(session.camera.target, SIMD3(3, 4, 3), 1e-3))           // #/camera target

        try await waitUntil("stats") { session.stats.atoms == 256 }
        #expect(session.stats.units == "lj")
        #expect(session.stats.dimension == 3)
        #expect(session.stats.typeCount >= 2)
        #expect(session.stats.boxSize.x > 0 && session.stats.boxSize.y > 0 && session.stats.boxSize.z > 0)
        #expect(abs(session.stats.volume - session.stats.boxSize.x * session.stats.boxSize.y
            * session.stats.boxSize.z) < 1e-9)

        // The reset-view control has something to do only after the camera moved.
        #expect(session.framedCamera != nil)
        #expect(session.isCameraFramed)
        session.camera.rotate(by: SIMD2(0.4, 0.1))
        #expect(!session.isCameraFramed)
        session.resetCamera()
        #expect(session.isCameraFramed)

        // Speed limit: set while running, and cleared by a non-positive value.
        #expect(session.maxStepsPerSecond == 5000)
        session.maxStepsPerSecond = 0
        #expect(session.maxStepsPerSecond == nil)

        // Bonds from the #/bond rule (fcc neighbors are about 1.12 apart).
        try await waitUntil("bonds") { (session.scene?.bonds?.pairs.count ?? 0) > 0 }
        session.showBonds = false
        #expect(session.scene?.bonds == nil)
        session.showBonds = true
        session.showBox = false
        #expect(session.scene?.lines.isEmpty == true)
        session.showBox = true

        // Picking and selection.
        session.selectParticle(5)
        let picked = try #require(session.selectedAtom)
        #expect(picked.index == 5)
        #expect(session.scene?.particles.flags?[5] == SceneBuilder.selectedFlag)
        session.selectParticle(5)                              // again: deselects
        #expect(session.selectedAtom == nil)
        session.selectAtom(tag: picked.tag)
        #expect(session.selectedAtom?.tag == picked.tag)
        session.selectParticle(nil)
        #expect(session.selectedAtom == nil)

        // Color by a per-atom quantity, from the compute in the script and built-ins.
        try await waitUntil("per-atom quantities") { session.availableQuantities.contains("c_ke") }
        #expect(session.availableQuantities.suffix(3) == ["vx", "vy", "vz"])
        session.colorQuantity = "vx"
        session.colormap = .coolwarm
        try await waitUntil("vx colors") { session.scene?.particles.colors != nil }
        #expect(session.colorRange != nil)
        #expect(session.colorMode.quantity == "vx")
        // The selected atom's swatch is the color it is drawn in, not its type's.
        session.selectParticle(3)
        let drawn = try #require(session.scene?.particles.colors?[3])
        let swatch = try #require(session.selectedAtom?.color)
        func linear(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        #expect(abs(linear(swatch.x) - drawn.x) < 1e-3 && abs(linear(swatch.z) - drawn.z) < 1e-3)
        session.clearSelection()
        session.customColorRange = -1...1
        #expect(session.colorRange == -1...1)
        session.customColorRange = nil
        session.resetColorRange()
        session.colorQuantity = nil
        #expect(session.scene?.particles.colors == nil)
        #expect(session.colorMode == .type)

        // Plots default to temperature and energies.
        try await waitUntil("plots") { !(session.plotData.values.first?.isEmpty ?? true) }
        let temperature = try #require(session.plotOptions.first { $0.title == "Temperature" })
        #expect(session.plottedSeries.contains(temperature.key))
        let extra = try #require(session.plotOptions.last)
        session.addPlot(extra.key)
        #expect(session.plottedSeries.last == extra.key)
        #expect(session.title(of: extra.key) == extra.title)
        session.removePlot(extra.key)
        #expect(!session.plottedSeries.contains(extra.key))

        // Console, pause and commands.
        try await waitUntil("thermo output") { session.console.text.contains("Step") }
        session.pause()
        #expect(session.status == .paused)
        session.resume()
        #expect(session.status == .running)
        session.togglePause()
        #expect(session.status == .paused)
        session.togglePause()
        session.enqueue("print \"hello from the console\"")
        try await waitUntil("command output") { session.console.text.contains("hello from the console") }
        #expect(session.console.text.contains("> print"))
        session.clearConsole()

        session.recordFrame(particlesDrawn: 256, gpuTimeMs: 1)
        session.recordFrame(particlesDrawn: 256, gpuTimeMs: 1)
        session.resetCamera()

        // Restart runs the original files again.
        session.restart()
        #expect(session.status == .running)
        try await waitUntil("scene after restart") { session.scene != nil }

        session.stop()
        #expect(session.status == .idle)
        #expect(session.scene != nil)      // the last picture stays
        session.enqueue("print ignored")
    }

    @Test(.timeLimit(.minutes(1))) func thermostatCoolsTheLiquid() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "lj"))
        let session = SimulationSession()
        session.continueAfterScript = true
        session.thermostat.isEnabled = true             // nothing running: stays off
        #expect(!session.thermostat.isEnabled)

        session.load(example, from: catalog)
        try await waitUntil("stats") { session.stats.atoms == 256 }
        #expect(session.thermostat.target == 1)         // the lj default
        #expect(!session.thermostat.isEnabled)

        session.thermostat = Thermostat(isEnabled: true, target: 0.1)
        #expect(session.thermostat.isEnabled)
        #expect(session.console.text.contains("> fix atomify_thermostat all langevin 0.1 0.1"))
        try await waitUntil("cooling", timeout: .seconds(40)) { session.stats.temperature < 0.5 }

        session.thermostat.target = 0.2                  // replaces the fix
        #expect(session.console.text.contains("langevin 0.2 0.2"))
        session.thermostat.isEnabled = false
        #expect(session.console.text.contains("> unfix atomify_thermostat"))
        try await waitUntil("commands run") { session.console.text.contains("Step") }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!session.console.text.contains("ERROR"), "LAMMPS rejected a thermostat command")

        session.thermostat.isEnabled = true
        session.restart()                                // a new run starts without it
        #expect(!session.thermostat.isEnabled)
        #expect(session.thermostat.target == 0.2)        // same units: target kept
        session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func atomify2ExamplesPlayAtTheirSpeed() async throws {
        // The fixture script with Atomify 2 run-time directives before its run.
        let fixtures = try fixturesDirectory()
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("lj"),
                                                withIntermediateDirectories: true)
        let original = try String(contentsOf: fixtures.appendingPathComponent("lj/lj.in"), encoding: .utf8)
        let script = original.replacingOccurrences(of: "run 200", with: "#/speed 2\n#/label Warming up\nrun 200")
        try script.write(to: scratch.appendingPathComponent("lj/lj.in"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("shared"),
                                         to: scratch.appendingPathComponent("shared"))
        let options = ExampleOptions(dialect: .atomify2, stepsPerFrame: 1,
                                     camera: ExampleCamera(position: [0, 0, 30], up: [0, -1, 0], fieldOfView: 25,
                                                           relativeToBoxCenter: true))
        let example = Example(id: "lj2", title: "LJ", description: "", inputScript: "lj.in",
                              files: [ExampleFile(fileName: "lj.in", url: "lj/lj.in"),
                                      ExampleFile(fileName: "settings.lmp", url: "shared/settings.lmp")],
                              atomifyMetal: options)
        let catalog = ExampleCatalog(directory: scratch, examples: [example])

        // By default (the Mac app) the pacing is ignored and the console shows the directives.
        let mac = SimulationSession()
        #expect(!mac.appliesScriptSpeed)
        mac.load(example, from: catalog)
        #expect(mac.stepsPerFrame == nil)
        #expect(mac.effectiveMaxStepsPerSecond == nil)
        try await waitUntil("label without pacing") { mac.scriptLabel == "Warming up" }
        #expect(mac.stepsPerFrame == nil)
        #expect(mac.effectiveMaxStepsPerSecond == nil)
        try await waitUntil("directives in the console") { mac.console.text.contains("#/label Warming up") }
        #expect(mac.console.text.contains("#/speed 2"))
        mac.stop()

        let session = SimulationSession()
        session.appliesScriptSpeed = true
        session.continueAfterScript = true
        session.load(example, from: catalog)
        #expect(session.stepsPerFrame == 1)
        #expect(session.effectiveMaxStepsPerSecond == SimulationSession.referenceFrameRate)

        try await waitUntil("label") { session.scriptLabel == "Warming up" }
        #expect(session.stepsPerFrame == 2)
        #expect(session.effectiveMaxStepsPerSecond == 2 * SimulationSession.referenceFrameRate)
        session.speedFactor = 0.5
        #expect(session.effectiveMaxStepsPerSecond == SimulationSession.referenceFrameRate)
        session.speedFactor = .infinity
        #expect(session.effectiveMaxStepsPerSecond == nil)

        try await waitUntil("first scene") { session.scene != nil }
        let scene = try #require(session.scene)
        // Atomify 2 draws `#/atom 1 1.0 #ff0000` at a quarter of the radius.
        #expect(abs(scene.particles.styles[1].radius - 0.25) < 1e-6)
        // The camera sits 30 in front of the box center, upside down, with a 25 degree view.
        #expect(abs(session.camera.distance - 30) < 1e-3)
        #expect(simd_length(session.camera.basis.up - SIMD3(0, -1, 0)) < 1e-4)
        #expect(abs(session.camera.fieldOfView - 25 * .pi / 180) < 1e-6)

        try await waitUntil("console") { session.console.text.contains("Step") }
        #expect(!session.console.text.contains("@atomify"))

        // Frame paced at two steps per frame: about 120 steps a second
        // (stats refresh every 0.2 s, hence the wide margin).
        session.speedFactor = 1
        try await Task.sleep(for: .milliseconds(300))
        let before = session.stats.timestep
        try await Task.sleep(for: .seconds(2))
        let rate = Double(session.stats.timestep - before) / 2
        #expect(rate > 90 && rate < 150, "steps per second \(rate)")
        session.speedFactor = .infinity
        session.restart()
        #expect(session.scriptLabel == nil)
        #expect(session.stepsPerFrame == 1)
        #expect(session.speedFactor == .infinity)          // the user's choice is kept
        session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func anExampleCanColorItsAtomsFromTheStart() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let plain = try #require(catalog.example(id: "lj"))
        var hot = plain
        hot.id = "lj-hot"
        hot.atomifyMetal = ExampleOptions(color: ExampleColoring(quantity: "c_ke", colormap: "inferno", range: [0, 4]))
        let session = SimulationSession()
        session.maxStepsPerSecond = 2000
        session.load(hot, from: catalog)
        #expect(session.colorQuantity == "c_ke")
        #expect(session.colormap == .inferno)
        #expect(session.customColorRange == 0...4)
        try await waitUntil("per-atom colors") {
            if case .perAtom(let quantity, let colormap, let range) = session.colorMode {
                return quantity == "c_ke" && colormap == .inferno && range == 0...4 && session.scene != nil
            }
            return false
        }

        // A restart of the same example keeps what the user changed ...
        session.colormap = .plasma
        session.restart()
        #expect(session.colormap == .plasma)
        // ... and another example starts with its own coloring: by type here.
        session.load(plain, from: catalog)
        #expect(session.colorQuantity == nil)
        #expect(session.customColorRange == nil)
        session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func dashboardPanelsMeasureAndControl() async throws {
        let fixtures = try fixturesDirectory()
        let panels = [
            DashboardPanel(kind: "summary"),
            DashboardPanel(kind: "thermometer"),
            DashboardPanel(kind: "meanSquareDisplacement"),
            DashboardPanel(kind: "angle", parameters: ["atom1": "1", "atom2": "2", "atom3": "3"]),
            DashboardPanel(kind: "volume"),
            DashboardPanel(kind: "thermostat", parameters: ["nvtEnabled": "true", "targetTemperature": "0.5",
                                                            "minimumValue": "0.1", "maximumValue": "2",
                                                            "temperatureDampening": "0.5"]),
        ]
        let example = Example(id: "lj-dashboard", title: "LJ", description: "", inputScript: "lj.in",
                              files: [ExampleFile(fileName: "lj.in", url: "lj/lj.in"),
                                      ExampleFile(fileName: "settings.lmp", url: "shared/settings.lmp")],
                              atomifyMetal: ExampleOptions(dashboard: panels))
        let catalog = ExampleCatalog(directory: fixtures, examples: [example])
        let session = SimulationSession()
        session.continueAfterScript = true
        session.load(example, from: catalog)
        #expect(session.dashboard == panels)
        #expect(session.thermostatRange == 0.1...2)
        #expect(session.gravity == nil)

        // The thermostat panel switches the heat bath on once there are atoms.
        try await waitUntil("thermostat") { session.thermostat.isEnabled }
        #expect(session.thermostat.target == 0.5)
        #expect(session.console.text.contains("> fix atomify_thermostat all langevin 0.5 0.5 0.5"))
        #expect(session.console.text.contains("> compute atomify_msd all msd"))
        session.thermostat.target = 10                   // limited to the panel's range
        #expect(session.thermostat.target == 2)

        let msd = DashboardSource.observable(DashboardLayout.msdKey)
        let temperature = DashboardSource.observable(DashboardLayout.temperatureKey)
        let angle = DashboardSource.angle(SIMD3(1, 2, 3))
        try await waitUntil("dashboard data", timeout: .seconds(40)) {
            (session.dashboardData[msd]?.count ?? 0) > 2 && (session.dashboardData[angle]?.count ?? 0) > 2
                && (session.dashboardData[temperature]?.count ?? 0) > 2
        }
        let angles = try #require(session.dashboardData[angle])
        #expect(angles.allSatisfy { $0.y >= 0 && $0.y <= 180 })
        let volume = try #require(session.dashboardData[.volume]?.last)
        #expect(abs(volume.y - session.stats.volume) < 1e-6 * max(session.stats.volume, 1))
        let average = try #require(session.dashboardData[.average(temperature)])
        #expect(average.count == session.dashboardData[temperature]?.count)
        #expect(!session.console.text.contains("ERROR"), "LAMMPS rejected a dashboard command")

        session.stop()
        #expect(!session.thermostat.isEnabled)

        // A plain script gets the summary and temperature.
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let script = scratch.appendingPathComponent("plain.in")
        try "units lj\n".write(to: script, atomically: true, encoding: .utf8)
        session.load(script: script)
        #expect(session.dashboard == DashboardLayout.fallback)
        #expect(session.thermostatPanel == nil)
        session.stop()
    }

    @Test(.timeLimit(.minutes(1))) func scriptErrorsAreSurfaced() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let script = scratch.appendingPathComponent("broken.in")
        try "units lj\nthis_is_not_a_command 1 2 3\n".write(to: script, atomically: true, encoding: .utf8)

        let session = SimulationSession()
        session.load(script: script)
        #expect(session.title == "broken.in")
        #expect(session.example == nil)
        try await waitUntil("failure") { if case .failed = session.status { true } else { false } }
        #expect(session.errorMessage?.isEmpty == false)
    }

    @Test func missingFilesFailBeforeStarting() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let session = SimulationSession()
        session.load(try #require(catalog.example(id: "missing-file")), from: catalog)
        #expect(session.status == .failed(ExampleCatalogError.missingFile("nowhere/gone.in").localizedDescription))
        #expect(session.errorMessage != nil)
        session.restart()
        #expect(session.errorMessage != nil)
        session.stop()
        session.pause()
        session.resume()
        session.resetCamera()
        session.selectParticle(0)
        #expect(session.selectedAtom == nil)
    }
}
