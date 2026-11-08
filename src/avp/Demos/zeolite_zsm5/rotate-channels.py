#!/usr/bin/env python3
"""Writes zeolite_zsm5_channels_z.data from zeolite_zsm5.data (one MFI unit cell).

The source cell has its straight 10-ring channels along y. Atomify treats +y as
up and looks along -z, so this applies the proper rotation (x, y, z) -> (x, -z, y)
and shifts the new y back into [0, Lz): the straight channels then run along z,
toward the viewer. Box lengths become (Lx, Lz, Ly).

    python3 rotate-channels.py
"""
import pathlib

here = pathlib.Path(__file__).resolve().parent
lines = (here / 'zeolite_zsm5.data').read_text().splitlines()
bounds = {}
atoms = []
in_atoms = False
for line in lines:
    words = line.split()
    if len(words) == 4 and words[2] in ('xlo', 'ylo', 'zlo'):
        bounds[words[2][0]] = (float(words[0]), float(words[1]))
    elif words[:1] == ['Atoms']:
        in_atoms = True
    elif in_atoms and len(words) == 5:
        atoms.append((int(words[0]), int(words[1]), *map(float, words[2:])))
lx = bounds['x'][1] - bounds['x'][0]
ly = bounds['y'][1] - bounds['y'][0]
lz = bounds['z'][1] - bounds['z'][0]
out = ['MFI (ZSM-5) unit cell from zeolite_zsm5.data, rotated (x, y, z) -> (x, -z, y) by rotate-channels.py',
       '', f'{len(atoms)} atoms', '2 atom types', '',
       f'0.0 {lx:.4f} xlo xhi', f'0.0 {lz:.4f} ylo yhi', f'0.0 {ly:.4f} zlo zhi', '', 'Atoms # atomic', '']
for tag, kind, x, y, z in atoms:
    x -= bounds['x'][0]; y -= bounds['y'][0]; z -= bounds['z'][0]
    new_y = (lz - z) % lz
    out.append(f'{tag} {kind} {x:.8f} {new_y:.8f} {y:.8f}')
(here / 'zeolite_zsm5_channels_z.data').write_text('\n'.join(out) + '\n')
print(f'wrote {len(atoms)} atoms, box {lx} x {lz} x {ly}')
