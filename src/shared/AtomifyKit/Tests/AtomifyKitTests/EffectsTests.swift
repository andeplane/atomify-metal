import AtomifyRender
import Foundation
import Testing
import simd
@testable import AtomifyKit

private func frame(_ positions: [SIMD3<Float>], types: [Int32]? = nil, tags: [Int64]? = nil,
                   periodic: [Bool] = [true, true, true]) -> AtomFrame {
    AtomFrame(tags: tags ?? positions.indices.map { Int64($0 + 1) }, types: types ?? positions.map { _ in 1 },
              positions: positions, boxLow: .zero, boxHigh: SIMD3(10, 10, 10), periodic: periodic)
}

private func scene(for frame: AtomFrame) -> SceneData {
    SceneBuilder.scene(from: frame, typeStyles: [SceneBuilder.fallbackStyle,
                                                  ParticleStyle(radius: 0.5, color: SIMD4(1, 1, 1, 1)),
                                                  ParticleStyle(radius: 0.4, color: SIMD4(0, 0, 1, 1))],
                       colorMode: .type, selectedTag: nil, showBox: false, bondRadius: 0)
}

@Suite struct EffectsTests {
    @Test func decodesEffectsUnderAtomifyMetal() throws {
        let json = """
        {"examples":[{"id":"a","title":"A","description":"d","inputScript":"a.in","files":[],
        "atomifyMetal":{"effects":[
          {"kind":"tracers","type":2,"color":[1,0,0],"scale":1.5},
          {"kind":"trails","ids":[3,4],"length":100,"every":2,"width":3},
          {"kind":"chart","series":"Temperature"}]}}]}
        """
        let catalog = try ExampleCatalog.decode(Data(json.utf8), directory: URL(fileURLWithPath: "/tmp"))
        let effects = try #require(catalog.example(id: "a")?.atomifyMetal?.effects)
        #expect(effects.map(\.kind) == [.tracers, .trails, .chart])
        #expect(effects[0] == ExampleEffect(kind: .tracers, type: 2, color: [1, 0, 0], scale: 1.5))
        #expect(effects[1].ids == [3, 4] && effects[1].length == 100 && effects[1].every == 2)
        #expect(effects[2].series == "Temperature")
    }

    @Test func picksAtomsByIDOrTypeWithALimit() {
        let f = frame((0..<100).map { SIMD3(Float($0) * 0.1, 0, 0) }, types: (0..<100).map { $0 % 2 == 0 ? 1 : 2 })
        #expect(ExampleEffect(kind: .tracers, ids: [3, 7, 9999]).indices(in: f) == [2, 6])
        #expect(ExampleEffect(kind: .tracers, type: 2).indices(in: f).count == ExampleEffect.atomLimit)
        #expect(ExampleEffect(kind: .tracers, type: 2).indices(in: f).first == 1)
        #expect(ExampleEffect(kind: .tracers).indices(in: f).isEmpty)
        #expect(ExampleEffect(kind: .tracers, type: 9).indices(in: f).isEmpty)
    }

    @Test func tracersChangeColorAndSizeOfJustTheirAtoms() {
        let f = frame([SIMD3(1, 1, 1), SIMD3(2, 2, 2), SIMD3(3, 3, 3)], types: [1, 2, 1])
        var built = scene(for: f)
        let pipeline = EffectPipeline(effects: [ExampleEffect(kind: .tracers, type: 2, color: [1, 0, 0], scale: 2)])
        pipeline.apply(to: &built, frame: f)
        let colors = built.particles.colors ?? []
        let radii = built.particles.radii ?? []
        #expect(colors.count == 3 && radii.count == 3)
        #expect(colors[1] == linearColor(srgb: SIMD3(1, 0, 0)))
        #expect(colors[0] == SIMD4(1, 1, 1, 1) && colors[2] == SIMD4(1, 1, 1, 1))
        #expect(radii == [0.5, 0.8, 0.5])
    }

    @Test func tracersKeepPerAtomColorsOfTheOthersAndDefaultTheirSize() {
        let f = frame([SIMD3(1, 1, 1), SIMD3(2, 2, 2)], types: [1, 1])
        var built = scene(for: f)
        built.particles.colors = [SIMD4(0.1, 0.2, 0.3, 1), SIMD4(0.4, 0.5, 0.6, 1)]
        EffectPipeline(effects: [ExampleEffect(kind: .tracers, ids: [2])]).apply(to: &built, frame: f)
        #expect(built.particles.colors?[0] == SIMD4(0.1, 0.2, 0.3, 1))
        #expect(built.particles.colors?[1] == linearColor(srgb: SIMD3(1, 0.25, 0.2)))
        #expect(built.particles.radii == [0.5, 0.75])      // 1.5 times
    }

