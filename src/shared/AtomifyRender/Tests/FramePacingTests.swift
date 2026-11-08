import XCTest
@testable import AtomifyRender

final class FramePacingTests: XCTestCase {
    private let pacing = FramePacing()

    func testInteractionDrawsFastest() {
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 0, sinceChange: 0, constrained: false), 120)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 0.4, sinceChange: 10, constrained: false), 120)
    }

    func testChangesDrawAtTheChangingRate() {
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 5, sinceChange: 0.1, constrained: false), 60)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: .infinity, sinceChange: 0, constrained: false), 60)
    }

    func testIdleStops() {
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 5, sinceChange: 5, constrained: false), 0)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: .infinity, sinceChange: .infinity, constrained: false), 0)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: .nan, sinceChange: .nan, constrained: false), 0)
        // A clock that went backwards is not a recent event.
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: -1, sinceChange: -1, constrained: false), 0)
    }

    func testConstrainedCapsTheRate() {
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 0, sinceChange: 0, constrained: true), 30)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 5, sinceChange: 0, constrained: true), 30)
        XCTAssertEqual(pacing.framesPerSecond(sinceInteraction: 5, sinceChange: 5, constrained: true), 0)
        let slow = FramePacing(interactive: 24, changing: 12, constrained: 30)
        XCTAssertEqual(slow.framesPerSecond(sinceInteraction: 0, sinceChange: 0, constrained: true), 24)
    }

    func testRateIsAtLeastOneWhenDrawing() {
        let zero = FramePacing(interactive: 0, changing: 0, constrained: 0)
        XCTAssertEqual(zero.framesPerSecond(sinceInteraction: 0, sinceChange: 0, constrained: false), 1)
    }
}
