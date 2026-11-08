import Foundation
import RealityKit

/// Optional feedback for acquiring an atom. This is an authored sound mapping,
/// not a recording or prediction of molecular sound. Visual feedback is primary.
@MainActor
final class InteractionAudio {
    /// Parent under MoleculeScene.simulation; cue positions use that local space.
    let emitter = Entity()

    private static var resourceTask: Task<AudioFileResource?, Never>?
    private var controller: AudioPlaybackController?
    private var isPreparing = false
    private var lastCue: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init() {
        emitter.name = "Optional interaction feedback"
        emitter.components.set(SpatialAudioComponent(
            gain: -12,
            reverbLevel: -18,
            directivity: .beam(focus: 0)
        ))
    }

    /// Load and decode the tiny mono asset once for the app; prepare one voice
    /// per scene. Missing or unreadable audio leaves the interaction silent.
    func prepare() async {
        guard controller == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        let task: Task<AudioFileResource?, Never>
        if let existing = Self.resourceTask {
            task = existing
        } else {
            task = Task { @MainActor in
                guard let url = Bundle.main.url(forResource: "interaction-cue", withExtension: "wav")
                    ?? Bundle.main.url(forResource: "interaction-cue", withExtension: "wav", subdirectory: "Resources")
                else { return nil }
                return try? await AudioFileResource(
                    contentsOf: url,
                    configuration: .init(loadingStrategy: .preload, shouldLoop: false)
                )
            }
            Self.resourceTask = task
        }
        guard let resource = await task.value, !Task.isCancelled else { return }
        controller = emitter.prepareAudio(resource)
    }

    /// Call only when a new grab succeeds, never from hover or held-hand updates.
    /// One 80 ms voice, at most once every 400 ms, avoids a stream of feedback.
    func cue(at position: SIMD3<Float>, enabled: Bool) {
        guard enabled, emitter.parent != nil, let controller,
              position.x.isFinite, position.y.isFinite, position.z.isFinite
        else { return }
        let now = clock.now
        if let lastCue, lastCue.duration(to: now) < .milliseconds(400) { return }
        self.lastCue = now
        emitter.position = position
        controller.stop()
        controller.seek(to: .zero)
        controller.play()
    }
}
