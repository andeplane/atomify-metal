# Phase journeys: model, evidence and limits

These three experiences run actual molecular dynamics. They are not scripted atom
animations, and their validation does not call a material “solid” or “liquid” just
because a thermometer passed a threshold. The validation uses structure and
mobility together. Their deliberately small periodic cells and rapid heating or
cooling are educational experiments, not measurements of a bulk melting point.

## A crystal loses its order (`phase-melting`)

256 identical Lennard-Jones particles begin on a face-centered cubic lattice at
number density 0.95. The model uses reduced LJ units: mass, energy scale epsilon
and length scale sigma are 1. It is not ice, argon or a named material. The pair
potential is truncated and shifted at 2.5 sigma. A Langevin bath holds T*=0.12 for
500 steps, heats to 1.6 over 4,000 steps, then holds there; the integration time
step is 0.004 in reduced units. The bath supplies the heat.

The question for the learner is **“When does vibration become flow?”** Observe the
initial repeated lattice, then follow a particle as the original neighbors change.
The distinction is loss of persistent arrangement and increased mobility, not
simply faster movement. Hand forces can perturb that process; the reproducible
validation runs without hand input.

Validation measures the fraction classified FCC or HCP by LAMMPS Common Neighbor
Analysis (CNA), and displacement over a late 10,000-step interval. The CNA cutoff
is 1.45 sigma, between this lattice's first and second neighbor shells. The
neighbor skin is 0.5 sigma, satisfying the CNA ghost-neighbor requirement. A
passing trajectory begins above 90% crystalline classification, ends below 15%
(average of eleven late samples), and has center-of-mass-corrected mean-squared
displacement (MSD) above 1 sigma² during the late interval.

## A seed helps a crystal grow (`phase-crystallization`)

The same LJ model starts from a real pre-equilibrated fluid around a fixed seed.
Of its 256 particles, **32 gold particles form an immobile crystalline template**;
the remaining 224 are mobile cyan particles. This deliberately demonstrates
**seed-assisted growth**, not spontaneous homogeneous nucleation. Cooling removes
energy through the bath. The input holds T*=1.6 for 500 steps, cools to 0.15 over
4,000 steps, then holds there. Quicker cooling is not asserted to give a crystal
for every potential or system; glass formation is a separate scientific question.

The question is **“Can one ordered surface teach a liquid a pattern?”** Follow the
mobile particles near the gold seed and look for order extending beyond the seed.
The validation explicitly excludes the 32 seed particles from its crystalline
fraction. Passing requires mobile FCC/HCP classification below 20% initially and
above 80% late, low late mobility (MSD below 0.15 sigma² over 5,000 steps), and zero
seed displacement. Thus the fixed seed alone cannot produce a passing result.

The bridge's global temperature includes the zero-velocity template particles;
it is consequently lower than the mobile-particle bath temperature. Do not equate
that global thermometer with the bath setpoint or with the temperature of a real
substance.

`seed-liquid.data` contains actual equilibrated positions, velocities and periodic
image counters, generated with a 15,000-step T*=1.6 dynamics run around the seed.
It is not a synthetic random scatter. `seed-preparation.in.txt` records the exact
preparation script. Starting from the data avoids a long hidden initialization
when the wearer enters the experience. Recreating the data requires changing into
an empty writable directory, copying the preparation script, and executing it in
the same pinned LAMMPS engine. The script writes `seed-liquid.data` there. Last-bit
numerical differences across compilers are expected; passing relies on structural
metrics, not byte-identical trajectories.

## Ice becomes moving water (`ice-melting`)

512 **whole-water sites**, initially in a cubic-ice (Ic) oxygen arrangement, use
the published Molinero–Moore **mW** coarse-grained water model. **One sphere is one
H₂O molecule**, not one oxygen atom in an explicit O–H simulation. The potential
uses both short-range two-body and tetrahedral three-body terms. There are no
explicit hydrogen atoms, rotating water molecules, electrostatics, chemical
reactions or individual hydrogen-bond energies in this representation.

The initial cubic-diamond lattice has a 6.3584 Å lattice parameter. After
minimization, the dynamics time step is 5 fs. A Langevin heat bath holds 200 K for
1,000 steps, heats to 380 K over 6,000 steps, then holds. The fixed-volume cell is
intentional: **this experiment does not demonstrate water's density anomaly or
ice expansion**. A perfect finite periodic crystal may superheat, so it does not
assert melting at exactly 273.15 K. The rapid bath schedule is an illustration,
not a physical heating rate for a macroscopic ice cube.

