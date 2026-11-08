import AtomifyEngine
import Foundation
import simd

/// Measurements of the displayed distance-based bond graph, not electronic bond order.
public struct MolecularInspection: Sendable, Equatable {
    public let tag: Int64
    public let type: Int32
    public let neighborTags: [Int64]
    public let pairDistance: Double?
    public let meanAngleDegrees: Double?

    public static func measure(snapshot s: SimulationSnapshot, tag: Int64,
                               pairedTag: Int64? = nil) -> Self? {
        guard s.positions.count == s.atomCount, s.types.count == s.atomCount,
              s.periodic.count == 3, s.typeCount > 0,
              zip(s.tags, s.tags.dropFirst()).allSatisfy({ $0 < $1 }),
              s.types.allSatisfy({ $0 > 0 && Int($0) <= s.typeCount }),
              s.positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              (0..<3).allSatisfy({ s.boxLow[$0].isFinite && s.boxHigh[$0].isFinite &&
                  (!s.periodic[$0] || (s.boxHigh[$0] > s.boxLow[$0] && (s.boxHigh[$0] - s.boxLow[$0]).isFinite)) }),
              let index = s.index(ofTag: tag) else { return nil }
        func vector(_ other: Int) -> SIMD3<Double> {
            var delta = SIMD3<Double>(s.positions[other]) - SIMD3<Double>(s.positions[index])
            for axis in 0..<3 where s.periodic[axis] {
                let length = s.boxHigh[axis] - s.boxLow[axis]
                delta[axis] -= (delta[axis] / length).rounded() * length
            }
            return delta
        }
        var neighbors = Set<Int>()
        for edge in s.bonds {
            let a = Int(edge.x), b = Int(edge.y)
            guard a < s.atomCount, b < s.atomCount, a != b else { continue }
            if a == index { neighbors.insert(b) }
            if b == index { neighbors.insert(a) }
        }
        let ordered = neighbors.sorted { s.tags[$0] < s.tags[$1] }
        let vectors = ordered.map(vector)
        var angle: Double?
        if vectors.count > 1, vectors.allSatisfy({ simd_length($0) > 1e-10 }) {
            var sum = 0.0, count = 0
            for a in 0..<(vectors.count - 1) {
                for b in (a + 1)..<vectors.count {
                    let cosine = simd_dot(simd_normalize(vectors[a]), simd_normalize(vectors[b]))
                    sum += acos(min(1, max(-1, cosine))) * 180 / .pi
                    count += 1
                }
            }
            angle = sum / Double(count)
        }
        let distance = pairedTag.flatMap { $0 == tag ? nil : s.index(ofTag: $0) }.map { simd_length(vector($0)) }
        return Self(tag: tag, type: s.types[index], neighborTags: ordered.map { s.tags[$0] },
                    pairDistance: distance, meanAngleDegrees: angle)
    }
}
