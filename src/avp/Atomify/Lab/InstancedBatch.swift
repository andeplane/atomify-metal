import RealityKit
import simd

/// One mesh drawn many times with GPU instancing: a single entity with a
/// MeshInstancesComponent. Atoms are batched per type (instances share a
/// material, so one batch per color), which keeps a few thousand atoms to a
/// handful of draw calls instead of one entity each.
@MainActor
final class InstancedBatch {
    let entity = Entity()
    private var instances: LowLevelInstanceData?
    private var capacity = 0

    /// Unused instance slots collapse to a point and draw nothing.
    private static let hidden = simd_float4x4(0)

    init(mesh: MeshResource, material: any Material) {
        entity.components.set(ModelComponent(mesh: mesh, materials: [material]))
        entity.isEnabled = false
    }

    func setMaterial(_ material: any Material) {
        entity.components[ModelComponent.self]?.materials = [material]
    }

    func update(_ transforms: [simd_float4x4]) {
        entity.isEnabled = !transforms.isEmpty
        guard !transforms.isEmpty else { return }
        if transforms.count > capacity || instances == nil {
            let newCapacity = max(64, transforms.count + transforms.count / 2)
            guard let data = try? LowLevelInstanceData(instanceCount: newCapacity) else { return }
            var component = MeshInstancesComponent()
            component[partIndex: 0] = .init(data: data)
            entity.components.set(component)
            instances = data
            capacity = newCapacity
        }
        let count = transforms.count, capacity = capacity
        instances?.withMutableTransforms { slots in
            for i in 0..<count { slots[i] = transforms[i] }
            for i in count..<capacity { slots[i] = Self.hidden }
        }
    }
}
