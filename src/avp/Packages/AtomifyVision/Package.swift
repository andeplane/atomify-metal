// swift-tools-version: 6.0
import PackageDescription

// visionOS-only logic for the Vision Pro app: hand and pinch interaction,
// placement and comfort in the room, the demo catalog, whole molecules across
// periodic faces. The engine (AtomifyEngine), the renderer (AtomifyRender)
// and the glue between them (AtomifyKit) come from the root package, which
// needs src/shared/lammps/Frameworks/CLammps.xcframework
// (src/shared/lammps/build-xcframework.sh).
let package = Package(
    name: "AtomifyVision",
    platforms: [.visionOS("26.0"), .macOS(.v15)],
    products: [.library(name: "AtomifyVision", targets: ["AtomifyVision"])],
    dependencies: [.package(name: "AtomifyMetal", path: "../../../..")],
    targets: [
        .target(name: "AtomifyVision", dependencies: [
            .product(name: "AtomifyEngine", package: "AtomifyMetal"),
            .product(name: "AtomifyKit", package: "AtomifyMetal"),
        ]),
        .testTarget(name: "AtomifyVisionTests", dependencies: [
            "AtomifyVision", .product(name: "AtomifyEngine", package: "AtomifyMetal"),
            .product(name: "AtomifyKit", package: "AtomifyMetal"),
        ], resources: [.copy("Fixtures")]),
    ]
)
