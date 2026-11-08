# Atomify for Apple Vision Pro

Real molecular dynamics in your room: LAMMPS runs on the headset and the atoms float in front of you. A fresh start, replacing the earlier [AtomifyVisionPro](https://github.com/andeplane/AtomifyVisionPro) prototype; the demos come from [Atomify](https://github.com/andeplane/atomify).

Status: focused release candidate. Five experiences open from a carousel into a mixed immersive lab with one interaction model: one hand pinches an atom to pull it, two hands pinch to move, turn and resize the experiment, and hands and forearms push atoms. A compact panel holds play/pause, restart, speed, recenter and the way back. See [the release description](docs/RELEASE.md). Headset acceptance remains outstanding. The earlier [UX proposal](docs/UX.md) and [roadmap](docs/ROADMAP.md) are historical.

## Build

```sh
cd vision-atomify
LAMMPS/build-xcframework.sh      # once, and after changing LAMMPS/; takes a while
open Atomify.xcodeproj
```

`build-xcframework.sh` clones the pinned LAMMPS release into `LAMMPS/build/`, adds the bridge, and writes `Packages/AtomifyKit/Frameworks/CLammps.xcframework` (visionOS, visionOS Simulator and macOS slices). Neither is committed. It needs Xcode with the visionOS platform and CMake 3.28 or newer.

## Layout

| Path | What |
| --- | --- |
| `LAMMPS/bridge/` | C interface (`atomify_lammps.h`) and `fix atomify`, compiled into the LAMMPS library |
| `LAMMPS/prepare_lammps.py` | Pinned LAMMPS version and the two small source edits |
| `Packages/AtomifyKit/` | Swift wrapper: simulation thread, snapshots, script `#/atom` and `#/bond` lines, instance transforms |
| `Atomify/` | visionOS app: experience carousel (`Library/`), controls panel (`Controls/`), immersive lab with instanced rendering and gestures (`Lab/`, `Interaction/`) |
| `Demos/` | Bundled simulations and `demos.json` |

## Checks

- `LAMMPS/build-host.sh` builds LAMMPS with the bridge for the current machine (Linux or macOS) and runs the bridge tests.
- `swift test` in `Packages/AtomifyKit` runs the Swift tests against the real engine. On a Mac with only Command Line Tools, run `python3 LAMMPS/package-host-library.py` after the host build to package a macOS-only test framework. Use the full Xcode build script for device distribution.
- `python3 LAMMPS/validate-release.py` checks the five featured trajectories and three controlled carbon–hydrogen pull/return trials against the real engine.
- `scripts/check-app-lifecycle.sh` runs the production `AppModel` against the host engine on macOS (load, replace, restart, pause, background, stop and cleanup).
- CI (`.github/workflows/atomify.yml`) runs both and builds the app for the visionOS Simulator and device.

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
