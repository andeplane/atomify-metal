import Foundation

/// Timings of one drawn frame, in milliseconds.
struct FrameSample: Sendable, Equatable {
    /// Since the previous frame started; nil for the first frame.
    var intervalMs: Double?
    /// CPU time spent in the frame: jitter, upload and encoding (not the
    /// wait for a drawable).
    var cpuMs: Double
    /// Particle positions jittered this frame, or nil.
    var jitterMs: Double?
    /// Scene uploaded this frame (`ParticleRenderer.update`), or nil.
    var uploadMs: Double?
    /// GPU time of the latest completed frame, from `RenderStats`.
    var gpuMs: Double
}

/// What the overlay shows, averaged over a short window.
struct LiveStats: Sendable, Equatable {
    var fps: Double?
    var frameMs: Double?
    var cpuMs: Double?
    var jitterMs: Double?
    /// Mean over the frames in the window that uploaded.
    var uploadMs: Double?
    /// Latest upload, however long ago.
    var lastUploadMs: Double?
    var gpuMs: Double?
    var particlesDrawn = 0
    var bondsDrawn = 0
}

enum FrameStatistics {
    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank percentile (`p` in 0...100) of finite values.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((min(max(p, 0), 100) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    /// Averages of `samples` that were collected over `seconds`.
    static func live(_ samples: [FrameSample], seconds: Double, lastUploadMs: Double?, gpuMs: Double,
                     particlesDrawn: Int, bondsDrawn: Int) -> LiveStats {
        let intervals = samples.compactMap(\.intervalMs)
        let frameMs = mean(intervals)
        return LiveStats(fps: frameMs.flatMap { $0 > 0 ? 1000 / $0 : nil },
                         frameMs: frameMs,
                         cpuMs: mean(samples.map(\.cpuMs)),
                         jitterMs: mean(samples.compactMap(\.jitterMs)),
                         uploadMs: mean(samples.compactMap(\.uploadMs)),
                         lastUploadMs: lastUploadMs,
                         gpuMs: gpuMs > 0 ? gpuMs : nil,
                         particlesDrawn: particlesDrawn,
                         bondsDrawn: bondsDrawn)
    }
}

/// The outcome of an orbit benchmark.
struct BenchmarkResult: Sendable, Equatable {
    var frames: Int
    var seconds: Double
    var meanFrameMs: Double
    var p95FrameMs: Double
    var maxFrameMs: Double
    var meanCPUMs: Double
    var p95CPUMs: Double
    var meanGPUMs: Double?
    var p95GPUMs: Double?
    var meanUploadMs: Double?
    var particlesDrawn: Int
    var bondsDrawn: Int
    /// What was measured, e.g. "SiC 1M, bonds, high, MSAA 4×".
    var label: String

    var fps: Double { seconds > 0 ? Double(frames) / seconds : 0 }

    /// nil when no frame interval was recorded.
    static func make(samples: [FrameSample], seconds: Double, particlesDrawn: Int, bondsDrawn: Int,
                     label: String) -> BenchmarkResult? {
        let intervals = samples.compactMap(\.intervalMs)
        guard let meanFrame = FrameStatistics.mean(intervals),
              let p95Frame = FrameStatistics.percentile(intervals, 95) else { return nil }
        let cpu = samples.map(\.cpuMs)
        let gpu = samples.map(\.gpuMs).filter { $0 > 0 }
        return BenchmarkResult(frames: intervals.count, seconds: seconds,
                               meanFrameMs: meanFrame, p95FrameMs: p95Frame, maxFrameMs: intervals.max() ?? meanFrame,
                               meanCPUMs: FrameStatistics.mean(cpu) ?? 0,
                               p95CPUMs: FrameStatistics.percentile(cpu, 95) ?? 0,
                               meanGPUMs: FrameStatistics.mean(gpu), p95GPUMs: FrameStatistics.percentile(gpu, 95),
                               meanUploadMs: FrameStatistics.mean(samples.compactMap(\.uploadMs)),
                               particlesDrawn: particlesDrawn, bondsDrawn: bondsDrawn, label: label)
    }

    /// Plain text for the clipboard.
    var report: String {
        func ms(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "–" }
        return [
            "RenderLab benchmark: \(label)",
            "frames \(frames) in \(String(format: "%.1f", seconds)) s (\(String(format: "%.1f", fps)) fps)",
            "frame mean \(ms(meanFrameMs)), p95 \(ms(p95FrameMs)), max \(ms(maxFrameMs))",
            "cpu mean \(ms(meanCPUMs)), p95 \(ms(p95CPUMs))",
            "gpu mean \(ms(meanGPUMs)), p95 \(ms(p95GPUMs))",
            "upload mean \(ms(meanUploadMs))",
            "drawn \(particlesDrawn) particles, \(bondsDrawn) bonds",
        ].joined(separator: "\n")
    }
}

/// The benchmark's camera path: one full turn around the target.
enum BenchmarkOrbit {
    static func yaw(start: Float, elapsed: Double, duration: Double) -> Float {
        guard duration > 0 else { return start }
        let t = min(max(elapsed / duration, 0), 1)
        return start + 2 * .pi * Float(t)
    }
}
