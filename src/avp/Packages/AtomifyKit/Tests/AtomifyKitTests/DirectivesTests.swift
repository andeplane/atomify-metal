import AtomifyKit
import Testing

@Suite struct DirectivesTests {
    @Test func parsesElementCustomAndBondCommands() {
        let script = """
        #/atom 1 oxygen
        #/atom 2 H
          #/atom 3 1.5 #00FF00
        #/bond 1 2 2.0
        #/camera position 1 2 3
        # an ordinary comment
        units metal
        """
        let directives = ScriptDirectives.parse(script)
        #expect(directives.warnings.isEmpty)
        #expect(directives.atomStyles[1]?.name == "O")
        #expect(directives.atomStyles[1]?.radius == 1.52 * ScriptDirectives.elementRadiusScale)
        #expect(directives.atomStyles[2]?.name == "H")
        #expect(directives.atomStyles[3]?.color == RGBColor(hex: 0x00FF00))
        #expect(directives.atomStyles[3]?.radius == 1.5 * ScriptDirectives.elementRadiusScale)
        #expect(directives.bondRules == [BondRule(type1: 1, type2: 2, cutoff: 2.0)])
    }

    @Test func reportsMalformedCommands() {
        let directives = ScriptDirectives.parse("#/atom 1 unobtainium\n#/bond 1 x 2\n#/atom zero oxygen")
        #expect(directives.atomStyles.isEmpty)
        #expect(directives.bondRules.isEmpty)
        #expect(directives.warnings.count == 3)
    }

    @Test func fillsMissingTypesFromPaletteWithUnitAwareRadius() {
        let directives = ScriptDirectives.parse("#/atom 2 carbon")
        let lj = AtomStyleTable(directives: directives, typeCount: 3, units: "lj")
        #expect(lj.style(forType: 1).radius == 0.5)
        #expect(lj.style(forType: 2).name == "C")
        #expect(lj.style(forType: 3).color == AtomStyleTable.palette[2])
        #expect(AtomStyleTable(directives: .init(), typeCount: 1, units: "metal").style(forType: 1).radius == 1.0)
    }
}
