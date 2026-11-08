#!/usr/bin/env python3
"""Validate real phase trajectories, not phase labels inferred from temperature.

Build the host LAMMPS library first. Uses only Python's standard library and the
actual Atomify bridge. LJ cases measure Common Neighbor Analysis and mobility;
mW ice measures loss of crystalline Bragg order, changed neighbors and mobility.
These short finite-cell tests do not determine an equilibrium melting point.
"""
import argparse
import cmath
import datetime
import hashlib
import json
import math
import pathlib
import shutil
import statistics
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SHARED_LAMMPS = HERE.parent.parent / 'shared/lammps'
APP = HERE.parent
RUNNER = r'''
#include "atomify_lammps.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
int main(int argc,char **argv) {
  if(argc!=4)return 2;
  auto *s=atomify_sim_create(0); if(!s)return 3;
  atomify_sim_set_publish_interval(s,0);
  if(atomify_sim_run_file(s,argv[1])!=ATOMIFY_OK) {
    std::fprintf(stderr,"%s\n",atomify_sim_last_error(s));return 4;
  }
  int count=std::atoi(argv[2]), steps=std::atoi(argv[3]);
  for(int stage=0;stage<=steps/500;stage++) {
    if(stage&&atomify_sim_command(s,"run 500")!=ATOMIFY_OK) {
      std::fprintf(stderr,"%s\n",atomify_sim_last_error(s));return 5;
    }
    atomify_snapshot v; if(!atomify_sim_snapshot_lock(s,&v))return 6;
    bool ok=v.natoms==count&&std::isfinite(v.temperature)&&std::isfinite(v.kinetic_energy)
      &&(!v.has_potential_energy||std::isfinite(v.potential_energy));
    for(int i=0;i<3*v.natoms;i++)ok&=std::isfinite(v.positions[i]);
    std::printf("{\"step\":%lld,\"atoms\":%d,\"temperature\":%.12g,\"potential_energy\":%.12g,\"has_potential_energy\":%s,\"finite\":%s}\n",
      (long long)v.timestep,v.natoms,v.temperature,v.potential_energy,v.has_potential_energy?"true":"false",ok?"true":"false");
    if(stage==0) {
      FILE *p=std::fopen("preview.json","w"); if(!p)return 8;
      std::fputs("{\"positions\":[",p);
      for(int i=0;i<v.natoms;i++)std::fprintf(p,"%s[%.9g,%.9g,%.9g]",i?",":"",v.positions[3*i],v.positions[3*i+1],v.positions[3*i+2]);
      std::fputs("],\"types\":[",p);
      for(int i=0;i<v.natoms;i++)std::fprintf(p,"%s%d",i?",":"",v.types[i]);
      std::fputs("],\"bonds\":[]}\n",p);std::fclose(p);
    }
    atomify_sim_snapshot_unlock(s);if(!ok)return 7;
  }
  atomify_sim_destroy(s);return 0;
}
'''


def trajectory(path):
    lines = path.read_text().splitlines()
    frames, offset = [], 0
    while offset < len(lines):
        assert lines[offset] == 'ITEM: TIMESTEP'
        step, count = int(lines[offset + 1]), int(lines[offset + 3])
        bounds = [tuple(map(float, line.split())) for line in lines[offset + 5:offset + 8]]
        fields = lines[offset + 8].split()[2:]
        atoms = []
        for line in lines[offset + 9:offset + 9 + count]:
            row = dict(zip(fields, map(float, line.split())))
            assert all(math.isfinite(value) for value in row.values())
            atoms.append(row)
        assert [int(a['id']) for a in atoms] == list(range(1, count + 1))
        frames.append(dict(step=step, bounds=bounds, atoms=atoms))
        offset += 9 + count
    assert frames
    return frames


def positions(frame, mobile_only=False):
    return [(a['xu'], a['yu'], a['zu']) for a in frame['atoms']
            if not mobile_only or int(a['type']) == 1]


