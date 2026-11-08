import AtomifyEngine
import AtomifyRender
import Testing
import simd
@testable import AtomifyKit

let sampleObservables = [
    ObservableInfo(id: "v_msd", kind: .variable, name: "msd"),
    ObservableInfo(id: "c_msd", kind: .compute, name: "msd", style: "msd", labels: ["", "", "", ""], valueCount: 4),
    ObservableInfo(id: "thermo_pe", kind: .thermo, name: "pe", labels: ["pe"]),
    ObservableInfo(id: "thermo_temp", kind: .thermo, name: "temp", labels: ["temp"]),
    ObservableInfo(id: "f_ave", kind: .fix, name: "ave", style: "ave/time", labels: ["a", "f_ave[2]"],
                   valueCount: 2),
    ObservableInfo(id: "thermo_step", kind: .thermo, name: "step"),
    ObservableInfo(id: "c_empty", kind: .compute, name: "empty", valueCount: 0),
]

@Suite struct PlotCatalogTests {
    @Test func optionsAreGroupedByKind() {
        let options = PlotCatalog.options(from: sampleObservables)
        #expect(options.map(\.group) == ["Thermo", "Thermo", "Thermo", "Computes", "Computes", "Computes", "Computes",
                                         "Fixes", "Fixes", "Variables"])
        #expect(options.map(\.title) == ["Potential energy", "Temperature", "step", "c_msd[1]", "c_msd[2]",
                                         "c_msd[3]", "c_msd[4]", "f_ave[1] a", "f_ave[2]", "v_msd"])
        #expect(options[3].key == PlotSeriesKey(observableID: "c_msd", component: 0))
        #expect(options[6].key == PlotSeriesKey(observableID: "c_msd", component: 3))
        #expect(options[0].id == options[0].key)
        #expect(PlotCatalog.options(from: []).isEmpty)
    }

    @Test func groupNames() {
        #expect(PlotCatalog.group(of: .thermo) == "Thermo")
        #expect(PlotCatalog.group(of: .compute) == "Computes")
        #expect(PlotCatalog.group(of: .fix) == "Fixes")
        #expect(PlotCatalog.group(of: .variable) == "Variables")
    }

    @Test func defaultsAreTemperatureAndEnergies() {
        #expect(PlotCatalog.defaultSelection(from: sampleObservables) == [
            PlotSeriesKey(observableID: "thermo_temp"), PlotSeriesKey(observableID: "thermo_pe"),
        ])
        #expect(PlotCatalog.defaultSelection(from: [ObservableInfo(id: "c_x", kind: .compute, name: "temp")]).isEmpty)
    }

    @Test func keysOrder() {
        #expect(PlotSeriesKey(observableID: "a", component: 2) < PlotSeriesKey(observableID: "b"))
        #expect(PlotSeriesKey(observableID: "a", component: 1) < PlotSeriesKey(observableID: "a", component: 2))
    }

    @Test func downsampleKeepsEndsAndBound() {
        let points = (0..<1000).map { SIMD2<Double>(Double($0), Double($0 * 2)) }
        let few = PlotCatalog.downsample(points, maxPoints: 100)
        #expect(few.count <= 100)
        #expect(few.count >= 50)
        #expect(few.first == points.first)
        #expect(few.last == points.last)
        #expect(zip(few, few.dropFirst()).allSatisfy { $0.x < $1.x })
        #expect(PlotCatalog.downsample(points, maxPoints: 2000).count == 1000)
        #expect(PlotCatalog.downsample(points, maxPoints: 1) == [points[999]])
        #expect(PlotCatalog.downsample(points, maxPoints: 0).isEmpty)
        #expect(PlotCatalog.downsample([Int](), maxPoints: 10).isEmpty)
        #expect(PlotCatalog.downsample([1, 2, 3], maxPoints: 2) == [1, 3])
    }
}

@Suite struct RunningAverageTests {
    @Test func averagesTheLastWindowOfPoints() {
        let points = [1.0, 3, 5, 7, 9].enumerated().map { SIMD2(Double($0.offset), $0.element) }
        let average = PlotCatalog.runningAverage(points, window: 2)
        #expect(average.map(\.x) == [0, 1, 2, 3, 4])
        #expect(average.map(\.y) == [1, 2, 4, 6, 8])
        let three = PlotCatalog.runningAverage(points, window: 3)
        #expect(three.map(\.y) == [1, 2, 3, 5, 7])
    }

