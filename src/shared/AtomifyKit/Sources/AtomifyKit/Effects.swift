import AtomifyRender
import Foundation
import simd

/// One visual effect an example asks for, under `"effects"` in its
/// `atomifyMetal` options: a small modifier of the picture that knows nothing
/// about LAMMPS, only about the frame (positions, types, ids, box).
///
///     {"kind": "tracers", "type": 2, "color": [1, 0.2, 0.2], "scale": 1.6}
///     {"kind": "trails",  "type": 2, "length": 300, "every": 2, "width": 2}
///
/// `kind`s the app draws itself, from the session's data and not the frame,
/// are listed in `ExampleEffect.Kind.chart` (a small live chart).
public struct ExampleEffect: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// Atoms picked out by color and size.
        case tracers
        /// The paths atoms have taken, drawn as fading lines.
        case trails
        /// A small live chart of a plotted quantity ("temperature"), in a
        /// corner of the view; drawn by the app.
        case chart
    }

    public var kind: Kind
    /// Atoms of this (1-based) LAMMPS type...
    public var type: Int?
    /// ... or with these atom IDs.
    public var ids: [Int64]?
    /// sRGB (0...1) of the tracers and their trails.
    public var color: [Double]?
    /// Tracers: radius as a multiple of their normal radius.
    public var scale: Double?
    /// Trails: points kept per atom.
    public var length: Int?
    /// Trails: one point every this many frames.
    public var every: Int?
    /// Trails: line width in points.
    public var width: Double?
    /// Chart: what to plot, matched against the plot titles ("Temperature").
    public var series: String?

    public init(kind: Kind, type: Int? = nil, ids: [Int64]? = nil, color: [Double]? = nil, scale: Double? = nil,
                length: Int? = nil, every: Int? = nil, width: Double? = nil, series: String? = nil) {
        self.kind = kind
        self.type = type
        self.ids = ids
        self.color = color
        self.scale = scale
        self.length = length
        self.every = every
        self.width = width
        self.series = series
    }

    /// The most atoms one effect follows; the rest are left alone.
    public static let atomLimit = 48

    /// `color` as sRGB, or red.
    var srgb: SIMD3<Float> {
        guard let color, color.count == 3, color.allSatisfy(\.isFinite) else { return SIMD3(1, 0.25, 0.2) }
        return SIMD3(Float(color[0]), Float(color[1]), Float(color[2]))
    }

    /// Frame indices of the atoms the effect is about: those of its `ids`
    /// that exist, else those of its `type`, at most `atomLimit`.
    func indices(in frame: AtomFrame) -> [Int] {
        if let ids {
            return ids.prefix(Self.atomLimit).compactMap { frame.index(ofTag: $0) }
        }
        guard let type else { return [] }
        var found: [Int] = []
        for (index, atomType) in frame.types.enumerated() where Int(atomType) == type {
            found.append(index)
            if found.count == Self.atomLimit { break }
        }
        return found
    }
}

/// The modifiers of a run, in order: tracers recolor and enlarge atoms, trails
/// add line segments behind them. It keeps the history trails need, so a
/// new run starts a new pipeline.
public struct EffectPipeline: Sendable {
    public private(set) var effects: [ExampleEffect]
    private var histories: [Int: TrailHistory] = [:]
    private var framesSeen = 0

    public init(effects: [ExampleEffect] = []) {
        self.effects = effects.filter { $0.kind != .chart }
    }

    public var isEmpty: Bool { effects.isEmpty }

    /// Notes a new frame: trails take their next point.
    public mutating func record(_ frame: AtomFrame) {
        framesSeen += 1
        for (number, effect) in effects.enumerated() where effect.kind == .trails {
            var history = histories[number] ?? TrailHistory(tags: effect.indices(in: frame).map { frame.tags[$0] })
            let every = max(effect.every ?? 1, 1)
            if (framesSeen - 1) % every == 0 {
                history.append(frame, length: min(max(effect.length ?? 200, 2), 5000))
            }
            histories[number] = history
        }
    }

