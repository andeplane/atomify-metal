import Testing
import simd
@testable import AtomifyVision

struct BoxPlacementTests {
    private func close(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ tolerance: Float = 1e-4) -> Bool {
        simd_length(a - b) < tolerance
    }

    @Test func turningBothHandsRotatesAroundTheirMidpoint() {
        let box = BoxPlacement(position: [0, 1, -1])
        // Hands on either side of the box, then swung a quarter turn about
        // the vertical axis.
        let held = box.held(from: ([-0.3, 1, -1], [0.3, 1, -1]), to: ([0, 1, -0.7], [0, 1, -1.3]))
        #expect(close(held.position, [0, 1, -1]))
        #expect(abs(held.scale - 1) < 1e-5)
        // The box's +x side now faces -z, where the right hand went.
        #expect(close(held.orientation.act([1, 0, 0]), [0, 0, -1]))
        // A point held in the right hand stays in it.
        #expect(close(held.worldPoint(fromLocal: box.localPoint(fromWorld: [0.3, 1, -1])), [0, 1, -1.3]))
    }

    @Test func spreadingHandsScalesAndMovingThemCarriesTheBox() {
        let box = BoxPlacement(position: [0, 1, -1], scale: 2)
        let held = box.held(from: ([-0.2, 1, -1], [0.2, 1, -1]), to: ([-0.3, 1.5, -1], [0.5, 1.5, -1]))
        #expect(abs(held.scale - 4) < 1e-5)
        #expect(close(held.orientation.act([1, 0, 0]), [1, 0, 0]))
        // The midpoint moved from (0, 1) to (0.1, 1.5); the box center sat
        // on it, so it moves with it.
        #expect(close(held.position, [0.1, 1.5, -1]))
    }

    @Test func scaleIsClampedAndCloseHandsAreIgnored() {
        let box = BoxPlacement(position: .zero, scale: 1)
        let huge = box.held(from: ([0, 0, 0], [0.05, 0, 0]), to: ([0, 0, 0], [5, 0, 0]))
        #expect(huge.scale == BoxPlacement.scaleRange.upperBound)
        let same = box.held(from: ([0, 0, 0], [0.001, 0, 0]), to: ([0, 0, 0], [1, 1, 0]))
        #expect(same == box)
    }

    @Test func steppingInsideCentersTheBoxOnTheHeadAndEnlargesIt() {
        let box = BoxPlacement(position: [0, 1.3, -1], orientation: simd_quatf(angle: 0.5, axis: [0, 1, 0]), scale: 1)
        let inside = box.surrounding(head: [0.2, 1.6, 0.1], extent: [0.6, 0.3, 0.6])
        #expect(inside.position == SIMD3(0.2, 1.6, 0.1))
        #expect(abs(inside.scale * 0.6 - 4) < 1e-4)
        #expect(inside.orientation == box.orientation)
        // A box already larger than that keeps its size.
        let big = BoxPlacement(position: .zero, scale: 7.5).surrounding(head: .zero, extent: [0.6, 0.6, 0.6])
        #expect(big.scale == 7.5)
    }

    @Test func worldAndLocalPointsRoundTrip() {
        let box = BoxPlacement(position: [0.2, 1.1, -0.8], orientation: simd_quatf(angle: 0.7, axis: simd_normalize([1, 2, 3])),
                               scale: 1.7)
        let point = SIMD3<Float>(0.13, -0.4, 0.25)
        #expect(close(box.localPoint(fromWorld: box.worldPoint(fromLocal: point)), point))
        let viaMatrix = box.worldFromLocal * SIMD4(point, 1)
        #expect(close(SIMD3(viaMatrix.x, viaMatrix.y, viaMatrix.z), box.worldPoint(fromLocal: point)))
        #expect(close(box.dragged(from: [0, 0, 0], to: [0.1, 0, 0]).position, [0.3, 1.1, -0.8]))
    }
}

