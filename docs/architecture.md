# Architecture and plan

Atomify Metal is one Swift package with three shared libraries and one app per platform.
The libraries hold everything the apps have in common, so an app is mostly UI.

```
             ┌───────────────────────── apps (UI only) ─────────────────────────┐
             │  src/macos  (examples browser, graphics playground)              │
             │  src/ios    (later)   src/avp (later, port of vision-atomify)    │
             │  tvOS / a LAMMPS editor app (later)                              │
             └───────────────┬──────────────────────────────────────────────────┘
                             │
                     AtomifyKit  (src/shared/AtomifyKit)
          glue: snapshot → render data, coloring, picking, plots, examples, camera hints
                ┌────────────┴─────────────┐
     AtomifyEngine                     AtomifyRender
  (src/shared/AtomifyEngine)        (src/shared/AtomifyRender)
  LAMMPS on its own thread,         Metal renderer for particles,
  snapshots, observables,           bonds and lines. Knows nothing
  interaction, script directives    about LAMMPS or atoms.
          │
     CLammps.xcframework  (src/shared/lammps)
  LAMMPS + C bridge + fix atomify, built per platform by a script
```

`AtomifyRender` and `AtomifyEngine` do not depend on each other.
`AtomifyKit` is the only place that knows about both.

## Where things come from

| Piece | Source |
| --- | --- |
| C bridge, `fix atomify`, LAMMPS build | `vision-atomify/LAMMPS/` in AppleVisionProProjects, extended |
| Engine Swift wrapper | `vision-atomify/Packages/AtomifyKit` (`LammpsSimulation`, `SimulationSnapshot`, `AtomStyles`, `Elements`) |
| Billboard renderer | `vision-atomify` `ImpostorRenderer` + `ImpostorShaders`, generalized |
| Product behavior (examples, plots, coloring, `#/atom`, `#/bond`, `#/camera`) | the web app, `andeplane/atomify` |
| Examples for the Mac app | `andeplane/atomify/public/examples` (`examples.json` format) |

## Libraries

### CLammps (`src/shared/lammps/`)

LAMMPS at a pinned release, plus the bridge (`atomify_lammps.h`, `fix atomify`).
`build-xcframework.sh` builds static slices for macOS, iOS, iOS Simulator, visionOS and visionOS Simulator.
`build-host.sh` builds for the current machine (also Linux) and runs the C++ bridge tests.
The xcframework is large and not committed.

The bridge exchanges, both ways:

- In: scripts and single commands, pause, cancel, speed limit, publish rate, bond rules, grabs and force spheres, freeze, walls.
- Out: a tag-sorted snapshot (positions, types, radii, bonds, box, thermo), the list of computes, fixes and variables with their current global values, and one per-atom quantity chosen for coloring.

### AtomifyEngine

Swift wrapper around CLammps. One `Simulation` is one LAMMPS instance on its own thread.
Owns script semantics (`#/atom`, `#/bond`, `#/camera` directives), elements, and units.

### AtomifyRender

Metal renderer for large numbers of spheres and cylinders. Agnostic: inputs are positions, radii, colors, bonds as index pairs, and line segments.

- **Fast mode**: ray-cast billboard impostors (4 vertices per sphere, real depth), ray-cast cylinders for bonds (one 4-vertex rectangle each, trimmed to the part between the spheres), spatial blocks with frustum culling (particles and bonds) and front-to-back order. Targets 1M+ particles; see docs/renderer/performance.md.
- **High quality mode**: the same impostors plus screen-space ambient occlusion, soft shadows and outlines, for smaller systems.
- **Picking**: an ID buffer pass, so clicking returns the particle under the cursor.
- Draws into any `MTLRenderCommandEncoder`, with one or two views (stereo with vertex amplification on Vision Pro), reverse Z optional. A ready-made SwiftUI `MetalView` with an orbit camera covers macOS and iOS.

### AtomifyKit

Glue shared by every app: converts snapshots to render input, coloring modes (by type, element, per-atom quantity with a color map), picking → atom info, plot series, example catalog loading and working copies.

## Apps

1. **macOS examples app** (now): pick an example, run it, orbit around, switch fast/high quality, color by type or quantity, click an atom to inspect it, see live plots of thermo and computes. This is where we iterate on the graphics.
2. **iOS / iPadOS** (next): same as macOS with touch UI.
3. **Vision Pro**: port `vision-atomify` onto the shared libraries (CompositorServices or RealityKit `LowLevelMesh` path).
4. **Editor app** (later): script editor, LAMMPS console, file handling, like the original Qt app.

## Testing

The C++ bridge is tested on Linux and macOS through `build-host.sh`.
Swift tests run with `swift test` on a Mac after building the xcframework.
Pure logic (packing, culling, colors, directives, camera math, catalogs) is separated from Metal and covered.

## Interfaces

The exact Swift interfaces between the libraries are in [interfaces.md](interfaces.md).
