/// How often `ParticleView` draws, to save battery on phones: fast while a
/// finger moves the camera, at the simulation's pace while the scene
/// changes, and not at all when nothing changes.
public struct FramePacing: Sendable, Equatable {
    /// Frames per second while the user interacts (ProMotion displays reach 120).
    public var interactive: Int
    /// Frames per second while the scene changes without interaction.
    public var changing: Int
    /// Upper limit in Low Power Mode or under thermal pressure.
    public var constrained: Int
    /// Seconds the faster rate lasts after the last touch or change, so
    /// momentum and the next snapshot do not drop a frame.
    public var linger: Double

    public init(interactive: Int = 120, changing: Int = 60, constrained: Int = 30, linger: Double = 0.5) {
        self.interactive = interactive
        self.changing = changing
        self.constrained = constrained
        self.linger = linger
    }

    /// Frames per second to draw at, or 0 to stop drawing until something
    /// changes. `sinceInteraction` and `sinceChange` are seconds since the
    /// last touch and the last scene, camera, settings or size change.
    public func framesPerSecond(sinceInteraction: Double, sinceChange: Double, constrained: Bool) -> Int {
        let rate: Int
        if sinceInteraction.isFinite, sinceInteraction >= 0, sinceInteraction < linger {
            rate = interactive
        } else if sinceChange.isFinite, sinceChange >= 0, sinceChange < linger {
            rate = changing
        } else {
            return 0
        }
        return max(1, constrained ? min(rate, self.constrained) : rate)
    }
}
