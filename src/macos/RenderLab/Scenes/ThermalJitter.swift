import Dispatch
import simd

/// Thermal noise for the animate toggle: every frame each particle sits at
/// its rest position plus an independent random offset, so the crystal
/// shakes in place and never drifts. Deterministic for a given frame.
enum ThermalJitter {
    /// Particles per parallel work item.
    static let chunkSize = 32_768

    /// Writes `base` plus a uniform offset in [−amplitude, amplitude) per
    /// component into `output`, resizing it to `base.count` when needed.
    /// Large inputs are split across cores.
    static func apply(base: [SIMD3<Float>], amplitude: Float, frame: UInt64, into output: inout [SIMD3<Float>]) {
        let count = base.count
        if output.count != count {
            output = [SIMD3<Float>](repeating: .zero, count: count)
        }
        guard count > 0 else { return }
        let key = LabHash.mix(frame &+ 0x2545_F491_4F6C_DD1D)
        let chunk = chunkSize
        let chunks = (count + chunk - 1) / chunk
        base.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let src = source.baseAddress, let dst = destination.baseAddress else { return }
                let pointers = JitterPointers(source: src, destination: dst)
                let work: @Sendable (Int) -> Void = { c in
                    let start = c * chunk
                    let end = min(start + chunk, count)
                    for i in start..<end {
                        pointers.destination[i] = pointers.source[i] + amplitude * offset(index: UInt64(i), key: key)
                    }
                }
                if chunks == 1 {
                    work(0)
                } else {
                    DispatchQueue.concurrentPerform(iterations: chunks, execute: work)
                }
            }
        }
    }

    /// A pseudo-random vector in [−1, 1)³ for particle `index`.
    static func offset(index: UInt64, key: UInt64) -> SIMD3<Float> {
        let h = LabHash.mix(index ^ key)
        let scale: Float = 1.0 / 1_048_576 // 21-bit integers to [0, 2)
        let x = Float(h & 0x1F_FFFF) * scale - 1
        let y = Float((h >> 21) & 0x1F_FFFF) * scale - 1
        let z = Float((h >> 42) & 0x1F_FFFF) * scale - 1
        return SIMD3(x, y, z)
    }
}

/// The two buffers of one `apply` call, handed to the worker threads. Each
/// worker writes a disjoint range, and the call does not return before all
/// of them finish, so sharing the pointers is safe.
private struct JitterPointers: @unchecked Sendable {
    let source: UnsafePointer<SIMD3<Float>>
    let destination: UnsafeMutablePointer<SIMD3<Float>>
}
