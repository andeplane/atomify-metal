# Renderer performance and look

Measured with `atomify-render-bench` (`src/tools/RenderBench`), which renders
what AtomifyMac shows offscreen: bundled examples run in LAMMPS for a few
hundred steps (`nanotube_water`, `sic_nanoparticle`, `3D-lj-fluid`) and a
1,000,000-atom 3C-SiC crystal (50³ cells, 1,970,150 bonds) built by a LAMMPS
script, with the app's styles, bonds, settings and camera. `sic1m-zoom` is the
same crystal from close by, with most of it out of view.

```sh
swift run -c release atomify-render-bench                    # the table below
swift run -c release atomify-render-bench --shots DIR        # fast and high quality PNGs
swift run -c release atomify-render-bench --scenes sic1m --size 640x400 --in-flight 3
```

Each run turns the camera once around the scene (240 frames) after a warm-up.
Apple M4 Max, 2560×1600 (a Retina window, 2 pixels per point), MSAA 4×,
reverse Z, one frame in flight, so GPU time is the frame's own. Times in ms.

## Before and after

Before is `45f259e` (the renderer as first committed); after is this branch.

| scene | atoms | bonds | quality | GPU mean before | GPU mean after | GPU p95 before | GPU p95 after | fps before | fps after |
| --- | --: | --: | --- | --: | --: | --: | --: | --: | --: |
| water | 2,454 | 2,401 | fast | 0.25 | 0.17 | 0.30 | 0.23 | 2503 | 3216 |
| water | | | high | 0.41 | 0.32 | 0.47 | 0.37 | 1772 | 2105 |
| SiC nanoparticle | 740 | 1,342 | fast | 0.31 | 0.20 | 0.33 | 0.21 | 2201 | 2977 |
| SiC nanoparticle | | | high | 0.60 | 0.49 | 0.63 | 0.53 | 1243 | 1426 |
| LJ liquid | 5,500 | 0 | fast | 0.32 | 0.33 | 0.34 | 0.35 | 2141 | 2123 |
| LJ liquid | | | high | 0.72 | 0.72 | 0.78 | 0.78 | 1079 | 1079 |
| SiC 1M | 1,000,000 | 1,970,150 | fast | **27.75** | **9.61** | 30.05 | 10.65 | 36 | 101 |
| SiC 1M | | | high | **24.43** | **9.84** | 25.97 | 10.90 | 40 | 99 |
| SiC 1M close-up | 1,000,000 | 1,970,150 (963,761 drawn after) | fast | **12.99** | **3.86** | 14.85 | 4.00 | 76 | 242 |
| SiC 1M close-up | | | high | **14.10** | **4.96** | 15.99 | 5.21 | 70 | 191 |

CPU time to encode a frame is 0.01–0.13 ms in every case, before and after.

## What helped

Bonds were the cost: the 1M crystal without bonds takes about 5 ms, and the
bond pass took about 20–30 ms more. The bond pass did not get faster at lower
resolution (640×400 was *slower* than 2560×1600), so it was limited by
geometry, not pixels.

| change | SiC 1M, fast, GPU ms |
| --- | --: |
| first renderer (face-on view; the table above is at an angle) | 34.4 |
| bonds as one rectangle (4 vertices, 2 triangles) instead of a 14-vertex box (12 triangles, drawn without culling, whose back faces also broke the conservative depth promise); cylinders trimmed to the part between the two sphere surfaces | 12.8 |
| rectangle bounded in closed form from the two end spheres instead of projecting 8 box corners in every vertex | 10.0 |
| exact projected extents of the end spheres (the first closed-form bound grew with distance from the view axis; near the camera that made rectangles larger than the screen: 115 ms close-up without culling) | 9.4 |
| bonds grouped by particle block and culled per block like particles (only matters when part of the scene is out of view: close-up 13.0 → 3.9 ms) | 9.6 |

`BondProxy` (Swift) mirrors the bond vertex shader and is tested: the
rectangle covers the cylinder and lies in front of it, the projected extents
are exact, and the trimmed span starts where the cylinder leaves each sphere.
`BondBlocking` groups and culls bonds, also tested.

## What did not help, or was not done

- A screen-size LOD for thin bonds: at 1M atoms in a Retina window a bond is
  still about 2 px wide, so skipping thin bonds would be visible and would not
  remove the cost, which is per bond, not per pixel.
- Fragment work is not the limit (resolution barely changes the time), so the
  bond fragment shader was left as it is.
- Atoms: 1M spheres cost about 4–5 ms and are already culled per block and
  drawn nearest first; nothing cheap was left there.
- Occlusion culling (skipping blocks hidden behind others, which is most of a
  solid crystal) would be the next big step for very large systems: a depth
  pyramid and GPU-driven draws.

## Look

- **Darkness of dense systems.** Density occlusion multiplied all lighting
  down to 10%, so fully lit atoms on the surface of a dense crystal and in a
  liquid were dark brown and murky. Crowding now takes ambient (sky and
  ground) light down to 20% and the key light and highlights only to 75%.
- **High quality ambient occlusion** was blotchy (a random rotation per
  half-resolution pixel, smoothed by a 5×5 nearest-sampled blur) and darkened
  the fronts of atoms (samples nearly in the tangent plane, squared on top).
  Rotations now come from a 4×4 interleaved pattern that a 4×4 bilinear,
  depth-aware blur averages out exactly, samples keep at least 0.35 along the
  normal, and the falloff exponent is 1.5. Occlusion is now soft and stays in
  the crevices.

Screenshots (1200×750, from 1600×1000 renders) are in
[`screenshots/`](screenshots), named `<scene>-<quality>-<before|after>.png`:

| scene | fast | high |
| --- | --- | --- |
| water | [before](screenshots/water-fast-before.png) · [after](screenshots/water-fast-after.png) | [before](screenshots/water-high-before.png) · [after](screenshots/water-high-after.png) |
| SiC nanoparticle | [before](screenshots/sic-fast-before.png) · [after](screenshots/sic-fast-after.png) | [before](screenshots/sic-high-before.png) · [after](screenshots/sic-high-after.png) |
| LJ liquid | [before](screenshots/lj-fast-before.png) · [after](screenshots/lj-fast-after.png) | [before](screenshots/lj-high-before.png) · [after](screenshots/lj-high-after.png) |
| SiC 1M | [before](screenshots/sic1m-fast-before.png) · [after](screenshots/sic1m-fast-after.png) | [before](screenshots/sic1m-high-before.png) · [after](screenshots/sic1m-high-after.png) |
| SiC 1M close-up | [before](screenshots/sic1m-zoom-fast-before.png) · [after](screenshots/sic1m-zoom-fast-after.png) | [before](screenshots/sic1m-zoom-high-before.png) · [after](screenshots/sic1m-zoom-high-after.png) |
