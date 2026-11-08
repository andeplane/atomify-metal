import AtomifyEngine
import AtomifyVision
import CoreGraphics
import Foundation
import RealityKit
import SwiftUI
import UIKit
import simd

/// A window into a small, deep space holding a piece of the experiment's
/// real structure. The structure sits on the portal plane, so half of it is
/// seen through the opening and half reaches out toward the viewer.
/// Dynamics start only when the lab opens.
struct PortalPreview: View {
    /// The checked-in snapshot (`preview.json`); nil gives an empty portal.
    let structureURL: URL?
    /// The demo's input script, for its `#/atom` colours and radii.
    let scriptURL: URL?
    /// The opening in points.
    let size: CGSize
    var cornerRadius: CGFloat = 24
    /// Cards out of focus fade their structure and draw it back behind the
    /// opening: crossing content is not clipped by the window, so a peeking
    /// card would otherwise float atoms beside the window. SwiftUI opacity
    /// is not used, as it turns the portal surface into a grey pane.
    var isDimmed = false
    /// Waits this long before loading the structure, so the card in focus
    /// fills first and its neighbours follow.
    var loadDelay: Duration = .zero

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader3D { proxy in
            RealityView { content in
                // Synchronous, so the opening and its backdrop show with the
                // window's first frame and no loading indicator. The structure
                // is decoded off the main actor and fades in when ready.
                let container = Entity()
                content.add(container)
                // The opening's size and centre in the content's own metres,
                // exact at any window distance or scale.
                let box = content.convert(proxy.frame(in: .local), from: .local, to: container)
                let metersPerPoint = box.extents.x / Float(max(size.width, 1))
                let shell = PortalSceneBuilder.makeShell(
                    width: box.extents.x, height: box.extents.y,
                    cornerRadius: Float(cornerRadius) * metersPerPoint,
                    reduceMotion: reduceMotion, focused: !isDimmed)
                // The view's frame has depth with its origin in the middle; the
                // window surface (and the 2D card) lies at its back face.
                shell.root.position = [box.center.x, box.center.y, box.min.z + 0.0005]
                container.addChild(shell.root)
                guard let structureURL else { return }
                Task { [scriptURL, loadDelay] in
                    await PortalSceneBuilder.populate(shell, structureURL: structureURL, scriptURL: scriptURL,
                                                      delay: loadDelay)
                }
            } update: { content in
                for entity in content.entities {
                    guard let pivot = entity.findEntity(named: PortalSceneBuilder.pivotName),
                          var spin = pivot.components[PortalSpinComponent.self] else { continue }
                    guard spin.reduceMotion != reduceMotion || spin.isFocused == isDimmed else { continue }
                    spin.reduceMotion = reduceMotion
                    if spin.isFocused == isDimmed { PortalSceneBuilder.setInteractive(!isDimmed, in: pivot) }
                    spin.isFocused = !isDimmed
                    pivot.components.set(spin)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement()
        .accessibilityLabel("Structure preview. Start the experiment to see it move.")
    }
}

// MARK: - Structure

/// The decoded snapshot, trimmed to a drawable subset around its centre.
struct PreviewStructure: Equatable, Sendable {
    var positions: [SIMD3<Float>]
    var types: [Int]
    var bonds: [(Int, Int)]
    var units: String

    /// Previews up to this size are shown whole; larger ones keep the
    /// compact 3D cluster of atoms nearest the centre.
    static let maxAtoms = 400
    static let maxBonds = 600

    static func == (a: Self, b: Self) -> Bool {
        a.positions == b.positions && a.types == b.types && a.units == b.units
            && a.bonds.map { [$0.0, $0.1] } == b.bonds.map { [$0.0, $0.1] }
    }

    private struct File: Decodable {
        var positions: [[Float]]
        var types: [Int]
        var bonds: [[Int]]?
        var units: String?
    }

    static func load(from url: URL) -> PreviewStructure? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> PreviewStructure? {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              !file.positions.isEmpty, file.positions.count == file.types.count,
              file.positions.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let all = file.positions.map { SIMD3($0[0], $0[1], $0[2]) }
        let bonds = (file.bonds ?? []).compactMap { pair -> (Int, Int)? in
            guard pair.count == 2, all.indices.contains(pair[0]), all.indices.contains(pair[1]), pair[0] != pair[1]
            else { return nil }
            return (pair[0], pair[1])
        }
        return subset(positions: all, types: file.types, bonds: bonds, units: file.units ?? "metal")
    }

    /// Keeps the atoms nearest the centre (a ball, never a flat slice) and the
    /// bonds between them, within the entity budget.
    static func subset(positions: [SIMD3<Float>], types: [Int], bonds: [(Int, Int)], units: String) -> PreviewStructure {
        let low = positions.reduce(positions[0], simd_min), high = positions.reduce(positions[0], simd_max)
        let center = (low + high) / 2
        var keep = Array(positions.indices)
        if keep.count > maxAtoms {
            keep = Array(keep.sorted { simd_length_squared(positions[$0] - center) < simd_length_squared(positions[$1] - center) }
                .prefix(maxAtoms)).sorted()
        }
        var newIndex: [Int: Int] = [:]
        for (new, old) in keep.enumerated() { newIndex[old] = new }
        let kept = bonds.compactMap { a, b -> (Int, Int)? in
            guard let x = newIndex[a], let y = newIndex[b] else { return nil }
            return (x, y)
        }
        return PreviewStructure(positions: keep.map { positions[$0] }, types: keep.map { types[$0] },
                                bonds: Array(kept.prefix(maxBonds)), units: units)
    }
}

// MARK: - Motion

/// Turns the structure slowly and steadily about the vertical axis. When its
/// card gains focus the structure fades in and glides forward through the
/// opening; out of focus it fades and settles back inside. Under Reduce
/// Motion it neither turns nor glides, and only fades.
struct PortalSpinComponent: Component {
    static let dimmedOpacity: Float = 0.35
    var radiansPerSecond: Float = 9 * .pi / 180
    var tilt = simd_quatf(angle: 0.32, axis: [1, 0, 0])
    var angle: Float = 0
    var reduceMotion = false
    var isFocused = true
    var opacity: Float = 1
    /// Depth of the structure's centre when focused, and when resting inside.
    var focusedDepth: Float = 0
    var restingDepth: Float = 0
}

struct PortalSpinSystem: System {
    private static let query = EntityQuery(where: .has(PortalSpinComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(min(context.deltaTime, 0.1))
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var spin = entity.components[PortalSpinComponent.self] else { continue }
            var changed = false
            if !spin.reduceMotion {
                spin.angle = (spin.angle + spin.radiansPerSecond * dt).truncatingRemainder(dividingBy: 2 * .pi)
                entity.orientation = spin.tilt * simd_quatf(angle: spin.angle, axis: [0, 1, 0])
                changed = true
            }
            let targetOpacity: Float = spin.isFocused ? 1 : PortalSpinComponent.dimmedOpacity
            if spin.opacity != targetOpacity {
                let step = dt / 0.35
                spin.opacity = spin.opacity < targetOpacity
                    ? min(targetOpacity, spin.opacity + step) : max(targetOpacity, spin.opacity - step)
                entity.components.set(OpacityComponent(opacity: spin.opacity))
                changed = true
            }
            let targetDepth = spin.isFocused ? spin.focusedDepth : spin.restingDepth
            if entity.position.z != targetDepth {
                let delta = targetDepth - entity.position.z
                // Gentle exponential ease, settling in about half a second.
                entity.position.z = spin.reduceMotion || abs(delta) < 1e-4
                    ? targetDepth : entity.position.z + delta * min(1, dt * 6)
            }
            if changed { entity.components.set(spin) }
        }
    }
}

// MARK: - Scene

@MainActor enum PortalSceneBuilder {
    static let pivotName = "portal-structure-pivot"
    /// Bounding-sphere diameter of the structure as a share of the opening height.
    static let structureFill: Float = 0.74
    /// How far the structure's centre sits behind the opening, as a share of its diameter.
    static let crossingInset: Float = 0.12

    private static var registered = false
    private static var sharedEnvironment: Task<EnvironmentResource?, Never>?
    private static var sharedTextures: (backdrop: TextureResource, floor: TextureResource, glow: TextureResource)?
    private static let unitSphere = MeshResource.generateSphere(radius: 1)
    private static let unitCylinder = MeshResource.generateCylinder(height: 1, radius: 1)
    /// Gaze target around a unit atom sphere.
    private static let hitSphere = ShapeResource.generateSphere(radius: 1.12)
    private static let glowColor = UIColor(red: 0.72, green: 0.92, blue: 1.0, alpha: 1)
    private static let glowStrength: Float = 1.8

    /// True element colour under a glossy clearcoat, so the gaze light leaves a sheen.
    private static func glossy(_ c: RGBColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1))
        material.roughness = 0.38
        material.metallic = 0.0
        material.specular = 0.6
        material.clearcoat = 0.7
        material.clearcoatRoughness = 0.06
        return material
    }