struct BoxGripTests {
    @Test func handsMovingTogetherCarryTheBoxWithoutTurningIt() {
        var grip = BoxGrip()
        let box = BoxPlacement(position: [0, 1, -1])
        _ = grip.update([.init(id: 1, position: [-0.2, 1, -1], ended: false),
                         .init(id: 2, position: [0.2, 1, -1], ended: false)], placement: box)
        let moved = grip.update([.init(id: 1, position: [-0.1, 1.2, -0.9], ended: false),
                                 .init(id: 2, position: [0.3, 1.2, -0.9], ended: false)], placement: box)
        #expect(moved.map { simd_length($0.position - [0.1, 1.2, -0.9]) < 1e-5 } == true)
        #expect(moved.map { abs($0.scale - 1) < 1e-5 } == true)
        #expect(moved.map { simd_length($0.orientation.act([1, 0, 0]) - [1, 0, 0]) < 1e-5 } == true)
    }

    @Test func oneHandAloneDoesNotMoveTheBox() {
        var grip = BoxGrip()
        var box = BoxPlacement(position: .zero)
        // A single pinch is for windows, not the box.
        #expect(grip.update([.init(id: 1, position: [-0.2, 0, 0], ended: false)], placement: box) == nil)
        #expect(grip.update([.init(id: 1, position: [0.3, 0, 0], ended: false)], placement: box) == nil)
        // The second hand joins: from here both hands hold it.
        box = grip.update([.init(id: 1, position: [0.3, 0, 0], ended: false),
                           .init(id: 2, position: [0.7, 0, 0], ended: false)], placement: box)!
        #expect(box == BoxPlacement(position: .zero))
        box = grip.update([.init(id: 1, position: [0.3, 0, 0], ended: false),
                           .init(id: 2, position: [1.1, 0, 0], ended: false)], placement: box)!
        #expect(abs(box.scale - 2) < 1e-5)
        // Lifting one hand stops it; moving the other does nothing.
        #expect(grip.update([.init(id: 1, position: [0.3, 0, 0], ended: true),
                             .init(id: 2, position: [1.1, 0, 0], ended: false)], placement: box) == nil)
        #expect(grip.update([.init(id: 2, position: [2, 0, 0], ended: false)], placement: box) == nil)
        #expect(grip.isHolding)
        #expect(grip.update([.init(id: 2, position: [2, 0, 0], ended: true)], placement: box) == nil)
        #expect(!grip.isHolding)
    }

    @Test func aPinchWhoseEndWasLostDoesNotTurnTheBoxLater() {
        var grip = BoxGrip()
        let box = BoxPlacement(position: .zero)
        // Two pinches, then the system stops reporting one without an end.
        _ = grip.update([.init(id: 1, position: [-0.2, 0, 0], ended: false),
                         .init(id: 2, position: [0.2, 0, 0], ended: false)], placement: box)
        #expect(grip.update([.init(id: 2, position: [0.2, 0, 0], ended: true)], placement: box) == nil)
        // A new single pinch must not pair up with the stale one.
        #expect(grip.update([.init(id: 3, position: [0.5, 0, 0], ended: false)], placement: box) == nil)
        #expect(grip.update([.init(id: 3, position: [0.9, 0.3, 0], ended: false)], placement: box) == nil)
    }

    @Test func rejectedPinchesDoNotHold() {
        var grip = BoxGrip()
        let box = BoxPlacement(position: .zero)
        #expect(grip.update([.init(id: 1, position: .zero, ended: false)], placement: box,
                            accepts: { _ in false }) == nil)
    }
}

struct FrameMeterTests {
    @Test func reportsGPUTimeFrameRateAndDroppedFrames() throws {
        let meter = FrameMeter(interval: 1, frameInterval: 0.01)
        var report: FrameMeter.Report?
        var time = 1.0
        for frame in 0..<120 {
            meter.recordGPU(start: time, end: time + (frame == 5 ? 0.02 : 0.004))
            // Two frames miss their slot.
            time += frame == 30 || frame == 60 ? 0.02 : 0.01
            if let next = meter.recordFrame(presentation: time, atoms: 42) { report = next }
        }
        let result = try #require(report)
        #expect(abs(result.medianGPU - 4) < 0.01)
        #expect(result.slowGPU < 5)
        #expect(result.dropped == 2)
        #expect(result.atoms == 42)
        #expect(result.framesPerSecond > 90 && result.framesPerSecond < 101)
        #expect(result.fits(budget: 11))
    }
}
