import Foundation

/// Measures how well rendering keeps up on the device: GPU time per frame
/// and frames that missed their display slot. Fed from the render thread
/// and Metal's completion handlers; reports once per interval.
public final class FrameMeter: @unchecked Sendable {
    public struct Report: Sendable, Equatable {
        /// Median and 95th percentile GPU time per frame, in milliseconds.
        public var medianGPU: Double
        public var slowGPU: Double
        public var framesPerSecond: Double
        /// Frames presented later than one display interval after the one before.
        public var dropped: Int
        public var atoms: Int

        /// Whether the GPU stays inside the display interval with room to spare.
        public func fits(budget: Double) -> Bool { slowGPU <= budget }

        public var summary: String {
            String(format: "GPU %.1f ms (slowest %.1f) · %.0f fps · %d dropped", medianGPU, slowGPU,
                   framesPerSecond, dropped)
        }
    }

    private let lock = NSLock()
    private let interval: TimeInterval
    private let frameInterval: TimeInterval
    private var gpu: [Double] = []
    private var presentations = 0
    private var dropped = 0
    private var lastPresentation: TimeInterval?
    private var windowStart: TimeInterval?
    private var atoms = 0

    /// `frameInterval` is the display's, 1/90 s on Vision Pro.
    public init(interval: TimeInterval = 1, frameInterval: TimeInterval = 1.0 / 90) {
        self.interval = interval
        self.frameInterval = frameInterval
    }

    /// One frame's GPU time, start and end in seconds.
    public func recordGPU(start: TimeInterval, end: TimeInterval) {
        guard end > start, start > 0 else { return }
        lock.withLock { gpu.append((end - start) * 1000) }
    }

    /// A frame handed to the compositor for display at `presentation`
    /// seconds. Returns a report when an interval has passed.
    public func recordFrame(presentation: TimeInterval, atoms: Int) -> Report? {
        lock.withLock {
            self.atoms = atoms
            if let last = lastPresentation, presentation - last > frameInterval * 1.5 {
                dropped += Int(((presentation - last) / frameInterval).rounded()) - 1
            }
            lastPresentation = presentation
            presentations += 1
            guard let start = windowStart else {
                windowStart = presentation
                return nil
            }
            let elapsed = presentation - start
            guard elapsed >= interval else { return nil }
            let sorted = gpu.sorted()
            func percentile(_ p: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
            }
            let report = Report(medianGPU: percentile(0.5), slowGPU: percentile(0.95),
                                framesPerSecond: Double(presentations - 1) / elapsed, dropped: dropped,
                                atoms: self.atoms)
            gpu.removeAll(keepingCapacity: true)
            presentations = 1
            dropped = 0
            windowStart = presentation
            return report
        }
    }
}
