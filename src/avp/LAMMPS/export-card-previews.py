#!/usr/bin/env python3
"""Regenerate preview.json for the five release demos from real engine snapshots.

Each demo is run through the Atomify bridge (bridge/tests/preview_export.cpp linked
against the host LAMMPS library from build-host.sh), exactly as the app runs it,
with a write_dump appended. A compact, representative subset is then cut from that
snapshot, unwrapped across periodic boundaries, centred and written as
Demos/<folder>/preview.json (positions in the script's length unit, LAMMPS atom types
starting at 1, bonds as 0-based index pairs from the script's #/bond cutoffs).

    python3 LAMMPS/export-card-previews.py [--build-dir LAMMPS/build/host] [--only water]

Needs numpy and scipy.
"""
import argparse
import json
import pathlib
import re
import shutil
import subprocess
import tempfile

import numpy as np
from scipy.sparse import coo_matrix
from scipy.sparse.csgraph import connected_components
from scipy.spatial import cKDTree

HERE = pathlib.Path(__file__).resolve().parent
DEMOS = HERE.parent / 'Demos'



def read_dump(path):
    lines = pathlib.Path(path).read_text().splitlines()
    n = int(lines[3])
    box = np.array([[float(v) for v in lines[5 + k].split()[:2]] for k in range(3)])
    columns = lines[8].split()[2:]
    data = np.array([line.split() for line in lines[9:9 + n]], dtype=float)
    data = data[np.argsort(data[:, columns.index('id')])]
    types = data[:, columns.index('type')].astype(int)
    positions = data[:, [columns.index(c) for c in 'x y z'.split()]]
    return box, types, positions


def minimum_image(delta, lengths, periodic=(True, True, True)):
    delta = np.array(delta, dtype=float)
    for k in range(3):
        if periodic[k]:
            delta[..., k] -= lengths[k] * np.round(delta[..., k] / lengths[k])
    return delta


def bond_rules(script):
    return [(int(a), int(b), float(c)) for a, b, c in
            re.findall(r'^#/bond\s+(\d+)\s+(\d+)\s+([0-9.]+)', script, re.M)]


def bonds_for(positions, types, rules):
    bonds = set()
    tree = cKDTree(positions)
    for t1, t2, cutoff in rules:
        for i, j in tree.query_pairs(cutoff):
            if {int(types[i]), int(types[j])} == {t1, t2} or (t1 == t2 == types[i] == types[j]):
                bonds.add((min(i, j), max(i, j)))
    return sorted(bonds)


def run_snapshot(engine, folder, script, transform):
    """Run the demo through the bridge with `transform` applied to the script text."""
    with tempfile.TemporaryDirectory(prefix='atomify-preview-') as temporary:
        work = pathlib.Path(temporary) / folder
        shutil.copytree(DEMOS / folder, work)
        text = transform((work / script).read_text())
        text += '\nwrite_dump all custom preview.dump id type x y z modify sort id\n'
        (work / 'preview-input.in').write_text(text)
        subprocess.run([str(engine), 'preview-input.in'], cwd=work, check=True,
                       stdout=subprocess.DEVNULL, timeout=900)
        return read_dump(work / 'preview.dump')


def water(box, types, pos):
    lengths = box[:, 1] - box[:, 0]
    oxygens = np.where(types == 1)[0]
    hydrogens = np.where(types == 2)[0]
    # Each hydrogen belongs to its nearest oxygen (rigid SPC/E, O-H = 1 A).
    tree = cKDTree((pos[oxygens] - box[:, 0]) % lengths, boxsize=lengths)
    _, owner = tree.query((pos[hydrogens] - box[:, 0]) % lengths)
    centre = box.mean(axis=1)
    first = oxygens[np.argmin(np.linalg.norm(minimum_image(pos[oxygens] - centre, lengths), axis=1))]
    offsets = minimum_image(pos[oxygens] - pos[first], lengths)
    chosen = np.argsort(np.linalg.norm(offsets, axis=1))[:16]
    out_pos, out_types = [], []
    for k in chosen:
        o = pos[first] + offsets[k]
        out_pos.append(o); out_types.append(1)
        for h in hydrogens[owner == k]:
            out_pos.append(o + minimum_image(pos[h] - pos[oxygens[k]], lengths)); out_types.append(2)
    return np.array(out_pos), np.array(out_types), None, '16 whole water molecules from the equilibrated 343-molecule liquid'


def zeolite(box, types, pos):
    lengths = box[:, 1] - box[:, 0]
    centre = box.mean(axis=1)  # a straight channel runs along z through the box centre
    d = minimum_image(pos - centre, lengths)
    radial = np.hypot(d[:, 0], d[:, 1])
    silicon = (types == 1) & (radial < 9.5) & (np.abs(d[:, 2]) < 3.4)
    si = np.where(silicon)[0]
    o = np.where(types == 2)[0]
    tree = cKDTree(d[o])
    keep = set(si.tolist())
    for neighbours in tree.query_ball_point(d[si], 2.0):
        keep.update(o[neighbours].tolist())
    keep = np.array(sorted(keep))
    return d[keep], types[keep], None, (
        f'{len(keep)}-atom slice, ring face-on along z, around one straight 10-ring channel of the 2304-atom crystal; '
        'complete SiO4 tetrahedra')


