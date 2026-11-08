import AtomifyVision
import Foundation
import Testing

@Suite struct DemoCatalogTests {
    /// vision-atomify/Demos, found from this file's location.
    static let demosDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Demos")

    @Test func everyBundledDemoHasItsScript() throws {
        let catalog = try DemoCatalog.load(from: Self.demosDirectory)
        #expect(catalog.demos.count >= 10)
        #expect(Set(catalog.demos.map(\.id)).count == catalog.demos.count)
        for demo in catalog.demos {
            let script = Self.demosDirectory.appendingPathComponent(demo.folder).appendingPathComponent(demo.inputScript)
            #expect(FileManager.default.fileExists(atPath: script.path), "\(demo.id) is missing \(demo.inputScript)")
        }
    }

    @Test func workingCopyIsWritable() throws {
        let catalog = try DemoCatalog.load(from: Self.demosDirectory)
        let demo = try #require(catalog.demos.first)
        let copy = try DemoCatalog.makeWorkingCopy(of: demo, from: Self.demosDirectory)
        defer { try? FileManager.default.removeItem(at: copy.folder) }
        #expect(FileManager.default.isWritableFile(atPath: copy.folder.path))
        #expect(FileManager.default.fileExists(atPath: copy.script.path))
    }
}

@Suite struct DemoModeTests {
    @Test func touchModeLeavesOutLargeDemos() throws {
        let catalog = try DemoCatalog.load(from: DemoCatalogTests.demosDirectory)
        let touch = catalog.demos.filter { $0.suits(mode: "touch") }
        #expect(!touch.isEmpty && touch.count < catalog.demos.count)
        #expect(catalog.demos.allSatisfy { $0.suits(mode: "watch") })
    }
}
