import AtomifyEngine
import AtomifyVision
import SwiftUI
import simd

/// Pinches on the experiment, from the compositor layer's spatial events.
/// One hand pinches an atom to pull it; two hands pinch to move, turn and
/// resize the experiment. A pinch counts when it starts on the content (the
/// gaze ray through it, or the hand inside it) and stays until it ends.
@MainActor
final class LabInput {
    private let model: AppModel
    private let scene: LabScene
    private let driver: LabDriver
    private let interaction: LabInteraction
    /// Pinches that started on the content and have not ended.
    private var accepted: Set<Int> = []
    /// The content's target is this much larger than what is drawn, so a
    /// pinch at the edge still lands.
    private static let targetMargin: Float = 1.1
    private static let directReach: Float = 0.05

    init(model: AppModel, scene: LabScene, driver: LabDriver, interaction: LabInteraction) {
        self.model = model
        self.scene = scene
        self.driver = driver
        self.interaction = interaction
    }

    func receive(_ events: SpatialEventCollection) {
        guard scene.isPlaced, let extent = scene.contentExtent else {
            end()
            return
        }
        var samples: [PinchSample] = []
        for event in events {
            let kind: PinchSample.Kind
            switch event.kind {
            case .directPinch: kind = .direct
            case .indirectPinch: kind = .indirect
            default: continue
            }
            let id = event.id.hashValue
            let pose = event.inputDevicePose?.pose3D
            let position = Self.vector(pose?.position ?? event.location3D)
            var ray: PinchSample.Ray?
            if kind == .indirect, let selection = event.selectionRay {
                ray = PinchSample.Ray(origin: Self.vector(selection.origin), direction: Self.vector(selection.direction))
            }
            let ended = event.phase != .active
            if !accepted.contains(id) {
                guard !ended, targetsContent(kind: kind, position: position, ray: ray, extent: extent) else { continue }
                accepted.insert(id)
            }
            if ended { accepted.remove(id) }
            let tracked = event.chirality.flatMap { chirality in
                driver.handOrientation(chirality == .left ? .left : .right)
            }
            let system = pose.map { simd_quatf(vector: SIMD4<Float>($0.rotation.quaternion.vector)) }
            let orientation = interaction.orientation(for: id, tracked: tracked, system: system)
            samples.append(PinchSample(id: id, kind: kind, position: position, orientation: orientation,
                                       ray: ray, ended: ended))
        }
        guard !samples.isEmpty else { return }
        interaction.keepOrientations(for: Set(samples.filter { !$0.ended }.map(\.id)))
        apply(interaction.router.update(samples, placement: scene.placement))
        if accepted.isEmpty { end() }
    }

    /// Ends every pinch: the gesture finished, was cancelled or the lab closed.
    func end() {
        accepted = []
        interaction.reset()
        scene.isBoxBeingMoved = false
    }

    private func targetsContent(kind: PinchSample.Kind, position: SIMD3<Float>, ray: PinchSample.Ray?,
                                extent: SIMD3<Float>) -> Bool {
        switch kind {
        case .direct:
            return scene.placement.contains(position, extent: extent * Self.targetMargin, reach: Self.directReach)
        case .indirect:
            guard let ray else { return false }
            return scene.placement.intersects(rayOrigin: ray.origin, direction: ray.direction, extent: extent,
                                              margin: Self.targetMargin)
        }
    }

    private func apply(_ output: PinchRouter.Output) {
        if output.atomEnded { interaction.link.end() }
        if let began = output.atomBegan {
            beginGrab(began)
        } else if let pinch = output.atomPinch {
            interaction.link.follow(pinch)
        }
        if output.isGripping, let placement = output.placement {
            interaction.link.end()
            scene.placement = placement
            scene.isBoxBeingMoved = true
            interaction.setGripping(true)
            model.heldWithBothHands()
        } else {
            scene.isBoxBeingMoved = false
            interaction.setGripping(false)
        }
    }

    /// Picks the atom a new single pinch is at (direct) or looking at
    /// (indirect). Nothing there: the pinch does nothing.
    private func beginGrab(_ pinch: PinchSample) {
        guard model.canInteract, scene.isPlaced, let snapshot = scene.currentSnapshot,
              let metersPerUnit = scene.worldMetersPerSimulationUnit, metersPerUnit > 1e-8 else { return }
        let scene = scene
        let radius: (Int) -> Float = { scene.drawnRadius($0, in: snapshot) }
        let index: Int?
        switch pinch.kind {
        case .direct:
            index = snapshot.atomNear(scene.simulationPoint(fromWorld: pinch.position),
                                      reach: AtomPick.directReach / metersPerUnit, radius: radius)
        case .indirect:
            guard let ray = pinch.ray else { return }
            let origin = scene.simulationPoint(fromWorld: ray.origin)
            let direction = scene.simulationPoint(fromWorld: ray.origin + ray.direction) - origin
            let distance = simd_distance(ray.origin, scene.placement.position)
            index = snapshot.atomHit(rayOrigin: origin, direction: direction, radius: radius,
                                     tolerance: AtomPick.angularTolerance * distance / metersPerUnit)
        }
        guard let index else { return }
        let atom = scene.worldPoint(fromSimulation: snapshot.positions[index])
        interaction.link.begin(AtomGrab(tag: snapshot.tags[index], atomPosition: atom, pinch: pinch))
    }

    private static func vector(_ point: Point3D) -> SIMD3<Float> {
        SIMD3(Float(point.x), Float(point.y), Float(point.z))
    }

    private static func vector(_ vector: Vector3D) -> SIMD3<Float> {
        SIMD3(Float(vector.x), Float(vector.y), Float(vector.z))
    }
}
