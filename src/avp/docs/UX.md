# Atomify UX proposal

The goal is a calm app: one window, one simulation floating in the room, and never more than one menu deep. What the hands do depends on the mode, so the mode is picked before a simulation starts, not switched mid-run.

## Modes

| Mode | What you get | What hands do |
| --- | --- | --- |
| **Watch** | A simulation in a box in front of you, about 60 cm across. | Pinch with both hands, as if holding the box (one pinch alone is left for windows): moving both hands together carries the box, turning or spreading them rotates and resizes it. **Step inside** centers the box on your head and makes it at least 4 m across, so the atoms are all around you; **Step out** puts it back. |
| **Touch** | Same box, but the atoms react to you. | Your whole hand and forearm push atoms away, and cupped hands hold them. Hands are solid: atoms can't get inside them, and a fast swipe sweeps atoms along instead of passing through. Pinch next to an atom to grab it and pull it around; let go to release it. Each hand can hold its own atom, so you can pull two apart or press them together. To move the box, pinch the handle under it and pinch with your other hand. |
| **Room** | No box. Atoms float in your room and bounce off walls, floor and furniture, using the room mesh. | Hands push atoms like in Touch. |

All three modes are implemented. In Touch and Room, pushing and grabbing are always on together (the whole hand and forearm push, modelled as overlapping spheres along every finger bone, across the palm and up the forearm, so a cupped hand holds atoms; a pinch grabs), so there is no hands toggle.

## Window

The window has two states.

**Library** (when nothing runs)

- A segmented picker at the top: Simulations or In your room, which have different simulations. Next to it, for Simulations, a **Touch atoms** switch picks Touch over Watch; demos that don't suit Touch say "Watch only" and open in Watch.
- Picture cards, one category at a time (Molecules, Materials, Fluids and grains, Flat worlds), so nothing needs scrolling. Each picture is rendered from the demo itself (`DemoThumbnailTests` writes Demos/<folder>/thumbnail.jpg).
- Later: "Open script" to run your own LAMMPS input from Files.

**Running**

```
 Water vapor                                          [Library]
 Low density water gas with the Vashishta potential.

 Atoms 3,000   Bonds 1,980   Temperature 337 K   Steps/s 3,320

 [Pause] [Restart]  ( Slow | Normal | Fast )            [View ▾]
```

- **Play/Pause, Restart, Speed** are the only transport controls. Speed caps the integration rate (Slow 20 steps/s, Normal 120, Fast unlimited), so a fast simulation can be slowed down to watch individual collisions.
- **View** menu: Bonds on/off, Simulation box on/off, Draw atoms as (Spheres, Billboards), Atom size (Small, Normal, Large).
- One mode-specific control, only in that mode: Touch gets *Freeze* (atoms stop moving, forces are still computed, so dragging an atom shows the force on it); Room gets *Atoms: Fewer / Normal / More*, which restarts the gas. The atoms wait until the first scan has produced walls (or 10 seconds pass), then walls found later are added during the simulation as the room mesh updates, so there is no Rescan button.
- **Graphs**: a button on the numbers row opens a small second window with temperature, kinetic and potential energy over time, and in Touch with Freeze on, the force on the grabbed atom (the first one, when both hands hold one).

Later, the running controls can move into an ornament under the simulation box so the window can be closed while watching.

## Things deliberately left out

- No per-atom-type color editor; colors come from the script's `#/atom` lines (same as the web app) and a fixed palette.
- No camera controls; you walk around the box or move it.
- No LAMMPS console in the headset. Script errors show as one line in the window.

## Rendering: spheres or billboards

Two renderers draw the same lab, picked under **View > Draw atoms as**:

- **Spheres** (default): real instanced RealityKit geometry, with fewer triangles as atom count grows and at most 40,000 atoms drawn. RealityKit has no custom Metal shaders and its materials cannot write per-pixel depth, so it cannot do billboards itself. When a system has more atoms than the cap, the window says so and offers to switch.
- **Billboards**: a Metal renderer through CompositorServices, in its own mixed immersive space. Each atom is a camera-facing square whose fragment shader ray-traces the sphere and writes its true depth, so atoms intersect each other, bonds and your hands correctly. Bonds and box edges are ray-traced cylinders. Every atom is drawn, in two instanced draw calls. Moving, turning and resizing the box uses pinches (system spatial events, the same `BoxGrip` as the sphere lab's SpatialEventGesture): always with both hands, since a single pinch is how windows and buttons are used: any two pinches in Watch; in Touch, one on the handle under the box and a second anywhere. Two pinches turn the box with the line between the hands, scale it with their distance and carry it with their midpoint (`BoxPlacement` in AtomifyKit). Rendering is foveated (full display resolution where you look) with 4x multisampling; fragment shaders output analytic edge coverage as alpha, which alpha-to-coverage turns into smooth silhouettes. A demo can ask for periodic copies (`copies` in demos.json): the nanoporous glass simulates 192,000 atoms and draws them 3×3×3 times, 5.2 million atoms in view, by shifting the same GPU buffer per copy. Copies and parts of copies outside the view are skipped, and while more than 800,000 atoms would be drawn per eye, the copies farthest from you are drawn with a quarter, then a sixteenth, of their atoms, each larger so they fill the same space; the near ones keep every atom.

The demo "Large liquid (108,000 atoms)" is there to show the difference.
