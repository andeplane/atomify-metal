import ARKit
import Foundation
import simd

/// The shape of both hands and forearms as overlapping spheres, pinch
/// positions and hand orientations, in world space (meters). ARKit's world
/// space is the lab's immersive scene space.
@MainActor
final class HandTracker {
    struct Hand {
        var chirality: HandAnchor.Chirality
        /// Spheres along every finger bone and across the palm, close
        /// enough to overlap, so the whole hand pushes and a cupped hand
        /// holds atoms instead of letting them slip between fingers.
        var colliders: [Collider]
        var thumbTip: SIMD3<Float>
        var indexTip: SIMD3<Float>
        /// The hand anchor's orientation in the world, for rolling the
        /// experiment with a twist of both wrists.
        var orientation: simd_quatf
        var updatedAt = ContinuousClock.now
        var pinchDistance: Float { simd_distance(thumbTip, indexTip) }
        var pinchPoint: SIMD3<Float> { (thumbTip + indexTip) / 2 }
    }

    struct Collider {
        var center: SIMD3<Float>
        var radius: Float
    }

    /// Sphere radii in meters, a little thicker than real fingers and palm.
    static let fingerRadius: Float = 0.014
    static let palmRadius: Float = 0.022
    static let forearmRadius: Float = 0.035
    /// Wrist to elbow; tracking only reports a point partway up the forearm.
    static let forearmLength: Float = 0.26

    private var trackedHands: [HandAnchor.Chirality: Hand] = [:]
    var hands: [HandAnchor.Chirality: Hand] {
        trackedHands.filter { ContinuousClock.now - $0.value.updatedAt < .milliseconds(200) }
    }
    /// A line for the window when tracking is unavailable.
    private(set) var problem: String?
    private var updates: Task<Void, Never>?

    /// The driver runs this provider in the head tracker's session, so the
    /// lab has a single ARKitSession.
    func prepareProvider() -> HandTrackingProvider? {
        guard updates == nil else { return nil }
        guard HandTrackingProvider.isSupported else {
            problem = "Hand tracking needs a Vision Pro; it is not available in the Simulator."
            return nil
        }
        let provider = HandTrackingProvider()
        updates = Task { [weak self] in
            for await update in provider.anchorUpdates {
                guard !Task.isCancelled else { break }
                if update.event == .removed { self?.trackedHands[update.anchor.chirality] = nil }
                else { self?.receive(update.anchor) }
            }
        }
        return provider
    }

    func stop() {
        updates?.cancel()
        updates = nil
        trackedHands = [:]
    }

    private func receive(_ anchor: HandAnchor) {
        guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
            trackedHands[anchor.chirality] = nil
            return
        }
        guard [.thumbTip, .indexFingerTip, .wrist].allSatisfy({ (name: HandSkeleton.JointName) in
            skeleton.joint(name).isTracked
        }) else {
            trackedHands[anchor.chirality] = nil
            return
        }
        func point(_ name: HandSkeleton.JointName) -> SIMD3<Float> {
            let m = anchor.originFromAnchorTransform * skeleton.joint(name).anchorFromJointTransform
            return SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        }
        let fingers: [[HandSkeleton.JointName]] = [
            [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
            [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
        ]
        var colliders: [Collider] = []
        for finger in fingers {
            if finger.allSatisfy({ skeleton.joint($0).isTracked }) {
                colliders += Self.chain(finger.map(point), radius: Self.fingerRadius)
            }
        }
        // The palm: from the wrist to each knuckle, filled in between.
        let wrist = point(.wrist)
        let knuckleNames: [HandSkeleton.JointName] = [.indexFingerKnuckle, .middleFingerKnuckle,
                                                     .ringFingerKnuckle, .littleFingerKnuckle]
        let knuckles = knuckleNames.filter { skeleton.joint($0).isTracked }.map(point)
        for knuckle in knuckles {
            colliders += Self.chain([wrist, knuckle], radius: Self.palmRadius).dropFirst()
        }
        colliders.append(Collider(center: wrist, radius: Self.palmRadius))
        // The forearm, from the wrist toward the elbow along the tracked
        // forearm joint, so arms push too.
        let forearmWrist = point(.forearmWrist), forearm = point(.forearmArm)
        let along = forearm - forearmWrist
        if skeleton.joint(.forearmWrist).isTracked, skeleton.joint(.forearmArm).isTracked,
           simd_length(along) > 0.01 {
            let elbow = forearmWrist + simd_normalize(along) * Self.forearmLength
            colliders += Self.chain([forearmWrist, elbow], radius: Self.forearmRadius)
        }
        guard colliders.allSatisfy({ $0.center.x.isFinite && $0.center.y.isFinite && $0.center.z.isFinite }) else {
            trackedHands[anchor.chirality] = nil
            return
        }
        let transform = anchor.originFromAnchorTransform
        let rotation = simd_float3x3(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
                                     SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
                                     SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let orientation = simd_normalize(simd_quatf(rotation))
        guard orientation.vector.x.isFinite, orientation.vector.y.isFinite,
              orientation.vector.z.isFinite, orientation.vector.w.isFinite else {
            trackedHands[anchor.chirality] = nil
            return
        }
        trackedHands[anchor.chirality] = Hand(chirality: anchor.chirality, colliders: colliders,
                                              thumbTip: point(.thumbTip), indexTip: point(.indexFingerTip),
                                              orientation: orientation)
    }

    /// Spheres along a chain of joints, spaced at most one radius apart so
    /// neighbours overlap and atoms can't squeeze between them.
    static func chain(_ joints: [SIMD3<Float>], radius: Float) -> [Collider] {
        guard radius.isFinite, radius > 0,
              joints.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              let first = joints.first else { return [] }
        var result = [Collider(center: first, radius: radius)]
        for (a, b) in zip(joints, joints.dropFirst()) {
            let length = simd_distance(a, b)
            guard length < 0.5 else { continue } // reject a corrupt joint jump
            let steps = min(64, max(1, Int((length / radius).rounded(.up))))
            for step in 1...steps {
                result.append(Collider(center: a + (b - a) * (Float(step) / Float(steps)), radius: radius))
            }
        }
        return result
    }
}
