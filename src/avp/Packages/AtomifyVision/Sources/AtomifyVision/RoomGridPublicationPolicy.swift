import Foundation

/// Geometry keeps improving while a distance grid builds. Requiring identical
/// revision numbers can starve publication forever; validate its frame, age and
/// represented anchors instead. Revisions still request the next rebuild.
public struct RoomGridPublicationPolicy: Sendable {
    public struct Pose: Equatable, Sendable {
        public var position: SIMD3<Float>
        /// Quaternion x, y, z, w.
        public var rotation: SIMD4<Float>
        public init(position: SIMD3<Float>, rotation: SIMD4<Float>) {
            self.position = position; self.rotation = rotation
        }
    }
    public struct Candidate: Sendable {
        public var epoch: UUID
        public var sequence: UInt64
        public var capturedAt: Double
        public var sourceRevisions: [UUID: UInt64]
        public var anchors: [UUID: Pose]
        public init(epoch: UUID, sequence: UInt64, capturedAt: Double,
                    sourceRevisions: [UUID: UInt64], anchors: [UUID: Pose]) {
            self.epoch = epoch; self.sequence = sequence; self.capturedAt = capturedAt
            self.sourceRevisions = sourceRevisions; self.anchors = anchors
        }
    }
    public enum Rejection: Equatable, Sendable {
        case epochChanged, superseded, invalidTime, invalidSource, sourceTooOld
        case anchorRemoved(UUID), invalidPose(UUID), anchorMoved(UUID)
    }
    public var maximumSourceAge: Double { 6 }

    public init() {}

    public func publicationRejection(for candidate: Candidate, currentEpoch: UUID,
                                     lastPublishedSequence: UInt64?, currentRevisions: [UUID: UInt64],
                                     currentAnchors: [UUID: Pose], now: Double) -> Rejection? {
        if let reason = commonRejection(for: candidate, currentEpoch: currentEpoch,
                                        currentRevisions: currentRevisions, currentAnchors: currentAnchors, now: now) {
            return reason
        }
        if let lastPublishedSequence, candidate.sequence <= lastPublishedSequence { return .superseded }
        return now - candidate.capturedAt > maximumSourceAge ? .sourceTooOld : nil
    }

    public func activeGridRejection(for candidate: Candidate, currentEpoch: UUID,
                                    currentRevisions: [UUID: UInt64], currentAnchors: [UUID: Pose],
                                    now: Double) -> Rejection? {
        if let reason = commonRejection(for: candidate, currentEpoch: currentEpoch,
                                        currentRevisions: currentRevisions, currentAnchors: currentAnchors, now: now) {
            return reason
        }
        let changed = candidate.sourceRevisions.contains { currentRevisions[$0.key] != $0.value }
        return changed && now - candidate.capturedAt > maximumSourceAge ? .sourceTooOld : nil
    }

    private func commonRejection(for candidate: Candidate, currentEpoch: UUID,
                                  currentRevisions: [UUID: UInt64], currentAnchors: [UUID: Pose],
                                  now: Double) -> Rejection? {
        guard candidate.epoch == currentEpoch else { return .epochChanged }
        guard now.isFinite, candidate.capturedAt.isFinite, now >= candidate.capturedAt else { return .invalidTime }
        guard !candidate.sourceRevisions.isEmpty, candidate.anchors.count == candidate.sourceRevisions.count,
              candidate.sourceRevisions.keys.allSatisfy({ candidate.anchors[$0] != nil }) else { return .invalidSource }
        for (id, captured) in candidate.anchors {
            guard currentRevisions[id] != nil, let current = currentAnchors[id] else { return .anchorRemoved(id) }
            var translationSquared = 0.0
            for k in 0..<3 {
                let a = Double(captured.position[k]), b = Double(current.position[k])
                guard a.isFinite, b.isFinite else { return .invalidPose(id) }
                translationSquared += (b - a) * (b - a)
            }
            var aNorm = 0.0, bNorm = 0.0, dot = 0.0
            for k in 0..<4 {
                let a = Double(captured.rotation[k]), b = Double(current.rotation[k])
                guard a.isFinite, b.isFinite else { return .invalidPose(id) }
                aNorm += a * a; bNorm += b * b; dot += a * b
            }
            guard aNorm > 1e-12, bNorm > 1e-12 else { return .invalidPose(id) }
            // q and -q describe the same orientation.
            let angle = 2 * acos(min(1, max(0, abs(dot) / sqrt(aNorm * bNorm))))
            // Half a grid cell, with Float rounding tolerance, or five degrees.
            guard translationSquared <= 0.030001 * 0.030001, angle <= 5 * .pi / 180 + 1e-6 else {
                return .anchorMoved(id)
            }
        }
        return nil
    }
}
