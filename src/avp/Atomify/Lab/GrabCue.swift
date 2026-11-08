import AVFoundation
import simd

/// Optional feedback for acquiring an atom: a short spatial sound at the
/// atom. An authored cue, not a recording or prediction of molecular sound;
/// visual feedback is primary. Missing or unplayable audio stays silent.
@MainActor
final class GrabCue {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let environment = AVAudioEnvironmentNode()
    private var buffer: AVAudioPCMBuffer?
    private var lastCue: ContinuousClock.Instant?

    init() {
        guard let url = Bundle.main.url(forResource: "interaction-cue", withExtension: "wav")
                ?? Bundle.main.url(forResource: "interaction-cue", withExtension: "wav", subdirectory: "Resources"),
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return }
        self.buffer = buffer
        engine.attach(player)
        engine.attach(environment)
        // Spatialized sources must be mono.
        engine.connect(player, to: environment, format: buffer.format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)
        player.renderingAlgorithm = .HRTFHQ
        player.volume = 0.25   // about -12 dB
        player.reverbBlend = 0.1
    }

    /// Call only when a new grab succeeds, never from hover or held-hand
    /// updates. At most once every 400 ms. `listener` is the head pose
    /// (origin from device); without it the sound plays straight ahead.
    func play(at position: SIMD3<Float>, listener: simd_float4x4?) {
        guard let buffer, position.x.isFinite, position.y.isFinite, position.z.isFinite else { return }
        let now = ContinuousClock.now
        if let lastCue, now - lastCue < .milliseconds(400) { return }
        lastCue = now
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setCategory(.ambient)
            guard (try? engine.start()) != nil else { return }
        }
        // The listener sits at the origin looking down -z: place the source
        // where the atom is relative to the head.
        var relative = SIMD3<Float>(0, 0, -0.5)
        if let listener {
            let local = listener.inverse * SIMD4(position, 1)
            relative = SIMD3(local.x, local.y, local.z)
        }
        player.position = AVAudio3DPoint(x: relative.x, y: relative.y, z: relative.z)
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}
