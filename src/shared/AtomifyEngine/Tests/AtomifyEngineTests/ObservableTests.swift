import Testing
@testable import AtomifyEngine

/// AtomifyEngine's Observable, not the Observation framework's macro.
typealias EngineObservable = AtomifyEngine.Observable

func snapshot(timestep: Int64 = 0, observables: [EngineObservable]) -> SimulationSnapshot {
    SimulationSnapshot(timestep: timestep, typeCount: 1, boxLow: .zero, boxHigh: SIMD3(1, 1, 1),
                       tags: [], types: [], positions: [], observables: observables)
}

@Suite struct ObservableTests {
    @Test func idsAndLabels() {
        let temp = EngineObservable(kind: .thermo, name: "temp", values: [1.5], timestep: 10)
        #expect(temp.id == "thermo_temp")
        #expect(temp.labels == ["thermo_temp"])
        #expect(temp.scalar == 1.5)
        #expect(temp.hasValues)

        let msd = EngineObservable(kind: .compute, name: "msd", style: "msd", values: [1, 2, 3, 4], timestep: 10)
        #expect(msd.id == "c_msd")
        #expect(msd.labels == ["c_msd[1]", "c_msd[2]", "c_msd[3]", "c_msd[4]"])
        #expect(msd.scalar == nil)

        // A scalar followed by a vector.
        let labels = EngineObservable.labels(id: "f_ave", count: 3, hasScalar: true)
        #expect(labels == ["f_ave", "f_ave[1]", "f_ave[2]"])
        #expect(EngineObservable.labels(id: "f_ave", count: 0, hasScalar: true).isEmpty)
        #expect(EngineObservable.id(kind: .variable, name: "e") == "v_e")
        #expect(EngineObservable.Kind.allCases.map(\.prefix) == ["thermo_", "c_", "f_", "v_"])
    }

    @Test func perAtomNames() {
        #expect(EngineObservable.perAtomNames(id: "c_ke", columns: 0) == ["c_ke"])
        #expect(EngineObservable.perAtomNames(id: "c_stress", columns: 3) == ["c_stress[1]", "c_stress[2]", "c_stress[3]"])
        let ke = EngineObservable(kind: .compute, name: "ke", style: "ke/atom",
                                  perAtomNames: EngineObservable.perAtomNames(id: "c_ke", columns: 0))
        #expect(!ke.hasValues)    // never computed
        #expect(ke.perAtomNames == ["c_ke"])
    }

    @Test func table() {
        let table = ObservableTable(rows: 2, columns: 3, values: [1, 2, 3, 4, 5, 6])
        #expect(table[1, 2] == 6)
        #expect(table.column(1) == [2, 5])
        #expect(table.column(3).isEmpty)
        #expect(table.column(-1).isEmpty)
        #expect(ObservableTable(rows: 2, columns: 3, values: [1]).column(0).isEmpty)
    }

    @Test func historyRecordsOnePointPerStep() {
        let history = ObservableHistory()
        func temp(_ value: Double, step: Int64?) -> EngineObservable {
            EngineObservable(kind: .thermo, name: "temp", values: [value], timestep: step, time: Double(step ?? 0) * 0.5)
        }
        history.record(snapshot(observables: [temp(1, step: nil)]))    // never computed
        #expect(history.ids.isEmpty)
        history.record(snapshot(observables: [temp(1, step: 10)]))
        history.record(snapshot(observables: [temp(1, step: 10)]))    // same step: carried over
        history.record(snapshot(observables: [temp(2, step: 20)]))
        #expect(history.series(id: "thermo_temp") == [SIMD2(5, 1), SIMD2(10, 2)])
        #expect(history.labels(id: "thermo_temp") == ["thermo_temp"])
        #expect(history.series(id: "thermo_temp", component: 1).isEmpty)
        #expect(history.series(id: "c_missing").isEmpty)
    }

    @Test func historyKeepsComponentsAndOrder() {
        let history = ObservableHistory()
        let msd = EngineObservable(kind: .compute, name: "msd", values: [1, 2, 3, 4], timestep: 1, time: 1)
        let pe = EngineObservable(kind: .thermo, name: "pe", values: [-5], timestep: 1, time: 1)
        history.record(snapshot(observables: [msd, pe]))
        #expect(history.ids == ["c_msd", "thermo_pe"])
        #expect(history.series(id: "c_msd", component: 3) == [SIMD2(1, 4)])

        // A redefined compute with a different length starts over.
        let redefined = EngineObservable(kind: .compute, name: "msd", values: [7, 8], timestep: 2, time: 2)
        history.record(snapshot(observables: [redefined]))
        #expect(history.series(id: "c_msd", component: 0) == [SIMD2(2, 7)])
        #expect(history.series(id: "c_msd", component: 3).isEmpty)
        #expect(history.ids == ["c_msd", "thermo_pe"])

        history.reset()
        #expect(history.ids.isEmpty)
        #expect(history.series(id: "thermo_pe").isEmpty)
    }

    @Test func historyDropsTheOldestPoints() {
        let history = ObservableHistory(capacity: 16)
        for step in 1...100 {
            let value = EngineObservable(kind: .variable, name: "x", values: [Double(step)], timestep: Int64(step),
                                         time: Double(step))
            history.record(snapshot(observables: [value]))
        }
        let points = history.series(id: "v_x")
        #expect(points.count == 16)
        #expect(points.first == SIMD2(85, 85))
        #expect(points.last == SIMD2(100, 100))
        #expect(ObservableHistory(capacity: 0).capacity == 1)
    }
}
