import AtomifyEngine
import AtomifyVision
import Foundation
import Testing

struct SafetyTests {
    private func validSnapshot() -> SimulationSnapshot {
        SimulationSnapshot(typeCount: 1, boxLow: [-5, -5, -5], boxHigh: [5, 5, 5],
                           temperature: 1, kineticEnergy: 1, tags: [1, 2], types: [1, 1],
                           positions: [[0, 0, 0], [1, 0, 0]], bonds: [[0, 1]])
    }

    @Test func invalidSnapshotsNeverReachARenderer() {
        let good = validSnapshot()
        #expect(good.validationIssue == nil)
        var bad = good; bad.positions[0].x = .nan
        #expect(bad.validationIssue != nil)
        bad = good; bad.temperature = .infinity
        #expect(bad.validationIssue != nil)
        bad = good; bad.potentialEnergy = .nan
        #expect(bad.validationIssue != nil)
        bad = good; bad.boxHigh.x = bad.boxLow.x
        #expect(bad.validationIssue != nil)
        bad = good; bad.boxHigh.x = 3e38; bad.boxLow.x = -3e38
        #expect(bad.validationIssue != nil)
        bad = good; bad.types = [1]
        #expect(bad.validationIssue != nil)
        bad = good; bad.tags = [2, 1]
        #expect(bad.validationIssue != nil)
        bad = good; bad.bonds = [[0, 2]]
        #expect(bad.validationIssue != nil)
    }

    @Test func watchdogDistinguishesStartupPauseAndAHang() {
        var watch = SimulationWatchdog()
        #expect(watch.issue(progressAge: 30, hasSnapshot: false, paused: false) == nil)
        #expect(watch.issue(progressAge: 61, hasSnapshot: false, paused: false) != nil)
        watch = SimulationWatchdog()
        #expect(watch.issue(progressAge: 1, hasSnapshot: true, paused: false) == nil)
        #expect(watch.issue(progressAge: 21, hasSnapshot: true, paused: false) != nil)
        #expect(watch.issue(progressAge: 1000, hasSnapshot: true, paused: true) == nil)
    }

    @Test func reacquiredClosedHandCannotGrabAndNoisyPinchDoesNotLatch() {
        var intent = PinchIntent()
        #expect(intent.update(distance: 0.01, at: 0) == .idle)
        #expect(intent.update(distance: 0.01, at: 1) == .idle)
        #expect(intent.update(distance: 0.04, at: 2) == .idle)
        #expect(intent.update(distance: 0.01, at: 3) == .idle)
        #expect(intent.update(distance: 0.03, at: 3.04) == .idle)
        #expect(intent.update(distance: 0.01, at: 4) == .idle)
        #expect(intent.update(distance: 0.01, at: 4.09) == .began)
        #expect(intent.update(distance: 0.025, at: 4.10) == .held)
        #expect(intent.update(distance: 0.04, at: 4.11) == .released)
        _ = intent.reset()
        #expect(intent.update(distance: 0.01, at: 6) == .idle)
        #expect(intent.update(distance: .nan, at: 7) == .idle)
    }

    @Test func elapsedTimeCannotInventScannedSurfaces() {
        var scan = RoomScanProgress()
        scan.update(tracking: true, surfaces: 0, area: 0, gridReady: false, at: 100)
        #expect(!scan.allowsSimulation)
        scan.update(tracking: true, surfaces: 10, area: 10, gridReady: false, at: 200)
        #expect(!scan.allowsSimulation)
        scan.update(tracking: true, surfaces: 10, area: .nan, gridReady: true, at: 300)
        #expect(!scan.allowsSimulation)
    }

    @Test func trackingLossOrRemovedGeometryWithdrawsReadiness() {
        var scan = RoomScanProgress()
        scan.update(tracking: true, surfaces: 3, area: 5, gridReady: true, at: 0)
        #expect(!scan.allowsSimulation)
        scan.update(tracking: true, surfaces: 3, area: 5, gridReady: true, at: 1)
        #expect(scan.allowsSimulation)
        scan.update(tracking: false, surfaces: 3, area: 5, gridReady: true, at: 2)
        #expect(scan.phase == .interrupted)
        #expect(!scan.allowsSimulation)
        scan.update(tracking: true, surfaces: 0, area: 0, gridReady: false, at: 3)
        #expect(!scan.allowsSimulation)
    }

    @Test func releaseCollectionIsGuidedAndExcludesStressTests() throws {
        let catalog = try DemoCatalog.load(from: DemoCatalogTests.demosDirectory)
        let featured = catalog.releaseDemos
        #expect(featured.map(\.id) == ["water", "zeolite_zsm5", "surface-diffusion", "sic_nanoparticle", "cnt_deformation"])
        #expect(!featured.contains { $0.id == "nanoporous_silica" || $0.id == "large-lj-liquid" })
        let legacy = try JSONDecoder().decode(Demo.self, from: Data("""
            {"id":"old","title":"Old","summary":"Old","category":"Old","folder":"old","inputScript":"in.old"}
            """.utf8))
        #expect(legacy.releaseOrder == nil)
    }
}
