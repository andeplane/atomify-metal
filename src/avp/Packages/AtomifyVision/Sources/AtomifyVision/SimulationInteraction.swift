import AtomifyEngine

extension Simulation {
    /// Lets go of every grab and removes the force spheres (hands, forearms).
    public func releaseInteractions() {
        releaseGrab()
        setForceSpheres([])
    }

    /// Walls from the room's distance field (simulation units); nil removes them.
    public func setWalls(_ grid: DistanceGrid?, cutoff: Double, strength: Double) {
        guard let grid else {
            removeWalls()
            return
        }
        setWalls(origin: SIMD3<Double>(grid.origin), spacing: Double(grid.spacing), dimensions: grid.dimensions,
                 distances: grid.distances, cutoff: cutoff, strength: strength)
    }
}
