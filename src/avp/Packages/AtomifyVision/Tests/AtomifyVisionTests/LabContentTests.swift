import AtomifyEngine
import AtomifyKit
import AtomifyVision
import simd
import Testing

@Suite struct LabContentTests {
    let snapshot = SimulationSnapshot(typeCount: 2, boxLow: [0, 0, 0], boxHigh: [10, 10, 10], tags: [1, 2, 3],
                                      types: [1, 2, 2], positions: [[1, 1, 1], [2, 1, 1], [5, 5, 5]],
                                      bonds: [SIMD2(0, 1)])
    let styles = AtomStyleTable(directives: .init(atomStyles: [
        1: AtomStyle(name: "O", color: RGBColor(hex: 0xff0000), radius: 0.6),
        2: AtomStyle(name: "H", color: RGBColor(hex: 0x808080), radius: 0.3),
    ]), typeCount: 2, units: "real")

    @Test func sceneHasEveryAtomBondsAndTheStyleTable() {
        let scene = LabContent.scene(snapshot: snapshot, styles: styles, showsBox: false, highlight: nil)
        #expect(scene.particles.count == 3)
        #expect(scene.particles.styleIndices == [1, 2, 2])
        #expect(scene.particles.styles[1].radius == 0.6)
        #expect(scene.particles.flags == nil)
        #expect(scene.bonds?.pairs == [SIMD2(0, 1)])
        #expect(abs((scene.bonds?.radius ?? 0) - 0.3 * 0.35) < 1e-6)
        #expect(scene.lines.isEmpty)
    }

    @Test func markedAtomIsFlaggedAndBoxUsesTheLabLook() {
        let scene = LabContent.scene(snapshot: snapshot, styles: styles, showsBox: true,
                                     highlight: LabHighlight(tag: 3, kind: .held))
        #expect(scene.particles.flags == [0, 0, SceneBuilder.selectedFlag])
        #expect(scene.lines.count == 1)
        #expect(scene.lines[0].segments.count == 12)
        #expect(scene.lines[0].color == LabContent.boxColor)
        #expect(scene.lines[0].width == LabContent.boxLineWidth)
    }

    @Test func highlightLiftsTheAtomsOwnColorMoreWhileHeld() {
        let near = LabContent.highlightColor(LabHighlight(tag: 1, kind: .near), in: snapshot, styles: styles)
        let held = LabContent.highlightColor(LabHighlight(tag: 1, kind: .held), in: snapshot, styles: styles)
        #expect(near.x == 1 && held.x == 1)            // red stays saturated
        #expect(near.y > 0 && held.y > near.y)         // and gets lighter
        #expect(abs(near.y - near.z) < 1e-6)
        #expect(LabContent.highlightColor(LabHighlight(tag: 99, kind: .near), in: snapshot, styles: styles)
                == SIMD4(1, 1, 1, 1))
        #expect(LabContent.lifted(RGBColor(red: 0, green: 0, blue: 0), by: 2) == SIMD4(1, 1, 1, 1))
        #expect(LabContent.lifted(RGBColor(red: 0, green: 0, blue: 0), by: -1) == SIMD4(0, 0, 0, 1))
    }

    @Test func worldAndSimulationPointsRoundTrip() {
        let frame = SimulationFrame(boxLow: [0, 0, 0], boxHigh: [10, 10, 10], size: 0.5)
        let placement = BoxPlacement(position: [0, 1.2, -1], orientation: simd_quatf(angle: 0.7, axis: [0, 1, 0]),
                                     scale: 2)
        let center = LabContent.worldPoint(fromSimulation: [5, 5, 5], placement: placement, frame: frame)
        #expect(simd_distance(center, placement.position) < 1e-5)
        let matrix = LabContent.worldFromSimulation(placement: placement, frame: frame)
        let corner = matrix * SIMD4<Float>(10, 5, 5, 1)
        let expected = LabContent.worldPoint(fromSimulation: [10, 5, 5], placement: placement, frame: frame)
        #expect(simd_distance(SIMD3(corner.x, corner.y, corner.z), expected) < 1e-5)
        #expect(abs(simd_distance(expected, center) - 0.5) < 1e-5)   // 5 units × 0.05 m × scale 2
        let back = LabContent.simulationPoint(fromWorld: expected, placement: placement, frame: frame)
        #expect(simd_distance(back, [10, 5, 5]) < 1e-4)
    }

    @Test func raysHitThePlacedContentOnlyInFront() {
        let placement = BoxPlacement(position: [0, 1, -2], orientation: simd_quatf(angle: .pi / 4, axis: [0, 1, 0]),
                                     scale: 2)
        let extent = SIMD3<Float>(0.5, 0.5, 0.5)
        let eye = SIMD3<Float>(0, 1, 0)
        #expect(placement.intersects(rayOrigin: eye, direction: [0, 0, -1], extent: extent))
        #expect(!placement.intersects(rayOrigin: eye, direction: [0, 0, 1], extent: extent))
        #expect(!placement.intersects(rayOrigin: eye, direction: [0, 1, 0], extent: extent))
        // Just beside the content (box is 1 m wide at scale 2, ~0.71 m half diagonal): a margin catches it.
        #expect(!placement.intersects(rayOrigin: [0.8, 1, 0], direction: [0, 0, -1], extent: extent))
        #expect(placement.intersects(rayOrigin: [0.8, 1, 0], direction: [0, 0, -1], extent: extent, margin: 1.2))
        #expect(!placement.intersects(rayOrigin: eye, direction: .zero, extent: extent))
        // Axis-parallel rays in local space, inside and outside the slab.
        let upright = BoxPlacement(position: .zero)
        #expect(upright.intersects(rayOrigin: [0.1, 0, 5], direction: [0, 0, -1], extent: [1, 1, 1]))
        #expect(!upright.intersects(rayOrigin: [0.6, 0, 5], direction: [0, 0, -1], extent: [1, 1, 1]))
        // From inside, every direction hits.
        #expect(upright.intersects(rayOrigin: .zero, direction: [1, 1, 1], extent: [1, 1, 1]))
    }

    @Test func pointsInsideTheContentOrWithinReach() {
        let placement = BoxPlacement(position: [0, 1, -1], scale: 2)
        let extent = SIMD3<Float>(0.4, 0.4, 0.4)
        #expect(placement.contains([0.35, 1, -1], extent: extent))        // 0.4 m half width at scale 2
        #expect(!placement.contains([0.45, 1, -1], extent: extent))
        #expect(placement.contains([0.45, 1, -1], extent: extent, reach: 0.06))
    }
}
