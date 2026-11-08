import AtomifyEngine
import simd

/// What the inspector shows about one atom.
public struct AtomInfo: Sendable, Equatable {
    /// Index in the frame the info was read from.
    public var index: Int
    public var tag: Int64
    public var type: Int
    /// Style name for the type ("O", "Type 2", ...).
    public var typeName: String?
    public var position: SIMD3<Float>
    public var radius: Float?
    /// The per-atom quantity the frame carries, and its value for this atom.
    public var quantity: String?
    public var value: Float?

    public init(index: Int, tag: Int64, type: Int, typeName: String? = nil, position: SIMD3<Float>,
                radius: Float? = nil, quantity: String? = nil, value: Float? = nil) {
        self.index = index
        self.tag = tag
        self.type = type
        self.typeName = typeName
        self.position = position
        self.radius = radius
        self.quantity = quantity
        self.value = value
    }
}

/// Maps a particle index from the renderer's picking back to an atom.
///
/// `SceneBuilder` draws one particle per atom in frame order, so the picked
/// index is an index into the frame that built the scene on screen. Keep the
/// selection by tag (`AtomInfo.tag`) and look it up again in later frames,
/// because indices change when atoms are added or removed.
public enum AtomPicking {
    /// The atom drawn as particle `index` of a scene built from `frame`, or
    /// nil when the index is out of range (nothing hit, or a stale frame).
    public static func atom(atParticle index: Int?, in frame: AtomFrame,
                            styles: AtomStyleTable? = nil) -> AtomInfo? {
        guard let index, index >= 0, index < frame.count, index < frame.tags.count,
              index < frame.types.count else { return nil }
        let type = Int(frame.types[index])
        var info = AtomInfo(index: index, tag: frame.tags[index], type: type,
                            typeName: styles?.style(forType: type).name, position: frame.positions[index])
        if let radii = frame.radii, index < radii.count {
            info.radius = radii[index]
        } else if let styles {
            info.radius = Float(styles.style(forType: type).radius)
        }
        if let quantity = frame.perAtomQuantity, let values = frame.perAtomValues, index < values.count {
            info.quantity = quantity
            info.value = values[index]
        }
        return info
    }

    /// The atom with this ID in `frame`, or nil when it is gone.
    public static func atom(withTag tag: Int64, in frame: AtomFrame, styles: AtomStyleTable? = nil) -> AtomInfo? {
        atom(atParticle: frame.index(ofTag: tag), in: frame, styles: styles)
    }

    /// The nearest atom whose sphere a ray hits, for hosts without the
    /// renderer's ID buffer (or to double check it). `radius` gives each
    /// atom's drawn radius. Returns an index into the frame.
    public static func atomHit(in frame: AtomFrame, rayOrigin: SIMD3<Float>, direction: SIMD3<Float>,
                               radius: (Int) -> Float) -> Int? {
        let length = simd_length(direction)
        guard length > 0, length.isFinite else { return nil }
        let d = direction / length
        var best: (index: Int, distance: Float)?
        for (i, center) in frame.positions.enumerated() {
            let r = radius(i)
            guard r > 0 else { continue }
            let oc = center - rayOrigin
            let along = simd_dot(oc, d)
            let perpendicular2 = simd_length_squared(oc) - along * along
            let r2 = r * r
            guard perpendicular2 <= r2 else { continue }
            let entry = along - (r2 - perpendicular2).squareRoot()
            let t = entry >= 0 ? entry : along + (r2 - perpendicular2).squareRoot()
            guard t >= 0 else { continue }
            if t < (best?.distance ?? .infinity) { best = (i, t) }
        }
        return best?.index
    }
}
