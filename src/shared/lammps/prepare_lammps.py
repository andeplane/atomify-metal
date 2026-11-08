#!/usr/bin/env python3
"""Fetch the pinned LAMMPS release and add the Atomify bridge to its sources.

Usage: prepare_lammps.py <checkout-dir>

The checkout is reused if it already has the pinned tag. Then:

  * The patches in patches/ are applied, in name order. Like lammps.js, a
    patch that does not apply is checked in reverse: if it is already
    applied it is skipped, otherwise the script stops, so a build never
    silently lacks a patch. See README.md for what each patch does.
  * The bridge (bridge/include/atomify_lammps.h and bridge/src/*) and the
    extra styles in extra_src/ are copied into src/. LAMMPS' CMake build
    compiles every src/*.cpp and registers the styles their headers declare
    (FixStyle(atomify, ...), PairStyle(lj/charmm/coul/charmm/inter, ...)).
    Files are only rewritten when they changed, so rebuilds stay incremental.
"""

import pathlib
import subprocess
import sys

LAMMPS_TAG = "stable_30Sep2026_update1"
LAMMPS_URL = "https://github.com/lammps/lammps.git"

HERE = pathlib.Path(__file__).resolve().parent
PATCHES = sorted((HERE / "patches").glob("*.patch"))
SOURCES = ([HERE / "bridge/include/atomify_lammps.h"]
           + sorted(p for p in (HERE / "bridge/src").iterdir() if p.suffix in (".h", ".cpp"))
           + sorted(p for p in (HERE / "extra_src").iterdir() if p.suffix in (".h", ".cpp")))


def run(*args, cwd=None):
    subprocess.run(args, cwd=cwd, check=True)


def succeeds(*args, cwd=None) -> bool:
    return subprocess.run(args, cwd=cwd, capture_output=True).returncode == 0


def checkout(root: pathlib.Path):
    if (root / "src/lammps.cpp").exists():
        tag = subprocess.run(["git", "describe", "--tags", "--exact-match"], cwd=root,
                             capture_output=True, text=True).stdout.strip()
        if tag == LAMMPS_TAG:
            return
        sys.exit(f"{root} holds {tag or 'an unknown revision'}, expected {LAMMPS_TAG}; remove it first")
    root.parent.mkdir(parents=True, exist_ok=True)
    run("git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--filter=blob:none", "--sparse",
        "--depth", "1", "--branch", LAMMPS_TAG, LAMMPS_URL, str(root))
    run("git", "sparse-checkout", "set", "src", "cmake", "lib", cwd=root)


def apply_patches(root: pathlib.Path):
    for patch in PATCHES:
        if succeeds("git", "apply", "--check", str(patch), cwd=root):
            run("git", "apply", str(patch), cwd=root)
            print(f"Applied {patch.name}")
        elif not succeeds("git", "apply", "--reverse", "--check", str(patch), cwd=root):
            sys.exit(f"{patch.name} does not apply to {root}. Remove the checkout (or fix the patch) "
                     "and run this again.")


def copy_if_changed(source: pathlib.Path, target: pathlib.Path):
    data = source.read_bytes()
    if not target.exists() or target.read_bytes() != data:
        target.write_bytes(data)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = pathlib.Path(sys.argv[1]).resolve()
    checkout(root)
    apply_patches(root)
    for source in SOURCES:
        copy_if_changed(source, root / "src" / source.name)
    print(f"LAMMPS {LAMMPS_TAG} with the Atomify bridge is ready in {root}")


if __name__ == "__main__":
    main()
