import AtomifyEngine
import Foundation
import Testing
import simd
@testable import AtomifyKit

@Suite struct ScriptEventTests {
    @Test func directivesBecomePrintCommands() {
        #expect(ScriptEvent.command(forDirective: "#/speed 20") == "print \"@atomify speed 20\"")
        #expect(ScriptEvent.command(forDirective: "  #/speed\t5\r") == "print \"@atomify speed 5\"")
        #expect(ScriptEvent.command(forDirective: "#/label Dissolving by entropy")
            == "print \"@atomify label Dissolving by entropy\"")
        #expect(ScriptEvent.command(forDirective: "#/label say \"hi\" for $5")
            == "print \"@atomify label say hi for 5\"")
        #expect(ScriptEvent.command(forDirective: "#/label One side will have'm all")
            == "print \"@atomify label One side will have`m all\"")
        #expect(ScriptEvent.parse(line: "@atomify label One side will have`m all")
            == .label("One side will have\u{2019}m all"))
        #expect(ScriptEvent.command(forDirective: "#/speed fast") == nil)
        #expect(ScriptEvent.command(forDirective: "#/speed 0") == nil)
        #expect(ScriptEvent.command(forDirective: "#/atom 1 oxygen") == nil)
        #expect(ScriptEvent.command(forDirective: "run 100") == nil)
    }

    @Test func preparationKeepsLineNumbers() {
        let script = "units lj\n#/speed 4\n#/label Go\nrun 10\n"
        let prepared = ScriptPreparation.prepare(script)
        #expect(prepared == "units lj\nprint \"@atomify speed 4\"\nprint \"@atomify label Go\"\nrun 10\n")
        #expect(ScriptPreparation.prepare("units lj\nrun 10") == "units lj\nrun 10")
    }

    @Test func preparationSplitsWindowsLineEndings() {
        // "\r\n" is one Character: a leading directive must not swallow the script.
        let script = "#/label Start\r\nunits lj\r\n#/speed 2\r\nrun 10\r\n"
        #expect(ScriptPreparation.prepare(script)
            == "print \"@atomify label Start\"\nunits lj\nprint \"@atomify speed 2\"\nrun 10\n")
        #expect(ScriptPreparation.prepare("suffix kk\r\nunits lj")
            == "# suffix kk  (KOKKOS is not in this build)\nunits lj")
    }

    @Test func filterCanEchoDirectivesForAConsole() {
        var filter = ScriptEventFilter(echoesEvents: true)
        let out = filter.filter("print \"@atomify label Hi\"\n@atomify label Hi\n@atomify speed 10\n  100 1.5\n")
        #expect(out.text == "#/label Hi\n#/speed 10\n  100 1.5\n")
        #expect(out.events == [.label("Hi"), .speed(10)])
        _ = filter.filter("@atomify speed 2.5")
        #expect(filter.flush().text == "#/speed 2.5")
        #expect(ScriptEvent.speed(4).directive == "#/speed 4")
    }

    @Test func filterTakesMarkersOutOfTheOutput() {
        var filter = ScriptEventFilter()
        let first = filter.filter("Step Temp\n@atomify spe")
        #expect(first.text == "Step Temp\n")
        #expect(first.events.isEmpty)
        let second = filter.filter("ed 20\nprint \"@atomify label Hi\"\n@atomify label Hi\n  100 1.5\n")
        #expect(second.text == "  100 1.5\n")
        #expect(second.events == [.speed(20), .label("Hi")])
        let third = filter.filter("tail without newline")
        #expect(third.text.isEmpty)
        let rest = filter.flush()
        #expect(rest.text == "tail without newline")
        #expect(rest.events.isEmpty)
        var marker = ScriptEventFilter()
        _ = marker.filter("@atomify label End")
        #expect(marker.flush().events == [.label("End")])
    }

    @Test func parsesOnlyWellFormedMarkers() {
        #expect(ScriptEvent.parse(line: "@atomify speed 2.5") == .speed(2.5))
        #expect(ScriptEvent.parse(line: "@atomify label") == .label(""))
        #expect(ScriptEvent.parse(line: "@atomify speed -1") == nil)
        #expect(ScriptEvent.parse(line: "atomify speed 2") == nil)
    }
}

@Suite struct PlaybackSpeedTests {
    @Test func stepsPerFrameAtSixtyFramesPerSecond() {
        typealias S = SimulationSession
        #expect(S.effectiveLimit(stepsPerFrame: 1, speedFactor: 1, maxStepsPerSecond: nil) == 60)
        #expect(S.effectiveLimit(stepsPerFrame: 20, speedFactor: 0.5, maxStepsPerSecond: nil) == 600)
        #expect(S.effectiveLimit(stepsPerFrame: 1, speedFactor: .infinity, maxStepsPerSecond: nil) == nil)
        #expect(S.effectiveLimit(stepsPerFrame: nil, speedFactor: 2, maxStepsPerSecond: nil) == nil)
        #expect(S.effectiveLimit(stepsPerFrame: nil, speedFactor: 2, maxStepsPerSecond: 500) == 500)
        #expect(S.effectiveLimit(stepsPerFrame: 10, speedFactor: 1, maxStepsPerSecond: 500) == 500)
        #expect(S.effectiveLimit(stepsPerFrame: 1, speedFactor: 1, maxStepsPerSecond: 500) == 60)
    }

