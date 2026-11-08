# DNA duplex: model, provenance and validation

The Biology experience contains a real, dynamically integrated **20-base-pair DNA duplex**. Each of its 40 colored beads represents an entire nucleotide. It is a coarse-grained oxDNA2 simulation, not an all-atom molecule or a decorative animated helix.

## What the wearer can learn

Two strands twist around one another. Four bead colors identify adenine (A, mint), cytosine (C, blue), guanine (G, orange), and thymine (T, violet). The prescribed duplex pairs A with T and C with G; thermal motion can make the ends breathe. The 38 drawn connections are the model's actual sugar-phosphate backbone bonds. The simulation also evaluates orientation-dependent base-pairing and stacking interactions, although their interaction sites and hydrogen bonds are not individually drawn.

The ordered sequence supplied to the upstream generator is `ACGTACGTTAGCGATACGTA`; the second strand is its antiparallel reverse complement. Atom types are 1=A, 2=C, 3=G, 4=T. The generator's bond ordering carries 3′-to-5′ strand polarity into LAMMPS. Bead radii and colors are visual choices; they do not change the potential. The custom radius directive is 0.70, which the app's presentation parser scales to a drawn 0.21 reduced-unit radius.

## Physical model

The script uses `atom_style hybrid bond ellipsoid oxdna`, FENE backbone interactions, and the published oxDNA2 excluded-volume, sequence-dependent stacking/base-pairing, cross-stacking, coaxial-stacking and screened electrostatic terms. Salt is an implicit 0.2 mol/L parameter; individual water molecules and ions are absent. `nve/dotc/langevin` advances both translational coordinates and nucleotide orientation quaternions, with rotational thermostatting. Adding a second translational integrator would be incorrect.

The fixed model bath is 300 K, represented by reduced temperature 0.1. Temperature changes must update the stacking and screened-electrostatic coefficients together with the thermostat. The current experience does not claim DNA melting, replication, enzymatic biology, covalent chemistry, or a quantitative biological timescale. Observe mode is appropriate until a torque-aware hand interaction has been validated for this orientation-dependent model.

The pinned upstream conversion utility gives length factor 8.518 Å, temperature factor approximately 3000 K, and time factor 1706 fs per reduced unit. Our timestep is 0.001 reduced time units. Generic Lennard-Jones labels must not imply that a raw temperature of 0.1 is 0.1 K or that a center-to-center distance of 1 is 1 Å. The bridge's kinetic energy and temperature currently measure translation only; they exclude nucleotide rotational kinetic energy. Do not call potential plus this kinetic value the complete DNA energy.

## Provenance

The potential file and generator are vendored byte-for-byte from the same `stable_22Jul2025_update1` LAMMPS tag used by the app. `Demos/dna-duplex/SOURCES.json` records URLs and SHA-256 hashes. The upstream reference input and GPL license are retained under `upstream/`. `regenerate.py` calls the unmodified generator with a fixed NumPy seed, then translates the whole duplex to the origin without changing any relative position, quaternion or bond order. No molecular parameters were tuned for visual appearance.

Authoritative sources:

- [Pinned oxDNA2 documentation and coefficient definitions](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/doc/src/pair_oxdna2.rst).
- [Pinned orientation-preserving integrator documentation](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/doc/src/fix_nve_dotc_langevin.rst).
- [Pinned unit conversion utility](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/examples/PACKAGES/cgdna/util/lj2real.py).
- [Pinned CG-DNA examples and credits](https://github.com/lammps/lammps/tree/stable_22Jul2025_update1/examples/PACKAGES/cgdna).
- Model: B. E. Snodin, F. Randisi, M. Mosayebi et al., *J. Chem. Phys.* **142**, 234901 (2015); sequence dependence: P. Šulc et al., *J. Chem. Phys.* **137**, 135101 (2012); LAMMPS implementation: O. Henrich, Y. A. Gutierrez-Fosado, T. Curk and T. E. Ouldridge, *Eur. Phys. J. E* **41**, 57 (2018).

## Actual engine validation

`python3 vision-atomify/LAMMPS/test-dna.py` compiles a probe against the built host library. It exercises the same bridge that supplies the app, plus an independent LAMMPS dump of full-precision quaternion coordinates. The test runs three stochastic seeds, each with 5,000 warmup steps and 100,000 subsequent steps. A checked receipt is saved in `Demos/dna-duplex/validation.json`.

All three tested trajectories retained 40 finite nucleotide positions and exactly the intended 38 published backbone bonds at every snapshot. All quaternion norms stayed within 1e-8 of one, and orientations actually evolved. Every sampled backbone interaction-site distance stayed inside the FENE domain (0.5064 to 1.0064 reduced length units); the observed combined range was approximately 0.5942 to 0.9010. A geometric proxy found 14–20 intended complementary pairs close during the first two runs and 16–20 during the third; all finished with 18 of 20 close. This uses base interaction-site separation below sqrt(0.2), not a hydrogen-bond-energy measurement. It is evidence of short-trajectory helix integrity and end fluctuations, not a melting-point measurement or experimental validation.

The bundled preview contains the real initialized 5,000-step state and its 38 topological bonds, with explicit reduced-unit and nucleotide-representation metadata. Do not export DNA with a tool that hardcodes the carbon 1–1 and 1–2 proximity rules; that adds false crosslinks. Headset visual quality and comfortable scale still require device testing.
