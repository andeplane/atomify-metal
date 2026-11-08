# LAMMPS for Atomify

LAMMPS (`stable_30Sep2026_update1`, the release lammps.js uses) with a small
C bridge, built as the static `CLammps` library that AtomifyEngine wraps.

**License.** LAMMPS is distributed under the GNU General Public License,
version 2 (GPLv2). The bridge, the patches and the extra styles here are
GPLv2 as well, and so is any app that links `CLammps`. Ship the
corresponding source with every binary.

## Layout

| Path | What |
| --- | --- |
| `bridge/include/atomify_lammps.h` | The C interface: the only public header of `CLammps`. |
| `bridge/include/module.modulemap` | `module CLammps`, for Swift. |
| `bridge/src/` | `fix atomify` (snapshots, observables, per-atom values, interaction forces, command queue) and the C functions. |
| `bridge/tests/bridge_test.cpp` | Host tests of the C interface, run by `build-host.sh`. |
| `patches/` | Small edits to LAMMPS sources, applied by `prepare_lammps.py`. |
| `extra_src/` | Extra styles compiled into LAMMPS (from lammps.js). |
| `atomify-preset.cmake` | The LAMMPS configuration: serial, static, no optional libraries, and the packages Atomify needs. |
| `prepare_lammps.py` | Fetches LAMMPS, applies the patches, copies bridge and extra styles into `src/`. |
| `build-host.sh` | Builds for this machine (Linux or macOS) and runs the bridge tests. |
| `build-xcframework.sh` | Builds `Frameworks/CLammps.xcframework` for macOS, iOS, iOS Simulator, visionOS and visionOS Simulator. |
| `package-host-library.py` | Wraps a macOS host build as a one-slice xcframework (quick local testing). |

`build/` and `Frameworks/` are generated and ignored by git.

## Building

```sh
# Any machine with git, CMake >= 3.20, a C++17 compiler and python3:
src/shared/lammps/build-host.sh            # ends with "All bridge tests passed"

# macOS with Xcode and the iOS and visionOS platforms installed:
src/shared/lammps/build-xcframework.sh     # then: swift build / swift test
SLICES=macos src/shared/lammps/build-xcframework.sh   # macOS only, much faster
```

The first build compiles all of LAMMPS and takes a while; later builds only
recompile what changed. `prepare_lammps.py` reuses `build/lammps` if it holds
the pinned tag; delete it after changing `LAMMPS_TAG`.

## Patches

Like lammps.js (`cpp/patches`, `LAMMPS-patches.md`), changes to LAMMPS
itself are patch files applied in name order. Applying is idempotent: a
patch that does not apply is checked in reverse, and if it is not already
applied either, preparing stops, so a build never silently lacks a patch.

| Patch | Why |
| --- | --- |
| `0001-input-expose-last-line` | `Input::get_last_line()`, the input line being executed (lammps.js patch 0001). The bridge reports it with errors (`atomify_sim_last_error_line`) and in snapshots (`input_line`). |
| `0002-modify-allow-atomify-pre-box` | Lets `fix atomify` exist before the box, so the bridge installs it before any script runs (as lammps.js does for `js/async`). |
| `0003-input-no-system` | `shell` commands call `system()`, which the iOS and visionOS SDKs mark unavailable; they now report failure. |
| `0004-run-atomify-integrate` | `run` integrates through `atomify_integrate`, which lets fix atomify end the integrator between two steps, execute commands the app queued and continue the same run (like `run N every M "command"`). |

To change a patch, edit the files in `build/lammps` and regenerate it with
`git -C build/lammps diff src/<file> > patches/<name>.patch`.

## Extra styles

`extra_src/` holds moltemplate's `pair_style lj/charmm/coul/charmm/inter`
(and the `lj/remix` and `lj/softcore2` base classes it needs), as in
lammps.js' `cpp/extra_src`. They are copied into `src/` and compiled with
the rest of LAMMPS.

## Packages

MOLECULE, MANYBODY, KSPACE, RIGID, GRANULAR, MISC, CLASS2, EXTRA-MOLECULE,
EXTRA-PAIR, EXTRA-FIX, EXTRA-COMPUTE, REAXFF, QEQ, MC, ASPHERE, CG-DNA and
SHOCK. Compared to lammps.js this leaves out VORONOI and COLVARS, which need
external libraries and none of the Atomify examples use.

## Threading

One `atomify_sim` owns one LAMMPS instance. Script execution blocks and runs
on one simulation thread; everything else (snapshots, the command queue,
pause, interaction input) may be called from any thread. See the comments in
`atomify_lammps.h`.