    @Test func eachTickGrantsTheStepsDueSinceTheLast() {
        typealias S = SimulationSession
        // One step per frame at 60 frames per second, ticked at 120 Hz: half a step a tick.
        let half = S.stepGrant(rate: 60, elapsed: .microseconds(8333))
        #expect(abs(half.steps - 0.5) < 1e-3)
        #expect(half.maxBudget == 2)
        // A hitch grants at most two reference frames' worth.
        #expect(abs(S.stepGrant(rate: 600, elapsed: .seconds(1)).steps - 20) < 1e-9)
        #expect(S.stepGrant(rate: 600, elapsed: .seconds(1)).maxBudget == 20)
        #expect(S.stepGrant(rate: 600, elapsed: .zero).steps == 0)
        // Slow speeds still let a whole step through.
        #expect(S.stepGrant(rate: 15, elapsed: .milliseconds(16)).maxBudget == 1)
    }
}

@Suite struct ExampleOptionsTests {
    @Test func decodesAtomify2Options() throws {
        let json = """
        {"title": "T", "examples": [{"id": "w", "title": "Water", "description": "", "inputScript": "w.in",
          "files": [{"fileName": "w.in", "url": "w/w.in"}],
          "atomifyMetal": {"dialect": "atomify2", "stepsPerFrame": 1, "periodicImages": [2, 2, 1],
            "camera": {"position": [0, 0, 2.5], "up": [0, -1, 0], "fieldOfView": 25, "relativeToBoxCenter": true},
            "dashboard": [{"kind": "summary"}, {"kind": "angle", "parameters": {"atom1": "1"}}],
            "notPorted": ["customColorShaderCode"]}}],
         "atomifyMetalSections": [{"id": "water", "title": "Water", "exampleIDs": ["w"]}]}
        """
        let catalog = try ExampleCatalog.decode(Data(json.utf8), directory: URL(fileURLWithPath: "/tmp"))
        let options = try #require(catalog.examples.first?.atomifyMetal)
        #expect(options.dialect == .atomify2)
        #expect(options.stepsPerFrame == 1)
        #expect(options.imageCounts == SIMD3(2, 2, 1))
        #expect(options.dashboard?.map(\.kind) == ["summary", "angle"])
        #expect(options.dashboard?[1].parameters?["atom1"] == "1")
        let hint = try #require(options.camera?.hint)
        #expect(hint.position == SIMD3(0, 0, 2.5))
        #expect(hint.up == SIMD3(0, -1, 0))
        #expect(hint.target == nil)
        #expect(hint.fieldOfView == 25)
        #expect(hint.relativeToBoxCenter)
        #expect(catalog.sections == [ExampleSections.Definition(id: "water", title: "Water", exampleIDs: ["w"])])
        #expect(ExampleOptions(periodicImages: [1, 1, 1]).imageCounts == nil)
        #expect(ExampleCamera(position: [1, 2]).hint.position == nil)
    }

