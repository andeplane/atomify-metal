// atomify-check-examples: runs every bundled example and reports which fail.
//
//   swift run atomify-check-examples [--steps N] [--timeout S] [--filter TEXT] [--examples DIR]
//
// Each example runs until its input completes or N steps (default 100) after
// its first run started, with a wall clock timeout of S seconds (default 120).
// --filter keeps the examples whose id contains TEXT. --examples points at a
// folder with an examples.json (default: src/macos/AtomifyMac/Examples).
// Prints a table and exits 1 if any example failed or timed out. Examples
// marked "atomifyMetal": {"skip": "reason"} in examples.json are skipped.
//
// The host counterpart without Xcode is src/shared/lammps/check-examples.sh.

import AtomifyKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var limits = ExampleRunLimits()
var filter = ""
var examplesDirectory = ExampleRunner.bundledExamplesDirectory(fromSourceFile: #filePath)
var arguments = CommandLine.arguments.dropFirst()
while let option = arguments.popFirst() {
    if option == "--help" || option == "-h" {
        print("usage: atomify-check-examples [--steps N] [--timeout S] [--filter TEXT] [--examples DIR]")
        exit(0)
    }
    guard let value = arguments.popFirst() else { fail("\(option) needs a value") }
    switch option {
    case "--steps":
        guard let steps = Int64(value), steps > 0 else { fail("--steps needs a positive number") }
        limits.steps = steps
    case "--timeout":
        guard let timeout = Double(value), timeout > 0 else { fail("--timeout needs a positive number") }
        limits.timeout = timeout
    case "--filter":
        filter = value
    case "--examples":
        examplesDirectory = URL(fileURLWithPath: value)
    default:
        fail("Unknown option \(option)")
    }
}

guard let directory = examplesDirectory else { fail("Could not find src/macos/AtomifyMac/Examples; pass --examples DIR") }
let catalog: ExampleCatalog
do {
    catalog = try ExampleCatalog.load(from: directory)
} catch {
    fail("Could not read \(directory.path)/examples.json: \(error.localizedDescription)")
}
let examples = catalog.examples.filter { filter.isEmpty || $0.id.localizedCaseInsensitiveContains(filter) }
guard !examples.isEmpty else { fail("No examples match '\(filter)'") }

FileHandle.standardError.write(Data(
    "Running \(examples.count) examples from \(directory.path) (\(limits.steps) steps, \(limits.timeout) s timeout)\n".utf8))
var results: [ExampleRunResult] = []
for example in examples {
    let result = await ExampleRunner.run(example, from: catalog, limits: limits)
    FileHandle.standardError.write(Data(
        "  \(example.id): \(result.status.rawValue) (\(String(format: "%.1f", result.seconds)) s)\n".utf8))
    results.append(result)
}
print(ExampleRunResult.table(results))
exit(results.contains(where: \.isProblem) ? 1 : 0)
