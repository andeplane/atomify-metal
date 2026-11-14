# Atomify for macOS

Two Mac apps live here, both on the shared packages in the root `Package.swift` (AtomifyKit with AtomifyEngine and AtomifyRender):

- **Atomify** (`Atomify/`): the app for everyone. It is the iPhone and iPad app in a Mac window, with the same views, model and examples, and a small Mac shell around them.
- **AtomifyMac** (`AtomifyMac/`): the developer bench for the graphics and the run lifecycle. It will grow into Atomify LAMMPS Pro, with a full script editor.

`RenderLab/` is a separate renderer playground with its own README.

## Atomify

The app compiles the iOS app's sources (`src/ios/AtomifyIOS`, all but its `@main` `AtomifyApp.swift`) and bundles the same `src/ios/Examples`.
Its own code is `Atomify/Sources`: the window (`AtomifyMacApp.swift`, one window, 1280×800 by default and at least 960×620, dark) with the menu bar, and `MacRootView.swift`, which shows the running simulation or the gallery in its place.
The simulation draws edge to edge under a transparent title bar; the gallery, an example's page and Settings have a real toolbar (back, title, search, Settings).
On Mac, the pages that are mostly text (an example, Settings, Files, Acknowledgements) sit in a centred column with 28 pt side margins, as the gallery does.

Using it: drag to rotate, right-drag or Option-drag to pan, scroll or pinch to zoom, click an atom to inspect it, double-click to frame the system again, and click empty space to hide the controls.
The Simulation menu has the floating controls with keys: Play/Pause (Space), Restart (⌘R), Faster and Slower (⌘] and ⌘[, through the speed choices), Simulations (⌘L), Reset View (⌘0), Info (⌘I), Dashboard (⌘D), View options (⇧⌘V), Hide/Show Controls (⌘.), and Back (Escape: closes the welcome, then an open panel; in the gallery goes back a page, or from its root back to the simulation).
Settings… (⌘,) opens the gallery's Settings page.

### Build and install

It needs `CLammps.xcframework` with a `macos` slice (below) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
The spec is `Atomify/project.yml`; the generated `Atomify.xcodeproj` is not committed. Generate again after adding files.

```sh
xcodegen generate --spec src/macos/Atomify/project.yml
xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme Atomify -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/macos build
```

The app is `build/macos/Build/Products/Release/Atomify.app`. It is Apple silicon only, because CLammps has a `macos-arm64` slice only.
`Atomify/build-and-install.sh` does both steps and copies the app into `/Applications`.
Signing uses `Atomify/Config/Signing.xcconfig` (ad hoc unless a team is set there or in a `Local.xcconfig` next to it).

### Screenshots without a window

`AtomifySnapshots` (`Atomify/Snapshots/main.swift`) draws each screen to a PNG at 1280×800 and 960×620 in windows that are never put on screen, from an app that never activates (no Dock icon, no menu bar), so it is safe to run while you work:

```sh
xcodebuild -project src/macos/Atomify/Atomify.xcodeproj -scheme AtomifySnapshots \
  -derivedDataPath build/macos-dd build
build/macos-dd/Build/Products/Debug/AtomifySnapshots.app/Contents/MacOS/AtomifySnapshots build/screens [name prefix]
```

The pictures show the layout, text, panels and the performance overlay (whose frame rate counts the frames the view really drew).
They do not show the atoms (the Metal view only draws on screen, so the canvas colour shows in its place), Liquid Glass (materials stand in), the accent colour of the window's default button (the window is never key), or hover.

## AtomifyMac, the bench

A SwiftUI app that runs the bundled Atomify examples with the shared engine and draws them with the Metal renderer.
Use it to work on the graphics: pick an example, run it, orbit around, switch between fast and high quality, color atoms by type or by a per-atom quantity, click an atom to inspect it, and watch live plots.
It is not a script editor; the console takes single LAMMPS commands while a run goes.

The app is the `AtomifyMac` executable in the root `Package.swift`.
Its code is in `AtomifyMac/`, and the logic it shows (catalog, scene building, coloring, picking, plots, the run lifecycle) is in `src/shared/AtomifyKit`.

### Build

LAMMPS comes as a static `CLammps.xcframework` that is built locally and not committed.
Build it once, and again after changing anything under `src/shared/lammps/`.
It needs Xcode (with the platforms the script builds for) and CMake 3.28 or newer, and it takes a while:

```sh
src/shared/lammps/build-xcframework.sh
```

