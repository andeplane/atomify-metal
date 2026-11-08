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
| `atomify-preset.cmake` | The LAMMPS configuration: no MPI, OpenMP threads, static, no optional libraries, and the packages Atomify needs. |
| `build-libomp.sh` | Builds LLVM's OpenMP runtime (libomp) for one Apple slice or the macOS host. |
| `host-openmp.sh` | OpenMP settings for the host build (compiler runtime on Linux, libomp on macOS). |
| `prepare_lammps.py` | Fetches LAMMPS, applies the patches, copies bridge and extra styles into `src/`. |
| `build-host.sh` | Builds for this machine (Linux or macOS) and runs the bridge tests. |
| `build-xcframework.sh` | Builds `Frameworks/CLammps.xcframework` for macOS, iOS, iOS Simulator, visionOS and visionOS Simulator. |
| `check-examples.sh`, `tools/` | Runs every bundled example with the host build (see below). |
| `bench-threads.sh` | Measures steps per second of the examples with 1, 2, 4, ... threads. |
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

## Checking the examples

```sh
src/shared/lammps/check-examples.sh [--steps 100] [--timeout 120] [--filter ID] [--jobs N] [--keep]
```

Runs each example of `src/macos/AtomifyMac/Examples/examples.json` in a fresh
working copy and its own process (`tools/example_check.cpp` through the
bridge, driven by `tools/check_examples.py`) until its input completes or N
steps after its first run started, and prints a table: status (ok, failed,
timeout, skipped), whether it ended with the input or at the step limit,
atoms, steps, seconds, and the error with its input line. LAMMPS output of
failing examples stays in `atomify-check.log` in their working copy. Exits
1 if any example failed or timed out. On a Mac, `swift run
atomify-check-examples` and the ExampleRunTests target do the same through
AtomifyKit's `ExampleRunner`. An example marked
`"atomifyMetal": {"skip": "reason"}` in examples.json is skipped by all three.

## Threads

LAMMPS runs on OpenMP threads through its OPENMP package. Apple ships no
OpenMP runtime, so `build-libomp.sh` builds LLVM's libomp (Apache 2.0 with
LLVM exceptions) for each slice and it is folded into `libCLammps.a`.
`ATOMIFY_OPENMP=OFF` in the environment builds the serial engine instead.

`atomify_sim_create_threaded(echo, n)` starts LAMMPS with `-suffix omp
-package omp n`, so every style with an `/omp` variant uses it, also after
`clear`. Threads cost microseconds per parallel region each step, which
small systems with cheap potentials cannot repay: on an M4 Pro a 400 atom
Lennard-Jones liquid runs 2-3x slower on 4 threads and a 100 atom ReaxFF
system 5-8x slower, while 4000 atoms and more gain 2-4x. So the first
initialization with atoms (`run` or `minimize`) picks the count for the
system (`atomify_before_init`, patch 0005): one thread per 1000 atoms for
pairwise potentials, per 250 for ReaxFF and per 100 with long range Coulomb
or manybody potentials, at least 1 and at most n. LAMMPS cannot change the
count once `/omp` styles exist, so when the system wants fewer, the bridge
starts a new instance on that many and runs the script and commands so far
again; the output says so, and shows the setup twice. Systems that start
without atoms keep n. `atomify_sim_threads` reports the count in use.
AtomifyEngine's `Simulation` defaults n to the performance core count, at
most 8.

```sh
src/shared/lammps/bench-threads.sh --examples src/ios/Examples --threads 1,2,4 --steps 2000
```

prints steps per second for each example and thread count, with the count
the bridge chose in brackets.

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
| `0005-init-atomify-threads` | `LAMMPS::init` first calls `atomify_before_init`, which picks the OpenMP thread count for the system at the first initialization with atoms (see Threads). |

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
