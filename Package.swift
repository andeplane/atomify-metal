// swift-tools-version: 6.0
import PackageDescription

// CLammps.xcframework is built locally by src/shared/lammps/build-xcframework.sh
// (large, not committed). AtomifyRender does not need it.
let package = Package(
    name: "AtomifyMetal",
    platforms: [.macOS(.v15), .iOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "AtomifyRender", targets: ["AtomifyRender"]),
        .library(name: "AtomifyEngine", targets: ["AtomifyEngine"]),
        .library(name: "AtomifyKit", targets: ["AtomifyKit"]),
        .executable(name: "AtomifyMac", targets: ["AtomifyMac"]),
    ],
    targets: [
        .binaryTarget(name: "CLammps", path: "src/shared/lammps/Frameworks/CLammps.xcframework"),

        .target(name: "AtomifyEngine", dependencies: ["CLammps"], path: "src/shared/AtomifyEngine/Sources",
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "AtomifyEngineTests", dependencies: ["AtomifyEngine"],
                    path: "src/shared/AtomifyEngine/Tests", resources: [.copy("Fixtures")]),

        .target(name: "AtomifyRender", path: "src/shared/AtomifyRender/Sources"),
        .testTarget(name: "AtomifyRenderTests", dependencies: ["AtomifyRender"],
                    path: "src/shared/AtomifyRender/Tests"),

        .target(name: "AtomifyKit", dependencies: ["AtomifyEngine", "AtomifyRender"],
                path: "src/shared/AtomifyKit/Sources"),
        .testTarget(name: "AtomifyKitTests", dependencies: ["AtomifyKit", "AtomifyEngine", "AtomifyRender"],
                    path: "src/shared/AtomifyKit/Tests", resources: [.copy("Fixtures")]),

        .executableTarget(name: "AtomifyMac", dependencies: ["AtomifyKit"], path: "src/macos/AtomifyMac",
                          resources: [.copy("Examples")]),
    ]
)
