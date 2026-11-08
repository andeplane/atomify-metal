import Foundation

/// A tracked hand must open before grabbing, including after tracking loss.
/// A short dwell rejects noisy fingertip estimates without delaying release.
public struct PinchIntent: Sendable {
    public enum Phase: Equatable, Sendable { case idle, began, held, released }
    private var armed = false
    private var closedSince: TimeInterval?
    private var holding = false
    public init() {}

    public mutating func update(distance: Float, at time: TimeInterval) -> Phase {
        guard distance.isFinite, distance >= 0, time.isFinite else { return reset() }
        if distance >= 0.035 {
            let wasHolding = holding
            holding = false
            closedSince = nil
            armed = true
            return wasHolding ? .released : .idle
        }
        if holding { return .held }
        guard armed, distance < 0.018 else { closedSince = nil; return .idle }
        if closedSince == nil { closedSince = time }
        guard time - (closedSince ?? time) >= 0.08 else { return .idle }
        holding = true
        return .began
    }

    @discardableResult public mutating func reset() -> Phase {
        let wasHolding = holding
        self = PinchIntent()
        return wasHolding ? .released : .idle
    }
}
