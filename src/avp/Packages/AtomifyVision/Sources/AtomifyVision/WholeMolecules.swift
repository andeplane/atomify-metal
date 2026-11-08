import AtomifyEngine
import simd

/// Display-only positions that draw molecules whole in a periodic box.
///
/// LAMMPS wraps every atom into the box, and the engine skips bonds that
/// cross a periodic face, so a molecule at a face shows up as an oxygen on
/// one side and a lone hydrogen on the other. This finds those crossing
/// bonds from the script's `#/bond` rules (minimum-image distance below the
/// rule's cutoff) and walks each bonded group from its lowest-index atom,
/// placing every atom at its parent plus the minimum image of their
/// separation. The group's first atom stays where LAMMPS put it, inside the
/// box; the rest may poke out of a face by about a bond length.
///
/// `shifts[i]` is `positions[i]` minus the atom's simulated position: a
/// whole number of box lengths. Subtract it to turn a drawn point near atom
/// `i` back into the atom's own frame. Everything is in simulation units.
public struct WholeMolecules: Equatable, Sendable {
    /// Where to draw each atom.
    public var positions: [SIMD3<Float>]
    /// Drawn minus simulated position, per atom.
    public var shifts: [SIMD3<Float>]
    /// Bonds across a periodic face, which the engine leaves out; short in
    /// the drawn positions.
    public var crossingBonds: [SIMD2<UInt32>]

    /// Whether any atom moved.
    public var movesAtoms: Bool { shifts.contains { $0 != .zero } }

    /// Nil when the experience does not ask for whole molecules, so a
    /// crystal or network is drawn exactly as simulated.
    public static func make(snapshot: SimulationSnapshot, rules: [BondRule], enabled: Bool) -> WholeMolecules? {
        guard enabled else { return nil }
        return make(positions: snapshot.positions, types: snapshot.types, boxLow: snapshot.boxLow,
                    boxHigh: snapshot.boxHigh, periodic: snapshot.periodic, bonds: snapshot.bonds, rules: rules)
    }

