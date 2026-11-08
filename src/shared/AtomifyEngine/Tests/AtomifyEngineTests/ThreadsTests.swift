import Testing
@testable import AtomifyEngine

struct ThreadsTests {
    @Test func defaultFollowsPerformanceCores() {
        #expect(SimulationThreads.recommended(performanceCores: 2, available: 6) == 2)
        #expect(SimulationThreads.recommended(performanceCores: 4, available: 10) == 4)
    }

    @Test func defaultIsCapped() {
        #expect(SimulationThreads.recommended(performanceCores: 12, available: 16) == SimulationThreads.defaultLimit)
        #expect(SimulationThreads.recommended(performanceCores: 12, available: 16, limit: 8) == 8)
        #expect(SimulationThreads.recommended(performanceCores: 4, available: 1) == 1)
    }

    @Test func unknownCoresRunSerial() {
        #expect(SimulationThreads.recommended(performanceCores: nil, available: 8) == 1)
        #expect(SimulationThreads.recommended(performanceCores: 0, available: 8) == 1)
    }

    @Test func buildReportsItsThreads() {
        #expect(SimulationThreads.available >= 1)
        #expect(SimulationThreads.default >= 1 && SimulationThreads.default <= SimulationThreads.available)
        #expect(SimulationThreads.sysctlInteger("hw.ncpu") ?? 1 >= 1)
        #expect(SimulationThreads.sysctlInteger("no.such.sysctl") == nil)
    }
}