    /// The scene with the effects drawn into it. `styles` are the type styles
    /// of the scene's particles, for the normal radius and color of atoms.
    public func apply(to scene: inout SceneData, frame: AtomFrame) {
        for (number, effect) in effects.enumerated() {
            switch effect.kind {
            case .tracers:
                Self.highlight(effect, in: &scene, frame: frame)
            case .trails:
                guard let history = histories[number] else { continue }
                scene.lines += history.lines(effect: effect, frame: frame)
            case .chart:
                break
            }
        }
    }

    static func highlight(_ effect: ExampleEffect, in scene: inout SceneData, frame: AtomFrame) {
        let indices = effect.indices(in: frame).filter { $0 < scene.particles.count }
        guard !indices.isEmpty else { return }
        var particles = scene.particles
        let count = particles.count
        let styleIndices = particles.styleIndices.flatMap { $0.count == count ? $0 : nil }
        let styles = particles.styles.isEmpty ? [ParticleStyle.fallback] : particles.styles
        func style(of index: Int) -> ParticleStyle {
            let i = Int(styleIndices?[index] ?? 0)
            return styles[i < styles.count ? i : 0]
        }
        var colors = particles.colors.flatMap { $0.count == count ? $0 : nil }
            ?? (0..<count).map { style(of: $0).color }
        var radii = particles.radii.flatMap { $0.count == count ? $0 : nil }
            ?? (0..<count).map { style(of: $0).radius }
        let color = linearColor(srgb: effect.srgb)
        let scale = Float(effect.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1.5)
        for index in indices {
            colors[index] = color
            radii[index] *= scale
        }
        particles.colors = colors
        particles.radii = radii
        scene.particles = particles
    }
}

/// The recent positions of some atoms (by ID).
struct TrailHistory: Sendable {
    let tags: [Int64]
    private(set) var paths: [[SIMD3<Float>]]

    init(tags: [Int64]) {
        self.tags = tags
        paths = Array(repeating: [], count: tags.count)
    }

    mutating func append(_ frame: AtomFrame, length: Int) {
        for (slot, tag) in tags.enumerated() {
            guard let index = frame.index(ofTag: tag), index < frame.positions.count else { continue }
            paths[slot].append(frame.positions[index])
            if paths[slot].count > length { paths[slot].removeFirst(paths[slot].count - length) }
        }
    }

    /// How many shades a trail fades through, from the oldest to the newest part.
    static let fadeSteps = 6

    /// Each trail as `fadeSteps` lines, the older parts dimmer (blended
    /// toward the background, since a line has one opaque color). A step
    /// across a periodic boundary is not drawn.
    func lines(effect: ExampleEffect, frame: AtomFrame) -> [LineData] {
        let size = SIMD3<Float>(frame.boxHigh - frame.boxLow)
        let periodic = frame.periodic + Array(repeating: false, count: max(3 - frame.periodic.count, 0))
        let width = Float(effect.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 2)
        let color = effect.srgb
        let background = SIMD3<Float>(repeating: 0.07)
        var result: [LineData] = []
        for path in paths where path.count > 1 {
            var groups = [[(SIMD3<Float>, SIMD3<Float>)]](repeating: [], count: Self.fadeSteps)
            let segments = path.count - 1
            for k in 0..<segments {
                let a = path[k], b = path[k + 1]
                let jump = abs(b - a)
                if (0..<3).contains(where: { periodic[$0] && jump[$0] > 0.5 * size[$0] }) { continue }
                groups[min(k * Self.fadeSteps / segments, Self.fadeSteps - 1)].append((a, b))
            }
            for (step, segments) in groups.enumerated() where !segments.isEmpty {
                let t = 0.25 + 0.75 * Float(step) / Float(Self.fadeSteps - 1)
                result.append(LineData(segments: segments, color: linearColor(srgb: simd_mix(background, color, SIMD3(repeating: t))),
                                       width: width))
            }
        }
        return result
    }
}