    @Test func aTracerOfNoAtomChangesNothing() {
        let f = frame([SIMD3(1, 1, 1)])
        var built = scene(for: f)
        EffectPipeline(effects: [ExampleEffect(kind: .tracers, ids: [42])]).apply(to: &built, frame: f)
        #expect(built.particles.colors == nil && built.particles.radii == nil)
    }

    @Test func trailsFollowAtomsAndFadeFromOldToNew() {
        var pipeline = EffectPipeline(effects: [ExampleEffect(kind: .trails, ids: [1], color: [1, 0, 0],
                                                              length: 100, width: 3)])
        var last = frame([SIMD3(0, 5, 5), SIMD3(9, 9, 9)])
        for k in 0..<13 {
            last = frame([SIMD3(Float(k) * 0.5, 5, 5), SIMD3(9, 9, 9)])
            pipeline.record(last)
        }
        var built = scene(for: last)
        pipeline.apply(to: &built, frame: last)
        let lines = built.lines
        #expect(lines.count == TrailHistory.fadeSteps)
        #expect(lines.reduce(0) { $0 + $1.segments.count } == 12)
        #expect(lines.allSatisfy { $0.width == 3 })
        #expect(lines.first?.segments.first?.0 == SIMD3(0, 5, 5))
        #expect(lines.last?.segments.last?.1 == SIMD3(6, 5, 5))
        // Older parts are dimmer.
        #expect(lines.first!.color.x < lines.last!.color.x)
    }

    @Test func trailsKeepOnlyTheLastPointsAndEveryNthFrame() {
        var pipeline = EffectPipeline(effects: [ExampleEffect(kind: .trails, ids: [1], length: 5, every: 2)])
        var last = frame([SIMD3(0, 0, 0)])
        for k in 0..<40 {
            last = frame([SIMD3(Float(k) * 0.1, 0, 0)])
            pipeline.record(last)
        }
        var built = scene(for: last)
        pipeline.apply(to: &built, frame: last)
        #expect(built.lines.reduce(0) { $0 + $1.segments.count } == 4)     // 5 points
        #expect(built.lines.first?.segments.first?.0 == SIMD3(3.0, 0, 0))   // frames 30, 32, ... 38
    }

    @Test func trailsSkipTheStepAcrossAPeriodicBoundary() {
        var pipeline = EffectPipeline(effects: [ExampleEffect(kind: .trails, ids: [1])])
        for x: Float in [8.5, 9.5, 0.5, 1.5] { pipeline.record(frame([SIMD3(x, 1, 1)])) }
        var built = scene(for: frame([SIMD3(1.5, 1, 1)]))
        pipeline.apply(to: &built, frame: frame([SIMD3(1.5, 1, 1)]))
        #expect(built.lines.reduce(0) { $0 + $1.segments.count } == 2)      // 9.5 -> 0.5 is not drawn
        // In a box that is not periodic along x the same step is drawn.
        var walled = EffectPipeline(effects: [ExampleEffect(kind: .trails, ids: [1])])
        for x: Float in [8.5, 9.5, 0.5, 1.5] { walled.record(frame([SIMD3(x, 1, 1)], periodic: [false, true, true])) }
        var other = scene(for: frame([SIMD3(1.5, 1, 1)]))
        walled.apply(to: &other, frame: frame([SIMD3(1.5, 1, 1)], periodic: [false, true, true]))
        #expect(other.lines.reduce(0) { $0 + $1.segments.count } == 3)
    }

    @Test func aChartIsNotAFrameEffect() {
        let pipeline = EffectPipeline(effects: [ExampleEffect(kind: .chart, series: "Temperature")])
        #expect(pipeline.isEmpty)
        #expect(EffectPipeline().isEmpty)
    }
}

/// Runs the real engine, so it belongs to the serialized suite of the session tests.
@MainActor extension SimulationSessionTests {
    @Test(.timeLimit(.minutes(1))) func showsTheDashboardChartTheExampleNames() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        var example = try #require(catalog.example(id: "lj"))
        let session = SimulationSession()
        #expect(session.miniChart == nil)

        example.atomifyMetal = ExampleOptions(dashboard: [DashboardPanel(kind: "summary"), DashboardPanel(kind: "thermometer")],
                                              effects: [ExampleEffect(kind: .chart, series: "temperature")])
        session.load(example, from: catalog)
        #expect(session.miniChartSeries == "temperature")
        #expect(session.miniChart?.title == "Temperature")
        session.stop()

        // A series the dashboard does not have, and an example without a chart.
        example.id = "other"
        example.atomifyMetal = ExampleOptions(dashboard: [DashboardPanel(kind: "thermometer")],
                                              effects: [ExampleEffect(kind: .chart, series: "Pressure")])
        session.load(example, from: catalog)
        #expect(session.miniChart == nil)
        example.id = "third"
        example.atomifyMetal = ExampleOptions(dashboard: [DashboardPanel(kind: "thermometer")])
        session.load(example, from: catalog)
        #expect(session.miniChartSeries == nil && session.miniChart == nil)
        session.stop()
    }
}