def surface(box, types, pos):
    lengths = box[:, 1] - box[:, 0]
    periodic = (True, False, True)  # the surface normal is +y
    substrate = types == 1
    top = np.percentile(pos[substrate, 1], 99)
    upper = substrate & (pos[:, 1] > top - 3.0)
    adatoms = np.where(types == 2)[0]
    half = np.array([7.5, 6.5])  # about 6 atoms x 6 rows of a (111) layer, in x and z
    best = None
    for a in adatoms:
        d = minimum_image(pos - pos[a], lengths, periodic)
        inside = (np.abs(d[:, 0]) < half[0]) & (np.abs(d[:, 2]) < half[1])
        count = int((inside & (types == 2)).sum())
        score = (3 <= count <= 5, -abs(count - 4))
        if best is None or score > best[0]:
            best = (score, a, inside)
    _, a, inside = best
    keep = np.where(inside & (upper | (types == 2)))[0]
    d = minimum_image(pos[keep] - pos[a], lengths, periodic)
    d[:, 1] = pos[keep, 1] - top
    return d, types[keep], None, (
        f'{len(keep)} atoms: a patch of the top two Ni(111) layers with '
        f'{int((types[keep] == 2).sum())} adatoms after 12 ps at 600 K')


def nanoparticle(box, types, pos):
    lengths = box[:, 1] - box[:, 0]
    wrapped = (pos - box[:, 0]) % lengths
    pairs = cKDTree(wrapped, boxsize=lengths).query_pairs(2.9, output_type='ndarray')
    n = len(pos)
    _, label = connected_components(coo_matrix((np.ones(len(pairs)), (pairs[:, 0], pairs[:, 1])), shape=(n, n)),
                                    directed=False)
    particle = np.where(label == np.argmax(np.bincount(label)))[0]
    d = minimum_image(wrapped[particle] - wrapped[particle[0]], lengths)
    d -= d.mean(axis=0)
    # The cooled particle has ~740 atoms; keep the half above the equator (<= 400 atoms)
    # so the card shows the crystalline core in the cut face and the rounded surface.
    keep = np.argsort(-d[:, 2])[:min(400, int((d[:, 2] > 0).sum()))]
    return d[keep], types[particle][keep], None, (
        f'{len(keep)} atoms: the upper half of the {len(particle)}-atom particle after cooling to 500 K; '
        'loose gas atoms omitted')


def nanotube(box, types, pos):
    z = pos[:, 0]  # the tube lies along x
    middle = types == 1
    lo, hi = np.percentile(z[middle], [0, 100])
    best = None
    for start in np.arange(lo + 2.0, hi - 21.5, 0.5):  # 19.5 A window with the fewest vacancies
        inside = middle & (z >= start) & (z < start + 19.5)
        if best is None or inside.sum() > best[1].sum():
            best = (start, inside)
    keep = np.where(best[1])[0]
    d = pos[keep] - pos[keep].mean(axis=0)
    return d, types[keep], None, (
        f'{len(keep)} atoms: an intact 2 nm section of the equilibrated tube (with its vacancies), '
        'before pulling')


def until_first_run(text):
    """The CNT script up to and including its 1 ps equilibration run."""
    cut = text.index('unfix\t\tmyber')
    return text[:cut]


SPECS = [
    ('water', 'water.in', 'real', lambda t: t, water),
    ('zeolite_zsm5', 'zeolite_zsm5.in', 'metal', lambda t: t, zeolite),
    ('surface-diffusion', 'surface.in', 'metal', lambda t: t + '\nrun 5000\n', surface),
    ('sic_nanoparticle', 'nanoparticle.in', 'metal', lambda t: t, nanoparticle),
    ('cnt_deformation', 'cnt-under-deformation.in', 'metal', until_first_run, nanotube),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--build-dir', type=pathlib.Path, default=HERE / 'build/host')
    parser.add_argument('--only', help='one demo folder')
    args = parser.parse_args()
    build = args.build_dir.resolve()
    engine = build / 'preview_export'
    subprocess.run(['c++', '-std=c++17', '-O1', '-I' + str(HERE / 'bridge/include'),
                    str(HERE / 'bridge/tests/preview_export.cpp'), str(build / 'liblammps.a'),
                    '-lpthread', '-o', str(engine)], check=True)
    for folder, script, units, transform, select in SPECS:
        if args.only and args.only != folder:
            continue
        box, types, pos = run_snapshot(engine, folder, script, transform)
        positions, out_types, _, representation = select(box, types, pos)
        positions = positions - (positions.min(axis=0) + positions.max(axis=0)) / 2
        bonds = bonds_for(positions, out_types, bond_rules((DEMOS / folder / script).read_text()))
        assert 40 <= len(positions) <= 400, (folder, len(positions))
        structure = {'positions': [[round(float(v), 4) for v in p] for p in positions],
                     'types': [int(t) for t in out_types],
                     'bonds': [[int(i), int(j)] for i, j in bonds],
                     'units': units, 'representation': representation}
        (DEMOS / folder / 'preview.json').write_text(json.dumps(structure, separators=(',', ':')) + '\n')
        print(f'{folder}: {len(positions)} atoms, {len(bonds)} bonds; {representation}', flush=True)


if __name__ == '__main__':
    main()
