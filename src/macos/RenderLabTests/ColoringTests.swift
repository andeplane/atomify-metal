import AtomifyRender
import simd
import Testing
@testable import RenderLab

@Suite struct ScalarFieldTests {
    static let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(4, 0, 1), SIMD3(0, 4, 2), SIMD3(4, 4, 3)]
    static let bounds = SceneBounds(low: .zero, high: SIMD3<Float>(4, 4, 3))

    @Test func height() {
        let values = ScalarField.values(.height, positions: Self.positions, bounds: Self.bounds)
        #expect(values == [0, 1, 2, 3])
    }

    @Test func distanceFromCenter() {
        let values = ScalarField.values(.distance, positions: Self.positions, bounds: Self.bounds)
        let center = Self.bounds.center
        #expect(values.count == 4)
        for (value, p) in zip(values, Self.positions) {
            #expect(closeF(value, simd_length(p - center)))
        }
    }

    @Test(arguments: ScalarProperty.allCases)
    func oneValuePerPositionAndDeterministic(property: ScalarProperty) {
        let positions = FCCLattice(latticeConstant: 4.05, cells: 4).positions()
        let bounds = SceneBounds.of(positions) ?? Self.bounds
        let a = ScalarField.values(property, positions: positions, bounds: bounds)
        let b = ScalarField.values(property, positions: positions, bounds: bounds)
        #expect(a.count == positions.count)
        #expect(a == b)
        let range = ScalarField.range(a)
        #expect(range.upperBound > range.lowerBound)
    }

    @Test func randomFieldRangeAndSeed() {
        let positions = FCCLattice(latticeConstant: 4.05, cells: 4).positions()
        let bounds = SceneBounds.of(positions) ?? Self.bounds
        let a = ScalarField.values(.randomField, positions: positions, bounds: bounds, seed: 1)
        let b = ScalarField.values(.randomField, positions: positions, bounds: bounds, seed: 2)
        #expect(a != b)
        for v in a {
            #expect(v >= 0 && v <= 1.5)
        }
    }

    @Test func sineWaveRange() {
        let positions = FCCLattice(latticeConstant: 4.05, cells: 4).positions()
        let bounds = SceneBounds.of(positions) ?? Self.bounds
        for v in ScalarField.values(.sineWave, positions: positions, bounds: bounds) {
            #expect(v >= -1.5 && v <= 1.5)
        }
    }

    @Test func valueNoiseAtLatticePoints() {
        let expected = LabHash.unitFloat(LabHash.hash(2, 3, 4, seed: 9))
        #expect(ScalarField.valueNoise(SIMD3<Float>(2, 3, 4), seed: 9) == expected)
        let minusOne = UInt64(bitPattern: -1)
        let negative = LabHash.unitFloat(LabHash.hash(minusOne, 0, 0, seed: 9))
        #expect(ScalarField.valueNoise(SIMD3<Float>(-1, 0, 0), seed: 9) == negative)
    }

    @Test func valueNoiseIsBoundedAndContinuous() {
        var rng = SplitMix64(seed: 3)
        for _ in 0..<500 {
            let x = rng.uniform(-20, 20)
            let y = rng.uniform(-20, 20)
            let z = rng.uniform(-20, 20)
            let p = SIMD3<Float>(x, y, z)
            let v = ScalarField.valueNoise(p, seed: 5)
            #expect(v >= 0 && v <= 1)
            let nearby = ScalarField.valueNoise(p + SIMD3<Float>(1e-3, 1e-3, 1e-3), seed: 5)
            #expect(abs(v - nearby) < 0.01)
        }
    }

    @Test func range() {
        #expect(ScalarField.range([3, 1, 2]) == 1...3)
        #expect(ScalarField.range([]) == 0...1)
        #expect(ScalarField.range([.nan, .infinity]) == 0...1)
        #expect(ScalarField.range([.nan, 5, -.infinity]) == 5...5)
    }

    @Test func radii() {
        let radii = ScalarField.radii([0, 5, 10, -3, 20], range: 0...10, radii: 1...2)
        #expect(radii.count == 5)
        #expect(closeF(radii[0], 1))
        #expect(closeF(radii[1], 1.5))
        #expect(closeF(radii[2], 2))
        #expect(closeF(radii[3], 1))
        #expect(closeF(radii[4], 2))
        let flat = ScalarField.radii([4, 4], range: 4...4, radii: 1...2)
        #expect(flat == [1.5, 1.5])
        let nan = ScalarField.radii([.nan], range: 0...1, radii: 1...2)
        #expect(nan == [1])
    }

    @Test func colors() {
        let colors = ScalarField.colors([0, 1, 0.5], range: 0...1, colormap: .viridis)
        #expect(colors.count == 3)
        #expect(closeV4(colors[0], Colormap.viridis.color(at: 0)))
        #expect(closeV4(colors[1], Colormap.viridis.color(at: 1)))
        #expect(closeV4(colors[2], Colormap.viridis.color(at: 0.5)))
    }

    @Test func titlesAndUnits() {
        #expect(ScalarProperty.height.unit == "Å")
        #expect(ScalarProperty.randomField.unit.isEmpty)
        #expect(Set(ScalarProperty.allCases.map(\.title)).count == ScalarProperty.allCases.count)
        #expect(RadiusMode.allCases.map(\.title) == ["Style radius", "Radius from value"])
    }
}

