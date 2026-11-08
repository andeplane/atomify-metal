// Every bundled example as a test case (Cmd-U in Xcode, or
// `swift test --filter ExampleRunTests`), the same check as
// `swift run atomify-check-examples`: each runs until its input completes or
// 100 steps after its first run started, within 120 s. Override with the
// environment variables ATOMIFY_EXAMPLE_STEPS and ATOMIFY_EXAMPLE_TIMEOUT.
// Examples marked "atomifyMetal": {"skip": "reason"} are not listed.

import AtomifyKit
import Foundation
import Testing

enum BundledExamples {
    static let catalog: ExampleCatalog? = ExampleRunner.bundledExamplesDirectory(fromSourceFile: #filePath)
        .flatMap { try? ExampleCatalog.load(from: $0) }

    /// Ids of the examples to run.
    static var ids: [String] { catalog?.examples.filter { $0.skipReason == nil }.map(\.id) ?? [] }

    static var limits: ExampleRunLimits {
        let environment = ProcessInfo.processInfo.environment
        var limits = ExampleRunLimits()
        if let steps = environment["ATOMIFY_EXAMPLE_STEPS"].flatMap(Int64.init), steps > 0 { limits.steps = steps }
        if let timeout = environment["ATOMIFY_EXAMPLE_TIMEOUT"].flatMap(Double.init), timeout > 0 {
            limits.timeout = timeout
        }
        return limits
    }
}

// Serialized: simulations take turns on the process working directory.
@Suite(.serialized) struct ExampleRunTests {
    @Test func catalogIsFound() throws {
        let catalog = try #require(BundledExamples.catalog, "src/macos/AtomifyMac/Examples/examples.json not found")
        #expect(!catalog.examples.isEmpty)
    }

    @Test(arguments: BundledExamples.ids)
    func exampleRuns(id: String) async throws {
        let catalog = try #require(BundledExamples.catalog)
        let example = try #require(catalog.example(id: id))
        let result = await ExampleRunner.run(example, from: catalog, limits: BundledExamples.limits)
        let details = [result.message, result.inputLine.map { "line: \($0)" }].compactMap { $0 }.joined(separator: " ")
        #expect(result.status == .ok, "\(id) \(result.status.rawValue) after \(result.steps) steps: \(details)")
        if result.status == .ok {
            #expect(result.atoms > 0, "\(id) has no atoms")
        }
    }
}
