import simd

/// Where the simulation box sits in the room: position of its center,
/// orientation, and uniform scale on top of its initial size.
public struct BoxPlacement: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf
    public var scale: Float

    public static let scaleRange: ClosedRange<Float> = 0.1...8

    public init(position: SIMD3<Float>, orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                scale: Float = 1) {
        self.position = position
        self.orientation = orientation
        self.scale = scale
    }

    /// Transform from the box's local space (meters at scale 1) to the world.
    public var worldFromLocal: simd_float4x4 {
        var matrix = simd_float4x4(orientation) * simd_float4x4(diagonal: SIMD4(scale, scale, scale, 1))
        matrix.columns.3 = SIMD4(position, 1)
        return matrix
    }

    public func localPoint(fromWorld point: SIMD3<Float>) -> SIMD3<Float> {
        orientation.inverse.act(point - position) / scale
    }

    public func worldPoint(fromLocal point: SIMD3<Float>) -> SIMD3<Float> {
        position + orientation.act(point * scale)
    }

    /// Centers the box on the wearer's head and makes it at least
    /// `minimumSize` meters along its longest side, keeping its orientation,
    /// so the atoms are all around them. `extent` is the box size at scale 1.
    public func surrounding(head: SIMD3<Float>, extent: SIMD3<Float>, minimumSize: Float = 4) -> BoxPlacement {
        let longest = extent.max()
        guard longest > 0, longest.isFinite else { return self }
        let newScale = min(max(scale, minimumSize / longest), Self.scaleRange.upperBound)
        return BoxPlacement(position: head, orientation: orientation, scale: newScale)
    }

    /// One pinch moving: the box follows the hand.
    public func dragged(from start: SIMD3<Float>, to end: SIMD3<Float>) -> BoxPlacement {
        var result = self
        result.position += end - start
        return result
    }

    /// Two pinches, as if holding the box with both hands: the box turns
    /// with the line between the hands, scales with their distance, and
    /// moves with their midpoint. Hand orientations are taken as unchanged,
    /// so there is no roll about that line; see `held(from:to:)` with
    /// `HandPose`s for that. Returns `self` when the hands started too close
    /// together to tell a direction.
    public func held(from start: (SIMD3<Float>, SIMD3<Float>),
                     to end: (SIMD3<Float>, SIMD3<Float>)) -> BoxPlacement {
        held(from: (HandPose(position: start.0), HandPose(position: start.1)),
             to: (HandPose(position: end.0), HandPose(position: end.1)))
    }

    /// Two hands holding the box, with their orientations: as the
    /// position-only `held(from:to:)`, and in addition the box rolls about
    /// the line between the hands by the average of how much each hand
    /// turned about it (a wrist twist), so turning both hands like a steering
    /// bar spins the box about that line. Hands are `(A, B)` in the same
    /// order before and after. Returns `self` when the hands started within
    /// 1 cm of each other.
    public func held(from start: (HandPose, HandPose), to end: (HandPose, HandPose)) -> BoxPlacement {
        let before = start.1.position - start.0.position, after = end.1.position - end.0.position
        let lengthBefore = simd_length(before), lengthAfter = simd_length(after)
        guard lengthBefore > 0.01, lengthAfter > 0.001,
              lengthBefore.isFinite, lengthAfter.isFinite else { return self }
        let axisBefore = before / lengthBefore, axisAfter = after / lengthAfter

        let swing = Self.shortestArc(from: axisBefore, to: axisAfter)
        func twist(_ from: HandPose, _ to: HandPose) -> Float {
            let residual = (to.orientation * from.orientation.inverse) * swing.inverse
            return Self.twistAngle(of: residual, about: axisAfter)
        }
        let roll = (twist(start.0, end.0) + twist(start.1, end.1)) / 2
        let turn = simd_quatf(angle: roll, axis: axisAfter) * swing

        let newScale = min(max(scale * lengthAfter / lengthBefore, Self.scaleRange.lowerBound),
                           Self.scaleRange.upperBound)
        let ratio = newScale / scale
        let midBefore = (start.0.position + start.1.position) / 2
        let midAfter = (end.0.position + end.1.position) / 2
        return BoxPlacement(position: midAfter + turn.act(position - midBefore) * ratio,
                            orientation: simd_normalize(turn * orientation), scale: newScale)
    }

    /// The smallest rotation taking unit vector `a` to unit vector `b`, also
    /// when they point (nearly) opposite ways: then a half turn about an
    /// axis perpendicular to `a`.
    static func shortestArc(from a: SIMD3<Float>, to b: SIMD3<Float>) -> simd_quatf {
        let cosine = simd_dot(a, b)
        if cosine < -0.9999 {
            var axis = simd_cross(SIMD3<Float>(1, 0, 0), a)
            if simd_length(axis) < 0.1 { axis = simd_cross(SIMD3<Float>(0, 1, 0), a) }
            return simd_quatf(angle: .pi, axis: simd_normalize(axis))
        }
        let cross = simd_cross(a, b)
        return simd_normalize(simd_quatf(ix: cross.x, iy: cross.y, iz: cross.z, r: 1 + cosine))
    }

    /// Signed angle in (-π, π] of the twist part of `rotation` about unit
    /// `axis` (swing–twist decomposition), right-handed about `axis`.
    static func twistAngle(of rotation: simd_quatf, about axis: SIMD3<Float>) -> Float {
        let sign: Float = rotation.real < 0 ? -1 : 1
        let along = simd_dot(rotation.imag, axis) * sign
        let real = rotation.real * sign
        guard abs(along) > 1e-7 || real > 1e-7 else { return 0 }
        return 2 * atan2(along, real)
    }
}

