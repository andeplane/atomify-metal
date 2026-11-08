// swift-tools-version: 6.0
import PackageDescription

// CLammps.xcframework is built locally by src/shared/lammps/build-xcframework.sh
// (large, not committed). AtomifyRender does not need it.
let package = Package(
    name: "AtomifyMetal",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "AtomifyEngine", targets: ["AtomifyEngine"]),
    ],
    targets: [
        .binaryTarget(name: "CLammps", path: "src/shared/lammps/Frameworks/CLammps.xcframework"),

        .target(name: "AtomifyEngine", dependencies: ["CLammps"], path: "src/shared/AtomifyEngine/Sources",
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "AtomifyEngineTests", dependencies: ["AtomifyEngine"],
                    path: "src/shared/AtomifyEngine/Tests", resources: [.copy("Fixtures")]),
    ]
)
