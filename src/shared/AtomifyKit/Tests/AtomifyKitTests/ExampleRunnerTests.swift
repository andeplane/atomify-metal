import Foundation
import Testing
@testable import AtomifyKit

@Suite(.serialized) struct ExampleRunnerTests {
    @Test func decodesTheSkipOption() throws {
        let json = """
            {"examples": [
              {"id": "a", "title": "A", "description": "", "inputScript": "a.in", "files": [],
               "atomifyMetal": {"skip": "Needs the VORONOI package"}},
              {"id": "b", "title": "B", "description": "", "inputScript": "b.in", "files": [],
               "atomifyMetal": {}},
              {"id": "c", "title": "C", "description": "", "inputScript": "c.in", "files": []}
            ]}
            """
        let catalog = try ExampleCatalog.decode(Data(json.utf8), directory: URL(fileURLWithPath: "/"))
        #expect(catalog.example(id: "a")?.skipReason == "Needs the VORONOI package")
        #expect(catalog.example(id: "b")?.atomifyMetal == ExampleOptions())
        #expect(catalog.example(id: "b")?.skipReason == nil)
        #expect(catalog.example(id: "c")?.atomifyMetal == nil)
    }

    @Test func skippedExamplesDoNotRun() async throws {
        var catalog = try ExampleCatalog.load(from: fixturesDirectory())
        var example = try #require(catalog.example(id: "missing-file"))
        example.atomifyMetal = ExampleOptions(skip: "Broken on purpose")
        catalog.examples = [example]
        let result = await ExampleRunner.run(example, from: catalog)
        #expect(result == ExampleRunResult(id: "missing-file", status: .skipped, message: "Broken on purpose"))
        #expect(!result.isProblem)
    }

    @Test func missingFilesFail() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "missing-file"))
        let result = await ExampleRunner.run(example, from: catalog, scratch: try scratchDirectory())
        #expect(result.status == .failed)
        #expect(result.message?.contains("nowhere/gone.in") == true)
        #expect(result.isProblem)
    }

    @Test func stopsAfterTheStepLimit() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "lj"))
        let result = await ExampleRunner.run(example, from: catalog, limits: ExampleRunLimits(steps: 20, timeout: 60),
                                             scratch: try scratchDirectory())
        #expect(result.status == .ok)
        #expect(result.atoms == 256)
        // Stopped at the limit, or the 200 step run was already over.
        #expect(result.completedInput ? result.steps == 200 : result.steps >= 20)
    }

    @Test func runsShortScriptsToTheEnd() async throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let example = try #require(catalog.example(id: "lj"))
        let result = await ExampleRunner.run(example, from: catalog, limits: ExampleRunLimits(steps: 10_000),
                                             scratch: try scratchDirectory())
        #expect(result.status == .ok)
        #expect(result.completedInput)
        #expect(result.steps == 200)
        #expect(result.message == nil)
    }

    @Test func reportsTheFailingLine() async throws {
        let directory = try scratchDirectory()
        try "units lj\natom_style atomic\nbogus_command 1 2\n".write(
            to: directory.appendingPathComponent("broken.in"), atomically: true, encoding: .utf8)
        let example = Example(id: "broken", title: "Broken", description: "", inputScript: "broken.in",
                              files: [ExampleFile(fileName: "broken.in", url: "broken.in")])
        let catalog = ExampleCatalog(directory: directory, examples: [example])
        let result = await ExampleRunner.run(example, from: catalog, scratch: directory)
        #expect(result.status == .failed)
        #expect(result.message?.hasPrefix("Unknown command: bogus_command") == true)
        #expect(result.inputLine == "bogus_command 1 2")
    }

    @Test func table() {
        let text = ExampleRunResult.table([
            ExampleRunResult(id: "lj", status: .ok, completedInput: true, atoms: 256, steps: 200, seconds: 0.26),
            ExampleRunResult(id: "broken-one", status: .failed, atoms: 0, steps: 0, seconds: 1,
                             message: "Unknown command: x", inputLine: "x 1"),
            ExampleRunResult(id: "slow", status: .timeout, atoms: 5, steps: 3, seconds: 120, message: "No 100 steps"),
        ])
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "id          status   ended  atoms  steps  seconds  error")
        #expect(lines[1] == "lj          ok       input    256    200      0.3")
        #expect(lines[2] == "broken-one  failed              0      0      1.0  Unknown command: x  [line: x 1]")
        #expect(lines[3] == "slow        timeout             5      3    120.0  No 100 steps")
        #expect(lines.last == "1 ok, 1 failed, 1 timeout, 0 skipped")
    }

    @Test func summaryIsTheFirstLine() {
        #expect(ExampleRunner.summary("ERROR: Unknown command: x (src/input.cpp:315)\nLast input line: x\n")
                == "Unknown command: x (src/input.cpp:315)")
        #expect(ExampleRunner.summary("Plain") == "Plain")
    }

    @Test func findsTheBundledExamples() throws {
        let directory = try #require(ExampleRunner.bundledExamplesDirectory(fromSourceFile: #filePath))
        #expect(directory.path.hasSuffix("src/macos/AtomifyMac/Examples"))
        #expect(ExampleRunner.bundledExamplesDirectory(fromSourceFile: "/nonexistent/file.swift") == nil)
    }
}
