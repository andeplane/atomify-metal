import AtomifyKit
import Observation
import simd

/// What pinches are doing, shared by the lab's gesture (which starts, moves
/// and ends grabs and grips) and the frame loop (which refreshes the held
/// atom in the engine every frame, and releases it).
@MainActor @Observable
final class LabInteraction {
    /// Two hands hold the experiment. Observed: system overlays are
    /// deferred while it is true, so wrist turns do not open the hand menu.
    private(set) var isGripping = false
    @ObservationIgnored var router = PinchRouter()
    @ObservationIgnored var link = GrabLink()
    /// Where each pinch's orientation comes from, fixed when the pinch
    /// starts, so a brief tracking gap cannot make the experiment jump.
    @ObservationIgnored private var orientations: [Int: (tracked: Bool, last: simd_quatf)] = [:]

    /// Any pinch is down on the experiment.
    var isPinching: Bool { router.mode != .idle }

    func setGripping(_ gripping: Bool) {
        if isGripping != gripping { isGripping = gripping }
    }

    /// Ends everything: the next frame releases a held atom.
    func reset() {
        router.reset()
        link.end()
        orientations = [:]
        setGripping(false)
    }

    /// The orientation to use for pinch `id`: the tracked hand's when it was
    /// available as the pinch started, otherwise the system's input pose;
    /// identity when neither is known.
    func orientation(for id: Int, tracked: simd_quatf?, system: simd_quatf?) -> simd_quatf {
        if let entry = orientations[id] {
            let fresh = entry.tracked ? tracked : system
            guard let fresh, fresh.vector.x.isFinite, fresh.vector.w.isFinite else { return entry.last }
            orientations[id] = (entry.tracked, fresh)
            return fresh
        }
        let usesTracked = tracked != nil
        let value = tracked ?? system ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        orientations[id] = (usesTracked, value)
        return value
    }

    /// Forgets pinches that are no longer reported.
    func keepOrientations(for ids: Set<Int>) {
        orientations = orientations.filter { ids.contains($0.key) }
    }
}
