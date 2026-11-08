# Atomify Metal

Native Apple apps for [Atomify](https://andeplane.github.io/atomify/), built on Metal.

[Atomify](https://github.com/andeplane/atomify) runs [LAMMPS](https://www.lammps.org) molecular dynamics and shows the atoms as they move.
You write a LAMMPS input script, press run, and watch the system in 3D while temperature, energy, and other quantities update live.
The web app does this in the browser: LAMMPS compiled to WebAssembly, and a WebGL view of atoms, bonds, the simulation box, and walls.

This repository is the Metal version of that.
A shared graphics engine draws atomic simulations on the GPU, and a native app on each Apple platform uses it.

## Apps

| Folder | App |
| --- | --- |
| [`macos/`](macos/) | Mac |
| [`ios/`](ios/) | iPhone and iPad |
| [`apple-vision-pro/`](apple-vision-pro/) | Apple Vision Pro |
