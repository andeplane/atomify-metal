# A spark in methane

A small, deliberately compressed reactive molecular-dynamics experiment:

- 4 methane molecules and 8 oxygen molecules (36 atoms).
- The published Chenoweth–van Duin–Goddard C/H/O oxidation ReaxFF, with charge equilibration every step.
- A 1 ps ignition preparation at a nominal 5500 K warms molecular internal modes.
- The ignition thermostat is then removed. Subsequent motion is constant-volume NVE dynamics with no prescribed products, temperature rescaling, or added heat.
- Time step: 0.05 fs. The validation observation is 10 ps (200,000 steps).

This is a qualitative, accelerated model of a tiny hot reactor, not the temperature, pressure, reaction rate, emissions or safety behavior of an ordinary methane flame. It contains no nitrogen from air. Expect radical and intermediate species, not a perfectly timed animation of `CH4 + 2 O2 → CO2 + 2 H2O`.

The preview depicts the starting reactants, before ignition. The app's distance-based bond drawing is illustrative. `species.out` is the separate validation measurement: connected species classified from actual ReaxFF bond orders using LAMMPS' default 0.3 cutoff. Bond-order classification is model dependent and can fluctuate at high temperature.

## Provenance

`ffield.reax.cho` is copied without edits from the LAMMPS release `stable_22Jul2025_update1` (commit `26e5f79b4e5aa77b65fc4fbf314b206bf0530b45`):

https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/potentials/ffield.reax.cho

SHA-256: `c5240c07e664dde5626fcdb740be1bdbe5e7e34d919902603db0bf962fea9aee`.

LAMMPS explicitly identifies this parameter file with:

Kimberly Chenoweth, Adri C. T. van Duin and William A. Goddard III, “ReaxFF Reactive Force Field for Molecular Dynamics Simulations of Hydrocarbon Oxidation,” *J. Phys. Chem. A* **112**, 1040–1053 (2008). DOI: [10.1021/jp709896w](https://doi.org/10.1021/jp709896w).

`README.upstream` and `LICENSE.lammps` preserve the upstream example's applicability warning and the pinned distribution's GNU GPL v2 license. The LAMMPS potentials mapping is [README.reax](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/potentials/README.reax). This is the CHO combustion model, **not** the RDX nitramine model used by the older bundled explosive example.

The initial tetrahedral methane and diatomic oxygen coordinates were generated for Atomify and relaxed by this potential. No experimental structure or product coordinates are used.

## Reproduce

From the repository root, after building the host LAMMPS archive:

```sh
python3 vision-atomify/LAMMPS/validate-oxidation.py --steps 200000
```

For independent velocity seeds:

```sh
python3 vision-atomify/LAMMPS/validate-oxidation.py --steps 200000 --seeds 49183 12347 98731
```

The validator requires conserved C/H/O both in snapshots and in species assignments, finite state, bounded total-energy drift after ignition, a sustained sequence of water plus carbon-oxide species, and an increase in averaged kinetic temperature accompanied by a decrease in potential energy. A hotter frame alone does not pass. Tiny reactive systems need not ignite within the same observation window for every random seed.
