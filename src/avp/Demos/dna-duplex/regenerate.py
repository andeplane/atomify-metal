#!/usr/bin/env python3
"""Regenerate the 20-base-pair duplex with the pinned upstream oxDNA generator.

Requires NumPy; run from any directory. The upstream generator is unmodified.
Only translate the generated center of mass to the origin; preserve all physical
coordinates relative to one another, quaternion orientations and bond polarity.
"""
from pathlib import Path
import os
import runpy
import sys
import tempfile

import numpy as np

ROOT = Path(__file__).resolve().parent
SEED = 231023


def regenerate():
    with tempfile.TemporaryDirectory(prefix="atomify-dna-") as temporary:
        original_cwd, original_argv = Path.cwd(), sys.argv[:]
        try:
            os.chdir(temporary)
            np.random.seed(SEED)
            sys.argv = [str(ROOT / "upstream/generate.py"), "-20", "40", str(ROOT / "sequence.txt")]
            runpy.run_path(str(ROOT / "upstream/generate.py"), run_name="__main__")
            lines = Path("data.oxdna").read_text().splitlines()
        finally:
            os.chdir(original_cwd)
            sys.argv = original_argv

    sections = {}
    current = None
    for index, line in enumerate(lines):
        if line in ("Atoms", "Bonds", "Ellipsoids", "Velocities", "Masses"):
            current = line
            sections[current] = []
        elif current and line and not line.startswith("#"):
            sections[current].append((index, line.split()))
    particles = sections["Atoms"]
    assert len(particles) == 40
    center = np.mean([[float(x) for x in row[2:5]] for _, row in particles], axis=0)
    positions, types = [], []
    for index, row in particles:
        point = [float(row[k + 2]) - float(center[k]) for k in range(3)]
        row[2:5] = [f"{value:.15e}" for value in point]
        lines[index] = " ".join(row)
        positions.append(point)
        types.append(int(row[1]))
    bonds = [[int(row[2]) - 1, int(row[3]) - 1] for _, row in sections["Bonds"]]
    assert len(bonds) == 38
    assert set(types) == {1, 2, 3, 4}
    (ROOT / "data.duplex").write_text("\n".join(lines) + "\n")
    print("Generated 40 nucleotides, 20 complementary base pairs, 38 backbone bonds.\nRefresh the initialized preview with LAMMPS/test-dna.py --export-preview.")


if __name__ == "__main__":
    regenerate()
