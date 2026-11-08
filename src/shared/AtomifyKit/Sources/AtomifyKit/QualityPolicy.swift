/// Picks the render quality and pixel density for a system size, so phones
/// stay smooth and cool: SSAO and outlines on small systems, plain impostors
/// on large ones, and fewer pixels per point on very large ones.
public struct QualityPolicy: Sendable, Equatable {
    /// What the user chose in the view options.
    public enum Mode: String, Sendable, CaseIterable, Identifiable {
        /// High quality for small systems, fast for large ones.
        case automatic
        /// Always the fast renderer.
        case fast
        /// Always the high quality renderer.
        case high

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .automatic: "Automatic"
            case .fast: "Fast"
            case .high: "High"
            }
        }
    }

    public var mode: Mode
    /// Atoms below which `automatic` draws at high quality.
    public var highQualityAtomLimit: Int
    /// Atoms from which the drawable is capped at `reducedContentScale`.
    public var reducedScaleAtomCount: Int
    /// Pixels per point for very large systems.
    public var reducedContentScale: Double

    public init(mode: Mode = .automatic, highQualityAtomLimit: Int = 300_000, reducedScaleAtomCount: Int = 300_000,
                reducedContentScale: Double = 2) {
        self.mode = mode
        self.highQualityAtomLimit = highQualityAtomLimit
        self.reducedScaleAtomCount = reducedScaleAtomCount
        self.reducedContentScale = reducedContentScale
    }

    /// The quality to draw `atomCount` atoms at. `constrained` (Low Power
    /// Mode or thermal pressure) makes `automatic` choose fast.
    public func quality(atomCount: Int, constrained: Bool = false) -> RenderQuality {
        switch mode {
        case .fast: .fast
        case .high: .high
        case .automatic: !constrained && atomCount < highQualityAtomLimit ? .high : .fast
        }
    }

    /// The most pixels per point to draw `atomCount` atoms at, or nil for
    /// the display's own. Applies in every mode.
    public func contentScaleLimit(atomCount: Int) -> Double? {
        atomCount >= reducedScaleAtomCount ? reducedContentScale : nil
    }
}