    /// Only the card in focus answers gaze; side cards keep their single tap shape.
    static func setInteractive(_ interactive: Bool, in pivot: Entity) {
        for child in pivot.children {
            guard var target = child.components[InputTargetComponent.self], target.isEnabled != interactive
            else { continue }
            target.isEnabled = interactive
            child.components.set(target)
        }
    }

    /// The parts of a portal the structure is added to later.
    struct Shell {
        let root: Entity
        let pivot: Entity
        let light: Entity
        let diameter: Float
    }

    /// The opening, its backdrop and an empty pivot: cheap and synchronous.
    static func makeShell(width: Float, height: Float, cornerRadius: Float, reduceMotion: Bool,
                          focused: Bool) -> Shell {
        if !registered {
            PortalSpinComponent.registerComponent()
            PortalSpinSystem.registerSystem()
            registered = true
        }
        let root = Entity()
        let world = Entity()
        world.components.set(WorldComponent())
        root.addChild(world)

        environmentTask()
        let light = Entity()
        world.addChild(light)
        if let textures = textures() { addBackdrop(to: world, width: width, height: height, textures: textures) }

        let pivot = Entity()
        pivot.name = pivotName
        var spin = PortalSpinComponent()
        // Focused, the centre sits slightly behind the opening, so under half
        // of the structure reaches out toward the viewer, a few centimetres
        // at most. Resting, all of it stays inside.
        let diameter = height * structureFill
        spin.focusedDepth = -diameter * crossingInset
        spin.restingDepth = -diameter * 0.6
        spin.reduceMotion = reduceMotion
        spin.isFocused = focused
        // Starts invisible; the spin system fades it in once atoms arrive.
        spin.opacity = 0
        pivot.position = [0, 0, focused ? spin.focusedDepth : spin.restingDepth]
        pivot.orientation = spin.tilt
        pivot.components.set(spin)
        pivot.components.set(OpacityComponent(opacity: 0))
        world.addChild(pivot)

        let portal = Entity()
        portal.components.set(ModelComponent(
            mesh: .generatePlane(width: width, height: height, cornerRadius: cornerRadius),
            materials: [PortalMaterial()]))
        portal.components.set(PortalComponent(target: world, clippingMode: .plane(.positiveZ),
                                              crossingMode: .plane(.positiveZ)))
        root.addChild(portal)
        return Shell(root: root, pivot: pivot, light: light, diameter: diameter)
    }