@Suite struct ColoringSceneTests {
    static let count = 4 * 16 * 16 * 16

    @Test func defaultColorsEveryParticle() {
        let generated = ColoringScene.make(ColoringParameters())
        let particles = generated.scene.particles
        #expect(particles.count == Self.count)
        #expect(particles.colors?.count == Self.count)
        #expect(particles.radii == nil)
        #expect(generated.scalars?.count == Self.count)
        #expect(generated.scalarName == ScalarProperty.height.title)
        #expect(generated.legend?.colormap == .viridis)
        #expect(generated.legend?.title == "Height (z) (Å)")
        let top = Float(15.5) * 4.05
        #expect(generated.legend?.range.lowerBound == 0)
        #expect(closeF(generated.legend?.range.upperBound ?? 0, top, tolerance: 1e-3))
        #expect(generated.scene.lines.count == 1)
    }

    @Test func colorsFollowTheColormap() {
        var parameters = ColoringParameters()
        parameters.colormap = .plasma
        let generated = ColoringScene.make(parameters)
        let colors = generated.scene.particles.colors ?? []
        let scalars = generated.scalars ?? []
        let range = generated.legend?.range ?? 0...1
        #expect(colors.count == scalars.count)
        for index in stride(from: 0, to: colors.count, by: 997) {
            let expected = Colormap.plasma.color(for: scalars[index], in: range)
            #expect(closeV4(colors[index], expected))
        }
    }

    @Test func radiiFromValue() {
        var parameters = ColoringParameters()
        parameters.radiusMode = .fromValue
        parameters.property = .distance
        let generated = ColoringScene.make(parameters)
        let radii = generated.scene.particles.radii ?? []
        #expect(radii.count == Self.count)
        let low = ColoringScene.radiusRange.lowerBound
        let high = ColoringScene.radiusRange.upperBound
        for r in radii {
            #expect(r >= low - 1e-5 && r <= high + 1e-5)
        }
        #expect(closeF(radii.min() ?? 0, low))
        #expect(closeF(radii.max() ?? 0, high))
    }

    @Test func overridesOff() {
        var parameters = ColoringParameters()
        parameters.colorOverrides = false
        parameters.radiusMode = .fromValue
        let generated = ColoringScene.make(parameters)
        #expect(generated.scene.particles.colors == nil)
        #expect(generated.legend == nil)
        #expect(generated.scene.particles.radii?.count == Self.count)
        #expect(generated.scalars?.count == Self.count)
    }

    @Test func sameGeometryForEveryProperty() {
        var parameters = ColoringParameters()
        let first = ColoringScene.make(parameters)
        parameters.property = .sineWave
        let second = ColoringScene.make(parameters)
        #expect(first.scene.particles.positions == second.scene.particles.positions)
        #expect(first.bounds == second.bounds)
    }
}
