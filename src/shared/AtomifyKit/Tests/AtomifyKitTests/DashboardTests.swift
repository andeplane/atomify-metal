import AtomifyEngine
import Foundation
import Testing
import simd
@testable import AtomifyKit

@Suite struct DashboardLayoutTests {
    @Test func panelSettingsAreRead() {
        let panel = DashboardPanel(kind: "atomPosition", parameters: [
            "yScale": "100", "colors": "[\"blue\", \"red\"]", "enabled": "true", "bad": "nan",
        ])
        #expect(panel.panelKind == .atomPosition)
        #expect(panel.number("yScale") == 100)
        #expect(panel.number("bad") == nil)
        #expect(panel.number("missing") == nil)
        #expect(panel.flag("enabled") == true)
        #expect(panel.list("colors") == ["blue", "red"])
        #expect(DashboardPanel(kind: "rdf").panelKind == nil)
    }

    @Test func thermometerChartsTemperatureAndItsAverage() throws {
        let panel = DashboardPanel(kind: "thermometer", parameters: [
            "xScale": "341.53026", "yScale": "119.6", "xRange": "1000", "xLabel": "Time [fs]",
        ])
        let chart = try #require(DashboardLayout.chart(for: panel))
        #expect(chart.title == "Temperature")
        #expect(chart.xLabel == "Time [fs]")
        #expect(chart.yLabel == "Temperature")
        #expect(chart.xScale == 341.53026 && chart.yScale == 119.6 && chart.xRange == 1000)
        #expect(chart.lines.map(\.title) == ["Instantaneous", "Average"])
        #expect(chart.lines[0].source == .observable(DashboardLayout.temperatureKey))
        #expect(chart.lines[1].source == .average(.observable(DashboardLayout.temperatureKey)))
    }

    @Test func angleUsesTheThreeAtomsWithAFixedAxis() throws {
        let panel = DashboardPanel(kind: "angle", parameters: [
            "atom1": "1", "atom2": "2", "atom3": "3", "title": "The experimental value is about 105 degrees.",
        ])
        let chart = try #require(DashboardLayout.chart(for: panel))
        #expect(chart.lines[0].source == .angle(SIMD3(1, 2, 3)))
        #expect(chart.yDomain == 90...120)
        #expect(chart.note == "The experimental value is about 105 degrees.")
        #expect(DashboardLayout.chart(for: DashboardPanel(kind: "angle", parameters: ["atom1": "1"])) == nil)
        #expect(DashboardLayout.chart(for: DashboardPanel(kind: "summary")) == nil)
    }

    @Test func msdPanelsAddOneCompute() {
        let panels = [DashboardPanel(kind: "diffusionCoefficient"), DashboardPanel(kind: "meanSquareDisplacement"),
                      DashboardPanel(kind: "thermometer")]
        #expect(DashboardLayout.setupCommands(for: panels) == ["compute atomify_msd all msd"])
        #expect(DashboardLayout.setupCommands(for: [DashboardPanel(kind: "thermometer")]).isEmpty)
        let sources = DashboardLayout.sources(for: panels)
        #expect(sources == [.diffusion(msd: DashboardLayout.msdKey), .observable(DashboardLayout.msdKey),
                            .observable(DashboardLayout.temperatureKey),
                            .average(.observable(DashboardLayout.temperatureKey))])
        #expect(DashboardLayout.msdKey == PlotSeriesKey(observableID: "c_atomify_msd", component: 3))
    }

    @Test func counterReadsTheScriptsVariables() throws {
        let chart = try #require(DashboardLayout.chart(for: DashboardPanel(kind: "atomPosition", parameters: [
            "yScale": "100", "colors": "[\"blue\", \"red\"]",
        ])))
        #expect(chart.lines.map(\.source) == [.observable(PlotSeriesKey(observableID: "v_atomify_left")),
                                              .observable(PlotSeriesKey(observableID: "v_atomify_right"))])
        #expect(chart.lines.map(\.color) == ["blue", "red"])
        #expect(chart.yDomain == 0...100)
    }

    @Test func displayedPointsAreScaledAndWindowed() {
        let chart = DashboardChart(title: "", xLabel: "", yLabel: "", xScale: 10, yScale: 2, xRange: 15,
                                   lines: [])
        let shown = chart.displayed([SIMD2(0, 1), SIMD2(1, 2), SIMD2(2, 3), SIMD2(3, 4)])
        #expect(shown == [SIMD2(20, 6), SIMD2(30, 8)])
        #expect(DashboardChart(title: "", xLabel: "", yLabel: "", lines: []).displayed([SIMD2(1, 1)]) == [SIMD2(1, 1)])
    }
}

