# Peptide and amphiphile experiences

These experiences complement the [coarse-grained DNA duplex](dna-model.md). They use different physical models and should not be mixed into one reaction engine.

## Peptide in water

The upstream LAMMPS `peptide` example contains an 84-atom, five-residue peptide and 640 three-site water molecules: **2,004 chemical atoms**, 1,365 fixed bonds, 786 angles, 207 dihedrals and 12 impropers. The bonded/nonbonded terms are CHARMM-style with long-range Coulomb interactions evaluated by PPPM. SHAKE constrains the configured fast bond/angle motions; the bath is 275 K and the timestep is 2 fs.

This is an atomistic fixed-topology fluctuation experiment. It does not establish a protein-folding pathway or support covalent bond breaking. Observe mode permits examining and repositioning the whole experiment without applying unvalidated forces to constrained bonds. Atom types 1–12 belong to the peptide; types 13–14 are solvent oxygen/hydrogen.

The library preview isolates the **84 actual peptide atoms** and their 85 actual covalent connections from the initialized 300-step engine snapshot. The 640 water molecules are omitted only in this preview; they remain present in the live simulation. The preview JSON records this representation explicitly. Its thumbnail is a native SceneKit render of that real geometry.

`data.peptide` is byte-identical to the pinned `stable_22Jul2025_update1` upstream example. The app input retains the physical model, with its existing element/camera comments and logging/group additions. Sources and hashes are recorded beside the demo.

## Heads, tails and self-organisation

The LAMMPS `micelle` example is a **two-dimensional coarse-grained surfactant toy**, with 150 three-bead amphiphilic chains and 750 solvent beads: 1,200 model particles and 300 harmonic backbone connections. Type 1 is solvent, type 2 a water-loving head, and types 3–4 water-avoiding tail beads. The model distinguishes their Lennard-Jones attractions, repulsions and effective sizes. These colors and parts do not identify chemical elements.

The simulator first performs a 1,000-step soft-potential push-off, then switches to the original main interaction model at reduced bath temperature 0.45. The app now loads after 1,000 main steps instead of hiding 100,000 steps in initialization. Subsequent organisation remains visible in the lab. The initial library preview contains the actual full 1,200-bead starting state. Its thumbnail crops the central region of the same geometry to make individual heads and tails legible.

Grouping is worth watching, but a colored cluster is not by itself evidence of a micelle, bilayer or biological membrane. This simplified flat model illustrates how selective interactions encourage association. It does not represent a calibrated lipid species, explicit molecular water, realistic solvent hydrodynamics or a complete cell membrane. Observe mode is the supported featured interaction.

The local data has the same topology and physical coordinates as the pinned upstream data after periodic wrapping; maximum modulo-box deviation is below 1e-13. Its input retains the upstream soft push-off and main coefficients, with existing cluster/logging additions, new presentation colors and the shorter visible startup. Sources and hashes are recorded beside the demo.

## Temperature correction and actual tests

Promoting the constrained peptide exposed an existing bridge error: computing temperature with `3N−3` degrees of freedom ignored the constraints and displayed approximately 181–193 K for this 275 K bath. Snapshot publication now evaluates LAMMPS's initialized default temperature compute, which includes the constraint-adjusted degrees of freedom. The kinetic-energy field remains the directly summed translational kinetic energy; it is not reconstructed from temperature.

`python3 vision-atomify/LAMMPS/test-biology.py --export-previews --output vision-atomify/Demos/peptide/biology-validation.json` runs the actual compiled bridge and compares its temperature with an independently evaluated LAMMPS `$(temp)` value. It checks 10,000 additional peptide steps, 10,010 additional amphiphile steps, an unconstrained Lennard-Jones control and a cold minimized control. Every sampled coordinate must be finite. Every displayed connection must be a real bond from the input topology; every non-wrapped bond must appear. Fixed-bond distances are checked with the minimum-image convention, and amphiphile beads must remain in their two-dimensional plane.

At the micelle's 100-step velocity-rescaling boundaries, Atomify's end-of-step publication precedes the later rescaling fix; post-run thermo observes the later velocity projection. Temperature equality is therefore checked at ten non-rescaling sample steps. The actual 1,000-step starting frame is retained for geometry and preview checks. This sampling distinction does not change the physical model.

The final local run passed all four cases. Peptide temperatures spanned 269.27–285.80 K, with bridge-versus-LAMMPS difference exactly zero at every sample. Its fixed-bond minimum-image distances stayed between 0.9572 and 1.9067 Å. The amphiphile trajectory stayed finite and strictly planar from step 1,000 through 11,010; all 300 input connections remained geometrically valid. Its comparable non-rescaling samples also matched the reference exactly. The unconstrained control matched at every sample, and the cold minimized control remained exactly zero temperature.

A geometric tail-association indicator counts connected groups of tail beads within 1.5 reduced length units over time. It is a reproducible structural observation, not a claim that the final morphology is a biological membrane. In this run the number of such groups changed from 64 to 42 while the largest contained 18 initially and 26 at the end, with intermediate growth and rearrangement. The receipt contains the observed timeline and exact temperature comparisons. Device frame rate, hand comfort and legibility still require headset testing.

Primary references:

- [Pinned peptide example](https://github.com/lammps/lammps/tree/stable_22Jul2025_update1/examples/peptide).
- [Pinned micelle example](https://github.com/lammps/lammps/tree/stable_22Jul2025_update1/examples/micelle).
- [Pinned temperature compute implementation](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/src/compute_temp.cpp).
- [LAMMPS temperature definition](https://docs.lammps.org/compute_temp.html).
- [LAMMPS SHAKE constraints and degrees of freedom](https://docs.lammps.org/fix_shake.html).
