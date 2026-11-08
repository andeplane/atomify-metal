import Foundation
import simd

/// Clear colors to check the shading on dark and light backgrounds.
enum LabBackground: String, CaseIterable, Identifiable, Sendable {
    case dark, black, gray, white

    var id: Self { self }

    var title: String { rawValue.capitalized }

    /// Linear RGBA.
    var color: SIMD4<Float> {
        switch self {
        case .dark: SIMD4(0.08, 0.08, 0.1, 1)
        case .black: SIMD4(0, 0, 0, 1)
        case .gray: SIMD4(0.22, 0.22, 0.24, 1)
        case .white: SIMD4(1, 1, 1, 1)
        }
    }
}

/// Which view draws the scene.
enum ViewportHost: String, CaseIterable, Identifiable, Sendable {
    /// RenderLab's own MTKView around `ParticleRenderer`: CPU, upload and
    /// frame timings, MSAA choice, benchmark.
    case lab
    /// The library's SwiftUI `ParticleView`, as the apps use it.
    case particleView

    var id: Self { self }

    var title: String {
        switch self {
        case .lab: "Lab view"
        case .particleView: "ParticleView"
        }
    }
}

/// Upper limits on particles drawn per frame with periodic copies
/// (`ParticleRenderer.particleBudget`).
enum ParticleBudget: Int, CaseIterable, Identifiable, Sendable {
    case one = 1_000_000
    case four = 4_000_000
    case sixteen = 16_000_000
    case unlimited = 1_000_000_000

    var id: Self { self }

    var title: String {
        switch self {
        case .one: "1M"
        case .four: "4M (default)"
        case .sixteen: "16M"
        case .unlimited: "No limit"
        }
    }
}
