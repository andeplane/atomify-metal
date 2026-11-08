import Testing
@testable import AtomifyKit

@Suite struct ThermostatTests {
    @Test func addAndRemoveCommands() {
        let on = Thermostat(isEnabled: true, target: 300)
        #expect(on.addCommand == "fix atomify_thermostat all langevin 300.0 300.0 $(100.0*dt) 48279 zero yes")
        #expect(Thermostat.removeCommand == "unfix atomify_thermostat")
        let custom = Thermostat(isEnabled: true, target: 0.75, dampingSteps: 50, seed: 0)
        #expect(custom.addCommand == "fix atomify_thermostat all langevin 0.75 0.75 $(50.0*dt) 1 zero yes")
        #expect(Thermostat.commandNumber(1e-5) == "1e-05")
        #expect(Thermostat.commandNumber(.nan) == "0.0")
    }

    @Test func commandsBetweenStates() {
        let off = Thermostat()
        let on = Thermostat(isEnabled: true, target: 300)
        let hotter = Thermostat(isEnabled: true, target: 1000)
        #expect(Thermostat.commands(from: off, to: off).isEmpty)
        #expect(Thermostat.commands(from: off, to: Thermostat(target: 500)).isEmpty)
        #expect(Thermostat.commands(from: off, to: on) == [on.addCommand])
        #expect(Thermostat.commands(from: on, to: off) == [Thermostat.removeCommand])
        #expect(Thermostat.commands(from: on, to: on).isEmpty)
        #expect(Thermostat.commands(from: on, to: hotter) == [Thermostat.removeCommand, hotter.addCommand])
    }

    @Test func unitsChoosePresetsAndRanges() {
        #expect(Thermostat.isReduced(units: "lj"))
        #expect(!Thermostat.isReduced(units: "metal"))
        #expect(Thermostat.defaultTarget(units: "lj") == 1)
        #expect(Thermostat.defaultTarget(units: "real") == 300)
        #expect(Thermostat.presets(units: "lj") == [0.5, 1.0, 1.5, 2.0])
        #expect(Thermostat.presets(units: "metal") == [300, 500, 1000, 2000])
        for units in ["lj", "metal", ""] {
            let range = Thermostat.targetRange(units: units)
            #expect(range.lowerBound > 0)
            #expect(Thermostat.presets(units: units).allSatisfy { range.contains($0) })
            #expect(range.contains(Thermostat.defaultTarget(units: units)))
        }
        #expect(Thermostat.clampedTarget(10_000, units: "metal") == 3000)
        #expect(Thermostat.clampedTarget(-4, units: "metal") == 1)
        #expect(Thermostat.clampedTarget(0.01, units: "lj") == 0.05)
        #expect(Thermostat.clampedTarget(1.2, units: "lj") == 1.2)
        #expect(Thermostat.clampedTarget(.nan, units: "lj") == 1)
    }
}