def msd(a, b, mobile_only=False):
    start, end = positions(a, mobile_only), positions(b, mobile_only)
    assert len(start) == len(end)
    delta = [tuple(y[i] - x[i] for i in range(3)) for x, y in zip(start, end)]
    drift = [statistics.mean(row[i] for row in delta) for i in range(3)]
    return statistics.mean(sum((row[i] - drift[i]) ** 2 for i in range(3)) for row in delta)


def order(frame, mobile_only=False):
    atoms = [a for a in frame['atoms'] if not mobile_only or int(a['type']) == 1]
    return sum(int(a['c_phase']) in (1, 2) for a in atoms) / len(atoms)


def bragg(frame, lattice=6.3584):
    p = positions(frame)
    # Four equivalent allowed cubic-diamond {111} reflections. Normalized to N².
    return statistics.mean(abs(sum(cmath.exp(2j * math.pi / lattice *
        sum(sign[i] * row[i] for i in range(3))) for row in p)) ** 2 / len(p) ** 2
        for sign in [(1, 1, 1), (-1, 1, 1), (1, -1, 1), (1, 1, -1)])


def neighbors(frame):
    p = positions(frame)
    length = [b[1] - b[0] for b in frame['bounds']]
    result, tetrahedrality = [], []
    for i, center in enumerate(p):
        near = []
        for j, point in enumerate(p):
            if i == j:
                continue
            d = [point[a] - center[a] for a in range(3)]
            d = [d[a] - length[a] * round(d[a] / length[a]) for a in range(3)]
            near.append((sum(x * x for x in d), j, d))
        near.sort()
        four = near[:4]
        result.append({row[1] for row in four})
        penalty = sum((sum(four[j][2][a] * four[k][2][a] for a in range(3)) /
            math.sqrt(four[j][0] * four[k][0]) + 1 / 3) ** 2
            for j in range(4) for k in range(j + 1, 4))
        tetrahedrality.append(1 - 3 / 8 * penalty)
    return result, statistics.mean(tetrahedrality)


