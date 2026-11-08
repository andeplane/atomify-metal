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
        .executable(name: "RenderLab", targets: ["RenderLab"]),
        .executable(name: "atomify-check-examples", targets: ["ExampleCheck"]),
        .executable(name: "atomify-render-bench", targets: ["RenderBench"]),
    ],
    targets: [
        .binaryTarget(name: "CLammps", path: "src/shared/lammps/Frameworks/CLammps.xcframework"),

        .target(name: "AtomifyRender", path: "src/shared/AtomifyRender/Sources"),
        .testTarget(name: "AtomifyRenderTests", dependencies: ["AtomifyRender"],
                    path: "src/shared/AtomifyRender/Tests"),

        .target(name: "AtomifyEngine", dependencies: ["CLammps"], path: "src/shared/AtomifyEngine/Sources",
                linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "AtomifyEngineTests", dependencies: ["AtomifyEngine"],
                    path: "src/shared/AtomifyEngine/Tests", resources: [.copy("Fixtures")]),

        .target(name: "AtomifyKit", dependencies: ["AtomifyEngine", "AtomifyRender"],
                path: "src/shared/AtomifyKit/Sources"),
        .testTarget(name: "AtomifyKitTests", dependencies: ["AtomifyKit", "AtomifyEngine", "AtomifyRender"],
                    path: "src/shared/AtomifyKit/Tests", resources: [.copy("Fixtures")]),

        .executableTarget(name: "AtomifyMac", dependencies: ["AtomifyKit"], path: "src/macos/AtomifyMac",
                          resources: [.copy("Examples")]),

        // Renderer test bench: synthetic scenes, no LAMMPS.
        .executableTarget(name: "RenderLab", dependencies: ["AtomifyRender"], path: "src/macos/RenderLab",
                          exclude: ["README.md"]),
        .testTarget(name: "RenderLabTests", dependencies: ["RenderLab"], path: "src/macos/RenderLabTests"),

        // Runs every bundled example for a few steps and reports which fail.
        // Times the renderer offscreen on real example scenes and saves reference screenshots.
        .executableTarget(name: "RenderBench", dependencies: ["AtomifyKit"], path: "src/tools/RenderBench"),
        .executableTarget(name: "ExampleCheck", dependencies: ["AtomifyKit"], path: "src/tools/ExampleCheck"),
        // The same check as a test target: one parameterized test per example (Cmd-U in Xcode).
        .testTarget(name: "ExampleRunTests", dependencies: ["AtomifyKit"], path: "src/tools/ExampleRunTests"),
    ]
)