    /// O(atoms + bonds) for molecular systems: only atoms within the
    /// largest cutoff of a periodic face are tested for crossing bonds, on a
    /// cell grid.
    public static func make(positions: [SIMD3<Float>], types: [Int32], boxLow: SIMD3<Double>,
                            boxHigh: SIMD3<Double>, periodic: [Bool], bonds: [SIMD2<UInt32>],
                            rules: [BondRule]) -> WholeMolecules {
        let count = positions.count
        let identity = WholeMolecules(positions: positions, shifts: Array(repeating: .zero, count: count),
                                      crossingBonds: [])
        let low = SIMD3<Float>(boxLow), length = SIMD3<Float>(boxHigh - boxLow)
        var wraps = SIMD3<Float>(repeating: 0)   // 1 along periodic axes
        for axis in 0..<3 where axis < periodic.count && periodic[axis] && length[axis] > 0 && length[axis].isFinite {
            wraps[axis] = 1
        }
        guard count > 1, types.count == count, wraps != .zero else { return identity }

        func minimumImage(_ delta: SIMD3<Float>) -> SIMD3<Float> {
            var result = delta
            for axis in 0..<3 where wraps[axis] == 1 {
                result[axis] -= length[axis] * (delta[axis] / length[axis]).rounded()
            }
            return result
        }

        let crossing = crossingBonds(positions: positions, types: types, low: low, length: length,
                                     wraps: wraps, rules: rules)
        let all = bonds + crossing
        guard !all.isEmpty else { return identity }

        // Adjacency in compressed rows.
        var degree = [Int](repeating: 0, count: count + 1)
        for bond in all where Int(bond.x) < count && Int(bond.y) < count && bond.x != bond.y {
            degree[Int(bond.x) + 1] += 1
            degree[Int(bond.y) + 1] += 1
        }
        for i in 0..<count { degree[i + 1] += degree[i] }
        var fill = degree
        var neighbors = [Int](repeating: 0, count: degree[count])
        for bond in all where Int(bond.x) < count && Int(bond.y) < count && bond.x != bond.y {
            let a = Int(bond.x), b = Int(bond.y)
            neighbors[fill[a]] = b; fill[a] += 1
            neighbors[fill[b]] = a; fill[b] += 1
        }

        // Breadth-first from each group's lowest-index atom.
        var drawn = positions
        var visited = [Bool](repeating: false, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count)
        for root in 0..<count where !visited[root] {
            visited[root] = true
            queue.removeAll(keepingCapacity: true)
            queue.append(root)
            var head = 0
            while head < queue.count {
                let parent = queue[head]
                head += 1
                for slot in degree[parent]..<degree[parent + 1] {
                    let child = neighbors[slot]
                    guard !visited[child] else { continue }
                    visited[child] = true
                    drawn[child] = drawn[parent] + minimumImage(positions[child] - positions[parent])
                    queue.append(child)
                }
            }
        }
        var shifts = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            // Snap to whole box lengths so float error cannot creep in.
            var shift = drawn[i] - positions[i]
            for axis in 0..<3 where wraps[axis] == 1 {
                shift[axis] = length[axis] * (shift[axis] / length[axis]).rounded()
            }
            shift *= wraps
            shifts[i] = shift
            drawn[i] = positions[i] + shift
        }
        return WholeMolecules(positions: drawn, shifts: shifts, crossingBonds: crossing)
    }

    /// Pairs within a rule's cutoff by minimum image but not directly,
    /// among atoms near periodic faces.
    static func crossingBonds(positions: [SIMD3<Float>], types: [Int32], low: SIMD3<Float>,
                              length: SIMD3<Float>, wraps: SIMD3<Float>, rules: [BondRule]) -> [SIMD2<UInt32>] {
        let valid = rules.filter { $0.type1 > 0 && $0.type2 > 0 && $0.cutoff > 0 && $0.cutoff.isFinite }
        guard let maxType = valid.map({ max($0.type1, $0.type2) }).max(),
              let maxCut = valid.map({ Float($0.cutoff) }).max() else { return [] }
        let width = maxType + 1
        var cutoffSquared = [Float](repeating: 0, count: width * width)
        for rule in valid {
            let squared = Float(rule.cutoff * rule.cutoff)
            cutoffSquared[rule.type1 * width + rule.type2] = squared
            cutoffSquared[rule.type2 * width + rule.type1] = squared
        }
        func cutoff2(_ a: Int32, _ b: Int32) -> Float {
            let a = Int(a), b = Int(b)
            guard a > 0, b > 0, a < width, b < width else { return 0 }
            return cutoffSquared[a * width + b]
        }

        // Atoms within the largest cutoff of a periodic face.
        var near: [Int] = []
        for (i, p) in positions.enumerated() {
            let local = p - low
            for axis in 0..<3 where wraps[axis] == 1 {
                if local[axis] < maxCut || length[axis] - local[axis] < maxCut {
                    near.append(i)
                    break
                }
            }
        }
        guard near.count > 1 else { return [] }

        // A cell grid over the box with cells at least `maxCut` wide, so
        // every pair within a cutoff is in neighbouring cells (wrapping
        // across periodic faces).
        var cell = maxCut
        var cells = SIMD3<Int>(repeating: 1)
        repeat {
            for axis in 0..<3 {
                cells[axis] = max(1, Int(length[axis] / cell))
            }
            if cells.x * cells.y * cells.z <= 4 * near.count + 64 { break }
            cell *= 1.5
        } while true
        func cellIndex(_ p: SIMD3<Float>) -> SIMD3<Int> {
            var index = SIMD3<Int>()
            for axis in 0..<3 {
                let fraction = length[axis] > 0 ? (p[axis] - low[axis]) / length[axis] : 0
                index[axis] = min(cells[axis] - 1, max(0, Int(fraction * Float(cells[axis]))))
            }
            return index
        }
        func flat(_ index: SIMD3<Int>) -> Int { (index.z * cells.y + index.y) * cells.x + index.x }
        var heads = [Int](repeating: -1, count: cells.x * cells.y * cells.z)
        var next = [Int](repeating: -1, count: near.count)
        var home = [SIMD3<Int>](repeating: .zero, count: near.count)
        for (slot, i) in near.enumerated() {
            let index = cellIndex(positions[i])
            home[slot] = index
            let f = flat(index)
            next[slot] = heads[f]
            heads[f] = slot
        }

        var result: [SIMD2<UInt32>] = []
        var visitedCells: [Int] = []
        for (slotA, a) in near.enumerated() {
            visitedCells.removeAll(keepingCapacity: true)
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                var index = home[slotA] &+ SIMD3(dx, dy, dz)
                var outside = false
                for axis in 0..<3 where index[axis] < 0 || index[axis] >= cells[axis] {
                    if wraps[axis] == 1 { index[axis] = (index[axis] + cells[axis]) % cells[axis] } else { outside = true }
                }
                guard !outside else { continue }
                let f = flat(index)
                guard !visitedCells.contains(f) else { continue }
                visitedCells.append(f)
                var slotB = heads[f]
                while slotB >= 0 {
                    let b = near[slotB]
                    slotB = next[slotB]
                    guard b > a else { continue }
                    let limit = cutoff2(types[a], types[b])
                    guard limit > 0 else { continue }
                    let direct = positions[b] - positions[a]
                    var image = direct
                    var crosses = false
                    for axis in 0..<3 where wraps[axis] == 1 && abs(direct[axis]) > length[axis] / 2 {
                        image[axis] -= length[axis] * (direct[axis] / length[axis]).rounded()
                        crosses = true
                    }
                    if crosses, simd_length_squared(image) < limit {
                        result.append(SIMD2(UInt32(a), UInt32(b)))
                    }
                }
            } } }
        }
        return result
    }
}