    @Test func smallWindowsAndEmptyInput() {
        let points = [SIMD2(0.0, 4.0), SIMD2(1.0, 8.0)]
        #expect(PlotCatalog.runningAverage(points, window: 1) == points)
        #expect(PlotCatalog.runningAverage(points, window: 0) == points)
        #expect(PlotCatalog.runningAverage([], window: 5).isEmpty)
        // A window longer than the series is the mean so far.
        #expect(PlotCatalog.runningAverage(points, window: 10).map(\.y) == [4, 6])
    }

    @Test func nonFiniteValuesAreLeftOut() {
        let points = [SIMD2(0.0, .nan), SIMD2(1.0, 2.0), SIMD2(2.0, .infinity), SIMD2(3.0, 4.0), SIMD2(4.0, 6.0)]
        let average = PlotCatalog.runningAverage(points, window: 2)
        #expect(average[0].y.isNaN)                  // nothing finite yet
        #expect(average.dropFirst().map(\.y) == [2, 2, 4, 5])
    }
}

@Suite struct ConsoleLogTests {
    @Test func joinsPartialLines() {
        var log = ConsoleLog()
        log.append("Step Temp\n  0 1.5")
        #expect(log.lines == ["Step Temp"])
        #expect(log.pending == "  0 1.5")
        #expect(log.text == "Step Temp\n  0 1.5")
        log.append("0\n100 1.4\r\n")
        #expect(log.lines == ["Step Temp", "  0 1.50", "100 1.4"])
        #expect(log.pending == "")
        #expect(log.text == "Step Temp\n  0 1.50\n100 1.4")
        let revision = log.revision
        log.append("")
        #expect(log.revision == revision)
    }

    @Test func keepsTheLastLines() {
        var log = ConsoleLog(maxLines: 3)
        log.append((1...10).map { "line \($0)\n" }.joined())
        #expect(log.lines == ["line 8", "line 9", "line 10"])
        log.clear()
        #expect(log.lines.isEmpty)
        #expect(log.text.isEmpty)
        #expect(ConsoleLog(maxLines: 0).maxLines == 1)
    }
}

@Suite struct RateMeterTests {
    @Test func countsEventsPerSecondInTheWindow() {
        var meter = RateMeter(window: 1)
        #expect(meter.rate == 0)
        meter.tick(at: 0)
        #expect(meter.rate == 0)
        for i in 1...60 { meter.tick(at: Double(i) / 60) }
        #expect(abs(meter.rate - 60) < 0.01)
        // After a pause only the recent events count.
        meter.tick(at: 10)
        meter.tick(at: 10.5)
        #expect(abs(meter.rate - 2) < 0.01)
        var same = RateMeter()
        same.tick(at: 1)
        same.tick(at: 1)
        #expect(same.rate == 0)
    }
}

@Suite struct CameraFramingTests {
    @Test func orbitRoundTrips() {
        let target = SIMD3<Float>(1, 2, 3)
        for position in [SIMD3<Float>(1, 2, 13), SIMD3(11, 2, 3), SIMD3(4, 9, -5), SIMD3(-3, -1, 0)] {
            let orbit = CameraFraming.orbit(position: position, target: target)
            #expect(isClose(orbit.distance, simd_length(position - target), 1e-4))
            let eye = CameraFraming.eye(target: target, distance: orbit.distance, yaw: orbit.yaw, pitch: orbit.pitch)
            #expect(isClose(eye, position, 1e-4))
        }
        let front = CameraFraming.orbit(position: SIMD3(0, 0, 10), target: .zero)
        #expect(front.yaw == 0 && front.pitch == 0 && front.distance == 10)
        let above = CameraFraming.orbit(position: SIMD3(0, 5, 0), target: .zero)
        #expect(isClose(above.pitch, .pi / 2))
        let degenerate = CameraFraming.orbit(position: .zero, target: .zero)
        #expect(degenerate.distance == 1)
    }

    @Test func hintSetsTargetAndOrbit() throws {
        let hint = try #require(ScriptDirectives.parse("#/camera position 50.0 72.7 221.7\n#/camera target 45.7 51.3 35.0").camera)
        let camera = CameraFraming.camera(hint: hint, boxLow: .zero, boxHigh: SIMD3(100, 100, 50))
        #expect(isClose(camera.target, SIMD3(45.7, 51.3, 35), 1e-4))
        let eye = CameraFraming.eye(target: camera.target, distance: camera.distance, yaw: camera.yaw,
                                    pitch: camera.pitch)
        #expect(isClose(eye, SIMD3(50, 72.7, 221.7), 1e-3))
    }

