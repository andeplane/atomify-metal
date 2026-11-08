# Methane oxidation: model and evidence

The older Atomify examples included a nitramine ReaxFF parameterization for RDX. Reusing that file because it contains C, H and O would not establish applicability to methane combustion. This experiment instead vendors the explicit C/H/O hydrocarbon-oxidation parameter set distributed by LAMMPS and attributed to Chenoweth, van Duin and Goddard (2008).

## What actually runs

`Demos/methane-oxidation/experiment.in` loads four CH4 and eight O2 molecules in a periodic 14 Å cube. The element counts are C4 H16 O16; the mass density is approximately 0.194 g/cm³. The compressed volume increases encounter frequency in a small visual demonstration. It is not atmospheric-pressure methane/air.

The script first minimizes the starting geometry with the same reactive potential. It then assigns Maxwellian velocities and uses a 5500 K Nosé–Hoover ignition thermostat for 20,000 steps (1 ps). The thermostat is explicitly removed, the visible observation clock is reset, and all subsequent dynamics use NVE integration. QEq solves partial charges every step to a 1e-8 tolerance with up to 500 iterations. The time step is 0.05 fs. Neither an external heat source nor predefined product topology remains in the observation stage.

Heating is assessed **after** removing ignition. Molecular kinetic temperature initially fluctuates and can fall as energy enters vibrations or dissociation; the learning experience must not promise a monotonic temperature rise. A reaction redistributes the existing total energy between potential and kinetic terms. The long-time averages and species assignments together are the useful evidence.

`fix reaxff/species 1 1 1000` classifies instantaneous connected species from ReaxFF bond orders at the default 0.3 cutoff. There is no multi-step bond averaging that would force infrequent neighbor-list rebuilds. Neighbor checks remain every step. Formula counts conserve C/H/O at every recorded species frame. This species classifier is distinct from the app renderer's geometric bond lines.

## Validation gate

`LAMMPS/validate-oxidation.py` compiles a probe against the actual static LAMMPS/Atomify bridge, executes the checked-in script in an isolated temporary folder, and samples state every 1000 steps. It writes the library and script SHA-256, seed, trajectory energies, temperatures and bond-order species into an ignored artifact.

A trajectory passes only when all of the following hold:

1. Every sampled coordinate, temperature and energy is finite; atom counts and element identities remain C4 H16 O16.
2. Every species assignment accounts for the same elements, without deleting products.
3. Maximum NVE total-energy deviation is no greater than 1% of the initial kinetic energy (with a 1 kcal/mol-system absolute floor).
4. Each qualifying observation window contains at least ten consecutive species samples with both H2O and CO or CO2 (50 fs between recorded frames).
5. A qualifying window's mean kinetic temperature exceeds the initial mean by at least 300 K and its mean potential energy falls by at least 30 kcal/mol-system. The baseline and observation windows each use 20 samples (approximately one picosecond), without overlapping the baseline.
6. At least ten successive qualifying windows must satisfy both the heat and product gates. Windows advance by one 1000-step sample and overlap; ten successive windows add 450 fs of persistence beyond the first window. A single lucky qualifying window does not pass.
7. Each qualifying window also contains **at least ten distinct raw samples** individually meeting both the same +300 K temperature and −30 kcal/mol-system potential-energy thresholds relative to the initial baseline means. They need not be consecutive, but one extreme sample cannot generate apparent persistence through overlapping averages. Product persistence remains a separate requirement in that same window.
8. Snapshot and species samples must align on the complete 1000-step cadence. A missing species sample does not count as an uninterrupted product observation.

The validator records the **earliest sustained exothermic episode**, its first and last qualifying windows, their actual intervals, product persistence, distinct qualifying raw heat-sample counts, and minimum heat/potential-energy changes. It also retains the original final-window temperature/potential-energy metrics and `terminal_heat_release` / `terminal_verifier_passed` verdicts. The energy-drift, element and finite-state gates still apply to the **entire** requested trajectory, including frames after the detected episode.

The temperature (+300 K), potential-energy (−30 kcal/mol-system), product (ten consecutive frames), averaging-length and total-energy limits are unchanged from the initial validator. The additional consecutive-window requirement, support from distinct raw samples, and coincident product observations prevent a lone endpoint, isolated thermal excursion or unrelated product interval from establishing the phenomenon. These gates detect an illustrative exothermic trajectory with limited integration drift. They do **not** validate quantitative flame temperatures or reaction kinetics. “kcal/mol-system” here denotes LAMMPS real-unit energy for the complete simulated collection, not energy per methane molecule.

## Measured host results (23 October 2026)

The app script was executed against the real bridge/static engine for three independent velocity seeds, each for 200,000 post-ignition steps (10 ps). All three conserved 36 atoms and C4 H16 O16, produced finite snapshots, conserved elements in bond-order species assignments and met the NVE total-energy drift limit.