    /// Decodes the structure off the main actor, lights the portal with the
    /// shared environment and adds the atoms, which then fade in.
    static func populate(_ shell: Shell, structureURL: URL, scriptURL: URL?, delay: Duration) async {
        if delay > .zero { try? await Task.sleep(for: delay) }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (PreviewStructure, ScriptDirectives)? in
            guard let structure = PreviewStructure.load(from: structureURL) else { return nil }
            let script = scriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            return (structure, ScriptDirectives.parse(script))
        }.value
        guard let loaded, !Task.isCancelled else { return }
        let (structure, directives) = loaded
        if let environment = await environment() {
            shell.light.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.6))
        }
        addStructure(structure, to: shell.pivot, diameter: shell.diameter, directives: directives, light: shell.light)
        if let spin = shell.pivot.components[PortalSpinComponent.self] { setInteractive(spin.isFocused, in: shell.pivot) }
    }

    private static func addStructure(_ structure: PreviewStructure, to pivot: Entity, diameter: Float,
                                     directives: ScriptDirectives, light: Entity) {
        let table = AtomStyleTable(directives: directives, typeCount: structure.types.max() ?? 1, units: structure.units)
        let positions = structure.positions
        let low = positions.reduce(positions[0], simd_min), high = positions.reduce(positions[0], simd_max)
        let center = (low + high) / 2
        let styles = structure.types.map(table.style(forType:))
        var bound: Float = 0
        for (i, p) in positions.enumerated() { bound = max(bound, simd_length(p - center) + Float(styles[i].radius)) }
        let scale = diameter / 2 / max(bound, 1e-6)
        guard scale.isFinite, scale > 0 else { return }

        let receiver = ImageBasedLightReceiverComponent(imageBasedLight: light)
        let lighting = EnvironmentLightingConfigurationComponent(environmentLightingWeight: 0)
        // One hover group per structure: the system moves a single soft light
        // across neighbouring atoms and bonds as the eyes travel, rather than
        // lighting one sphere at a time. Gaze never reaches the app.
        let glow = HoverEffectComponent(.spotlight(
            HoverEffectComponent.SpotlightHoverEffectStyle(color: glowColor, strength: glowStrength),
            groupID: HoverEffectComponent.GroupID()))
        func finish(_ entity: ModelEntity) {
            entity.components.set(PortalCrossingComponent())
            entity.components.set(receiver)
            entity.components.set(lighting)
            entity.components.set(glow)
            pivot.addChild(entity)
        }

        var materials: [Int: PhysicallyBasedMaterial] = [:]
        for (i, position) in positions.enumerated() {
            let type = structure.types[i]
            let material = materials[type] ?? glossy(styles[i].color)
            materials[type] = material
            let atom = ModelEntity(mesh: unitSphere, materials: [material])
            atom.position = (position - center) * scale
            atom.scale = SIMD3(repeating: Float(styles[i].radius) * scale)
            // Atoms are the gaze targets; the slightly larger sphere makes
            // small atoms easy to look at without swallowing neighbours.
            atom.components.set(CollisionComponent(shapes: [hitSphere], isStatic: true))
            atom.components.set(InputTargetComponent(allowedInputTypes: .indirect))
            finish(atom)
        }

        let smallest = Float(styles.map(\.radius).min() ?? 0.3)
        let bondRadius = min(0.11, smallest * 0.4) * scale
        var bondMaterial = PhysicallyBasedMaterial()
        bondMaterial.baseColor = .init(tint: UIColor(white: 0.80, alpha: 1))
        bondMaterial.roughness = 0.3
        bondMaterial.metallic = 0.5
        bondMaterial.clearcoat = 0.4
        bondMaterial.clearcoatRoughness = 0.1
        for (a, b) in structure.bonds {
            let p = (positions[a] - center) * scale, q = (positions[b] - center) * scale
            let delta = q - p, length = simd_length(delta)
            // Bonds across a periodic boundary would cut through the picture.
            guard length > 0, length < diameter * 0.4 else { continue }
            let bond = ModelEntity(mesh: unitCylinder, materials: [bondMaterial])
            bond.position = (p + q) / 2
            bond.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
            bond.scale = [bondRadius, length, bondRadius]
            finish(bond)
        }
    }

    /// A dark, domed room behind the opening: a gradient sky, a soft glow
    /// behind the structure and a floor grid that recedes into the distance.
    private static func addBackdrop(to world: Entity, width: Float, height: Float,
                                    textures: (backdrop: TextureResource, floor: TextureResource, glow: TextureResource)) {
        var sky = UnlitMaterial()
        sky.color = .init(tint: .white, texture: .init(textures.backdrop))
        sky.faceCulling = .none
        let dome = ModelEntity(mesh: .generateSphere(radius: 1), materials: [sky])
        dome.scale = SIMD3(repeating: max(width, height) * 2.2)
        world.addChild(dome)

        var glow = UnlitMaterial()
        glow.color = .init(tint: UIColor(red: 0.35, green: 0.75, blue: 1.0, alpha: 1), texture: .init(textures.glow))
        glow.blending = .transparent(opacity: .init(scale: 0.55, texture: .init(textures.glow)))
        let halo = ModelEntity(mesh: .generatePlane(width: height * 1.5, height: height * 1.5), materials: [glow])
        halo.position = [0, 0, -height * 0.75]
        world.addChild(halo)

        var grid = UnlitMaterial()
        grid.color = .init(tint: UIColor(red: 0.45, green: 0.8, blue: 1.0, alpha: 1), texture: .init(textures.floor))
        grid.blending = .transparent(opacity: .init(scale: 1.0, texture: .init(textures.floor)))
        let depth = height * 3.2
        let floor = ModelEntity(mesh: .generatePlane(width: width * 2.4, depth: depth), materials: [grid])
        floor.position = [0, -height * 0.43, -depth * 0.32]
        world.addChild(floor)

        // A soft pool of light on the floor beneath the structure anchors it in depth.
        var pool = UnlitMaterial()
        pool.color = .init(tint: UIColor(red: 0.4, green: 0.78, blue: 1.0, alpha: 1), texture: .init(textures.glow))
        pool.blending = .transparent(opacity: .init(scale: 0.45, texture: .init(textures.glow)))
        let spot = ModelEntity(mesh: .generatePlane(width: height * 1.1, depth: height * 0.9), materials: [pool])
        spot.position = [0, -height * 0.429, -height * 0.12]
        world.addChild(spot)
    }

    /// One lighting environment for every portal, started with the first
    /// shell so it is ready by the time a structure arrives.
    private static func environment() async -> EnvironmentResource? {
        await environmentTask().value
    }

    @discardableResult
    private static func environmentTask() -> Task<EnvironmentResource?, Never> {
        if let sharedEnvironment { return sharedEnvironment }
        let task = Task { @MainActor () -> EnvironmentResource? in
            guard let image = gradientImage(width: 64, height: 32, stops: [
                (0.0, [1.0, 0.97, 0.92, 1]), (0.35, [0.62, 0.70, 0.82, 1]),
                (0.55, [0.30, 0.36, 0.48, 1]), (1.0, [0.06, 0.07, 0.10, 1]),
            ]) else { return nil }
            return try? await EnvironmentResource(equirectangular: image, withName: "atomify-portal-light")
        }
        sharedEnvironment = task
        return task
    }

    private static func textures() -> (backdrop: TextureResource, floor: TextureResource, glow: TextureResource)? {
        if let sharedTextures { return sharedTextures }
        let color = TextureResource.CreateOptions(semantic: .color)
        guard let skyImage = gradientImage(width: 8, height: 256, stops: [
                  (0.0, [0.010, 0.016, 0.040, 1]), (0.38, [0.030, 0.070, 0.150, 1]),
                  (0.50, [0.055, 0.135, 0.250, 1]), (0.62, [0.025, 0.055, 0.115, 1]),
                  (1.0, [0.004, 0.006, 0.016, 1]),
              ]),
              let floorImage = gridImage(size: 512, cells: 10),
              let glowImage = radialImage(size: 256),
              let backdrop = try? TextureResource(image: skyImage, options: color),
              let floor = try? TextureResource(image: floorImage, options: color),
              let glow = try? TextureResource(image: glowImage, options: color) else { return nil }
        sharedTextures = (backdrop, floor, glow)
        return sharedTextures
    }

    // MARK: Images

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Top-to-bottom gradient; locations run from the top row (0) to the bottom (1).
    private static func gradientImage(width: Int, height: Int, stops: [(CGFloat, [CGFloat])]) -> CGImage? {
        guard let ctx = context(width: width, height: height),
              let gradient = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colorComponents: stops.flatMap(\.1), locations: stops.map(\.0),
                                        count: stops.count) else { return nil }
        // Core Graphics has its origin at the bottom left.
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return ctx.makeImage()
    }

    /// Opaque greyscale images: brightness is the strength, so the same
    /// texture serves as colour and as opacity (read from the red channel).
    /// Grid lines fade with distance from the centre.
    private static func gridImage(size: Int, cells: Int) -> CGImage? {
        guard let ctx = context(width: size, height: size),
              let fade = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    colorComponents: [1, 1, 1, 1, 0.35, 0.35, 0.35, 1, 0, 0, 0, 1],
                                    locations: [0, 0.45, 1], count: 3) else { return nil }
        let full = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(full)
        let step = CGFloat(size) / CGFloat(cells)
        ctx.setFillColor(gray: 1, alpha: 1)
        for i in 0...cells {
            let x = CGFloat(i) * step
            ctx.fill(CGRect(x: x - 3, y: 0, width: 6, height: CGFloat(size)))
            ctx.fill(CGRect(x: 0, y: x - 3, width: CGFloat(size), height: 6))
        }
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.setBlendMode(.multiply)
        ctx.drawRadialGradient(fade, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2,
                               options: [.drawsAfterEndLocation])
        return ctx.makeImage()
    }

    private static func radialImage(size: Int) -> CGImage? {
        guard let ctx = context(width: size, height: size),
              let gradient = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        colorComponents: [1, 1, 1, 1, 0.4, 0.4, 0.4, 1, 0, 0, 0, 1],
                                        locations: [0, 0.35, 1], count: 3) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let c = CGPoint(x: size / 2, y: size / 2)
        ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(size) / 2,
                               options: [])
        return ctx.makeImage()
    }
}
