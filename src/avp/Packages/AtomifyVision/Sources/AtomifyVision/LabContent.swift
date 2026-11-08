import AtomifyEngine
import AtomifyKit
import simd

/// The one marked atom in the lab: the atom a hand is near, or the one it holds.
public struct LabHighlight: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case near, held }
    public var tag: Int64
    public var kind: Kind

    public init(tag: Int64, kind: Kind) {
        self.tag = tag
        self.kind = kind
    }
}

/// What the Metal lab draws for a snapshot, built with AtomifyKit's scene
/// builder: atoms in their type colors, bonds, optionally the box, and the
/// marked atom in a lighter shade of its own color.
public enum LabContent {
    /// Box edges: a soft white that reads on passthrough without dominating.
    public static let boxColor = SIMD4<Float>(0.75, 0.77, 0.8, 1)
    public static let boxLineWidth: Float = 1.25

    /// The renderer's input for `snapshot`. `styles` must cover its types.
    public static func scene(snapshot: SimulationSnapshot, styles: AtomStyleTable, showsBox: Bool,
                             highlight: LabHighlight?) -> SceneData {
        var scene = SceneBuilder.scene(from: snapshot, styles: styles, colorMode: .type,
                                       selectedTag: highlight?.tag, showBox: showsBox,
                                       bondRadius: LabBonds.radius(styles: styles))
        for index in scene.lines.indices {
            scene.lines[index].color = boxColor
            scene.lines[index].width = boxLineWidth
        }
        return scene
    }

    /// The marked atom's color (linear RGBA): its own color, lifted toward
    /// white a little when a hand is near and more while it is held. Never
    /// a different hue, so the atom stays recognizable.
    public static func highlightColor(_ highlight: LabHighlight, in snapshot: SimulationSnapshot,
                                      styles: AtomStyleTable) -> SIMD4<Float> {
        guard let index = snapshot.index(ofTag: highlight.tag), index < snapshot.types.count else {
            return SIMD4(1, 1, 1, 1)
        }
        let color = styles.style(forType: Int(snapshot.types[index])).color
        return lifted(color, by: highlight.kind == .held ? 0.4 : 0.18)
    }

    /// `color` moved `amount` (0...1) of the way to white, in sRGB, returned linear.
    public static func lifted(_ color: RGBColor, by amount: Double) -> SIMD4<Float> {
        let t = min(max(amount, 0), 1)
        func lift(_ value: Double) -> Double { value + (1 - value) * t }
        return RGBColor(red: lift(color.red), green: lift(color.green), blue: lift(color.blue)).linear
    }

    /// World (meters) from simulation coordinates for content framed by
    /// `frame` and placed by `placement`.
    public static func worldFromSimulation(placement: BoxPlacement, frame: SimulationFrame) -> simd_float4x4 {
        placement.worldFromLocal * frame.localFromSimulation
    }

    public static func simulationPoint(fromWorld point: SIMD3<Float>, placement: BoxPlacement,
                                       frame: SimulationFrame) -> SIMD3<Float> {
        frame.simulationPoint(fromLocal: placement.localPoint(fromWorld: point))
    }

    public static func worldPoint(fromSimulation point: SIMD3<Float>, placement: BoxPlacement,
                                  frame: SimulationFrame) -> SIMD3<Float> {
        let local = frame.localFromSimulation * SIMD4(point, 1)
        return placement.worldPoint(fromLocal: SIMD3(local.x, local.y, local.z))
    }
}

extension BoxPlacement {
    /// Whether a ray (world space) passes through the placed content, whose
    /// size at scale 1 is `extent` meters, grown by `margin` on every side.
    /// Points behind the origin do not count.
    public func intersects(rayOrigin: SIMD3<Float>, direction: SIMD3<Float>, extent: SIMD3<Float>,
                           margin: Float = 1) -> Bool {
        let origin = localPoint(fromWorld: rayOrigin)
        let towards = localPoint(fromWorld: rayOrigin + direction) - origin
        guard simd_length_squared(towards) > 0, towards.x.isFinite, towards.y.isFinite, towards.z.isFinite else {
            return false
        }
        let half = extent * margin / 2
        var enter: Float = 0, exit = Float.infinity
        for axis in 0..<3 {
            if abs(towards[axis]) < 1e-12 {
                if abs(origin[axis]) > half[axis] { return false }
                continue
            }
            var a = (-half[axis] - origin[axis]) / towards[axis]
            var b = (half[axis] - origin[axis]) / towards[axis]
            if a > b { swap(&a, &b) }
            enter = max(enter, a)
            exit = min(exit, b)
            if enter > exit { return false }
        }
        return true
    }

    /// Whether a world point is inside the placed content (`extent` meters
    /// at scale 1), grown by `reach` meters in the world on every side.
    public func contains(_ point: SIMD3<Float>, extent: SIMD3<Float>, reach: Float = 0) -> Bool {
        let local = localPoint(fromWorld: point)
        let half = extent / 2 + reach / max(scale, 1e-6)
        return abs(local.x) <= half.x && abs(local.y) <= half.y && abs(local.z) <= half.z
    }
}
