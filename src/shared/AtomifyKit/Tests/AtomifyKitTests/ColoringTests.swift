import AtomifyEngine
import AtomifyRender
import Testing
@testable import AtomifyKit

@Suite struct ColoringTests {
    @Test func colorModeQuantity() {
        #expect(ColorMode.type.quantity == nil)
        #expect(ColorMode.perAtom(quantity: "c_ke", colormap: .jet, range: nil).quantity == "c_ke")
        #expect(ColorMode.perAtom(quantity: "vx", colormap: .jet, range: 0...1)
            != ColorMode.perAtom(quantity: "vx", colormap: .jet, range: nil))
    }

    @Test func availableQuantitiesAreUniqueAndEndWithVelocities() {
        let names = PerAtomQuantities.available(perAtomNames: [["c_ke"], [], ["c_stress[1]", "c_stress[2]", "c_ke"],
                                                               ["vx", ""]])
        #expect(names == ["c_ke", "c_stress[1]", "c_stress[2]", "vx", "vy", "vz"])
        #expect(PerAtomQuantities.available(perAtomNames: []) == ["vx", "vy", "vz"])
        #expect(PerAtomQuantities.available(from: []) == ["vx", "vy", "vz"])
    }

    @Test func finiteRangeSkipsNonFiniteValues() {
        #expect(finiteRange(of: [3, -1, .nan, 2, .infinity, -.infinity]) == -1...3)
        #expect(finiteRange(of: [5]) == 5...5)
        #expect(finiteRange(of: []) == nil)
        #expect(finiteRange(of: [.nan]) == nil)
    }

    @Test func rangeTrackerGrowsAndResets() {
        var tracker = ColorRangeTracker()
        #expect(tracker.range == nil)
        tracker.include([1, 2])
        #expect(tracker.range == 1...2)
        tracker.include([1.5])
        #expect(tracker.range == 1...2)
        tracker.include([-3, 0])
        #expect(tracker.range == -3...2)
        tracker.include([.nan])
        tracker.include([])
        #expect(tracker.range == -3...2)
        tracker.include([10])
        #expect(tracker.range == -3...10)
        tracker.reset()
        #expect(tracker.range == nil)
    }

    @Test func lookupSamplesTheColormap() {
        let lookup = ColorLookup(colormap: .coolwarm, range: 0...10, resolution: 11)
        #expect(lookup.colors.count == 11)
        #expect(isClose(lookup.color(for: 0), Colormap.coolwarm.color(at: 0)))
        #expect(isClose(lookup.color(for: 3), Colormap.coolwarm.color(at: 0.3)))
        #expect(isClose(lookup.color(for: 10), Colormap.coolwarm.color(at: 1)))
        #expect(isClose(lookup.color(for: -5), Colormap.coolwarm.color(at: 0)))
        #expect(isClose(lookup.color(for: 50), Colormap.coolwarm.color(at: 1)))
        #expect(lookup.fraction(of: 2.5) == 0.25)
        #expect(lookup.fraction(of: .nan) == 0.5)
        #expect(ColorLookup(colormap: .jet, range: 1...1).fraction(of: 1) == 0.5)
        #expect(ColorLookup(colormap: .jet, range: 0...1, resolution: 0).colors.count == 2)
        #expect(lookup.colors(for: [0, 10]).count == 2)
    }

    @Test func linearColorFromSRGB() {
        #expect(isClose(RGBColor(hex: 0xFFFFFF).linear, SIMD4(1, 1, 1, 1)))
        #expect(isClose(RGBColor(hex: 0x000000).linear, SIMD4(0, 0, 0, 1)))
        let mid = RGBColor(hex: 0x808080).linear
        #expect(mid.x > 0.2 && mid.x < 0.23)   // sRGB 0.5 is about 0.21 linear
        #expect(mid.w == 1)
    }
}

