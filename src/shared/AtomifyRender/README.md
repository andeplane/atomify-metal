# AtomifyRender

Metal renderer for very many spheres, the cylinders between them, and thin
lines. It knows nothing about atoms or LAMMPS: the input is particles
(positions, a style table and per-particle overrides), bonds as index pairs,
and line segments. `AtomifyKit` turns simulation snapshots into this input.

The interface the other libraries use is in
[docs/interfaces.md](../../../docs/interfaces.md); this file explains how it
works inside.

## Pieces

| File | What it holds |
| --- | --- |
| `SceneTypes.swift` | Public input and settings: `ParticleData`, `BondData`, `LineData`, `SceneData`, `RenderSettings`, `RenderView`, `RenderStats` |
| `ParticleRenderer.swift` | Pipelines, upload (`update`), drawing (`encode`, `encodeFrame`), the high quality passes and picking |
| `ShaderSource.swift` | All Metal shaders, as source compiled at run time |
| `GPULayout.swift` | Swift mirrors of the shader structs, and the CPU packing into them |
| `SpatialBlocking.swift` | Sorting particles into spatial blocks; frustum culling, front-to-back order and thinning of periodic copies |
| `DensityOcclusion.swift` | Per-particle ambient light from local density (fast mode's depth cue) |
| `AmbientOcclusionKernel.swift` | SSAO sample kernel and the buffer growth policy |
| `GPUResources.swift` | Growable triple-buffered MTLBuffers, offscreen targets, pick targets |
| `OrbitCamera.swift`, `Transforms.swift` | Camera and matrix math (Metal clip space, optional reverse Z) |
| `Colormap.swift` | Color maps and sRGB/linear helpers |
| `ParticleView.swift`, `ParticleViewMath.swift` | SwiftUI view around `MTKView` for macOS and iOS, with its pure helpers |

Everything that is not a Metal call or a view is a plain function and is
unit tested (`Tests/`). `RendererGPUTests` renders small scenes on the
machine's GPU, so it also checks that the shaders compile; it is skipped where
there is no Metal device.

## Data layout on the GPU

Per particle, 16 bytes:

```
struct Particle {            // GPUParticle in Swift
    packed_float3 position;  // scene units
    uint styleFlags;         // bits 0–15 style index, 16–23 flags, 24–31 ambient (255 = lit)
};
```

Colors and radii come from the style table (32 bytes per style: linear RGBA
and a radius), so the common case costs 16 bytes per particle. Optional
per-particle overrides are separate buffers, only bound when present:
radius as `float` (4 B), color as RGBA8 with sRGB-encoded color (4 B,
decoded in the shader). Flags: bit 0 selected (drawn in the highlight color,
1.2× larger), bit 1 hidden.

Bonds are 8 bytes (`uint a, b`); the bond vertex shader reads both particles,
so bond geometry follows the particles with no CPU work. Per-bond colors are
an optional RGBA8 buffer. Lines are 48 bytes per segment.

Uniforms are built only from `float4`, `float4x4` and `uint4`, so Swift and
MSL agree without padding rules; `GPULayoutTests` checks every stride and
offset.

## Upload

`update(_:)` writes into the next of three buffer sets while the GPU may still
read the others. Buffers are shared, write-combined, and only grow (by half
again, in multiples of 256 elements). Before reusing a set it waits for any
committed command buffer that read it; `encodeFrame` registers its command
buffer automatically, and `encode(into:views:commandBuffer:)` does when given
one.

Above 20 000 particles (or whenever periodic copies are drawn), particles are
reordered into a grid of spatial blocks with a counting sort (linear time;
about 2 048 particles per block, 8³ blocks for a million). Bond indices are
remapped to the new order on the CPU while they are copied. The sort order is
kept so picking can map back to the caller's indices.

With periodic copies, each block is additionally ordered so that its first
quarter and first sixteenth are even samples of the block, the same particles
every frame (a hash of the index picks them).

Density occlusion (`settings.densityOcclusion`) counts neighbours with a
summed-volume table, linear in the particle count, and is refreshed every
`occlusionRefreshInterval` updates or when the count changes.

## Drawing

Each view culls blocks against its frustum (blocks padded by their largest
radius), sorts the visible ones nearest first, and issues one instanced draw
per block (4 vertices per particle, `baseInstance` = block start). Nearest
first plus conservative depth keeps early-z effective: particles hidden behind
others cost almost nothing.

Spheres are camera-facing squares at the front of the sphere, sized to the
silhouette; the fragment shader ray-casts the sphere and writes the true
depth (`[[depth(greater)]]`, or `less` with reverse Z). Bonds are ray-cast
cylinders inside a box built from a 14-vertex triangle strip. Edges are
antialiased analytically: alpha carries pixel coverage, turned into a
multisample mask by alpha-to-coverage when `sampleCount > 1`.

Periodic copies are the same buffers drawn with an offset. When the copies in
view exceed `particleBudget`, the farthest copies drop to a quarter, then a
sixteenth, of their particles, drawn twice / four times larger; the primary
copy is never thinned. Bonds are drawn for every copy at full detail.

Lines are screen-space quads, clipped to the near plane, antialiased by
coverage (alpha-to-coverage, or blending without multisampling).

### Fast and high quality

- **Fast**: one pass into the target. Lighting is a key light, sky/ground fill,
  Fresnel specular and rim, darkened by density occlusion.
- **High** (`encodeFrame` only): the same geometry into an offscreen color
  target plus a normal / inverse-depth target (RGBA16Float), a half-resolution
  SSAO pass (16 hemisphere samples, radius `ambientOcclusionRadius` or four
  times the largest style radius, in scene units), then a composite into the
  target with a depth-aware blur of the occlusion and optional outlines where a
  neighbour pixel is much farther. Multisampled offscreen attachments are
  memoryless on Apple GPUs.

### Picking

`pick(at:completion:)` renders particle IDs (sorted index + 1, 0 = nothing)
into a 1×1 `R32Uint` target, using the last frame's view with a pick matrix
that blows the chosen pixel up to the whole target, so culling leaves only the
blocks under the cursor. It runs at once on the renderer's own queue, reads
the value back with a blit, maps it through the sort order, and calls
completion on the main queue. Bonds are drawn with ID 0, so they hide what is
behind them.

### Several views

`maxViews: 2` compiles the shaders with `[[amplification_id]]`.
`encode(into:views:)` with two views sets vertex amplification (view *i* to
render target slice *i* and viewport *i* unless `viewMappings` says
otherwise), culls against the union of the frusta and sorts by the first.
The host owns the pass, the viewports and the projections (reverse Z on
Vision Pro). `settings.nearFade` shrinks geometry close to the eye.

## Shaders

The source is a Swift string compiled with `makeLibrary(source:options:)`.
That works the same under `swift build`, `swift test` and Xcode and lets
`MAX_VIEWS` and `REVERSE_Z` be preprocessor macros. Compiling takes a fraction
of a second, once per renderer. `Sources/Shaders/` only holds a README because
`Package.swift` declares it as a resource folder.

## Using it

```swift
let renderer = try ParticleRenderer(device: device, colorFormat: .bgra8Unorm_srgb,
                                    depthFormat: .depth32Float, sampleCount: 4, reverseZ: true)
renderer.update(scene)                       // when the scene changes
renderer.settings.quality = .high
renderer.encodeFrame(commandBuffer: commandBuffer, target: passDescriptor, view: view)
renderer.pick(at: pixel) { index in print(index as Any) }
```

Or in SwiftUI: `ParticleView(scene: scene, camera: $camera, settings: settings, onPick: { … })`.

Colors are linear; draw into an sRGB pixel format.
