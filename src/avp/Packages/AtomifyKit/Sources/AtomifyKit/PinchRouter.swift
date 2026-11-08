import simd

/// One pinch as the system reports it in one update. Positions and
/// directions are in world (scene) meters, y up.
public struct PinchSample: Equatable, Sendable {
    /// Direct: the hand is at or inside the box. Indirect: the wearer looks
    /// at something and pinches anywhere.
    public enum Kind: Equatable, Sendable { case direct, indirect }

    /// The gaze ray that selected the target of an indirect pinch.
    public struct Ray: Equatable, Sendable {
        /// Near the eyes.
        public var origin: SIMD3<Float>
        public var direction: SIMD3<Float>

        public init(origin: SIMD3<Float>, direction: SIMD3<Float>) {
            self.origin = origin
            self.direction = direction
        }
    }

    public var id: Int
    public var kind: Kind
    /// Where the pinching hand is.
    public var position: SIMD3<Float>
    /// The hand's orientation; identity when unknown.
    public var orientation: simd_quatf
    /// Only for indirect pinches.
    public var ray: Ray?
    public var ended: Bool

    public init(id: Int, kind: Kind, position: SIMD3<Float>,
                orientation: simd_quatf = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                ray: Ray? = nil, ended: Bool = false) {
        self.id = id
        self.kind = kind
        self.position = position
        self.orientation = orientation
        self.ray = ray
        self.ended = ended
    }

    public var pose: HandPose { HandPose(position: position, orientation: orientation) }
}

/// Decides what pinches on the box do. One hand is always for atoms: a
/// single pinch that starts while no other pinch is down grabs an atom.
/// Two hands are always for the box: with two pinches down the box moves,
/// turns, rolls and scales with them. After a two-hand grip, a hand still
/// pinching does nothing until every pinch is released, so letting go with
/// one hand never grabs an atom by accident.
public struct PinchRouter: Sendable {
    public enum Mode: Equatable, Sendable {
        case idle
        /// One pinch, holding an atom (or trying to).
        case atom(pinch: Int)
        /// Two pinches holding the box, in the order they started.
        case grip(Int, Int)
        /// A grip ended but a pinch is still down; waits for all to release.
        case afterGrip
    }

    /// What one update means for the caller.
    public struct Output: Equatable, Sendable {
        /// The pinch that started an atom grab this update; pick an atom with it.
        public var atomBegan: PinchSample?
        /// The atom pinch now, for dragging; nil when there is none.
        public var atomPinch: PinchSample?
        /// The atom pinch ended, or a second pinch joined; release the atom.
        public var atomEnded: Bool
        /// Where the box goes while two hands grip it.
        public var placement: BoxPlacement?
        public var isGripping: Bool

        public init(atomBegan: PinchSample? = nil, atomPinch: PinchSample? = nil, atomEnded: Bool = false,
                    placement: BoxPlacement? = nil, isGripping: Bool = false) {
            self.atomBegan = atomBegan
            self.atomPinch = atomPinch
            self.atomEnded = atomEnded
            self.placement = placement
            self.isGripping = isGripping
        }
    }

    public private(set) var mode: Mode = .idle
    /// Pinches down now, in the order they started.
    private var active: [PinchSample] = []
    /// Hand poses and the box placement when the grip began.
    private var gripStart: (a: HandPose, b: HandPose, placement: BoxPlacement)?

    public init() {}

    public mutating func reset() {
        mode = .idle
        active = []
        gripStart = nil
    }

    /// Applies one update. `pinches` is every pinch the system reports now;
    /// a pinch missing from it has ended. `placement` is where the box is now.
    public mutating func update(_ pinches: [PinchSample], placement: BoxPlacement) -> Output {
        let current = Dictionary(pinches.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        active = active.compactMap { old in current[old.id].flatMap { $0.ended ? nil : $0 } }
        let known = Set(active.map(\.id))
        active += pinches.filter { !$0.ended && !known.contains($0.id) }.sorted { $0.id < $1.id }
        func sample(_ id: Int) -> PinchSample? { active.first { $0.id == id } }

        var output = Output()
        switch mode {
        case .idle:
            if active.count == 1 {
                mode = .atom(pinch: active[0].id)
                output.atomBegan = active[0]
                output.atomPinch = active[0]
            } else if active.count >= 2 {
                beginGrip(placement: placement)
            }
        case .atom(let id):
            if let pinch = sample(id) {
                if active.count >= 2 {
                    output.atomEnded = true
                    beginGrip(placement: placement)
                } else {
                    output.atomPinch = pinch
                }
            } else {
                output.atomEnded = true
                // A pinch that joined as the atom pinch ended did not start
                // alone, so it waits like a leftover grip hand.
                mode = active.isEmpty ? .idle : .afterGrip
            }
        case .grip(let a, let b):
            if sample(a) == nil || sample(b) == nil {
                mode = active.isEmpty ? .idle : .afterGrip
                gripStart = nil
            }
        case .afterGrip:
            if active.isEmpty { mode = .idle }
        }

        if case .grip(let a, let b) = mode, let start = gripStart, let pa = sample(a), let pb = sample(b) {
            output.placement = start.placement.held(from: (start.a, start.b), to: (pa.pose, pb.pose))
            output.isGripping = true
        }
        return output
    }

    private mutating func beginGrip(placement: BoxPlacement) {
        let a = active[0], b = active[1]
        mode = .grip(a.id, b.id)
        gripStart = (a.pose, b.pose, placement)
    }
}
