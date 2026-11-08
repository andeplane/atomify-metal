import Testing
@testable import AtomifyEngine

@Suite struct DirectivesTests {
    @Test func elementByNameOrSymbolIgnoringCase() throws {
        let directives = ScriptDirectives.parse("""
            #/atom 1 oxygen
            #/atom 2 H
            #/atom 3 CARBON
            """)
        #expect(directives.warnings.isEmpty)
        let oxygen = try #require(directives.atomStyles[1])
        #expect(oxygen.name == "O")
        #expect(oxygen.color == RGBColor(hex: 0xAA0000))
        #expect(abs(oxygen.radius - 1.52 * ScriptDirectives.elementRadiusScale) < 1e-12)
        #expect(directives.atomStyles[2]?.name == "H")
        #expect(directives.atomStyles[3]?.name == "C")
    }

    @Test func customRadiusAndColor() throws {
        let directives = ScriptDirectives.parse("#/atom 2 1.5 #FF0000")
        let style = try #require(directives.atomStyles[2])
        #expect(style.name == "Type 2")
        #expect(style.color == RGBColor(red: 1, green: 0, blue: 0))
        #expect(abs(style.radius - 1.5 * 0.33) < 1e-12)
        #expect(directives.warnings.isEmpty)
    }

    @Test func malformedAtomLinesWarn() {
        let directives = ScriptDirectives.parse("""
            #/atom x oxygen
            #/atom 0 oxygen
            #/atom 1 unobtainium
            #/atom 2 1.5 ff0000
            #/atom 3 -1 #ff0000
            #/atom 4 1.5 #ff00
            #/atom 5
            """)
        #expect(directives.atomStyles.isEmpty)
        #expect(directives.warnings.count == 7)
        #expect(directives.warnings[2].contains("unobtainium"))
    }

    @Test func bondRules() {
        let directives = ScriptDirectives.parse("""
            #/bond 1 2 2.0
            #/bond 3 3 1.1
            #/bond 2 1 2.5
            """)
        #expect(directives.bondRules == [BondRule(type1: 2, type2: 1, cutoff: 2.5), BondRule(type1: 3, type2: 3, cutoff: 1.1)])
        #expect(directives.warnings.isEmpty)
    }

    @Test func malformedBondLinesWarn() {
        let directives = ScriptDirectives.parse("""
            #/bond 1 2
            #/bond 1 2 zero
            #/bond 0 2 1.0
            #/bond 1 2 -1.0
            #/bond 1 2 1.0 extra
            """)
        #expect(directives.bondRules.isEmpty)
        #expect(directives.warnings.count == 5)
    }

    @Test func cameraPositionAndTarget() throws {
        let directives = ScriptDirectives.parse("""
            #/camera position 10.0 -2 30.5
            #/camera target 5 5 5
            """)
        let camera = try #require(directives.camera)
        #expect(camera.position == SIMD3(10, -2, 30.5))
        #expect(camera.target == SIMD3(5, 5, 5))
        #expect(directives.warnings.isEmpty)
    }

    @Test func cameraLaterLinesWinAndPartialHints() {
        let onlyTarget = ScriptDirectives.parse("#/camera target 1 2 3")
        #expect(onlyTarget.camera == CameraHint(position: nil, target: SIMD3(1, 2, 3)))
        let twice = ScriptDirectives.parse("#/camera position 1 1 1\n#/camera position 2 2 2")
        #expect(twice.camera?.position == SIMD3(2, 2, 2))
        #expect(twice.camera?.target == nil)
        #expect(ScriptDirectives.parse("units lj").camera == nil)
    }

    @Test func malformedCameraLinesWarn() {
        let directives = ScriptDirectives.parse("""
            #/camera position 1 2
            #/camera position 1 2 three
            #/camera zoom 1 2 3
            #/camera
            """)
        #expect(directives.camera == nil)
        #expect(directives.warnings.count == 4)
    }

    @Test func onlyDirectiveCommentsCount() {
        let directives = ScriptDirectives.parse("""
            # /atom 1 oxygen
            atom_style atomic
            #/unknown 1 2 3
            #/
            #atom 1 oxygen
            \t #/atom 1 neon\r
            """)
        #expect(directives.atomStyles.count == 1)
        #expect(directives.atomStyles[1]?.name == "Ne")
        #expect(directives.warnings.isEmpty)
    }

    @Test func emptyScript() {
        #expect(ScriptDirectives.parse("") == ScriptDirectives())
    }
}