The question is **“What survives when the ice lattice disappears?”** Whole-water
sites lose the long-range lattice while retaining a preference for local
approximately tetrahedral arrangements. Ice-like local geometry alone is not
sufficient to call the final state a crystal.

Validation therefore combines the normalized intensity of four equivalent cubic
{111} Bragg reflections, MSD over a late 50 ps interval, and persistence of each
site's original four nearest neighbors. Passing requires initial Bragg order above
0.35 and late average below 0.05, late MSD above 10 Å², and original-neighbor
retention below 25%. The four-neighbor tetrahedrality is also recorded to explain
why local tetrahedral order and long-range crystalline order are different.

The `mW.sw` parameter file is a direct transcription of the published model, in
LAMMPS `real` units (kcal/mol, Å). It is not claimed to be a file shipped in the
LAMMPS potential directory. Parameters: epsilon=6.189, sigma=2.3925, a=1.8,
lambda=23.15, gamma=1.2, cos(theta0)=-1/3, A=7.049556277, B=0.6022245584,
p=4, q=0, tolerance=0. The header declares `UNITS: real` to prevent accidental
interpretation of 6.189 as eV. Mass is 18.01528 g/mol per whole-water site.

## Reproduce the evidence

```sh
bash vision-atomify/LAMMPS/build-host.sh
python3 vision-atomify/LAMMPS/validate-phases.py --export-previews
```

The validator compiles a small probe against the **actual Atomify bridge and host
LAMMPS static library**, runs each experiment with three thermal-noise seeds,
checks every sampled particle count and coordinate for finiteness, and records
structure samples and measurements in
`vision-atomify/artifacts/phase-validation.json`. It also records the source file
hashes and static-library hash. Exported previews are actual initial simulation
snapshots; none of the phase journeys invents covalent bonds between model sites.
The default suite runs 210,000 dynamics steps across nine independent cases.

The host checks do not prove headset frame rate, hand comfort, thermal performance
or the appearance of the interface. Those remain device acceptance checks.

### Recorded host results

All nine cases passed (three seeds 49183, 12347 and 98731 per experiment), recorded
2026-10-22 23:50 UTC / 23 October in Oslo after the temperature-reporting correction.
The tested static library SHA-256 was
`8502d2694cb18d2998c5be448aba05ac636f2945e810adf6ca7e1874b7695fd0`.

| Experiment | Structural evidence across three seeds | Mobility evidence |
| --- | --- | --- |
| LJ melting | FCC/HCP fraction 100% initially, 0% late in every case | Late MSD 6.87–7.94 sigma² over 40 reduced time units |
| Seed-assisted LJ growth | Mobile FCC/HCP fraction 1.34–1.79% initially, 86.69–99.03% late | Late mobile MSD 0.00798–0.02929 sigma²; all 32 seed sites stayed fixed |
| mW ice melting | Bragg order 0.4678–0.4705 initially, 0.000970–0.001637 late | Late 50 ps MSD 119.7–126.95 Å²; only 0.78–1.22% of original four-neighbor memberships survived |

Final mW four-neighbor tetrahedrality remained 0.640–0.656 (initial ideal crystal
1.0). The liquid therefore retained local tetrahedral preference while losing the
long-range crystal and its original neighboring molecules. These are measured
short-trajectory results for the supplied finite cells, not a phase diagram.

## Primary sources

- Molinero and Moore, *Water modeled as an intermediate element between carbon
  and silicon*, J. Phys. Chem. B 113, 4008–4016 (2009),
  [DOI 10.1021/jp805227c](https://doi.org/10.1021/jp805227c).
  [Author manuscript](https://arxiv.org/pdf/0809.2811), model definitions on pages
  3–6 and the distinction between local tetrahedrality and phase behavior.
- [LAMMPS `pair_style sw`](https://docs.lammps.org/pair_sw.html): parameter order,
  two- and three-body interactions, and potential-file unit metadata.
- [LAMMPS `compute cna/atom`](https://docs.lammps.org/compute_cna_atom.html): crystal
  classification, cutoff sensitivity and required neighbor coverage.
- [LAMMPS LJ unit conventions](https://docs.lammps.org/units.html): reduced units
  and the distinction from real or metal units.