    @Test func targetDefaultsToTheBoxCenter() throws {
        let hint = try #require(ScriptDirectives.parse("#/camera position 5 5 30").camera)
        #expect(hint.target == nil)
        let camera = CameraFraming.camera(hint: hint, boxLow: .zero, boxHigh: SIMD3(10, 10, 10))
        #expect(isClose(camera.target, SIMD3(5, 5, 5)))
        #expect(isClose(camera.distance, 25))
    }

    @Test func noHintFramesTheBox() {
        var expected = OrbitCamera()
        expected.frame(low: SIMD3(0, 0, 0), high: SIMD3(10, 20, 30))
        let camera = CameraFraming.camera(hint: nil, boxLow: .zero, boxHigh: SIMD3(10, 20, 30))
        #expect(camera == expected)
        let targetHint = ScriptDirectives.parse("#/camera target 1 1 1").camera
        #expect(targetHint?.position == nil)
        let onlyTarget = CameraFraming.camera(hint: targetHint, boxLow: .zero,
                                              boxHigh: SIMD3(10, 20, 30))
        #expect(onlyTarget.target == SIMD3(1, 1, 1))
        #expect(onlyTarget.distance == expected.distance)
        // A box LAMMPS has not set up yet is not framed.
        let unset = CameraFraming.camera(hint: nil, boxLow: SIMD3(repeating: .infinity),
                                         boxHigh: SIMD3(repeating: -.infinity))
        #expect(unset == OrbitCamera())
    }
}

@Suite struct CameraViewComparisonTests {
    @Test func sameViewWithinTolerance() {
        let camera = OrbitCamera(target: SIMD3(1, 2, 3), distance: 50, yaw: 0.3, pitch: 0.2)
        #expect(CameraFraming.isSameView(camera, camera))
        var nudged = camera
        nudged.target.x += 1e-4                   // relative to a distance of 50
        nudged.yaw += 1e-5
        #expect(CameraFraming.isSameView(camera, nudged))
        var rotated = camera
        rotated.rotate(by: SIMD2(0.1, 0))
        #expect(!CameraFraming.isSameView(camera, rotated))
        var zoomed = camera
        zoomed.distance = 40
        #expect(!CameraFraming.isSameView(camera, zoomed))
        var panned = camera
        panned.target.y += 1
        #expect(!CameraFraming.isSameView(camera, panned))
        var tilted = camera
        tilted.pitch -= 0.1
        #expect(!CameraFraming.isSameView(camera, tilted))
        var wide = camera
        wide.fieldOfView = .pi / 3
        #expect(!CameraFraming.isSameView(camera, wide))
    }
}

@Suite struct SessionStatsTests {
    @Test func boxSizeAndVolume() {
        let size = SessionStats.boxSize(low: SIMD3(-1, 0, 2), high: SIMD3(3, 5, 8))
        #expect(size == SIMD3(4, 5, 6))
        #expect(SessionStats.volume(boxSize: size, dimension: 3) == 120)
        #expect(SessionStats.volume(boxSize: size, dimension: 2) == 20)
        // A box LAMMPS has not set up yet.
        #expect(SessionStats.boxSize(low: SIMD3(repeating: .infinity), high: SIMD3(repeating: -.infinity)) == .zero)
        #expect(SessionStats.boxSize(low: SIMD3(1, 1, 1), high: .zero) == .zero)
    }

    @Test func speedLimits() {
        #expect(SimulationSession.speedLimit(nil) == nil)
        #expect(SimulationSession.speedLimit(0) == nil)
        #expect(SimulationSession.speedLimit(-5) == nil)
        #expect(SimulationSession.speedLimit(.infinity) == nil)
        #expect(SimulationSession.speedLimit(.nan) == nil)
        #expect(SimulationSession.speedLimit(120) == 120)
    }
}

@Suite struct RunStatusTests {
    @Test func outcomes() {
        #expect(RunStatus.after(.finished) == .finished)
        #expect(RunStatus.after(.cancelled) == .finished)
        #expect(RunStatus.after(.failed("ERROR: x")) == .failed("ERROR: x"))
        #expect(RunStatus.running.isActive && RunStatus.paused.isActive)
        #expect(!RunStatus.idle.isActive && !RunStatus.finished.isActive && !RunStatus.failed("").isActive)
        #expect([RunStatus.idle, .running, .paused, .finished, .failed("x")].map(\.label)
            == ["Idle", "Running", "Paused", "Finished", "Failed"])
        #expect(SessionStats() == SessionStats())
    }
}
