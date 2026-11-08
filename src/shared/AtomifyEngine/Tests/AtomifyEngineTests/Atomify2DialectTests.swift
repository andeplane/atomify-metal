import Testing
@testable import AtomifyEngine

/// The Qt app's reading of `#/atom`, used by the iOS examples ported from it.
@Suite struct Atomify2DialectTests {
    @Test func elementsUseTheQtTableAndScale() throws {
        let directives = ScriptDirectives.parse("#/atom 1 oxygen\n#/atom 2 hydrogen\n#/atom 3 silicon",
                                                dialect: .atomify2)
        #expect(directives.dialect == .atomify2)
        #expect(directives.warnings.isEmpty)
        let oxygen = try #require(directives.atomStyles[1])
        #expect(oxygen.name == "O")
        #expect(oxygen.color == RGBColor(hex: 0xFF0D0D))
        #expect(abs(oxygen.radius - 1.52 * 0.25) < 1e-12)
        #expect(directives.atomStyles[2]?.color == RGBColor(hex: 0xFFFFFF))
        #expect(abs((directives.atomStyles[3]?.radius ?? 0) - 2.10 * 0.25) < 1e-12)
    }

    @Test func customRadiusUsesTheQtScale() throws {
        let directives = ScriptDirectives.parse("#/atom 2 1.5 #ffff73", dialect: .atomify2)
        let style = try #require(directives.atomStyles[2])
        #expect(abs(style.radius - 0.375) < 1e-12)
        #expect(style.color == RGBColor(hex: 0xFFFF73))
        // The web dialect is unchanged.
        let web = ScriptDirectives.parse("#/atom 2 1.5 #ffff73")
        #expect(abs((web.atomStyles[2]?.radius ?? 0) - 1.5 * 0.33) < 1e-12)
        #expect(ScriptDirectives.parse("#/atom 1 oxygen").atomStyles[1]?.color == RGBColor(hex: 0xAA0000))
    }

    @Test func typesWithoutDirectivesFollowTheElementOrder() {
        let directives = ScriptDirectives.parse("#/atom 2 1.0 #ff0000", dialect: .atomify2)
        let table = AtomStyleTable(directives: directives, typeCount: 4, units: "lj")
        #expect(table.dialect == .atomify2)
        #expect(table.style(forType: 1).color == RGBColor(hex: 0xD9FFFF))   // helium
        #expect(abs(table.style(forType: 1).radius - 1.40 * 0.25) < 1e-12)
        #expect(table.style(forType: 2).color == RGBColor(hex: 0xFF0000))   // the directive
        #expect(table.style(forType: 3).color == RGBColor(hex: 0xC2FF00))   // beryllium
        #expect(table.style(forType: 4).color == RGBColor(hex: 0xFFB5B5))   // boron
        #expect(table.style(forType: 20).color == RGBColor(hex: 0xFFFFFF))  // hydrogen again
        #expect(table.style(forType: 21).color == RGBColor(hex: 0xD9FFFF))
    }

    @Test func qtTableIsComplete() {
        #expect(Element.atomify2.count == 103)
        #expect(Element.atomify2.first?.name == "hydrogen")
        #expect(Element.atomify2[19].name == "calcium")
        #expect(Element.named("zinc", dialect: .atomify2)?.color == RGBColor(hex: 0x7D80B0))
        #expect(Element.named("Fe", dialect: .atomify2)?.name == "iron")
        #expect(Set(Element.atomify2.map(\.symbol)).count == 103)
    }

    @Test func cameraHintKeepsItsDefaults() {
        let hint = CameraHint(position: SIMD3(0, 0, 10))
        #expect(hint.up == nil)
        #expect(hint.fieldOfView == nil)
        #expect(!hint.relativeToBoxCenter)
    }
}
