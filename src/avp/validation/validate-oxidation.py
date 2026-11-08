#!/usr/bin/env python3
"""Measure real CH4/O2 ReaxFF trajectories after ignition, without prescribed products.

The default seed is the app's deterministic initial condition. Optional seeds
are independent exploration, not a guarantee that a tiny reactor ignites on cue.
The verdict requires conserved elements, finite snapshots, bounded NVE energy,
sustained bond-order-classified water/carbon oxides, and a rise in averaged
kinetic temperature accompanied by falling potential energy in the same
approximately one-picosecond window as persistent products. Later redistribution
can cool the tiny reactor again; the final frame is not a reaction deadline.
Temperature alone is never accepted as evidence of oxidation.
"""
import argparse
import collections
import datetime
import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
SHARED_LAMMPS = HERE.parent.parent / 'shared/lammps'
APP = HERE.parent
SOURCE = APP / 'Demos/methane-oxidation'
EXPECTED = {'C': 4, 'H': 16, 'O': 16}
MODEL_SHA256 = 'c5240c07e664dde5626fcdb740be1bdbe5e7e34d919902603db0bf962fea9aee'
PROBE = r'''
#include "atomify_lammps.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
int main(int argc, char **argv) {
  if (argc != 4) return 2;
  auto *sim = atomify_sim_create(0);
  if (!sim) return 3;
  atomify_sim_set_publish_interval(sim, 0);
  auto command = [&](const char *text) {
    if (atomify_sim_command(sim, text) == ATOMIFY_OK) return true;
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return false;
  };
  if (atomify_sim_run_file(sim, argv[1]) != ATOMIFY_OK) {
    std::fprintf(stderr, "%s\n", atomify_sim_last_error(sim)); return 4;
  }
  int steps = std::atoi(argv[2]), cadence = std::atoi(argv[3]);
  std::puts("step,temperature_K,kinetic_kcal_mol,potential_kcal_mol,total_kcal_mol,C,H,O,finite");
  for (int done = 0; done <= steps; done += cadence) {
    if (done) {
      char advance[64]; std::snprintf(advance, sizeof(advance), "run %d pre no post no", cadence);
      if (!command(advance)) return 5;
    }
    atomify_snapshot s;
    if (!atomify_sim_snapshot_lock(sim, &s)) return 6;
    int counts[4] = {};
    bool valid = s.natoms == 36 && s.has_potential_energy &&
        std::isfinite(s.temperature) && std::isfinite(s.kinetic_energy) &&
        std::isfinite(s.potential_energy);
    for (int i = 0; i < s.natoms; ++i) {
      valid &= s.types[i] >= 1 && s.types[i] <= 3;
      if (s.types[i] >= 1 && s.types[i] <= 3) ++counts[s.types[i]];
      for (int j = 0; j < 3; ++j) valid &= std::isfinite(s.positions[3*i+j]);
    }
    std::printf("%lld,%.12g,%.12g,%.12g,%.12g,%d,%d,%d,%d\n",
      static_cast<long long>(s.timestep), s.temperature, s.kinetic_energy,
      s.potential_energy, s.kinetic_energy+s.potential_energy,
      counts[1], counts[2], counts[3], valid);
    atomify_sim_snapshot_unlock(sim);
    std::fflush(stdout);
    if (!valid || counts[1] != 4 || counts[2] != 16 || counts[3] != 16) return 7;
  }
  atomify_sim_destroy(sim);
}
'''


def formula_counts(formula):
    tokens = re.findall(r'([A-Z][a-z]?)([0-9]*)', formula)
    if ''.join(symbol + count for symbol, count in tokens) != formula:
        raise ValueError('Unrecognized species formula: ' + formula)
    result = collections.Counter()
    for symbol, count in tokens:
        result[symbol] += int(count or 1)
    return result


