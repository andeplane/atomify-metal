#!/usr/bin/env python3
"""Fetch the pinned LAMMPS release and add the Atomify bridge to its sources.

Usage: prepare_lammps.py <checkout-dir>

The checkout is reused if it already has the pinned tag. The bridge files
are copied into src/ (LAMMPS' CMake build compiles every src/*.cpp and
registers the FixStyle in fix_atomify.h) and two small source edits are
applied:

  * modify.cpp: allow `fix atomify` before the simulation box exists, so the
    bridge can install it before any user script runs.
  * input.cpp: the `shell` command calls system(), which the visionOS SDK
    marks unavailable. Route it through a stub that reports failure.
"""

import pathlib
import shutil
import subprocess
import sys

LAMMPS_TAG = "stable_22Jul2025_update1"
LAMMPS_URL = "https://github.com/lammps/lammps.git"

HERE = pathlib.Path(__file__).resolve().parent
BRIDGE_FILES = [
    HERE / "bridge/include/atomify_lammps.h",
    HERE / "bridge/src/atomify_shared.h",
    HERE / "bridge/src/atomify_lammps.cpp",
    HERE / "bridge/src/fix_atomify.h",
    HERE / "bridge/src/fix_atomify.cpp",
]


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def checkout(root: pathlib.Path):
    if (root / "src/lammps.cpp").exists():
        tag = subprocess.run(["git", "describe", "--tags", "--exact-match"], cwd=root,
                             capture_output=True, text=True).stdout.strip()
        if tag == LAMMPS_TAG:
            return
        sys.exit(f"{root} holds {tag or 'an unknown revision'}, expected {LAMMPS_TAG}; remove it first")
    root.parent.mkdir(parents=True, exist_ok=True)
    run("git", "clone", "--quiet", "--filter=blob:none", "--sparse", "--depth", "1",
        "--branch", LAMMPS_TAG, LAMMPS_URL, str(root))
    run("git", "sparse-checkout", "set", "src", "cmake", "lib", cwd=root)


def edit(path: pathlib.Path, old: str, new: str, count: int):
    text = path.read_text()
    if new in text:
        return  # already applied
    found = text.count(old)
    if found != count:
        sys.exit(f"{path.name}: expected {count} occurrence(s) of {old!r}, found {found}")
    path.write_text(text.replace(old, new))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = pathlib.Path(sys.argv[1]).resolve()
    checkout(root)
    src = root / "src"

    for file in BRIDGE_FILES:
        shutil.copyfile(file, src / file.name)

    edit(src / "modify.cpp",
         '"amoeba/pitorsion", "amoeba/bitorsion", "DUMMY", nullptr};',
         '"amoeba/pitorsion", "amoeba/bitorsion", "DUMMY", "atomify", nullptr};', 1)

    edit(src / "input.cpp", "if (system(", "if (atomify_no_system(", 2)
    edit(src / "input.cpp", '#include "variable.h"\n',
         '#include "variable.h"\n\n'
         '// Atomify: system() is unavailable on visionOS; shell commands report failure.\n'
         'static int atomify_no_system(const char *) { return -1; }\n', 1)
    print(f"LAMMPS {LAMMPS_TAG} with the Atomify bridge is ready in {root}")


if __name__ == "__main__":
    main()