@Suite struct DashboardControlTests {
    @Test func thermostatPanelScalesItsRange() {
        let panel = ThermostatPanel(panel: DashboardPanel(kind: "thermostat", parameters: [
            "unitScale": "119.6", "minimumValue": "1.0", "maximumValue": "500.0", "temperatureDampening": "0.1",
        ]))
        #expect(abs(panel.range.lowerBound - 1 / 119.6) < 1e-12)
        #expect(abs(panel.range.upperBound - 500 / 119.6) < 1e-12)
        #expect(panel.dampingTime == 0.1)
        #expect(!panel.startsEnabled)
        #expect(panel.initialTarget(default: 1.0) == 1.0)
        #expect(panel.initialTarget(default: 300) == panel.range.upperBound)

        let vapor = ThermostatPanel(panel: DashboardPanel(kind: "thermostat", parameters: [
            "nvtEnabled": "true", "minimumValue": "10", "maximumValue": "600", "targetTemperature": "300",
        ]))
        #expect(vapor.startsEnabled)
        #expect(vapor.initialTarget(default: 1000) == 300)
    }

    @Test func thermostatUsesAGivenDampingTime() {
        var thermostat = Thermostat(isEnabled: true, target: 300)
        #expect(thermostat.addCommand == "fix atomify_thermostat all langevin 300.0 300.0 $(100.0*dt) 48279 zero yes")
        thermostat.dampingTime = 0.05
        #expect(thermostat.addCommand == "fix atomify_thermostat all langevin 300.0 300.0 0.05 48279 zero yes")
    }

    @Test func gravityCommands() {
        let start = GravityControl(panel: DashboardPanel(kind: "gravity", parameters: [
            "minimumValue": "-1", "maximumValue": "1.0", "initialValue": "0.1", "enabled": "true",
        ]))
        #expect(start.isEnabled)
        #expect(start.magnitude == 0.1)
        #expect(start.range == -1...1)
        #expect(start.addCommand == "fix atomify_gravity mobile gravity 0.1 vector 0 0 1")
        var off = start
        off.isEnabled = false
        #expect(GravityControl.commands(from: off, to: start) == [start.addCommand])
        #expect(GravityControl.commands(from: start, to: off) == ["unfix atomify_gravity"])
        var stronger = start
        stronger.magnitude = 0.5
        #expect(GravityControl.commands(from: start, to: stronger)
            == ["unfix atomify_gravity", "fix atomify_gravity mobile gravity 0.5 vector 0 0 1"])
        #expect(GravityControl.commands(from: start, to: start).isEmpty)
    }
}

@Suite struct DashboardMeasureTests {
    @Test func angleAtTheFirstAtom() throws {
        // Water-like: 90 degrees at atom 1 between 2 and 3.
        let frame = AtomFrame(tags: [1, 2, 3], types: [1, 2, 2],
                              positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 2, 0)],
                              boxLow: SIMD3(-5, -5, -5), boxHigh: SIMD3(5, 5, 5))
        let angle = try #require(DashboardMeasure.angle(SIMD3(1, 2, 3), in: frame))
        #expect(abs(angle - 90) < 1e-4)
        #expect(DashboardMeasure.angle(SIMD3(1, 2, 9), in: frame) == nil)
        #expect(DashboardMeasure.angle(SIMD3(1, 1, 2), in: frame) == nil)
    }

    @Test func angleAcrossAPeriodicBoundary() throws {
        // Atom 2 sits across the x boundary from atom 1: its nearest image is at -1.
        let frame = AtomFrame(tags: [1, 2, 3], types: [1, 2, 2],
                              positions: [SIMD3(4.5, 0, 0), SIMD3(-4.5, 0, 0), SIMD3(4.5, 1, 0)],
                              boxLow: SIMD3(-5, -5, -5), boxHigh: SIMD3(5, 5, 5))
        let angle = try #require(DashboardMeasure.angle(SIMD3(1, 2, 3), in: frame))
        #expect(abs(angle - 90) < 1e-3)
        var fixed = frame
        fixed.periodic = [false, true, true]
        let unwrapped = try #require(DashboardMeasure.angle(SIMD3(1, 2, 3), in: fixed))
        #expect(abs(unwrapped - 90) < 1e-3)    // still perpendicular, but now via the far side
    }

    @Test func averagesAndDiffusion() {
        let points: [SIMD2<Double>] = [SIMD2(0, 2), SIMD2(1, 4), SIMD2(2, .nan), SIMD2(3, 6)]
        let average = DashboardMeasure.cumulativeAverage(points)
        #expect(average.map(\.y)[0] == 2 && average.map(\.y)[1] == 3 && average.map(\.y)[2] == 3)
        #expect(average[3] == SIMD2(3, 4))

        let msd: [SIMD2<Double>] = [SIMD2(10, 0), SIMD2(11, 6), SIMD2(12, 12)]
        #expect(DashboardMeasure.diffusion(fromMSD: msd, dimension: 3) == [SIMD2(11, 1), SIMD2(12, 1)])
        #expect(DashboardMeasure.diffusion(fromMSD: msd, dimension: 2) == [SIMD2(11, 1.5), SIMD2(12, 1.5)])
        #expect(DashboardMeasure.diffusion(fromMSD: [], dimension: 3).isEmpty)
    }
}