    @Test func imageOffsetsFollowAtomify2() {
        let offsets = SceneBuilder.imageOffsets(counts: SIMD3(2, 2, 1), low: .zero, high: SIMD3(10, 20, 30),
                                                tilt: .zero)
        #expect(offsets.count == 4)
        #expect(offsets[0] == .zero)
        #expect(Set(offsets.map { SIMD3<Int>(Int($0.x), Int($0.y), Int($0.z)) })
            == [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 20, 0), SIMD3(10, 20, 0)])
        let three = SceneBuilder.imageOffsets(counts: SIMD3(3, 1, 1), low: .zero, high: SIMD3(1, 1, 1), tilt: .zero)
        #expect(Set(three.map(\.x)) == [-1, 0, 1])
        #expect(SceneBuilder.imageOffsets(counts: SIMD3(1, 1, 1), low: .zero, high: SIMD3(1, 1, 1),
                                          tilt: .zero) == [.zero])
    }

    @Test func theBoxSurroundsAllTheCopies() throws {
        // 2 x 2 copies reach from 0 to 20 in x and y: one box around them all.
        let box = SceneBuilder.replicatedBox(counts: SIMD3(2, 2, 1), low: .zero, high: SIMD3(10, 20, 30), tilt: .zero)
        #expect(box.low == .zero && box.high == SIMD3(20, 40, 30) && box.tilt == .zero)
        // Three copies are centered on the original: -10 ... 20.
        let three = SceneBuilder.replicatedBox(counts: SIMD3(3, 1, 1), low: SIMD3(0, 0, 0), high: SIMD3(10, 10, 10),
                                               tilt: .zero)
        #expect(three.low == SIMD3(-10, 0, 0) && three.high == SIMD3(20, 10, 10))
        // One copy is the box itself, and tilt scales with the copies.
        let one = SceneBuilder.replicatedBox(counts: SIMD3(1, 1, 1), low: SIMD3(1, 2, 3), high: SIMD3(4, 5, 6),
                                             tilt: SIMD3(1, 2, 3))
        #expect(one.low == SIMD3(1, 2, 3) && one.high == SIMD3(4, 5, 6) && one.tilt == SIMD3(1, 2, 3))
        let tilted = SceneBuilder.replicatedBox(counts: SIMD3(2, 2, 2), low: .zero, high: SIMD3(1, 1, 1),
                                                tilt: SIMD3(0.5, 0.25, 0.1))
        #expect(tilted.high == SIMD3(2, 2, 2) && tilted.tilt == SIMD3(1.0, 0.5, 0.2))

        // The scene's box lines span the replicated box, and every copy lies inside it.
        let frame = AtomFrame(tags: [1], types: [1], positions: [SIMD3(5, 5, 5)], boxLow: .zero,
                              boxHigh: SIMD3(10, 10, 10))
        let single = SceneBuilder.scene(from: frame, typeStyles: [], colorMode: .type, selectedTag: nil, showBox: true,
                                        bondRadius: 0)
        let replicated = SceneBuilder.scene(from: frame, typeStyles: [], colorMode: .type, selectedTag: nil,
                                            showBox: true, bondRadius: 0, imageCounts: SIMD3(2, 2, 1))
        func extent(_ scene: SceneData) throws -> SIMD3<Float> {
            let points = try #require(scene.lines.first).segments.flatMap { [$0.0, $0.1] }
            return points.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
                - points.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        }
        #expect(try extent(single) == SIMD3(10, 10, 10))
        #expect(try extent(replicated) == SIMD3(20, 20, 10))
        let offsets = SceneBuilder.imageOffsets(counts: SIMD3(2, 2, 1), low: .zero, high: SIMD3(10, 10, 10), tilt: .zero)
        #expect(offsets.allSatisfy { $0.x >= 0 && $0.x <= 10 && $0.y >= 0 && $0.y <= 10 })
    }
}

@Suite struct CameraHintFramingTests {
    @Test func positionsRelativeToTheBoxCenter() {
        let hint = CameraHint(position: SIMD3(0, 0, -45), up: SIMD3(0, -1, 0), fieldOfView: 25,
                              relativeToBoxCenter: true)
        let camera = CameraFraming.camera(hint: hint, boxLow: SIMD3(0, 0, -1), boxHigh: SIMD3(20, 10, 1))
        #expect(simd_length(camera.target - SIMD3(10, 5, 0)) < 1e-4)
        #expect(abs(camera.distance - 45) < 1e-3)
        #expect(simd_length(camera.position - SIMD3(10, 5, -45)) < 1e-3)
        #expect(abs(camera.fieldOfView - 25 * .pi / 180) < 1e-6)
        #expect(camera.fitsShorterSide)
        // Looking along +z with -y up: screen up is -y, screen right is +x.
        #expect(simd_length(camera.basis.up - SIMD3(0, -1, 0)) < 1e-4)
        #expect(simd_length(camera.basis.right - SIMD3(1, 0, 0)) < 1e-4)
    }

    @Test func targetAndUpAlongOtherAxes() {
        let hint = CameraHint(position: SIMD3(0, 30, 0), up: SIMD3(0, 0, 1), relativeToBoxCenter: true)
        let camera = CameraFraming.camera(hint: hint, boxLow: SIMD3(-5, -5, -5), boxHigh: SIMD3(5, 5, 5))
        #expect(simd_length(camera.position - SIMD3(0, 30, 0)) < 0.1)
        #expect(simd_dot(camera.basis.up, SIMD3(0, 0, 1)) > 0.999)
        #expect(abs(camera.fieldOfView - OrbitCamera().fieldOfView) < 1e-6)
    }

    @Test func framingWithoutHintResetsRollAndFieldOfView() {
        var base = OrbitCamera()
        base.roll = 1
        base.fieldOfView = 0.3
        base.fitsShorterSide = true
        let camera = CameraFraming.camera(hint: nil, boxLow: .zero, boxHigh: SIMD3(1, 1, 1), base: base)
        #expect(camera.roll == 0)
        #expect(camera.fieldOfView == OrbitCamera().fieldOfView)
        #expect(!camera.fitsShorterSide)
    }
}
