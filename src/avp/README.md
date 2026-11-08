# Atomify for Apple Vision Pro

Real molecular dynamics in your room: LAMMPS runs on the headset and the atoms float in front of you. A fresh start, replacing the earlier [AtomifyVisionPro](https://github.com/andeplane/AtomifyVisionPro) prototype; the demos come from [Atomify](https://github.com/andeplane/atomify).

Status: focused release candidate. Five experiences open from a carousel into a mixed immersive lab with one interaction model: one hand pinches an atom to pull it, two hands pinch to move, turn and resize the experiment, and hands and forearms push atoms. A compact panel holds play/pause, restart, speed, recenter and the way back. See [the release description](docs/RELEASE.md). Headset acceptance remains outstanding. The earlier [UX proposal](docs/UX.md) and [roadmap](docs/ROADMAP.md) are historical.

## Build

The app uses the shared libraries from the root package (`../..`): `AtomifyEngine` runs LAMMPS, and
the visionOS-only logic (pinches, grabbing, placement and comfort, the demo catalog, whole molecules)
is in the local package `Packages/AtomifyVision`.

```sh
src/shared/lammps/build-xcframework.sh   # once, from the repository root; takes a while
open src/avp/Atomify.xcodeproj
```

`build-xcframework.sh` writes `src/shared/lammps/Frameworks/CLammps.xcframework` (macOS, iOS, visionOS and
their simulators). It is not committed.

```sh
xcodebuild -project src/avp/Atomify.xcodeproj -scheme Atomify -destination 'generic/platform=visionOS Simulator' build
```

Debug builds accept `-AtomifyAutostart <demo id>` (for example `water`) to open an experience at launch,
`-AtomifyPanelAhead` to put the controls straight ahead and `-AtomifyHidePanel` to leave them closed.

## The lab

The immersive lab is a `CompositorLayer` in a mixed `ImmersiveSpace` with the wearer's hands and arms
visible. A render thread (`Lab/LabRenderer.swift`) draws with AtomifyRender's `ParticleRenderer`: ray-cast
sphere and bond impostors with real depth, reverse Z, both eyes in one pass with vertex amplification when
the layer is layered (one pass per eye otherwise), foveated, 4x multisampled until frames run over budget.
The scene for each snapshot is built in the background with AtomifyKit's `SceneBuilder`
(`LabContent` in AtomifyVision). Pinches arrive as the layer's spatial events (`Lab/LabInput.swift`); hand
pushing and head pose come from ARKit. The library's card previews are still RealityKit.

## Layout

| Path | What |
| --- | --- |
| `Packages/AtomifyVision/` | visionOS-only logic on top of `AtomifyEngine`, with its tests |
| `Atomify/` | visionOS app: experience carousel (`Library/`), controls panel (`Controls/`), immersive lab drawn with Metal through CompositorServices, and hand interaction (`Lab/`, `Interaction/`) |
| `Demos/` | Bundled simulations and `demos.json` |
| `validation/` | Real-engine checks of the demos (C++ probes against the shared bridge) |

## Checks

- `swift test` in `Packages/AtomifyVision` runs the Swift tests against the real engine (macOS slice of CLammps).
  `ATOMIFY_ROOM_SOAK=1` adds the room soak test.
- `scripts/check-app-lifecycle.sh` runs the production `AppModel` against the host engine on macOS (load, replace, restart, pause, background, stop and cleanup).
- `validation/` holds the demo validations; see its README.

Compiling does not show how it looks or performs on the headset; that needs a device run.

## Script commands

Like the web app, scripts can carry drawing hints as LAMMPS comments:

```
#/atom 1 oxygen          element color and size for type 1
#/atom 2 1.5 #ff0000     custom size and color for type 2
#/bond 1 2 2.0           draw bonds between types 1 and 2 closer than 2.0
```

Real bonds from the LAMMPS topology are drawn automatically.

## License

LAMMPS is GPLv2 and the demos come from GPL projects (credits in `Demos/demos.json`), so app builds that include them are GPL.
