# Demo validation

Checks that the bundled demos behave in the real engine: each script compiles small C++ probes
(`probes/`) against the shared bridge header (`src/shared/lammps/bridge/include`) and a host build of
LAMMPS with the bridge, runs the demos, and writes evidence as JSON. Nothing here runs on a headset.

Build the host library first (`src/shared/lammps/build-host.sh`, which writes
`src/shared/lammps/build/host/liblammps.a`), or pass `--build-dir` / `--build` pointing at any folder
with a `liblammps.a` built with the bridge for this machine (e.g. `src/shared/lammps/build/macos`).

| Script | What it checks |
| --- | --- |
| `validate-release.py` | The release lineup and featured experiments run and stay finite; controlled C–H pull/return trials |
| `validate-phases.py` | Crystallization and ice melting reach their expected structural order |
| `test-biology.py` | Coarse-grained biology demos keep their topology and temperature |
| `validate-oxidation.py` | Methane oxidation energy drift and heat gates (statistical; use the default seeds and steps) |
| `test-dna.py` | DNA duplex stability (`dna-duplex` demo) |

Status against the shared LAMMPS (stable_30Sep2026_update1), November 2026: `validate-release.py`,
`validate-phases.py` and `test-biology.py` pass. `test-dna.py` fails: this LAMMPS release rejects the
`pair_coeff * * oxdna2/stk seqdep ...` line in `Demos/dna-duplex/experiment.in` (it is not in the release
lineup). `validate-oxidation.py` failed its gates on a shortened single-seed run, which is not conclusive.