/// A hand's pose in the world: position in meters and orientation
/// (identity when unknown).
public struct HandPose: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var orientation: simd_quatf

    public init(position: SIMD3<Float>, orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)) {
        self.position = position
        self.orientation = orientation
    }
}

/// Tracks pinches holding the box and turns them into placements. It takes
/// both hands: moving them together carries the box, moving them relative
/// to each other turns and resizes it, and twisting the wrists rolls it
/// about the line between them. A single pinch does nothing, since
/// that is how windows and buttons are used.
public struct BoxGrip: Sendable {
    /// One pinch update, positions in world meters.
    public struct Touch: Sendable {
        public var id: Int
        public var position: SIMD3<Float>
        /// The hand's world orientation; identity when unknown.
        public var orientation: simd_quatf
        public var ended: Bool

        public init(id: Int, position: SIMD3<Float>, ended: Bool) {
            self.init(id: id, position: position, orientation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), ended: ended)
        }

        public init(id: Int, position: SIMD3<Float>, orientation: simd_quatf, ended: Bool) {
            self.id = id
            self.position = position
            self.orientation = orientation
            self.ended = ended
        }

        var pose: HandPose { HandPose(position: position, orientation: orientation) }
    }

    private var touches: [Int: HandPose] = [:]
    /// Where each pinch was, and the box's placement, when the current set
    /// of pinches started.
    private var start: (touches: [Int: HandPose], placement: BoxPlacement)?

    public init() {}

    public var isHolding: Bool { !touches.isEmpty }

    public mutating func reset() {
        touches = [:]
        start = nil
    }

    /// Applies pinch updates and returns the new placement, or nil unless
    /// two pinches hold the box. `accepts` decides whether a new pinch at a
    /// position may take hold.
    ///
    /// `events` is every pinch the system reports right now (a spatial event
    /// collection), so a held pinch missing from it has ended, even when its
    /// end was never reported. Without that, a lost end leaves a stale
    /// pinch behind and a later single pinch would turn the box around it.
    public mutating func update(_ events: [Touch], placement: BoxPlacement,
                                accepts: (SIMD3<Float>) -> Bool = { _ in true }) -> BoxPlacement? {
        let reported = Set(events.map(\.id))
        for id in touches.keys where !reported.contains(id) {
            touches.removeValue(forKey: id)
            start = nil
        }
        for event in events {
            if event.ended {
                if touches.removeValue(forKey: event.id) != nil { start = nil }
            } else if touches[event.id] != nil {
                touches[event.id] = event.pose
            } else if touches.count < 2, accepts(event.position) {
                touches[event.id] = event.pose
                start = nil
            }
        }
        guard touches.count >= 2 else { return nil }
        // A pinch started or ended: continue from where the box is now.
        if start == nil { start = (touches, placement) }
        guard let start else { return nil }

        let ids = touches.keys.sorted()
        guard let a0 = start.touches[ids[0]], let b0 = start.touches[ids[1]],
              let a1 = touches[ids[0]], let b1 = touches[ids[1]] else { return nil }
        return start.placement.held(from: (a0, b0), to: (a1, b1))
    }
}