| Velocity seed | Early / late mean kinetic temperature | Mean potential-energy change | Max total-energy deviation | Water + CO/CO2 classification | Exothermic illustration gate |
|---|---|---|---|---|---|
| 49183 (app preset) | 5684.6 / 6801.6 K | −118.97 kcal/mol-system | 3.445 kcal/mol-system (limit 6.060) | 83 consecutive sampled frames | Pass |
| 12347 | 6537.6 / 6517.0 K | +1.01 kcal/mol-system | 4.237 (limit 7.046) | No simultaneous water/carbon oxide within 10 ps | Not reached |
| 98731 | 4724.3 / 4744.3 K | +0.89 kcal/mol-system | 5.079 (limit 5.403) | 117 consecutive sampled frames | Not reached |

The preset demonstrates chemical energy redistribution after ignition: the approximately 119 kcal/mol-system potential-energy decrease is much larger than the 3.45 kcal/mol-system maximum total-energy deviation. Other seeds demonstrate why neither a reaction deadline nor a monotonic temperature rise should be promised. These are actual dynamically emerging species; product atoms are never created, deleted or moved into target coordinates.

Separate exploratory controls with nominal ignition temperatures of 3500 K and 4500 K remained mostly reactants/intermediates and did not meet the exothermic gate over the same 10 ps. These controls were exploratory, not authored app presets.

Extending the other seeds to 20 ps gave the following:

| Velocity seed | Early / late mean kinetic temperature | Mean potential-energy change | Max total-energy deviation | Complete validation gate |
|---|---|---|---|---|
| 12347 | 6537.6 / 7568.0 K | −107.02 kcal/mol-system | 4.237 (limit 7.046) | Pass; 140 consecutive water + carbon-oxide frames |
| 98731 | 4724.3 / 6235.1 K | −152.84 kcal/mol-system | **6.768 (limit 5.403)** | **Fail**; chemistry and heating occurred, but numerical energy drift exceeded the fixed gate |

No threshold was loosened to admit the failed trajectory. This limits the demonstrated numerical validation to the stated seeds and time windows. Longer observations and arbitrary initial conditions are not established as quantitatively reliable thermochemistry.

The final exact app script was rerun after adding illustrative C–C and H–H drawing directives; its 10 ps preset trajectory reproduced the temperatures, energies and 83 consecutive product frames above. Those directives are comments to LAMMPS and do not alter the force model. The extended-seed runs used identical MD commands with the earlier drawing directives.

The full sampled traces and bond-order species records are in ignored `artifacts/oxidation-validation.json`, `oxidation-validation-seed12347.json`, `oxidation-validation-seed98731.json`, `oxidation-validation-20ps-seed12347.json` and `oxidation-validation-20ps-seed98731.json`. The latest exact-preset repeat against the final host archive took 61.7 seconds on this Mac mini. The additional seeds used the earlier host archive, identified separately in `Demos/methane-oxidation/validation.json`. This does not establish headset throughput.

- Parameter-file SHA-256: `c5240c07e664dde5626fcdb740be1bdbe5e7e34d919902603db0bf962fea9aee`.
- Validated app-script SHA-256: `cd57a152c63594c742788d811f71b69a321c20c80f2ee3c9197aa19915e1cb06`.
- Latest preset host-library SHA-256: `8502d2694cb18d2998c5be448aba05ac636f2945e810adf6ca7e1874b7695fd0`.

## Cross-platform endpoint failure and correction