@Suite struct AtomPickingTests {
    @Test func pickedIndexMapsToTheAtom() throws {
        let frame = sampleFrame(quantity: "c_ke", values: [0.5, 1.5, 2.5, 3.5])
        let info = try #require(AtomPicking.atom(atParticle: 2, in: frame))
        #expect(info.index == 2)
        #expect(info.tag == 9)
        #expect(info.type == 1)
        #expect(info.position == SIMD3(0, 1, 0))
        #expect(info.quantity == "c_ke")
        #expect(info.value == 2.5)
        #expect(info.radius == nil)
        #expect(info.typeName == nil)
        #expect(info.color == nil)
        #expect(info.elementName == nil)
    }

    @Test func elementNameAndColor() throws {
        let table = AtomStyleTable(directives: ScriptDirectives.parse("#/atom 1 oxygen\n#/atom 2 2.0 #00ff00"),
                                   typeCount: 2, units: "real")
        let oxygen = try #require(AtomPicking.atom(atParticle: 0, in: sampleFrame(), styles: table))
        #expect(oxygen.elementName == "Oxygen")
        let oxygenColor = try #require(oxygen.color)
        #expect(abs(oxygenColor.x - Float(0xAA) / 255) < 1e-6)
        #expect(oxygenColor.y == 0 && oxygenColor.z == 0)
        let custom = try #require(AtomPicking.atom(atParticle: 1, in: sampleFrame(), styles: table))
        #expect(custom.elementName == nil)
        #expect(custom.color == SIMD3(0, 1, 0))
    }

    @Test func outOfRangeOrNilPicksNothing() {
        let frame = sampleFrame()
        #expect(AtomPicking.atom(atParticle: nil, in: frame) == nil)
        #expect(AtomPicking.atom(atParticle: -1, in: frame) == nil)
        #expect(AtomPicking.atom(atParticle: 4, in: frame) == nil)
    }

    @Test func styleNameAndRadius() throws {
        let table = AtomStyleTable(directives: ScriptDirectives.parse("#/atom 2 2.0 #00ff00"), typeCount: 2,
                                   units: "lj")
        let info = try #require(AtomPicking.atom(atParticle: 1, in: sampleFrame(), styles: table))
        #expect(info.typeName == table.style(forType: 2).name)
        #expect(info.radius == Float(table.style(forType: 2).radius))
        #expect(info.quantity == nil)
        #expect(info.value == nil)

        var granular = sampleFrame()
        granular.radii = [0.1, 0.2, 0.3, 0.4]
        #expect(AtomPicking.atom(atParticle: 3, in: granular, styles: table)?.radius == 0.4)
    }

    @Test func lookupByTagFollowsTheAtom() throws {
        var frame = sampleFrame()
        #expect(AtomPicking.atom(withTag: 11, in: frame)?.index == 3)
        // An atom before it disappears: same tag, new index and position.
        frame.tags.removeFirst()
        frame.types.removeFirst()
        frame.positions = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(7, 7, 7)]
        let info = try #require(AtomPicking.atom(withTag: 11, in: frame))
        #expect(info.index == 2)
        #expect(info.position == SIMD3(7, 7, 7))
        #expect(AtomPicking.atom(withTag: 2, in: frame) == nil)
    }

    @Test func rayHitsTheNearestSphere() {
        let frame = AtomFrame(tags: [1, 2, 3], types: [1, 1, 1],
                              positions: [SIMD3(0, 0, -10), SIMD3(0, 0, -5), SIMD3(3, 0, -5)])
        let radius: (Int) -> Float = { _ in 0.5 }
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: .zero, direction: SIMD3(0, 0, -2), radius: radius) == 1)
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: SIMD3(3, 0.4, 0), direction: SIMD3(0, 0, -1),
                                    radius: radius) == 2)
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: SIMD3(1.5, 0, 0), direction: SIMD3(0, 0, -1),
                                    radius: radius) == nil)
        // Behind the origin does not count; from inside a sphere it does.
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: SIMD3(0, 0, -20), direction: SIMD3(0, 0, -1),
                                    radius: radius) == nil)
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: SIMD3(0, 0, -5), direction: SIMD3(0, 0, -1),
                                    radius: radius) == 1)
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: .zero, direction: .zero, radius: radius) == nil)
        #expect(AtomPicking.atomHit(in: frame, rayOrigin: .zero, direction: SIMD3(0, 0, -1), radius: { _ in 0 }) == nil)
    }
}
