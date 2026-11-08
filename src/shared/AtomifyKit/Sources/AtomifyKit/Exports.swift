// Apps import AtomifyKit only. The renderer's types (ParticleView, OrbitCamera,
// RenderSettings, Colormap, ...) appear in AtomifyKit's API, so they come along.
//
// AtomifyEngine is deliberately not re-exported: it declares a type named
// `Observable`, which would collide with the Observation macro in every app
// file that imports SwiftUI. AtomifyKit wraps what apps need from it.
@_exported import AtomifyRender
