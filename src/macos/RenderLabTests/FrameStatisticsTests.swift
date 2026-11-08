import Testing
@testable import RenderLab

@Suite struct FrameStatisticsTests {
    static func sample(interval: Double?, cpu: Double = 1, jitter: Double? = nil, upload: Double? = nil,
                       gpu: Double = 2) -> FrameSample {
        FrameSample(intervalMs: interval, cpuMs: cpu, jitterMs: jitter, uploadMs: upload, gpuMs: gpu)
    }

    @Test func mean() {
        #expect(FrameStatistics.mean([]) == nil)
        #expect(FrameStatistics.mean([1, 2, 3]) == 2)
        #expect(FrameStatistics.mean([5]) == 5)
    }

    @Test func percentileNearestRank() {
        let values = (1...100).map { Double($0) }
        #expect(FrameStatistics.percentile(values, 95) == 95)
        #expect(FrameStatistics.percentile(values, 50) == 50)
        #expect(FrameStatistics.percentile(values, 100) == 100)
        #expect(FrameStatistics.percentile(values, 0) == 1)
        #expect(FrameStatistics.percentile(values, 150) == 100)
        #expect(FrameStatistics.percentile(values, -5) == 1)
    }

    @Test func percentileOfFewValues() {
        let reversed: [Double] = [40, 30, 20, 10]
        #expect(FrameStatistics.percentile(reversed, 95) == 40)
        #expect(FrameStatistics.percentile(reversed, 50) == 20)
        #expect(FrameStatistics.percentile([7], 95) == 7)
    }

    @Test func percentileSkipsNonFinite() {
        #expect(FrameStatistics.percentile([], 95) == nil)
        #expect(FrameStatistics.percentile([.nan, .infinity], 95) == nil)
        #expect(FrameStatistics.percentile([.nan, 3, .infinity, 1], 100) == 3)
    }

    @Test func liveAverages() {
        let samples = [
            Self.sample(interval: nil, cpu: 1, upload: 30),
            Self.sample(interval: 10, cpu: 2),
            Self.sample(interval: 20, cpu: 3, jitter: 4, upload: 10),
        ]
        let live = FrameStatistics.live(samples, seconds: 0.25, lastUploadMs: 10, gpuMs: 5,
                                        particlesDrawn: 100, bondsDrawn: 7)
        #expect(live.frameMs == 15)
        #expect(closeD(live.fps ?? 0, 1000.0 / 15.0))
        #expect(live.cpuMs == 2)
        #expect(live.jitterMs == 4)
        #expect(live.uploadMs == 20)
        #expect(live.lastUploadMs == 10)
        #expect(live.gpuMs == 5)
        #expect(live.particlesDrawn == 100)
        #expect(live.bondsDrawn == 7)
    }

    @Test func liveWithoutData() {
        let live = FrameStatistics.live([], seconds: 0, lastUploadMs: nil, gpuMs: 0, particlesDrawn: 0,
                                        bondsDrawn: 0)
        #expect(live.fps == nil)
        #expect(live.frameMs == nil)
        #expect(live.cpuMs == nil)
        #expect(live.uploadMs == nil)
        #expect(live.gpuMs == nil)
        #expect(live == LiveStats())
    }

    @Test func liveIgnoresZeroIntervals() {
        let live = FrameStatistics.live([Self.sample(interval: 0)], seconds: 1, lastUploadMs: nil, gpuMs: 1,
                                        particlesDrawn: 0, bondsDrawn: 0)
        #expect(live.frameMs == 0)
        #expect(live.fps == nil)
    }
}

@Suite struct BenchmarkTests {
    @Test func result() {
        var samples: [FrameSample] = []
        for i in 1...100 {
            let upload: Double? = i % 2 == 0 ? 4 : nil
            samples.append(FrameSample(intervalMs: Double(i), cpuMs: Double(i) / 10, jitterMs: nil,
                                       uploadMs: upload, gpuMs: i == 1 ? 0 : 3))
        }
        let result = BenchmarkResult.make(samples: samples, seconds: 5, particlesDrawn: 12, bondsDrawn: 3,
                                          label: "test")
        #expect(result != nil)
        guard let result else { return }
        #expect(result.frames == 100)
        #expect(closeD(result.meanFrameMs, 50.5))
        #expect(result.p95FrameMs == 95)
        #expect(result.maxFrameMs == 100)
        #expect(closeD(result.meanCPUMs, 5.05))
        #expect(closeD(result.p95CPUMs, 9.5))
        #expect(result.meanGPUMs == 3)
        #expect(result.p95GPUMs == 3)
        #expect(result.meanUploadMs == 4)
        #expect(result.fps == 20)
        #expect(result.particlesDrawn == 12)
        #expect(result.bondsDrawn == 3)
    }

    @Test func noIntervalsNoResult() {
        let samples = [FrameSample(intervalMs: nil, cpuMs: 1, jitterMs: nil, uploadMs: nil, gpuMs: 1)]
        #expect(BenchmarkResult.make(samples: samples, seconds: 1, particlesDrawn: 0, bondsDrawn: 0,
                                     label: "") == nil)
        #expect(BenchmarkResult.make(samples: [], seconds: 1, particlesDrawn: 0, bondsDrawn: 0, label: "") == nil)
    }

    @Test func gpuMissing() {
        let samples = [FrameSample(intervalMs: 16, cpuMs: 1, jitterMs: nil, uploadMs: nil, gpuMs: 0)]
        let result = BenchmarkResult.make(samples: samples, seconds: 0, particlesDrawn: 0, bondsDrawn: 0, label: "x")
        #expect(result?.meanGPUMs == nil)
        #expect(result?.meanUploadMs == nil)
        #expect(result?.fps == 0)
    }

    @Test func report() {
        let samples = [FrameSample(intervalMs: 8, cpuMs: 1, jitterMs: nil, uploadMs: nil, gpuMs: 2)]
        let result = BenchmarkResult.make(samples: samples, seconds: 1, particlesDrawn: 5, bondsDrawn: 0,
                                          label: "SiC, 1M")
        let report = result?.report ?? ""
        #expect(report.contains("RenderLab benchmark: SiC, 1M"))
        #expect(report.contains("frame mean 8.00 ms, p95 8.00 ms"))
        #expect(report.contains("gpu mean 2.00 ms"))
        #expect(report.contains("upload mean –"))
        #expect(report.contains("drawn 5 particles, 0 bonds"))
    }

    @Test func orbit() {
        #expect(BenchmarkOrbit.yaw(start: 1, elapsed: 0, duration: 10) == 1)
        #expect(closeF(BenchmarkOrbit.yaw(start: 1, elapsed: 5, duration: 10), 1 + Float.pi))
        #expect(closeF(BenchmarkOrbit.yaw(start: 1, elapsed: 10, duration: 10), 1 + 2 * Float.pi))
        #expect(closeF(BenchmarkOrbit.yaw(start: 1, elapsed: 50, duration: 10), 1 + 2 * Float.pi))
        #expect(BenchmarkOrbit.yaw(start: 1, elapsed: -3, duration: 10) == 1)
        #expect(BenchmarkOrbit.yaw(start: 1, elapsed: 3, duration: 0) == 1)
    }
}
