import Foundation
import Testing
@testable import AtomifyKit

/// Headless check that a running simulation reaches the view at display
/// rate: counts the scenes the session builds per second of a real run.
@MainActor @Suite(.serialized) struct PlaybackRateTests {
    @Test(.timeLimit(.minutes(1))) func scenesArriveAtDisplayRate() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "lj"))
        let session = SimulationSession()
        session.continueAfterScript = true
        session.load(example, from: catalog)
        try await waitUntil("first scene") { session.scene != nil }
        try await Task.sleep(for: .milliseconds(300))

        let start = ContinuousClock.now
        let before = session.scenesShown
        try await Task.sleep(for: .seconds(3))
        let seconds = Double((ContinuousClock.now - start).components.attoseconds) * 1e-18
            + Double((ContinuousClock.now - start).components.seconds)
        let rate = Double(session.scenesShown - before) / seconds
        print("PLAYBACK scenes per second: \(rate) (ticker: \(session.usesDisplayTicker))")
        session.stop()
        // The engine publishes at most 60 snapshots a second.
        #expect(rate > 45)
    }
}
