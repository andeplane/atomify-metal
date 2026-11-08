import AtomifyRender
import Foundation
import simd
import Testing
@testable import RenderLab

@Suite struct WaterMoleculeTests {
    @Test func bondLengths() {
        let p = WaterMolecule.positions
        #expect(p.count == 3)
        #expect(closeF(distance(p, 0, 1), 0.9572))
        #expect(closeF(distance(p, 0, 2), 0.9572))
    }

    @Test func bondAngle() {
        let p = WaterMolecule.positions
        let u = simd_normalize(p[1] - p[0])
        let v = simd_normalize(p[2] - p[0])
        let degrees = acosf(simd_dot(u, v)) * 180 / Float.pi
        #expect(closeF(degrees, 104.52, tolerance: 1e-3))
    }

    @Test func planarAndSymmetric() {
        let p = WaterMolecule.positions
        #expect(p[0] == SIMD3<Float>(0, 0, 0))
        #expect(p[1].z == 0 && p[2].z == 0)
        #expect(closeF(p[1].x, -p[2].x))
        #expect(closeF(p[1].y, p[2].y))
    }

    @Test func scene() {
        let generated = WaterMolecule.make()
        let particles = generated.scene.particles
        #expect(particles.count == 3)
        #expect(particles.styleIndices == [0, 1, 1])
        #expect(particles.styles == [LabElement.oxygen.style, LabElement.hydrogen.style])
        #expect(particles.colors == nil)
        #expect(particles.radii == nil)
        let pairs = generated.scene.bonds?.pairs ?? []
        #expect(pairs == [SIMD2<UInt32>(0, 1), SIMD2<UInt32>(0, 2)])
        #expect(generated.scene.bonds?.radius == WaterMolecule.bondRadius)
        #expect(generated.scene.lines.isEmpty)
        #expect(generated.scene.images == [SIMD3<Float>.zero])
        #expect(generated.styleNames.count == 2)
        #expect(generated.bondCount == 2)
        #expect(generated.legend == nil)
    }

    @Test func staticAcrossCalls() {
        let a = WaterMolecule.make().scene.particles.positions
        let b = WaterMolecule.make().scene.particles.positions
        #expect(a == b)
    }

    @Test func bondsStayVisible() {
        // Ball-and-stick: the two spheres must not swallow the bond.
        let sum = LabElement.oxygen.radius + LabElement.hydrogen.radius
        #expect(sum < WaterMolecule.bondLength)
    }
}

@Suite struct LabElementTests {
    @Test func cpkColors() {
        #expect(LabElement.oxygen.srgbHex == 0xFF0D0D)
        #expect(LabElement.hydrogen.srgbHex == 0xFFFFFF)
        #expect(LabElement.carbon.srgbHex == 0x909090)
        #expect(LabElement.silicon.srgbHex == 0xF0C8A0)
    }

    @Test func styleIsLinear() {
        let style = LabElement.oxygen.style
        #expect(style.radius == LabElement.oxygen.radius)
        #expect(closeV4(style.color, linearColor(hex: 0xFF0D0D)))
        let white = LabElement.hydrogen.style.color
        #expect(closeV4(white, SIMD4<Float>(1, 1, 1, 1)))
    }

    @Test func radiiOrder() {
        #expect(LabElement.hydrogen.radius < LabElement.oxygen.radius)
        #expect(LabElement.carbon.radius < LabElement.silicon.radius)
    }

    @Test func boxLines() {
        let box = LabLines.box(size: SIMD3<Float>(1, 2, 3))
        #expect(box.segments.count == 12)
        #expect(box.color == LabLines.boxColor)
    }
}
