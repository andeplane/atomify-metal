import AtomifyEngine
import Testing
import simd
@testable import AtomifyVision

struct ExhibitFramingTests {
    let styles = AtomStyleTable(directives: .init(atomStyles: [
        1: .init(name: "Large", color: RGBColor(hex: 0x6EC6FF), radius: 0.5),
        2: .init(name: "Small", color: RGBColor(hex: 0xFFFFFF), radius: 0.3),
    ]), typeCount: 2, units: "metal")

    func molecule(box: Double = 40) -> SimulationSnapshot {
        .init(typeCount: 2, boxLow: SIMD3(repeating: -box), boxHigh: SIMD3(repeating: box),
              tags: [1, 2], types: [1, 2], positions: [[-1, 2, 3], [2, 2, 3]])
    }

    @Test func vacuumSizeCannotShrinkTheExhibit() throws {
        let near = try #require(ExhibitFraming(snapshot: molecule(box: 6), styles: styles))
        let huge = try #require(ExhibitFraming(snapshot: molecule(box: 400), styles: styles))
        #expect(near == huge)
        #expect(abs(near.extent.max() - 0.32) < 1e-5)
        #expect(simd_distance(near.frame.center, [0.4, 2, 3]) < 1e-5)
        // Sphere surfaces span 3.8 units; they should occupy ~28.6 cm.
        #expect(abs(3.8 * near.frame.metersPerUnit - 0.32 / 1.12) < 1e-5)
    }

    @Test func handAndPresentationTransformsRoundTripAfterMovingAndResizing() throws {
        let exhibit = try #require(ExhibitFraming(snapshot: molecule(), styles: styles))
        let placement = BoxPlacement(position: [0.2, 1.25, -0.7],
                                     orientation: simd_quatf(angle: 0.7, axis: [0, 1, 0]), scale: 1.8)
        let atom = SIMD3<Float>(2, 2, 3)
        let matrixPoint = exhibit.frame.localFromSimulation * SIMD4(atom, 1)
        let local = SIMD3(matrixPoint.x, matrixPoint.y, matrixPoint.z)
        let world = placement.worldPoint(fromLocal: local)
        let recovered = exhibit.frame.simulationPoint(fromLocal: placement.localPoint(fromWorld: world))
        #expect(simd_distance(recovered, atom) < 1e-5)
        let otherLocal = exhibit.frame.localFromSimulation * SIMD4<Float>(-1, 2, 3, 1)
        let otherWorld = placement.worldPoint(fromLocal: SIMD3(otherLocal.x, otherLocal.y, otherLocal.z))
        #expect(abs(simd_distance(world, otherWorld) - 3 * exhibit.frame.metersPerUnit * placement.scale) < 1e-5)
    }

    @Test func actualParticleRadiiTakePrecedenceOverTypeRadii() throws {
        var frame = molecule()
        frame.radii = [1, 1]
        let exhibit = try #require(ExhibitFraming(snapshot: frame, styles: styles))
        #expect(simd_distance(exhibit.frame.center, [0.5, 2, 3]) < 1e-5)
        #expect(abs(exhibit.frame.metersPerUnit - 0.32 / (5 * 1.12)) < 1e-5)
    }

    @Test func framingDoesNotMutatePhysicalBoxAndHasAUsableFlatHitVolume() throws {
        let snapshot = molecule()
        let exhibit = try #require(ExhibitFraming(snapshot: snapshot, styles: styles))
        #expect(snapshot.boxLow == SIMD3(repeating: -40))
        #expect(snapshot.boxHigh == SIMD3(repeating: 40))
        #expect(exhibit.extent.y >= 0.05)
        #expect(exhibit.extent.z >= 0.05)
        #expect(exhibit.extent.y < 0.15)
    }

    @Test func absentOrInvalidGeometryCannotCreateABadTransform() {
        var frame = molecule()
        frame.positions[0].x = .nan
        #expect(ExhibitFraming(snapshot: frame, styles: styles) == nil)
        frame = molecule(); frame.positions = []; frame.types = []; frame.tags = []
        #expect(ExhibitFraming(snapshot: frame, styles: styles) == nil)
        frame = molecule(); frame.radii = [1]
        #expect(ExhibitFraming(snapshot: frame, styles: styles) == nil)
        #expect(ExhibitFraming(snapshot: molecule(), styles: styles, size: 0) == nil)
    }
}
