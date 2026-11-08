import RealityKit
import simd

/// Low polygon meshes for instancing. Triangle count per instance is what
/// limits large systems, so atoms get coarser spheres as their number grows.
@MainActor
enum Meshes {
    /// Unit icosphere. Level 1 has 80 triangles, 2 has 320, 3 has 1280.
    static func sphere(subdivisions: Int) throws -> MeshResource {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [
            [-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
            [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1],
        ]
        var vertices = corners.map { simd_normalize($0) }
        var faces: [SIMD3<UInt32>] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4],
            [11, 10, 2], [10, 7, 6], [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8],
            [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1],
        ]
        for _ in 0..<subdivisions {
            var midpoints: [UInt64: UInt32] = [:]
            func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let index = midpoints[key] { return index }
                vertices.append(simd_normalize(vertices[Int(a)] + vertices[Int(b)]))
                let index = UInt32(vertices.count - 1)
                midpoints[key] = index
                return index
            }
            faces = faces.flatMap { f -> [SIMD3<UInt32>] in
                let ab = midpoint(f.x, f.y), bc = midpoint(f.y, f.z), ca = midpoint(f.z, f.x)
                return [[f.x, ab, ca], [f.y, bc, ab], [f.z, ca, bc], [ab, bc, ca]]
            }
        }
        var descriptor = MeshDescriptor(name: "atom")
        descriptor.positions = MeshBuffers.Positions(vertices)
        descriptor.normals = MeshBuffers.Normals(vertices)
        descriptor.primitives = .triangles(faces.flatMap { [$0.x, $0.y, $0.z] })
        return try MeshResource.generate(from: [descriptor])
    }

    static func sphereSubdivisions(forAtomCount count: Int) -> Int {
        switch count {
        case ..<1500: 3
        case ..<6000: 2
        default: 1
        }
    }

    /// Open unit tube along +Y from -0.5 to 0.5 with radius 1. The ends are
    /// hidden inside atoms, so no caps.
    static func tube(sides: Int = 10) throws -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for i in 0...sides {
            let angle = Float(i) / Float(sides) * 2 * .pi
            let normal = SIMD3<Float>(cos(angle), 0, sin(angle))
            positions += [normal + [0, -0.5, 0], normal + [0, 0.5, 0]]
            normals += [normal, normal]
        }
        for i in 0..<UInt32(sides) {
            let a = 2 * i, b = a + 1, c = a + 2, d = a + 3
            indices += [a, b, c, c, b, d]
        }
        var descriptor = MeshDescriptor(name: "bond")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