Linux CI run [39876271970](https://github.com/andeplane/AppleVisionProProjects/actions/runs/39876271970), commit `d58339585af32ece570194287de997fa6bf1f78f`, exposed a flaw in the original **terminal-window-only** reaction gate. Compiler-dependent numerical differences change a chaotic tiny reactor's induction and later chemistry; matching the velocity seed does not require identical trajectories across toolchains.

The original Linux run remains a recorded failure under that original gate:

- Initial / final window means: 6109.2 / 6275.2 K (only +166 K).
- Final-minus-initial mean potential energy: −14.47 kcal/mol-system.
- All atoms and elements conserved; finite snapshots and species assignments.
- Maximum total-energy deviation: 3.775 kcal/mol-system, below its unchanged 7.157 limit.
- Water and a carbon oxide persisted for 41 consecutive sampled frames, first appearing together at 8.0 ps.

Inspecting the **existing full trace**, without rerunning, shortening, fabricating or extending it, found a sustained qualifying exothermic episode before the arbitrary 10 ps endpoint:

| Observation | Mean temperature rise | Mean potential-energy change | Consecutive product frames |
|---|---|---|---|
| First qualifying window, 7.50–8.45 ps | +628.47 K | −62.52 kcal/mol-system | 10 |
| Last window in the uninterrupted sequence, 7.95–8.90 ps | +338.20 K | −32.46 kcal/mol-system | 19 |

Ten successive overlapping windows meet the unchanged numerical gates. Each also contains 10–16 distinct raw samples individually meeting both heat thresholds; the Linux result does not depend on a single extreme frame. Further redistribution then lowers the terminal average. A requirement to remain above an arbitrary terminal threshold contradicts the app's explicit lesson that temperature need not rise monotonically. The revised verifier tests the observed, sustained phenomenon while preserving the terminal metrics and original failed verdict in reassessment evidence.

Reassessing all archived host trajectories preserves their original positive and negative verdicts: the 10 ps Mac preset and 20 ps seed 12347 pass; seeds 12347 and 98731 at 10 ps remain unconfirmed; seed 98731 at 20 ps remains a failure because energy drift exceeds the fixed gate. A further **20 ps preset** run also remains a failure: drift **11.266 > 6.060** kcal/mol-system, despite clear reaction/heating. Thus merely extending every test to 20 ps is not an established numerical fix. The app's demonstrated validation window remains 10 ps; longer trajectories are not quantitatively established.

The eight pure-analysis regression tests cover a sustained heat episode followed by cooling, absent products, products at an unrelated time, energy drift masquerading as heat, an unsustained pair of qualifying windows, one extreme raw thermal sample, a missing species frame and atom loss:

```sh
python3 vision-atomify/LAMMPS/validate-oxidation.py --self-test
```

To reproduce the Linux reassessment without another long MD run:

```sh
python3 vision-atomify/LAMMPS/validate-oxidation.py \
  --assess-evidence /tmp/atomify-linux-validation/oxidation-validation.json
```

This writes `oxidation-validation-reassessed.json` separately, preserves the original measurements and failed verdict, records the original evidence's SHA-256, and identifies the revised analysis method. It is an analysis of the downloaded physical run, not a claim that the original CI job turned green. Local ignored copies are `artifacts/linux-oxidation-endpoint-failure.json`, `artifacts/linux-oxidation-reassessed-v2.json`, and the all-trace replay summary `artifacts/oxidation-analysis-replay-v2.json`.

## App study window

The app now requests exactly **200,000 NVE observation steps (10 ps)** after the ignition input finishes, using `LammpsSimulation.continuationSteps` for this experiment only. It does not silently continue this reactor into the known, unvalidated longer interval. Other experiments retain their existing continuation behavior.

Successful completion keeps the study frame, explanation/particle inspector and graphs available. The controls label the 10 ps observation complete; Reset restarts from the original prepared input rather than extending the old reactor. Pausing or changing playback speed changes wall-clock pacing, not the model's 0.05 fs integration step or its finite observation length. Actual completion time depends on device throughput.

This bounds the app lesson to its demonstrated validation interval; it does not establish a general long-time thermochemical model. The 20 ps failures above remain part of the evidence.

## Scope and presentation

- The observation should identify the ignition energy separately from subsequent chemical energy redistribution. The app marks input preparation and clears its graph history when the input finishes or the clock resets, so the ignition preparation is not mixed into the subsequent observation history.
- Show declared model time (LAMMPS real units use femtoseconds; 1000 fs = 1 ps), actual kinetic temperature, and a clear statement that these are accelerated, compressed model conditions.
- Observe mode is the appropriate default for the energy demonstration. Pulling atoms applies external work and invalidates a closed-system energy explanation.
- An isolated tiny reactor has fluctuations and seed-dependent induction times. Do not script a successful product count or require every seed to burn on cue.
- Do not reuse this model as a general-purpose description of DNA, proteins, ice, hydrates, metals or arbitrary chemistry.
- Host trajectories prove the model can perform the demonstrated process. They do not prove headset performance, comfort or the rendered bond interpretation.
- Live energy curves are downsampled; potential-energy tallies can be cached between engine updates while kinetic energy uses the current snapshot. Do not infer per-step energy conservation by adding arbitrary displayed samples. The quantitative validator samples aligned 1000-step thermo checkpoints.

## Primary sources

- [Chenoweth et al., hydrocarbon oxidation ReaxFF paper](https://doi.org/10.1021/jp709896w).
- [Pinned LAMMPS CHO parameter file](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/potentials/ffield.reax.cho).
- [LAMMPS model-to-publication mapping](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/potentials/README.reax).
- [LAMMPS CHO example applicability notes](https://github.com/lammps/lammps/blob/stable_22Jul2025_update1/examples/reaxff/CHO/README).
- [LAMMPS ReaxFF species measurement](https://docs.lammps.org/fix_reaxff_species.html).
