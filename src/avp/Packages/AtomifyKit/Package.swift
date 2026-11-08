// swift-tools-version: 6.0
import PackageDescription

// CLammps.xcframework is built locally by ../../LAMMPS/build-xcframework.sh
// (it is large and not committed).
let package = Package(
    name: "AtomifyKit",
    platforms: [.visionOS("26.0"), .macOS(.v15)],
    products: [.library(name: "AtomifyKit", targets: ["AtomifyKit"])],
    targets: [
        .binaryTarget(name: "CLammps", path: "Frameworks/CLammps.xcframework"),
        .target(name: "AtomifyKit", dependencies: ["CLammps"], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "AtomifyKitTests", dependencies: ["AtomifyKit"], resources: [.copy("Fixtures")]),
    ]
)