def parse_species(path):
    rows = []
    names = []
    for line in path.read_text().splitlines():
        if line.startswith('#'):
            names = line.split()[4:]
        elif line.strip():
            values = [int(x) for x in line.split()]
            if len(values) != 3 + len(names):
                raise ValueError('Species header and values disagree')
            species = dict(zip(names, values[3:]))
            atoms = collections.Counter()
            for formula, count in species.items():
                for symbol, amount in formula_counts(formula).items():
                    atoms[symbol] += count * amount
            if dict(atoms) != EXPECTED or sum(species.values()) != values[1]:
                raise ValueError('Species assignment does not conserve C/H/O')
            rows.append({'step': values[0], 'species': species})
    return rows


def has_products(row):
    species = row['species']
    return species.get('H2O', 0) >= 1 and species.get('CO', 0) + species.get('CO2', 0) >= 1


def longest_product_sequence(rows):
    longest = sequence = 0
    for row in rows:
        sequence = sequence + 1 if has_products(row) else 0
        longest = max(longest, sequence)
    return longest


def assess(stdout, species):
    import csv
    rows = list(csv.DictReader(stdout.splitlines()))
    return assess_trace([{name: float(value) for name, value in row.items()} for row in rows], species)


def assess_trace(trace, species):
    finite = bool(trace) and all(all(math.isfinite(x) for x in row.values()) and
        row['finite'] == 1 and [row[x] for x in ['C', 'H', 'O']] == [4, 16, 16] for row in trace)
    if not finite:
        return {'passed': False, 'finite_and_element_counts': False, 'trace': trace}
    species_conserve = bool(species)
    for row in species:
        atoms = collections.Counter()
        for formula, count in row['species'].items():
            if not isinstance(count, int) or count < 0:
                species_conserve = False
            for symbol, amount in formula_counts(formula).items():
                atoms[symbol] += count * amount
        species_conserve &= dict(atoms) == EXPECTED
    # A missing sample must not count as a consecutive product observation.
    trace_steps = [int(row['step']) for row in trace]
    samples_align = trace_steps == list(range(0, trace_steps[-1] + 1, 1000)) and \
        [row['step'] for row in species] == trace_steps
    # Keep the original averaging length and all numerical thresholds. We seek
    # the earliest observed exothermic episode, not the hottest window or an
    # arbitrary terminal temperature. A candidate must also contain persistent
    # products; the former terminal-only gate allowed products at unrelated times.
    window = min(20, max(2, len(trace) // 5))
    early, late = trace[:window], trace[-window:]
    average = lambda part, key: statistics.mean(row[key] for row in part)
    initial_ke = trace[0]['kinetic_kcal_mol']
    energy_drift = max(abs(row['total_kcal_mol'] - trace[0]['total_kcal_mol']) for row in trace)
    energy_limit = max(1.0, .01 * initial_ke)
    first_T, last_T = average(early, 'temperature_K'), average(late, 'temperature_K')
    first_pe = average(early, 'potential_kcal_mol')
    delta_pe = average(late, 'potential_kcal_mol') - first_pe
    products = [row for row in species if has_products(row)]
    longest = longest_product_sequence(species)
    terminal_heat_release = last_T >= first_T + 300 and delta_pe <= -30
    episodes = []
    maximum_raw_heat_samples = 0
    if samples_align:
        for end in range(2 * window - 1, len(trace)):
            segment = trace[end - window + 1:end + 1]
            product_run = longest_product_sequence(species[end - window + 1:end + 1])
            temperature = average(segment, 'temperature_K')
            potential_change = average(segment, 'potential_kcal_mol') - first_pe
            # Overlapping averages alone could turn one enormous excursion into
            # twenty qualifying windows. Require support from distinct samples.
            raw_heat_samples = sum(row['temperature_K'] >= first_T + 300 and
                row['potential_kcal_mol'] <= first_pe - 30 for row in segment)
            maximum_raw_heat_samples = max(maximum_raw_heat_samples, raw_heat_samples)
            if temperature >= first_T + 300 and potential_change <= -30 and product_run >= 10 and raw_heat_samples >= 10:
                episodes.append({'start_step': int(segment[0]['step']), 'end_step': int(segment[-1]['step']),
                    'mean_temperature_K': temperature, 'temperature_increase_K': temperature - first_T,
                    'mean_potential_change_kcal_mol': potential_change,
                    'consecutive_product_frames': product_run,
                    'qualifying_raw_heat_samples': raw_heat_samples})
    groups = []
    for episode in episodes:
        if groups and episode['end_step'] == groups[-1][-1]['end_step'] + 1000:
            groups[-1].append(episode)
        else:
            groups.append([episode])
    sustained_groups = [group for group in groups if len(group) >= 10]
    confirmed_episode = None
    if sustained_groups:
        group = sustained_groups[0]
        confirmed_episode = {
            'start_step': group[0]['start_step'], 'end_step': group[-1]['end_step'],
            'consecutive_qualifying_windows': len(group),
            'first_qualifying_window': group[0], 'last_qualifying_window': group[-1],
            'minimum_window_temperature_increase_K': min(x['temperature_increase_K'] for x in group),
            'least_negative_window_potential_change_kcal_mol': max(x['mean_potential_change_kcal_mol'] for x in group),
            'minimum_window_consecutive_product_frames': min(x['consecutive_product_frames'] for x in group),
            'minimum_window_qualifying_raw_heat_samples': min(x['qualifying_raw_heat_samples'] for x in group)}
    heat_release = confirmed_episode is not None
    return {'passed': species_conserve and samples_align and energy_drift <= energy_limit and heat_release,
        'finite_and_element_counts': True, 'species_element_counts': bool(species_conserve),
        'samples_align_at_1000_steps': samples_align,
        'post_ignition_energy_drift_kcal_mol': energy_drift,
        'allowed_energy_drift_kcal_mol': energy_limit,
        'early_mean_temperature_K': first_T, 'late_mean_temperature_K': last_T,
        'late_minus_early_potential_kcal_mol': delta_pe,
        'product_frames_with_water_and_carbon_oxide': len(products),
        'first_product_step': products[0]['step'] if products else None,
        'longest_consecutive_product_frames': longest,
        'sustained_products': longest >= 10, 'heat_release_after_ignition': heat_release,
        'terminal_heat_release': terminal_heat_release,
        'terminal_verifier_passed': bool(species_conserve and samples_align and energy_drift <= energy_limit and longest >= 10 and terminal_heat_release),
        'earliest_exothermic_episode': confirmed_episode,
        'longest_consecutive_qualifying_windows': max((len(group) for group in groups), default=0),
        'required_consecutive_qualifying_windows': 10,
        'required_raw_heat_samples_per_window': 10,
        'maximum_raw_heat_samples_in_window': maximum_raw_heat_samples,
        'qualifying_episode_windows': len(episodes),
        'assessment_method': 'sustained-coincident-products-and-distinct-heat-samples-v2',
        'averaging_samples': window, 'trace': trace, 'species': species}


def run_analysis_tests():
    import unittest

    class AnalysisTests(unittest.TestCase):
        @staticmethod
        def trajectory(hot_start=30, hot_end=70, hot_temperature=1600):
            trace, species = [], []
            for index in range(100):
                temperature = hot_temperature if hot_start <= index < hot_end else 1000.0
                kinetic = .1 * temperature
                # Exactly conserve energy while allowing a later endothermic return.
                trace.append(dict(step=index * 1000, temperature_K=temperature,
                    kinetic_kcal_mol=kinetic, potential_kcal_mol=-400.0 - kinetic,
                    total_kcal_mol=-400.0, C=4.0, H=16.0, O=16.0, finite=1.0))
                # Complete oxidation products have exactly the initial C/H/O totals.
                species.append(dict(step=index * 1000, species={'CO2': 4, 'H2O': 8}))
            return trace, species

        def test_nonmonotonic_heat_episode_survives_a_cool_terminal_window(self):
            trace, species = self.trajectory()
            result = assess_trace(trace, species)
            self.assertTrue(result['passed'])
            self.assertFalse(result['terminal_heat_release'])
            self.assertFalse(result['terminal_verifier_passed'])
            self.assertGreaterEqual(result['longest_consecutive_qualifying_windows'], 10)
            self.assertIsNotNone(result['earliest_exothermic_episode'])

        def test_heat_without_oxidation_products_is_rejected(self):
            trace, species = self.trajectory()
            for row in species:
                row['species'] = {'CH4': 4, 'O2': 8}
            self.assertFalse(assess_trace(trace, species)['passed'])

        def test_products_at_an_unrelated_time_do_not_establish_exothermic_oxidation(self):
            trace, species = self.trajectory()
            for index, row in enumerate(species):
                if index < 80:
                    row['species'] = {'CH4': 4, 'O2': 8}
            result = assess_trace(trace, species)
            self.assertTrue(result['sustained_products'])
            self.assertFalse(result['passed'])

        def test_energy_drift_cannot_masquerade_as_chemical_heat(self):
            trace, species = self.trajectory()
            for row in trace[30:70]:
                row['potential_kcal_mol'] += 2
                row['total_kcal_mol'] += 2
            result = assess_trace(trace, species)
            self.assertTrue(result['heat_release_after_ignition'])
            self.assertGreater(result['post_ignition_energy_drift_kcal_mol'], result['allowed_energy_drift_kcal_mol'])
            self.assertFalse(result['passed'])

        def test_a_lucky_pair_of_qualifying_windows_is_not_sustained(self):
            trace, species = self.trajectory(hot_end=49, hot_temperature=1316)
            result = assess_trace(trace, species)
            self.assertGreater(result['qualifying_episode_windows'], 0)
            self.assertLess(result['longest_consecutive_qualifying_windows'], 10)
            self.assertFalse(result['passed'])

        def test_one_hot_sample_cannot_masquerade_as_a_sustained_episode(self):
            trace, species = self.trajectory(hot_start=40, hot_end=41, hot_temperature=7500)
            for index, row in enumerate(species):
                if index < 30:
                    row['species'] = {'CH4': 4, 'O2': 8}
            result = assess_trace(trace, species)
            # Means would pass +325 K / -32.5 kcal in twenty overlapping
            # windows, but they all arise from the same 50 fs sample.
            self.assertEqual(result['maximum_raw_heat_samples_in_window'], 1)
            self.assertFalse(result['passed'])

        def test_a_missing_species_frame_breaks_the_evidence(self):
            trace, species = self.trajectory()
            del species[40]
            result = assess_trace(trace, species)
            self.assertFalse(result['samples_align_at_1000_steps'])
            self.assertFalse(result['passed'])

        def test_atom_loss_is_rejected_even_with_a_heat_episode(self):
            trace, species = self.trajectory()
            trace[50]['O'] = 15
            self.assertFalse(assess_trace(trace, species)['passed'])

    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(AnalysisTests))
    raise SystemExit(0 if result.wasSuccessful() else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, default=SHARED_LAMMPS / 'build/host')
    parser.add_argument('--output', type=Path, help='Evidence destination; reassessment never overwrites its source')
    parser.add_argument('--self-test', action='store_true', help='Run pure-analysis regression tests without MD')
    parser.add_argument('--assess-evidence', type=Path, help='Reassess an existing full trace without rerunning or changing its measurements')
    parser.add_argument('--steps', type=int, default=200000, help='NVE steps after the explicit ignition stage')
    parser.add_argument('--seeds', type=int, nargs='+', default=[49183])
    args = parser.parse_args()
    if args.self_test:
        run_analysis_tests()
    if args.assess_evidence:
        source_path = args.assess_evidence.resolve()
        output = args.output or source_path.with_name(source_path.stem + '-reassessed.json')
        if output.resolve() == source_path:
            parser.error('Reassessment output must differ from its original evidence')
        evidence = json.loads(source_path.read_text())
        if evidence.get('model_sha256') != MODEL_SHA256:
            parser.error('Evidence does not identify the pinned CHO model')
        evidence['original_verifier_passed'] = evidence['passed']
        evidence['reassessment_source_sha256'] = hashlib.sha256(source_path.read_bytes()).hexdigest()
        evidence['reassessed_at_utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        evidence['validator_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        for record in evidence['runs']:
            record['original_verifier_passed'] = record['passed']
            record.update(assess_trace(record['trace'], record['species']))
        evidence['passed'] = all(record['passed'] for record in evidence['runs'])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2) + '\n')
        print(f"Reassessment: {'PASS' if evidence['passed'] else 'FAIL'}; original evidence preserved")
        print(output.resolve())
        raise SystemExit(0 if evidence['passed'] else 1)
    args.output = args.output or APP / 'artifacts/oxidation-validation.json'
    if not 20000 <= args.steps <= 2000000 or args.steps % 1000:
        parser.error('--steps must be a multiple of 1000 between 20000 and 2000000')
    if any(seed <= 0 or seed > 900000000 for seed in args.seeds):
        parser.error('Seeds must be positive LAMMPS random seeds')
    model_hash = hashlib.sha256((SOURCE / 'ffield.reax.cho').read_bytes()).hexdigest()
    if model_hash != MODEL_SHA256:
        raise SystemExit('Model checksum differs from the pinned upstream CHO file')
    evidence = {'recorded_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'model': 'Chenoweth, van Duin and Goddard, J. Phys. Chem. A 112, 1040–1053 (2008)',
        'model_sha256': model_hash,
        'script_sha256': hashlib.sha256((SOURCE / 'experiment.in').read_bytes()).hexdigest(),
        'library_sha256': hashlib.sha256((args.build_dir / 'liblammps.a').read_bytes()).hexdigest(),
        'expected_elements': EXPECTED, 'timestep_fs': .05, 'ignition_steps': 20000,
        'observation_steps': args.steps, 'observation_duration_ps': args.steps * .05 / 1000,
        'species_method': 'ReaxFF instantaneous bond orders, cutoff 0.3; 1000-step samples',
        'validator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'runs': []}
    with tempfile.TemporaryDirectory(prefix='atomify-oxidation-probe-') as temporary:
        root = Path(temporary)
        (root / 'probe.cpp').write_text(PROBE)
        subprocess.run(['c++', '-std=c++17', '-O1', '-I' + str(SHARED_LAMMPS / 'bridge/include'),
            str(root / 'probe.cpp'), str(args.build_dir.resolve() / 'liblammps.a'),
            '-lpthread', '-o', str(root / 'probe')], check=True)
        for seed in args.seeds:
            work = root / str(seed)
            work.mkdir()
            for name in ['ffield.reax.cho', 'reactants.data']:
                shutil.copy2(SOURCE / name, work / name)
            (work / 'experiment.in').write_text((SOURCE / 'experiment.in').read_text().replace('49183', str(seed)))
            started = time.monotonic()
            result = subprocess.run([str(root / 'probe'), 'experiment.in', str(args.steps), '1000'],
                cwd=work, capture_output=True, text=True, timeout=2400)
            record = {'seed': seed, 'exit_code': result.returncode,
                'wall_seconds': time.monotonic() - started, 'error': result.stderr}
            if result.returncode == 0:
                record.update(assess(result.stdout, parse_species(work / 'species.out')))
            else:
                record.update(passed=False, output=result.stdout)
            evidence['runs'].append(record)
            print(f"seed {seed}: {'PASS' if record['passed'] else 'FAIL'}", flush=True)
            if result.returncode == 0:
                print(f"  energy drift {record['post_ignition_energy_drift_kcal_mol']:.4f} / "
                      f"{record['allowed_energy_drift_kcal_mol']:.4f} kcal/mol-system; "
                      f"qualifying consecutive windows {record['longest_consecutive_qualifying_windows']} / 10; "
                      f"terminal heat gate {record['terminal_heat_release']}", flush=True)
    evidence['passed'] = all(run['passed'] for run in evidence['runs'])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + '\n')
    print(args.output.resolve())
    raise SystemExit(0 if evidence['passed'] else 1)


if __name__ == '__main__':
    main()
