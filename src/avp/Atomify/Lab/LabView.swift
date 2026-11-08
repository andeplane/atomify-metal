import ARKit
import AtomifyVision
import RealityKit
import SwiftUI

/// The immersive lab: a live simulation about a metre in front of you.
/// One hand pinches an atom to pull it; two hands pinch to move, turn and
/// resize the experiment. Hands and forearms also push atoms.
struct LabView: View {
    @Environment(AppModel.self) private var model
    @State private var scene = MoleculeScene()
    @State private var driver = LabDriver()
    @State private var interaction = LabInteraction()
    /// Resets when the gesture ends or is cancelled, which `onEnded` alone
    /// does not report.
    @GestureState private var isGesturing = false

    var body: some View {
        RealityView { content in
            content.add(scene.root)
            content.add(scene.tipAnchor)
            scene.tipView.components.set(ViewAttachmentComponent(rootView: LabTipView(model: model)))
        }
        .task(id: model.run?.id) {
            await driver.run(model: model, scene: scene, interaction: interaction)
        }
        .gesture(
            SpatialEventGesture()
                .targetedToEntity(scene.root)
                .updating($isGesturing) { _, active, _ in active = true }
                .onChanged { value in route(value) }
                .onEnded { value in
                    route(value)
                    endGesture()
                }
        )
        .onChange(of: isGesturing) { _, active in if !active { endGesture() } }
        .onChange(of: model.recenterRequests) { _, _ in driver.recenter() }
        .onWorldRecenter { phase in if phase == .ended { driver.recenter() } }
        // Rolling the wrists while holding the experiment would otherwise
        // bring up the hand menu.
        .persistentSystemOverlays(interaction.isGripping ? .hidden : .automatic)
    }

    /// Turns the pinches in one gesture update into router input and acts
    /// on what it decides.
    private func route(_ value: EntityTargetValue<SpatialEventCollection>) {
        var samples: [PinchSample] = []
        for event in value.gestureValue {
            let kind: PinchSample.Kind
            switch event.kind {
            case .directPinch: kind = .direct
            case .indirectPinch: kind = .indirect
            default: continue
            }
            let id = event.id.hashValue
            let pose = event.inputDevicePose?.pose3D
            let position = value.convert(pose?.position ?? event.location3D, from: .local, to: .scene)
            let tracked = event.chirality.flatMap { chirality in
                driver.handOrientation(chirality == .left ? .left : .right)
            }
            let system = pose.map { value.convert($0.rotation, from: .local, to: .scene) }
            let orientation = interaction.orientation(for: id, tracked: tracked, system: system)
            var ray: PinchSample.Ray?
            if kind == .indirect, let selection = event.selectionRay {
                ray = PinchSample.Ray(origin: value.convert(selection.origin, from: .local, to: .scene),
                                      direction: value.convert(selection.direction, from: .local, to: .scene))
            }
            samples.append(PinchSample(id: id, kind: kind, position: position, orientation: orientation,
                                       ray: ray, ended: event.phase != .active))
        }
        interaction.keepOrientations(for: Set(samples.filter { !$0.ended }.map(\.id)))
        apply(interaction.router.update(samples, placement: scene.placement))
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

    private func endGesture() {
        interaction.reset()
        scene.isBoxBeingMoved = false
    }
}

/// The in-context tip under the experiment: one short line on glass.
struct LabTipView: View {
    var model: AppModel

    var body: some View {
        if let tip = model.tips.current, model.run != nil {
            Label(tip.text, systemImage: tip.systemImage)
                .font(.title)
                .padding(.horizontal, 36)
                .padding(.vertical, 22)
                .glassBackgroundEffect()
                .transition(.opacity)
                .id(tip.text)
        }
    }
}
