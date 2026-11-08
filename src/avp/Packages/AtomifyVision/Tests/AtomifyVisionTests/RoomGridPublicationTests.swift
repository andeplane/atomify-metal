import AtomifyVision
import Foundation
import Testing

@Suite struct RoomGridPublicationTests {
    typealias Policy = RoomGridPublicationPolicy
    let policy = Policy()
    let epoch = UUID(), id = UUID()
    func pose(x: Float = 0, degrees: Double = 0) -> Policy.Pose {
        let half = degrees * .pi / 360
        return .init(position: [x, 0, 0], rotation: [0, Float(sin(half)), 0, Float(cos(half))])
    }
    var candidate: Policy.Candidate {
        .init(epoch: epoch, sequence: 10, capturedAt: 100, sourceRevisions: [id: 1], anchors: [id: pose()])
    }
    func rejection(_ pose: Policy.Pose? = nil, revision: UInt64 = 1,
                   now: Double = 101, last: UInt64? = nil) -> Policy.Rejection? {
        policy.publicationRejection(for: candidate, currentEpoch: epoch, lastPublishedSequence: last,
                                     currentRevisions: [id: revision], currentAnchors: [id: pose ?? self.pose()], now: now)
    }
    @Test func continuousMeshUpdatesDoNotStarveACompletedGrid() {
        for revision in UInt64(2)...100 { #expect(rejection(revision: revision) == nil) }
    }
    @Test func unchangedActiveGeometryDoesNotExpire() {
        #expect(policy.activeGridRejection(for: candidate, currentEpoch: epoch,
            currentRevisions: [id: 1], currentAnchors: [id: pose()], now: 10_000) == nil)
    }
    @Test func changedActiveGeometryExpiresWhenRefreshDoesNotArrive() {
        #expect(policy.activeGridRejection(for: candidate, currentEpoch: epoch,
            currentRevisions: [id: 2], currentAnchors: [id: pose()], now: 106) == nil)
        #expect(policy.activeGridRejection(for: candidate, currentEpoch: epoch,
            currentRevisions: [id: 2], currentAnchors: [id: pose()], now: 106.001) == .sourceTooOld)
    }
    @Test func additionalAnchorsDoNotInvalidateExistingGeometry() {
        let added = UUID()
        #expect(policy.publicationRejection(for: candidate, currentEpoch: epoch, lastPublishedSequence: nil,
            currentRevisions: [id: 2, added: 1], currentAnchors: [id: pose(), added: pose(x: 2)], now: 101) == nil)
    }
    @Test func removalWithdrawsPendingAndActiveGeometry() {
        #expect(policy.publicationRejection(for: candidate, currentEpoch: epoch, lastPublishedSequence: nil,
            currentRevisions: [:], currentAnchors: [:], now: 101) == .anchorRemoved(id))
        #expect(policy.activeGridRejection(for: candidate, currentEpoch: epoch,
            currentRevisions: [:], currentAnchors: [:], now: 101) == .anchorRemoved(id))
    }
    @Test func movedAndRotatedAnchorsAreRejectedAtPublicationAndWhileActive() {
        for (current, expected): (Policy.Pose, Policy.Rejection?) in [
            (pose(x: 0.03), nil), (pose(x: 0.031), .anchorMoved(id)),
            (pose(degrees: 5), nil), (pose(degrees: 5.1), .anchorMoved(id))] {
            #expect(rejection(current) == expected)
            #expect(policy.activeGridRejection(for: candidate, currentEpoch: epoch,
                currentRevisions: [id: 2], currentAnchors: [id: current], now: 101) == expected)
        }
    }
    @Test func equivalentQuaternionSignsAreAccepted() {
        var current = pose(); current.rotation = -current.rotation
        #expect(rejection(current) == nil)
    }
    @Test func supersededAndOldEpochCompletionsAreRejected() {
        #expect(rejection(last: 10) == .superseded)
        #expect(rejection(last: 11) == .superseded)
        #expect(policy.publicationRejection(for: candidate, currentEpoch: UUID(), lastPublishedSequence: nil,
            currentRevisions: [id: 1], currentAnchors: [id: pose()], now: 101) == .epochChanged)
    }
    @Test func clockAndAgeBoundariesAreValidated() {
        #expect(rejection(now: 106) == nil)
        #expect(rejection(now: 106.001) == .sourceTooOld)
        #expect(rejection(now: 99) == .invalidTime)
        #expect(rejection(now: .nan) == .invalidTime)
    }
    @Test func invalidPosesAndMalformedSourceAreRejected() {
        #expect(rejection(.init(position: .zero, rotation: .zero)) == .invalidPose(id))
        #expect(rejection(pose(x: .nan)) == .invalidPose(id))
        var invalid = candidate; invalid.anchors = [:]
        #expect(policy.publicationRejection(for: invalid, currentEpoch: epoch, lastPublishedSequence: nil,
            currentRevisions: [id: 1], currentAnchors: [id: pose()], now: 101) == .invalidSource)
    }
}