The framework lands in `src/shared/lammps/Frameworks/CLammps.xcframework`, where `Package.swift` expects it.

Then either run from the terminal:

```sh
swift run AtomifyMac              # debug
swift run -c release AtomifyMac   # use this for large systems
```

or open `Package.swift` in Xcode, pick the `AtomifyMac` scheme and My Mac, and run.
A SwiftPM executable starts as a background process; the app switches itself to a regular app with a Dock icon, menu bar and a front window.

Tests for the shared logic run with `swift test` (the AtomifyKit session test runs the real engine, so it also needs the framework).

### Using it

- **Sidebar**: the examples, with search (title, description, author, keywords) and a keyword filter. Selecting an example copies its files into a temporary folder and runs it there; the copy is removed when the run ends.
- **Toolbar**: run or pause, restart, stop; fast or high quality; color by type or by a per-atom quantity (the computes, fixes and variables of the running script that provide per-atom values, plus `vx`, `vy`, `vz`); the colormap; atom radius scale; bonds and the simulation box on or off; reset the camera.
- **View**: drag to rotate, right-drag or two-finger drag to pan, scroll or pinch to zoom, click an atom to select it. The overlay shows frame rate, GPU time, atom count, timestep and simulation speed, and a legend for per-atom colors.
- **Inspector**: the selected atom (ID, type, position, radius, the colored quantity), live plots (temperature and energies by default; add any compute, fix, variable or thermo value from the menu), and the LAMMPS console with a field to queue a command.
- **Simulation menu**: pause (⇧⌘P), restart (⌘R), stop (⌘.), reset camera (⌘0), deselect (⌘D), and whether a run keeps going after its script ends (on by default, so the view stays alive).

Scripts can carry the web app's drawing hints as comments: `#/atom 1 oxygen` or `#/atom 2 1.5 #ff0000` for type styles, `#/bond 1 2 1.2` for distance bonds, and `#/camera position x y z` / `#/camera target x y z` for the starting view.

### Examples

`AtomifyMac/Examples` is a curated subset of the web app's [`public/examples`](https://github.com/andeplane/atomify/tree/main/public/examples), in the same `examples.json` format with the same relative file urls, credits (`author`, `authorUrl`) and descriptions.
Thumbnails are downscaled copies of the web app's images.

Left out: `nanoporous_sio2` (25 MB of data), `proteinfolding` (uses a pair style that is not in this LAMMPS build), and the two methane systems (1.7 MB each, close to `water_isobutane` and `alkane_chain_single`).
The rest run with the packages in `src/shared/lammps/atomify-preset.cmake` (MOLECULE, MANYBODY, KSPACE, RIGID, GRANULAR, MISC, CLASS2, EXTRA-MOLECULE, EXTRA-PAIR, EXTRA-FIX, EXTRA-COMPUTE, REAXFF, QEQ, MC, ASPHERE, CG-DNA).
The web app runs a few examples with KOKKOS (`suffix kk`); this build has no KOKKOS, so the working copy comments that line out.

Three large Lennard-Jones melts were added for stress-testing the renderer: `lj-melt-108k`, `lj-melt-500k` and `lj-melt-1m` (108 000, 500 000 and 1 000 188 atoms), scaled up from `bench/in.lj` in LAMMPS.
LAMMPS runs on one core here, so the 1M system advances slowly; it is there for the drawing, not the dynamics.

## Structure for Pro

Both apps sit on the same two packages:

- **AtomifyKit**: `SimulationSession` (one run: the engine thread, snapshots at display rate, stats, plots, console, selection, speed), the example catalog and sections, effects, the dashboard, and the small pure helpers the shells use (`AppNavigation` for Escape and speed steps).
- **AtomifyRender**: `ParticleView` and the Metal renderer, with its frame pacing and pointer and touch handling.

The shared SwiftUI views (the canvas and its controls, the Info, Dashboard and View panels, the gallery, an example's page, Settings) live in `src/ios/AtomifyIOS` today, compiled by both the iOS app and Atomify for Mac.
Once the iOS release settles they should move into a shared `src/shared/AtomifyUI` package target, so that Atomify LAMMPS Pro reuses the canvas, panels and gallery as they are, and adds the script editor, file handling and the console around the same `SimulationSession`.

## License

The examples come from the Atomify web app, which is GPLv3, and LAMMPS is GPLv2.
An app that bundles them and links LAMMPS is distributed under the GPL.
