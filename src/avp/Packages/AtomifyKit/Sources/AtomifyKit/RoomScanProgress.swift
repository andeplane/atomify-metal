import Foundation

/// Readiness means useful observed geometry, never whole-room coverage.
public struct RoomScanProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case scanning, surfacesDetected, interrupted }
    public private(set) var phase: Phase = .scanning
    public private(set) var surfaceCount = 0
    public private(set) var areaSquareMeters = 0.0
    private var usableSince: TimeInterval?
    public init() {}

    public mutating func update(tracking: Bool, surfaces: Int, area: Double,
                                gridReady: Bool, at time: TimeInterval) {
        surfaceCount = max(0, surfaces)
        areaSquareMeters = area.isFinite ? max(0, area) : 0
        guard tracking else { usableSince = nil; phase = .interrupted; return }
        guard time.isFinite, gridReady, surfaceCount > 0, areaSquareMeters >= 1 else {
            usableSince = nil; phase = .scanning; return
        }
        if usableSince == nil { usableSince = time }
        phase = time - (usableSince ?? time) >= 0.75 ? .surfacesDetected : .scanning
    }

    public var allowsSimulation: Bool { phase == .surfacesDetected }
}
