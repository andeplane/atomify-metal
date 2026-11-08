# A focused Atomify release

Five live molecular dynamics experiences, one way to touch them, and a small
panel. Everything else was removed so this part can be excellent.

## Experiences

The carousel shows the release lineup from `Demos/demos.json` (entries with a
`releaseOrder`): `water`, `zeolite_zsm5`, `surface-diffusion`,
`sic_nanoparticle` and `cnt_deformation`. Each entry can set:

| Field | Meaning | Default |
| --- | --- | --- |
| `stepsPerSecond` | Integration rate at Normal speed | 120 |
| `frame` | `"atoms"` fits the view to the actual atoms; `"box"` fits the simulation box | box |
| `showsBox` | Draw the simulation box edges | no |
| `hint` | The one line the panel shows under the controls | the summary |
| `wholeMolecules` | Draw molecules whole across periodic faces (display only; picking and grabbing map back to each atom's simulated position) | no |

Slow runs at 0.3 × Normal; Fast is unlimited. Bonds are always drawn.

## Entering the lab

Start opens a mixed immersive space, closes the carousel and opens the controls
panel as a utility panel near the wearer. The experiment appears about 1 m in
front of the head, along the direction the wearer faces (heading only), its
centre 15 cm below eye level, anchored in the room. Its longest visible side is
55 cm. Without a usable head pose (for example in the Simulator) it opens at
(0, 1.2, −1) m. Digital Crown recenter and the panel's Recenter button place it
in front of the wearer again, upright and at its initial size. Restart keeps it
where the wearer put it.

## Gestures

One interaction model, no modes, no handles or bars:

- **One hand: pinch an atom to pull it.** A direct pinch takes the nearest atom
  within 3.5 cm of the pinch (or within a large atom's drawn radius). A pinch
  while looking at an atom takes the atom the gaze ray hits, with a tolerance of
  about 2.5° of visual angle; looking past every atom does nothing. The atom
  follows the hand one to one for direct pinches and with distance-based gain
  for indirect ones, through a smoothed spring that is refreshed every frame.
- **Two hands: pinch to move, turn and resize.** Moving both hands carries the
  experiment, changing their distance scales it (0.1–8 ×), turning the line
  between them turns it, and twisting both wrists rolls it about that line.
  While both hands hold it, any held atom is released, hand pushing stops and
  the system overlays (hand menu) are deferred so a wrist roll does not open
  them. Letting go with one hand never grabs an atom: nothing happens until both
  hands have opened.
- **Hands and forearms push atoms** when no pinch is down.

Feedback: the atom nearest a hand within reach is marked by a barely larger,
slightly brighter sphere in its own colour; a held atom glows clearly in its
own colour, and a soft spatial sound plays at it when the grab begins. Nothing
is selected automatically and there is no translucent shell.

Two in-context tips teach this by doing. A small glass tip under the
experiment says "Pinch an atom to pull it" until the first successful pull,
then "Pinch with both hands to move, turn and resize" until the first two-hand
hold, then disappears for the rest of the session. The panel repeats both in
one line.

## Controls panel

One compact glass panel sized to its content, with no scrolling, menus or
disclosure sections:

1. The experience title and temperature ("300 K", or "T = 0.85 (reduced)" in
   Lennard-Jones units), with **Back to Experiences** at the top right.
2. Play/Pause, Restart, a Slow/Normal/Fast speed control and Recenter.
3. One status line: the experience's hint; "Preparing…" until the first frame
   and while the starting structure is minimized; or the error/ending message
   with Restart.
4. "One hand: pinch an atom to pull it. Two hands: pinch to move, turn and
   resize."

Back to Experiences, the Digital Crown and system dismissal share one exit:
the run stops, the carousel reopens and the panel closes. Backgrounding the app
pauses the engine. The engine watchdog, error recovery and late-callback guards
are unchanged.

## Removed

The room experience (room scanning, wall collisions and its scenarios),
Watch/Touch/Room modes, the grab bar under the box, the graphs window,
discovery cards, atom inspection and automatic selection, neighbourhood focus,
history samples, freeze and the force arrow, bond reshaping, step inside, the
billboard (Metal) renderer and its immersive space, renderer and atom-size
choices, bond and box toggles, and per-demo special cases in the app. The
VisionRoomKit package is no longer linked. AtomifyKit keeps its room,
discovery, inspection and impostor types for now.

## Checks

- `swift test --package-path Packages/AtomifyKit`: placement, tips, grab
  bookkeeping, picking, speed and readout logic alongside the engine tests.
- `scripts/check-app-lifecycle.sh`: the production `AppModel` against the real
  host engine (rapid replacement, restart, pause, background, stop, cleanup).
- Debug builds accept `-AtomifyAutostart <demo id>` (with optional
  `-AtomifyHidePanel` or `-AtomifyPanelAhead`) to open an experience at launch
  for Simulator screenshots.

## Needs the headset

Two-hand roll direction and feel, overlay deferral during a grip, the pinch
position and orientation conversion, grab smoothing and indirect-pinch gain,
the proximity marker and cue volume, comfort of the initial placement, and
frame rate for each experience.
