# AGENTS.md

Atomify Metal is the native Apple implementation of Atomify.
A shared Metal graphics engine draws atomic simulations, and a native app on each platform uses it.

Code lives under `src/`.
`src/shared/` is the Metal graphics engine.
`src/macos/`, `src/ios/`, and `src/avp/` are the native apps for Mac, iPhone and iPad, and Apple Vision Pro.
The engine and the apps are not written yet.
Read the repositories below before adding structure, and build the new code in this repository.

## What Atomify is

Atomify runs [LAMMPS](https://www.lammps.org) and shows the atoms while the simulation runs.
A person writes or picks a LAMMPS input script, starts it, and watches the system in 3D.
Temperature, energy, and other computed quantities update live.

The web app at [andeplane/atomify](https://github.com/andeplane/atomify) is the current product.
It compiles LAMMPS to WebAssembly and draws atoms, bonds, the simulation box, and walls with WebGL (three.js), including lighting and ambient occlusion.
Scripts can carry drawing hints as comments: `#/atom` for element color and size, `#/bond` for dynamic bonds, and `#/camera` for the initial view.
Try it at [andeplane.github.io/atomify](https://andeplane.github.io/atomify/).

That behavior is the target here.
Metal replaces the WebGL view.
The three apps are the shells around the shared engine.

## Direction

- One Metal graphics engine in `src/shared/`, used by Mac, iPhone and iPad, and Apple Vision Pro.
- A native app in `src/macos/`, `src/ios/`, and `src/avp/`.
- The same kind of simulation as Atomify: a LAMMPS script in, atoms on screen, quantities plotted while the run goes.
- Product behavior comes from the web app.
- Embedding LAMMPS on Apple platforms, and the feel of an immersive lab, come from the visionOS proof of concept.
- The Qt app is the history of the native desktop program.

Leave the other repositories where they are.
Link to them and read them.
Do the work in this repository.

## Tests

Aim for about 100% test coverage of the code in this repository.
New code arrives with tests that cover its branches.

A few kinds of code sit outside that bar:

- App entry points and other thin platform shells.
- Metal shader source, and GPU-only paths that a unit test cannot run.
- Code that needs a headset or another device.

Pull logic out of those paths when you can.
Buffer packing, colors, bonds, camera math, and script directives are ordinary code, and they are covered.
A file being about rendering is not itself an exception.

LAMMPS is GPLv2.
An app that links it is GPL.
The visionOS proof of concept states the same constraint, because its demos also come from GPL projects.

## Look here first

### The web app, which is the product

[github.com/andeplane/atomify](https://github.com/andeplane/atomify)

This is what Atomify does today.
Match its behavior when the Metal apps grow: scripts, live 3D, live plots, and the `#/atom`, `#/bond`, and `#/camera` comments.

For the picture on screen, start in `src/containers/View.tsx` and `src/rendering/`.
Atoms are instanced spheres, bonds are cylinders, and the box, walls, lighting, and ambient occlusion sit around that.
`src/utils/atomtypes.ts`, `src/utils/lighting.ts`, and `src/utils/ambientOcclusion.ts` hold the appearance rules.

### The visionOS proof of concept

[vision-atomify](https://github.com/andeplane/AppleVisionProProjects/tree/main/vision-atomify) inside [AppleVisionProProjects](https://github.com/andeplane/AppleVisionProProjects)

A working visionOS app: LAMMPS runs on the device and the atoms are shown in an immersive lab.
The demos come from the web app.
It replaced an earlier prototype, [AtomifyVisionPro](https://github.com/andeplane/AtomifyVisionPro).

Use it as a reference for an Apple build, not as the layout of this repository.

Worth reading:

- `LAMMPS/bridge/` is the C interface and `fix atomify`, compiled into LAMMPS.
- `LAMMPS/build-xcframework.sh` produces a visionOS and macOS framework.
- `Packages/AtomifyKit/` is the Swift wrapper: simulation thread, snapshots, script directives, and instance transforms. `ImpostorRenderer.swift` is the drawing path used on the headset.
- `Atomify/` is the visionOS app: library, controls, hand interaction, and the lab.
- `Demos/` is the bundled simulations.
- `README.md` explains the build and the GPL note.

The drawing there is an impostor renderer for that one app.
`src/shared/` is where the shared Metal engine goes.
`src/macos/`, `src/ios/`, and `src/avp/` are where the apps go.

### The original Qt app

[github.com/ovilab/atomify](https://github.com/ovilab/atomify)

The first Atomify, in C++ and Qt, with OpenGL.
Its README says the web app replaced it.
It was a single desktop program: a code editor, live visualization, live plots of LAMMPS variables, OpenMP, and GPU acceleration, fast enough for large systems.

Read it for that native-app shape and for how the visualization was driven from LAMMPS.
The web app is the behavior to follow, and the new renderer is Metal.
