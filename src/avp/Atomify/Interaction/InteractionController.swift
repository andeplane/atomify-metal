import ARKit
import AtomifyKit
import simd

/// Turns hands and forearms into soft forces on the atoms: the whole hand
/// pushes, so a cupped hand can hold and carry atoms. Pinching is handled by
/// the lab's gesture, not here; pushing pauses while any pinch is down.
@MainActor
final class InteractionController {
    private var isPushing = false

    func update(hands: [HandAnchor.Chirality: HandTracker.Hand], scene: MoleculeScene,
                simulation: LammpsSimulation) {
        guard let snapshot = scene.currentSnapshot, !snapshot.minimizing,
              let metersPerUnit = scene.worldMetersPerSimulationUnit, metersPerUnit.isFinite, metersPerUnit > 1e-8 else {
            reset(simulation)
            return
        }
        let tuning = InteractionTuning.forUnits(snapshot.units)
        let contact = scene.atomContactRadius
        var spheres: [LammpsSimulation.ForceSphere] = []
        // Hands are mapped into the drawn frame. Where molecules are drawn
        // whole across a periodic face, an atom may be drawn a box length
        // from where it is simulated; the engine measures sphere contact by
        // minimum image, so the hand still pushes the atom it touches.
        for hand in hands.values {
            for collider in hand.colliders {
                spheres.append(.init(center: SIMD3<Double>(scene.simulationPoint(fromWorld: collider.center)),
                                     radius: Double(collider.radius / metersPerUnit + contact),
                                     strength: tuning.pushStrength))
            }
        }
        guard isPushing || !spheres.isEmpty else { return }
        simulation.setForceSpheres(spheres)
        isPushing = !spheres.isEmpty
    }

    func reset(_ simulation: LammpsSimulation?) {
        guard isPushing else { return }
        isPushing = false
        simulation?.setForceSpheres([])
    }
}