def validate(name, frames):
    # Means across late trajectory samples avoid choosing a lucky endpoint.
    late = frames[-11:]
    result = {}
    if name == 'phase-melting':
        initial_order = statistics.mean(order(f) for f in frames[:2])
        final_order = statistics.mean(order(f) for f in late)
        mobility = msd(frames[-21], frames[-1])
        result.update(initial_fcc_hcp_fraction=initial_order, final_fcc_hcp_fraction=final_order,
                      late_msd_sigma_squared=mobility)
        passed = initial_order > .9 and final_order < .15 and mobility > 1.0
    elif name == 'phase-crystallization':
        initial_order = statistics.mean(order(f, True) for f in frames[:2])
        final_order = statistics.mean(order(f, True) for f in late)
        mobility = msd(frames[-11], frames[-1], True)
        template = [a for a in frames[0]['atoms'] if int(a['type']) == 2]
        end = [a for a in frames[-1]['atoms'] if int(a['type']) == 2]
        displacement = max(sum((a[key] - b[key]) ** 2 for key in ['xu', 'yu', 'zu'])
                           for a, b in zip(template, end))
        result.update(initial_mobile_fcc_hcp_fraction=initial_order,
                      final_mobile_fcc_hcp_fraction=final_order,
                      late_mobile_msd_sigma_squared=mobility,
                      fixed_template_particles=len(template),
                      max_template_displacement_squared=displacement)
        passed = initial_order < .2 and final_order > .8 and mobility < .15 and displacement < 1e-15
    else:
        initial_bragg = statistics.mean(bragg(f) for f in frames[:3])
        final_bragg = statistics.mean(bragg(f) for f in late)
        mobility = msd(frames[-21], frames[-1])
        initial_neighbors, initial_tetra = neighbors(frames[0])
        final_neighbors, final_tetra = neighbors(frames[-1])
        persistence = statistics.mean(len(a & b) / 4 for a, b in zip(initial_neighbors, final_neighbors))
        result.update(initial_111_bragg_order=initial_bragg, final_111_bragg_order=final_bragg,
                      late_msd_A_squared=mobility, initial_tetrahedrality=initial_tetra,
                      final_tetrahedrality=final_tetra, original_four_neighbor_retention=persistence)
        passed = initial_bragg > .35 and final_bragg < .05 and mobility > 10 and persistence < .25
    result['passed'] = passed
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=pathlib.Path, default=SHARED_LAMMPS / 'build/host')
    parser.add_argument('--output', type=pathlib.Path, default=APP / 'artifacts/phase-validation.json')
    parser.add_argument('--seeds', nargs='+', type=int, default=[49183, 12347, 98731])
    parser.add_argument('--export-previews', action='store_true')
    args = parser.parse_args()
    if any(seed <= 0 or seed > 900_000_000 for seed in args.seeds):
        parser.error('Seeds must be positive and at most 900,000,000')
    library = args.build_dir.resolve() / 'liblammps.a'
    evidence = dict(recorded_at_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(), trajectories=[])
    with tempfile.TemporaryDirectory(prefix='atomify-phase-probe-') as temporary:
        base = pathlib.Path(temporary)
        (base / 'probe.cpp').write_text(RUNNER)
        subprocess.run(['c++', '-std=c++17', '-O1', '-I' + str(SHARED_LAMMPS / 'bridge/include'),
                        str(base / 'probe.cpp'), str(library), '-lpthread', '-o', str(base / 'probe')], check=True)
        for name, count, steps in [('phase-melting', 256, 20000),
                                   ('phase-crystallization', 256, 20000), ('ice-melting', 512, 30000)]:
            source = APP / 'Demos' / name
            source_hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in source.iterdir() if p.suffix in ['.in', '.data', '.sw']}
            for seed_index, seed in enumerate(args.seeds):
                work = base / (name + '-' + str(seed))
                shutil.copytree(source, work)
                script = (work / 'experiment.in').read_text().replace('49183', str(seed)).replace('82347', str(seed + 33164))
                script += '\n' + ('compute phase all cna/atom 1.45\n' if name != 'ice-melting' else '')
                script += 'dump evidence all custom 500 phase.dump id type xu yu zu' + (' c_phase' if name != 'ice-melting' else '') + '\ndump_modify evidence sort id\nrun 0\n'
                (work / 'validation.in').write_text(script)
                completed = subprocess.run([str(base / 'probe'), 'validation.in', str(count), str(steps)],
                                           cwd=work, capture_output=True, text=True, timeout=300)
                result = dict(id=name, seed=seed, atoms=count, steps=steps, script_sha256=source_hashes,
                              exit_code=completed.returncode, error=completed.stderr)
                if completed.returncode == 0:
                    snapshots = [json.loads(line) for line in completed.stdout.splitlines() if line.startswith('{')]
                    frames = trajectory(work / 'phase.dump')
                    assert len(snapshots) == steps // 500 + 1
                    assert all(s['atoms'] == count and s['finite'] for s in snapshots)
                    assert len(frames) == len(snapshots)
                    result.update(validate(name, frames))
                    result['snapshots'] = snapshots
                    result['sampled_structure'] = [dict(step=f['step'], fcc_hcp_fraction=order(f, name == 'phase-crystallization'))
                        if name != 'ice-melting' else dict(step=f['step'], bragg_111=bragg(f)) for f in frames]
                    if args.export_previews and seed_index == 0 and result['passed']:
                        shutil.copy2(work / 'preview.json', source / 'preview.json')
                else:
                    result.update(passed=False, output=completed.stdout)
                evidence['trajectories'].append(result)
                metrics = {k: v for k, v in result.items() if k not in ['snapshots', 'sampled_structure', 'script_sha256']}
                print(json.dumps(metrics), flush=True)
    evidence['passed'] = all(t['passed'] for t in evidence['trajectories'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(args.output.resolve())
    raise SystemExit(0 if evidence['passed'] else 1)


if __name__ == '__main__':
    main()
