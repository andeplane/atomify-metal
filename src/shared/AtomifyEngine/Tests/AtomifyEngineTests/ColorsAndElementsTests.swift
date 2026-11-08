import Testing
@testable import AtomifyEngine

@Suite struct ColorsAndElementsTests {
    @Test func colorFromHex() {
        let color = RGBColor(hex: 0xFF8000)
        #expect(color.red == 1)
        #expect(abs(color.green - 128.0 / 255) < 1e-12)
        #expect(color.blue == 0)
        #expect(color.hexString == "#FF8000")
        #expect(RGBColor(red: 0, green: 0, blue: 0).hexString == "#000000")
        #expect(RGBColor(red: 2, green: -1, blue: 0.5).hexString == "#FF0080")
    }

    @Test func colorFromHexString() {
        #expect(RGBColor(hexString: "#ff8000") == RGBColor(hex: 0xFF8000))
        #expect(RGBColor(hexString: "FF8000") == RGBColor(hex: 0xFF8000))
        #expect(RGBColor(hexString: "#ff80") == nil)
        #expect(RGBColor(hexString: "#ff80001") == nil)
        #expect(RGBColor(hexString: "#gg8000") == nil)
        #expect(RGBColor(hexString: "#+f8000") == nil)
        #expect(RGBColor(hexString: "") == nil)
    }

    @Test func elementsByNameOrSymbol() throws {
        let oxygen = try #require(Element.named("Oxygen"))
        #expect(oxygen.symbol == "O")
        #expect(oxygen.radius == 1.52)
        #expect(oxygen.color == RGBColor(hex: 0xAA0000))
        #expect(Element.named("o") == oxygen)
        #expect(Element.named("ar")?.name == "argon")
        #expect(Element.named("unobtainium") == nil)
        // Symbols and names are unique.
        #expect(Set(Element.all.map(\.symbol)).count == Element.all.count)
        #expect(Set(Element.all.map(\.name)).count == Element.all.count)
        #expect(Element.all.allSatisfy { $0.radius > 0 })
    }

    @Test func styleTableUsesDirectivesThenPalette() {
        let directives = ScriptDirectives.parse("#/atom 2 oxygen\n#/atom 7 1.0 #00ff00")
        let table = AtomStyleTable(directives: directives, typeCount: 3, units: "metal")
        #expect(table.styles.count == 4)    // 1...3 and the directive for 7
        #expect(table.style(forType: 2).name == "O")
        #expect(table.style(forType: 1) == AtomStyle(name: "Type 1", color: AtomStyleTable.palette[0], radius: 1.0))
        #expect(table.style(forType: 3).color == AtomStyleTable.palette[2])
        #expect(table.style(forType: 7).color == RGBColor(hex: 0x00FF00))
        // Types without a style fall back to the palette, wrapping around.
        let count = AtomStyleTable.palette.count
        #expect(table.style(forType: count + 1).color == AtomStyleTable.palette[0])
        #expect(AtomStyleTable.fallback(type: 0, units: "lj").color == AtomStyleTable.palette[count - 1])
    }

    @Test func defaultRadiusFollowsUnits() {
        #expect(AtomStyleTable.defaultRadius(units: "lj") == 0.5)
        #expect(AtomStyleTable.defaultRadius(units: "real") == 1.0)
        #expect(AtomStyleTable.defaultRadius(units: "metal") == 1.0)
        #expect(AtomStyleTable.defaultRadius(units: "si") == 1.0e-10)
        let table = AtomStyleTable(directives: ScriptDirectives(), typeCount: 0, units: "lj")
        #expect(table.styles.keys.sorted() == [1])
        #expect(table.style(forType: 1).radius == 0.5)
    }

    @Test func unitSystems() throws {
        let metal = try #require(UnitSystem.named("metal"))
        #expect(metal.time == "ps")
        #expect(metal.energy == "eV")
        #expect(UnitSystem.named("real")?.length == "Å")
        #expect(UnitSystem.named("lj")?.temperature == "reduced LJ")
        #expect(UnitSystem.named("furlongs") == nil)
        #expect(Set(UnitSystem.all.map(\.style)).count == UnitSystem.all.count)
    }
}
