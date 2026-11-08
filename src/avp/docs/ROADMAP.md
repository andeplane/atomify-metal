# Roadmap

## Milestone 1: LAMMPS on the headset, rendered fast (this branch)

- LAMMPS `stable_22Jul2025_update1` built as a static library for visionOS, the visionOS Simulator and macOS (`LAMMPS/build-xcframework.sh`), with a small C bridge (`LAMMPS/bridge`). Two one-line source edits, no fork: `fix atomify` may be created before the box exists, and `shell` does not call `system()` (unavailable on visionOS).
- `fix atomify` runs inside every LAMMPS timestep. It publishes snapshots sorted by atom ID (tag), never by local index, so atoms keep their identity through re-sorting, migration and periodic wrapping. It also pauses, throttles and cancels runs, and applies the app's forces.
- Bonds: real LAMMPS bonds from the topology, distance bonds from the script's `#/bond` lines (cell list, not drawn across periodic boundaries), merged without duplicates.
- Rendering: RealityKit `MeshInstancesComponent`, one instanced batch per atom type and one per type for half bonds, so a system is a handful of draw calls. Sphere detail drops as atom count grows (1280, 320 or 80 triangles).
- 17 demos from Atomify, all checked to run on the bridge.

Open questions for headset testing: frame rate with 5,000+ atoms, sphere detail levels, and whether 60 cm is the right initial size.

## Milestone 2: Touch (implemented, untested on a headset)

- Hand tracking (`HandTrackingProvider`) gives fingertip positions. Convert them to simulation coordinates (inverse of the box transform) and pass them as force spheres. Bridge: `atomify_sim_set_force_spheres`, already tested.
- Grab: on pinch, pick the nearest atom to the pinch point from the latest snapshot, keep its tag, and pull it with a damped spring to the pinch point. Bridge: `atomify_sim_set_grab`, already tested.
- Force strength scales with the unit system (`lj`, `metal`, `real`) so the same gesture feels similar in every demo.
- Freeze: `fix atomify` holds every atom at its frozen position (by tag) after each step, while forces keep being evaluated, and reports the force on the grabbed atom. Bridge: `atomify_sim_set_frozen`, tested.
- Graphs window with Swift Charts: temperature, kinetic and potential energy.

## Milestone 3: Room (implemented, untested on a headset)

- Use VisionRoomKit with scene reconstruction for the room mesh. Hand tracking currently runs in its own ARKit session next to VisionRoomKit's; if visionOS objects to two sessions, hands should move into VisionRoomKit.
- Build a distance grid (about 4 cm voxels) over the room's bounding box from the mesh triangles, off the main thread, and rebuild it when the mesh changes.
- Bridge call `atomify_sim_set_wall_grid` hands the grid to `fix atomify`, which pushes atoms away from surfaces along the grid gradient. The LAMMPS box is the room's bounding box with fixed boundaries, plus `fix wall/reflect` as a safety net.
- A Lennard-Jones gas with σ mapped to a few centimeters, a few thousand atoms, hands pushing as in Touch.

## Billboards (implemented, untested on a headset)

- `ImpostorRenderer` in AtomifyKit: ray-traced sphere and cylinder impostors with real depth (reverse Z), two instanced draws per eye. Offscreen tests on macOS check the depth of spheres, cylinders and intersecting spheres.
- The app's billboard lab (`Atomify/Lab/BillboardLab.swift`) renders it through CompositorServices in mixed immersion, with world tracking for the head pose and the same driver (hands, room walls) as the sphere lab.
- Open questions for the headset: frame rate and LAMMPS speed with 108,000 atoms, whether pinch spatial events move the box reliably, and whether foveation (off for now) is worth adding.

## Licensing

LAMMPS is GPLv2 and the bundled Atomify examples come from GPLv3 projects, so builds that link LAMMPS are GPL. Worth deciding before any App Store distribution.
