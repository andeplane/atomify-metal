# RenderLab

A macOS test bench for the `AtomifyRender` Metal renderer, with no LAMMPS.
Every scene is a synthetic `SceneData` built by a small, deterministic Swift generator, so the renderer can be checked on known input: geometry, colors, picking, and speed from ten thousand to eight million particles.

## Run

```sh
swift run RenderLab              # debug
swift run -c release RenderLab   # use this for the large crystal and for benchmarks
```

Or open `Package.swift` in Xcode, pick the `RenderLab` scheme and My Mac, and run.
RenderLab depends only on `AtomifyRender`, so it does not need `CLammps.xcframework`.
Like `AtomifyMac`, it switches itself from a background executable to a regular app with a Dock icon, menu bar and a front window.

Debug builds generate the multi-million particle crystals and jitter them much more slowly than release builds; timings from a debug build say little about the renderer.

## Scenes

| Scene | What it checks |
| --- | --- |
| **Water molecule** | One static H₂O: O–H 0.9572 Å, H–O–H 104.52°, CPK colors (O red, H white), ball-and-stick radii and two bonds. Positions never change. |
| **SiC crystal** | Zincblende 3C-SiC, a = 4.3596 Å, 1–12 unit cells per side (4×4×4 by default, 512 atoms). Si and C styles, bonds between nearest neighbours (a√3/4 ≈ 1.888 Å), and the box. Bonds stop at the box. |
| **Large crystal** | SiC or FCC (Al, a = 4.05 Å) with about 10k, 100k, 1M, 4M or 8M particles; SiC bonds on or off; none, 3×3×3 or 5×5×5 periodic images. *Animate* adds thermal noise (a fresh random offset per particle per frame, around fixed rest positions), so every frame jitters and uploads the whole scene. |
| **Colored atoms** | A 16×16×16-cell FCC block colored per particle by height, distance from the center, smooth random noise, or a sine pattern, through any `Colormap`, with a color bar. Per-particle colors can be switched off, and *Radius from value* sets per-particle radii (0.45–1.45 Å) from the same value. |
| **Picking** | *Dense cluster*: 4 000 overlapping spheres of four sizes and colors in a ball. *Layered slabs*: three sheets one behind the other (red in front with bonds, green, blue at the back), offset so the back ones show through the gaps. The highlight must always land on the particle that is visible under the cursor. |

Generation runs off the main thread; the overlay shows how long it took.

## Controls

- **View**: drag to rotate, right-, option- or shift-drag to pan, scroll or pinch to zoom, click to pick. Clicking empty space or a bond deselects (bonds are drawn with ID 0 in the pick pass, so they hide what is behind them).
- **Toolbar**: fast or high quality, bonds, box, reset camera (⌘0), show or hide the controls.
- **Selection**: index, position, style, color (sRGB hex, and whether it is a per-particle override), radius as given and as drawn (radius scale, and 1.2× while selected), and the scalar value in the colored scene. The selected particle gets `ParticleFlags.selected`.
- **Rendering**: the view (see below), quality, MSAA (1/2/4/8, whatever the GPU supports; lab view only), radius scale, ambient occlusion strength and radius, outline width, density occlusion, background (dark, black, gray, white), bonds, box, reset camera.
- **Benchmark**: the particle budget for periodic images (`ParticleRenderer.particleBudget`), an orbit duration, and *Run Benchmark* (⇧⌘B).

### Two views

- **Lab view** (default) is RenderLab's own `MTKView` around `ParticleRenderer`. It measures each frame and lets you choose MSAA. Input handling and the per-frame `RenderView` are the same as in `ParticleView` (`ParticleViewMath`, `OrbitCamera`).
- **ParticleView** is the library's SwiftUI view, exactly as the apps use it, including `onPick` and `onStats`. It reports only GPU time and drawn counts, always uses 4× MSAA where available, and animation is driven from the model at about 60 Hz.

## Statistics

The overlay averages over a quarter of a second:

| Row | Meaning |
| --- | --- |
| fps, frame | Frame rate and time between frames. Capped by the display's refresh rate. |
| cpu | Time spent in the frame on the CPU: jitter, upload and encoding, not the wait for a drawable. |
| gpu | `RenderStats.gpuTimeMs`: GPU time of the latest completed frame. |
| jitter | Writing the jittered positions (while animating; parallel over all cores). |
| upload | `ParticleRenderer.update`. This includes waiting for a buffer set the GPU still reads, spatial sorting, and density occlusion when it is refreshed (every 8 updates). Without animation it is the latest upload. |
| particles, bonds | `RenderStats` counts: instances drawn after culling, all periodic copies. |
| scene | Particles and bonds in the generated scene. |

The benchmark turns the camera once around the scene over the chosen duration and reports the mean, 95th percentile and maximum frame time, and the mean and 95th percentile of CPU and GPU time (and upload, while animating). *Copy* puts a plain-text report on the clipboard.
Frame times are capped by vsync; compare CPU and GPU times between configurations.

## Code

| Path | What it holds |
| --- | --- |
| `Scenes/` | Pure Swift, no UI: the scene generators and everything they need. |
| `Scenes/Lattices.swift` | Zincblende and FCC lattices, nearest-neighbour bonds from lattice indices (no neighbour search, linear time). |
| `Scenes/WaterMolecule.swift`, `SiliconCarbideScene.swift` | The water molecule and the small SiC crystal. |
| `Scenes/PerformanceScene.swift`, `ColoringScene.swift`, `PickingScene.swift` | The other scenes; `ColoringScene.swift` also holds the scalar fields. |
| `Scenes/LabSceneCatalog.swift` | Scene kinds, `SceneRequest` (equal requests give identical scenes), `GeneratedScene`, `SceneFactory`, and `SceneComposer` (display toggles and selection flags). |
| `Scenes/ThermalJitter.swift` | Per-frame noise, parallel and deterministic per frame. |
| `Scenes/FrameStatistics.swift` | Live averages, percentiles, benchmark results and the orbit path. |
| `Scenes/PickedParticle.swift`, `SceneBounds.swift`, `LabElement.swift`, `LabRandom.swift`, `LabOptions.swift` | Selection details, bounds and periodic offsets, element styles, the seeded random generator, option enums. |
| `App/` | SwiftUI and AppKit: the app, `LabModel`, the lab `MTKView` host and its coordinator, controls and overlays. |

The code under `Scenes/` is ordinary logic and should be covered by unit tests.
`Package.swift` has no test target for RenderLab yet; one would be `.testTarget(name: "RenderLabTests", dependencies: ["RenderLab"], path: "src/macos/RenderLabTests")`, using `@testable import RenderLab`.
