# Atomify: questions across matter

Updated 23 October 2026. This map separates working experiments from future
models. Each question needs its own appropriate interactions, representation and
numerical checks; one potential cannot reliably cover all biology and chemistry.

## In the app

| Family | Working examples | What to learn |
| --- | --- | --- |
| Small molecules | Benzene, methane, ethane | Geometry, local angles, flexibility and force response |
| Carbon solids | Finite sheet and diamond | Same element, different coordination and structure |
| Porous solids | ZSM-5 silica framework | Repeating channels and the role of empty space |
| Molecular gas | Explicit water vapor | Translation, rotation and local molecular geometry |
| Genetic material | 20-base-pair oxDNA2 duplex | Two backbones, base identities and nucleotide-scale organization |
| Peptide in solvent | Five amino acids plus 640 water molecules | A flexible chain surrounded by explicit water; fixed topology |
| Amphiphilic organization | 150 three-bead chains plus solvent, flat LJ toy | How head/tail affinities can produce association |
| Melting | 256-site LJ crystal | Persistent crystal order gives way to rearranging motion |
| Seeded crystallization | 32 fixed seed sites, 224 mobile sites | An ordered template can help a liquid organize |
| Ice and water | 512-site mW ice-Ic melting | Long-range order can disappear while local tetrahedral preference remains |
| Reactive chemistry | 4 CH₄ + 8 O₂, CHO ReaxFF | Ignition, products, and chemical potential energy becoming kinetic energy |
| Room-scale physics | Gas, droplets and driven particles in measured geometry | Motion and interaction with actual observed surfaces |

These examples have different coarse-graining levels. A DNA sphere is a
nucleotide; an mW sphere is a whole water molecule; a surfactant bead represents
part of a model chain. The UI names those differences. None establishes a complete
protein-folding, cell, arbitrary-reaction or electronic-structure simulator.

## Strong next additions

| Family | A strong spatial question | Model and validation needed |
| --- | --- | --- |
| Gas hydrates | How can water cages trap methane? | A jointly parameterized methane–water model, cage topology and occupancy, comparison to known hydrate structure; do not mix current unrelated potentials |
| Membranes and vesicles | Why can a sheet assemble and seal itself? | A validated amphiphilic bilayer model; distinguish membrane from the current 2D surfactant toy; area, thickness and permeability checks |
| Polymers | Why does stretching a chain change its behavior? | Bead-spring entropic chains, relaxation and force–extension curves; mark coarse beads explicitly |
| Metals and defects | How can a missing layer change a solid? | Appropriate EAM metal potential, FCC/BCC/HCP structures, dislocations and validated loading; avoid extrapolating tiny cells to bulk strength |
| Glass and competing order | Why can cooling make a crystal or a glass? | Appropriate glass former, multiple cooling rates/seeds, order and mobility metrics; current seeded growth is not proof of universal crystallization |
| Colloids and Brownian motion | Why does a small particle never sit still? | Langevin diffusion with measured mean-squared displacement and fluctuation–dissipation consistency |
| Transport and statistical physics | How does an imbalance relax? | Diffusion, mixing and heat flow; conservation and finite-size controls, not only attractive visuals |
| Electrical and magnetic matter | How do invisible fields organize motion? | A separate documented field/spin model with explicit energy and units; not a claim supported by the current atom-force potentials |

Gas hydrate is especially promising for Vision Pro: transparent cages, a guest
molecule, cage-count overlays and a comparison with ordinary ice. A suitable
primary starting point is Jacobson and Molinero, *A Methane–Water Model for
Coarse-Grained Simulations of Solutions and Clathrate Hydrates*,
[DOI 10.1021/jp1013576](https://doi.org/10.1021/jp1013576). That is a parameterized
joint methane–water model, not the existing mW water alone. A reliable first
experience could begin from a known hydrate and examine cage stability; spontaneous
nucleation is a rarer process and should not be promised on a short headset visit.

Biology could later extend toward membranes, polymers and protein structure
exploration. Quantitative folding, catalysis and arbitrary biochemistry demand
additional validated models and substantially different time scales. The best
next experiments should each deliver one visible, testable discovery.
