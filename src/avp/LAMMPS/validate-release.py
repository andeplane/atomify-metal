#!/usr/bin/env python3
"""Compile real-engine probes and validate featured trajectories and C-H manipulation.

Run build-host.sh first. Saves evidence in the ignored artifacts directory.
No headset interaction, general chemistry or physical reaction rates are inferred.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
APP = HERE.parent
CASES = [('benzene', 12, 'experiment.in'), ('methane', 5, 'experiment.in'),
         ('ethane', 8, 'experiment.in'), ('carbon-workshop', 160, 'experiment.in'),
         ('diamond', 216, 'experiment.in'), ('watervapor', 3000, 'vapor.in'),
         ('zeolite_zsm5', 2304, 'zeolite_zsm5.in'),
         # Release lineup (Demos/demos.json releaseOrder 0-4)
         ('water', 1029, 'water.in'), ('surface-diffusion', 510, 'surface.in'),
         ('sic_nanoparticle', 740, 'nanoparticle.in'), ('cnt_deformation', 676, 'cnt-under-deformation.in')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=pathlib.Path, default=HERE / 'build/host')
    parser.add_argument('--output', type=pathlib.Path, default=APP / 'artifacts/release-validation.json')
    parser.add_argument('--stress', action='store_true', help='48 hand contacts and six 100,000-step molecule checks')
    parser.add_argument('--steps', type=int, default=2000, help='Additional dynamics steps per featured experiment')
    parser.add_argument('--export-previews', action='store_true', help='Regenerate the three native structure previews')
    args = parser.parse_args()
    if not 10 <= args.steps <= 1_000_000: parser.error('--steps must be between 10 and 1,000,000')
    build = args.build_dir.resolve()
    evidence = {'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'library_sha256': hashlib.sha256((build / 'liblammps.a').read_bytes()).hexdigest(),
                'experiments': [], 'reactive_manipulation': [], 'contact_stress': [], 'small_molecules': []}
    for name in ['demo_probe', 'reactive_probe'] + (['contact_probe', 'molecule_probe'] if args.stress else []) + (['preview_export'] if args.export_previews else []):
        subprocess.run(['c++', '-std=c++17', '-O1', '-I' + str(HERE / 'bridge/include'),
                        str(HERE / f'bridge/tests/{name}.cpp'), str(build / 'liblammps.a'),
                        '-lpthread', '-o', str(build / name)], check=True)
    passed = True
    for name, count, script in CASES:
        folder = APP / 'Demos' / name
        result = subprocess.run([str(build / 'demo_probe'), script, str(count), str(args.steps)], cwd=folder,
                                capture_output=True, text=True, timeout=600)
        record = {'id': name, 'expected_atoms': count, 'additional_steps': args.steps, 'exit_code': result.returncode,
                  'script_sha256': hashlib.sha256((folder / script).read_bytes()).hexdigest(),
                  'output': result.stdout, 'error': result.stderr}
        evidence['experiments'].append(record)
        passed &= result.returncode == 0
        print(f'{name}: {"PASS" if result.returncode == 0 else "FAIL"}', flush=True)
        if args.export_previews and name in ['benzene', 'methane', 'ethane', 'carbon-workshop', 'diamond']:
            result = subprocess.run([str(build / 'preview_export'), script], cwd=folder,
                                    capture_output=True, text=True, timeout=30, check=True)
            structure = json.loads(result.stdout)
            assert len(structure['positions']) == count
            (folder / 'preview.json').write_text(json.dumps(structure, separators=(',', ':')) + '\n')
    source = APP / 'Demos/benzene'
    for seed in [49183, 12347, 98731]:
        with tempfile.TemporaryDirectory(prefix='atomify-reactive-') as temporary:
            work = pathlib.Path(temporary)
            shutil.copy2(source / 'CH.airebo', work / 'CH.airebo')
            (work / 'experiment.in').write_text((source / 'experiment.in').read_text().replace(
                '50.0 49183', '50.0 ' + str(seed)))
            result = subprocess.run([str(build / 'reactive_probe'), 'experiment.in'], cwd=work,
                                    capture_output=True, text=True, timeout=30)
        measured = re.search(r'max_distance=([0-9.]+) final_distance=([0-9.]+)', result.stdout)
        record = {'velocity_seed': seed, 'exit_code': result.returncode,
                  'max_CH_distance_A': float(measured[1]) if measured else None,
                  'final_CH_distance_A': float(measured[2]) if measured else None,
                  'output': result.stdout, 'error': result.stderr}
        evidence['reactive_manipulation'].append(record)
        passed &= result.returncode == 0
        print(f'C-H pull/return seed {seed}: {"PASS" if result.returncode == 0 else "FAIL"}', flush=True)
    if args.stress:
        for seed in [49183, 12347, 98731]:
            for name in ['benzene', 'methane', 'ethane']:
                source = APP / 'Demos' / name
                with tempfile.TemporaryDirectory(prefix='atomify-stress-') as temporary:
                    work = pathlib.Path(temporary)
                    shutil.copy2(source / 'CH.airebo', work / 'CH.airebo')
                    (work / 'experiment.in').write_text((source / 'experiment.in').read_text().replace(
                        '50.0 49183', '50.0 ' + str(seed)))
                    if name == 'benzene':
                        cases = [(kind, steps) for kind in ['sweep', 'overlap', 'deep', 'tracking']
                                 for steps in [1, 2, 10, 100]]
                        for kind, steps in cases:
                            result = subprocess.run([str(build / 'contact_probe'), 'experiment.in', kind, str(steps)],
                                                    cwd=work, capture_output=True, text=True, timeout=30)
                            evidence['contact_stress'].append(dict(seed=seed, case=kind, cadence_steps=steps,
                                exit_code=result.returncode, output=result.stdout, error=result.stderr))
                            passed &= result.returncode == 0
                    else:
                        result = subprocess.run([str(build / 'molecule_probe'), 'experiment.in', name],
                                                cwd=work, capture_output=True, text=True, timeout=30)
                        evidence['small_molecules'].append(dict(seed=seed, molecule=name, steps=100000,
                            exit_code=result.returncode, output=result.stdout, error=result.stderr))
                        passed &= result.returncode == 0
            print(f'Extended contact and molecule seed {seed}: complete', flush=True)
    evidence['passed'] = bool(passed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(args.output.resolve())
    raise SystemExit(0 if passed else 1)


if __name__ == '__main__':
    main()
