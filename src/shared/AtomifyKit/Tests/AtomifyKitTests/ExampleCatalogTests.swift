import Foundation
import Testing
@testable import AtomifyKit

func fixturesDirectory() throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
}

func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("atomifykit-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct ExampleCatalogTests {
    @Test func decodesTheWebAppFormat() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        #expect(catalog.title == "Fixture examples")
        #expect(catalog.examples.map(\.id) == ["lj", "minimal", "missing-file", "escaping", "no-script"])

        let lj = try #require(catalog.example(id: "lj"))
        #expect(lj.title == "Lennard-Jones liquid")
        #expect(lj.imageUrl == "lj/lj.png")
        #expect(lj.inputScript == "lj.in")
        #expect(lj.keywords == ["lennard jones", "Fluid"])
        #expect(lj.author == "Atomify tests")
        #expect(lj.authorUrl == "https://example.org")
        #expect(lj.analysisDescription?.hasPrefix("# About") == true)
        #expect(lj.analysisScript == nil)
        #expect(lj.files == [ExampleFile(fileName: "lj.in", url: "lj/lj.in"),
                             ExampleFile(fileName: "settings.lmp", url: "shared/settings.lmp")])

        let minimal = try #require(catalog.example(id: "minimal"))
        #expect(minimal.imageUrl == nil)
        #expect(minimal.keywords == nil)
        #expect(minimal.author == nil)
        #expect(catalog.example(id: "nope") == nil)
    }

    @Test func decodesFromData() throws {
        let json = #"{"examples":[{"id":"a","title":"A","description":"d","inputScript":"a.in","files":[]}]}"#
        let catalog = try ExampleCatalog.decode(Data(json.utf8), directory: URL(fileURLWithPath: "/tmp"))
        #expect(catalog.title == nil)
        #expect(catalog.examples.count == 1)
        #expect(throws: (any Error).self) {
            try ExampleCatalog.decode(Data("{}".utf8), directory: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func missingCatalogThrows() throws {
        #expect(throws: (any Error).self) {
            try ExampleCatalog.load(from: scratchDirectory())
        }
    }

    @Test func keywordsAreUniqueAndSorted() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        #expect(catalog.keywords == ["broken", "Fluid", "lennard jones"])
    }

    @Test func searchAndKeywordFilter() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        #expect(catalog.filtered(query: "").count == 5)
        #expect(catalog.filtered(query: "lennard").map(\.id) == ["lj", "missing-file"])
        #expect(catalog.filtered(query: "LIQUID two").map(\.id) == ["lj"])
        #expect(catalog.filtered(query: "fluid").map(\.id) == ["lj"])
        #expect(catalog.filtered(query: "tests").map(\.id) == ["lj"])
        #expect(catalog.filtered(query: "", keyword: "fluid").map(\.id) == ["lj"])
        #expect(catalog.filtered(query: "missing", keyword: "lennard jones").map(\.id) == ["missing-file"])
        #expect(catalog.filtered(query: "zzz").isEmpty)
        #expect(catalog.examples[0].hasKeyword(nil))
        #expect(!catalog.examples[1].hasKeyword("fluid"))
    }

    @Test func imageURLsResolveInsideTheCatalog() throws {
        let directory = try fixturesDirectory()
        let catalog = try ExampleCatalog.load(from: directory)
        let lj = try #require(catalog.example(id: "lj"))
        let image = try #require(catalog.imageURL(for: lj))
        #expect(image.standardizedFileURL == directory.appendingPathComponent("lj/lj.png").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: image.path))
        #expect(catalog.imageURL(for: try #require(catalog.example(id: "minimal"))) == nil)
        #expect(catalog.imageURL(for: try #require(catalog.example(id: "escaping"))) == nil)
    }

    @Test func inputScriptAndFileURLsResolveInsideTheCatalog() throws {
        let directory = try fixturesDirectory()
        let catalog = try ExampleCatalog.load(from: directory)
        let lj = try #require(catalog.example(id: "lj"))
        let script = try #require(catalog.inputScriptURL(for: lj))
        #expect(script.standardizedFileURL == directory.appendingPathComponent("lj/lj.in").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: script.path))
        let settings = try #require(catalog.fileURL(for: lj.files[1]))
        #expect(settings.lastPathComponent == "settings.lmp")
        #expect(catalog.inputScriptURL(for: try #require(catalog.example(id: "escaping"))) == nil)
        #expect(catalog.inputScriptURL(for: try #require(catalog.example(id: "no-script"))) == nil)
    }

    @Test func workingCopyHoldsEveryFileUnderItsName() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let copy = try catalog.workingCopy(of: try #require(catalog.example(id: "lj")), into: scratch)
        #expect(copy.folder.deletingLastPathComponent().standardizedFileURL == scratch.standardizedFileURL)
        #expect(copy.folder.lastPathComponent.hasPrefix("atomify-lj-"))
        #expect(copy.script.lastPathComponent == "lj.in")
        #expect(copy.script.deletingLastPathComponent().standardizedFileURL == copy.folder.standardizedFileURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: copy.folder.path).sorted()
        #expect(names == ["lj.in", "settings.lmp"])

        // The copy is writable and adapted: the KOKKOS opt-in is commented out.
        let script = try String(contentsOf: copy.script, encoding: .utf8)
        #expect(script.contains("# suffix kk"))
        #expect(!script.split(separator: "\n").contains("suffix kk"))
        #expect(script.contains("#/camera position 3.0 4.0 20.0"))
        try "log none\n".write(to: copy.folder.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)

        // Two copies never share a folder.
        let second = try catalog.workingCopy(of: try #require(catalog.example(id: "lj")), into: scratch)
        #expect(second.folder != copy.folder)
    }

    @Test func workingCopyErrorsLeaveNothingBehind() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        #expect(throws: ExampleCatalogError.missingFile("nowhere/gone.in")) {
            try catalog.workingCopy(of: try #require(catalog.example(id: "missing-file")), into: scratch)
        }
        #expect(throws: ExampleCatalogError.unsupportedLocation("../lj/lj.in")) {
            try catalog.workingCopy(of: try #require(catalog.example(id: "escaping")), into: scratch)
        }
        #expect(throws: ExampleCatalogError.missingInputScript("run.in")) {
            try catalog.workingCopy(of: try #require(catalog.example(id: "no-script")), into: scratch)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
    }

    @Test func refusesUnsafeFileNamesAndLocations() throws {
        let catalog = try ExampleCatalog.load(from: fixturesDirectory())
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sneaky = Example(id: "x/y", title: "", description: "", inputScript: "../lj.in",
                             files: [ExampleFile(fileName: "../lj.in", url: "lj/lj.in")])
        #expect(throws: ExampleCatalogError.unsupportedLocation("../lj.in")) {
            try catalog.workingCopy(of: sneaky, into: scratch)
        }
        for path in ["/etc/passwd", "https://example.org/a.in", "", "a/../../b"] {
            #expect(throws: ExampleCatalogError.unsupportedLocation(path)) { try catalog.resolve(path) }
        }
        #expect(ExampleCatalog.safeName("a/b c.d") == "a_b_c_d")
        #expect(!ExampleCatalog.isPlainName("."))
        #expect(!ExampleCatalog.isPlainName(""))
        #expect(ExampleCatalog.isPlainName("data.lmp"))
    }

    @Test func errorsDescribeThemselves() {
        #expect(ExampleCatalogError.missingFile("a").errorDescription?.contains("a") == true)
        #expect(ExampleCatalogError.unsupportedLocation("b").errorDescription?.contains("b") == true)
        #expect(ExampleCatalogError.missingInputScript("c").errorDescription?.contains("c") == true)
    }

    @Test func bundledAppCatalogIsConsistent() throws {
        // The Mac app's Examples folder, found relative to this source file.
        let examples = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macos/AtomifyMac/Examples")
        guard FileManager.default.fileExists(atPath: examples.appendingPathComponent("examples.json").path) else {
            return
        }
        let catalog = try ExampleCatalog.load(from: examples)
        #expect(catalog.examples.count > 10)
        #expect(Set(catalog.examples.map(\.id)).count == catalog.examples.count)
        for example in catalog.examples {
            #expect(example.files.contains { $0.fileName == example.inputScript }, "\(example.id)")
            for file in example.files {
                let url = try catalog.resolve(file.url)
                #expect(FileManager.default.fileExists(atPath: url.path), "\(example.id): \(file.url)")
            }
            if example.imageUrl != nil {
                #expect(catalog.imageURL(for: example) != nil, "\(example.id)")
            }
        }
    }
}

@Suite struct ScriptPreparationTests {
    @Test func commentsOutKokkosSuffix() {
        let script = "units lj\nsuffix kk\n  suffix\tkk # fast\nsuffix kk#x\nsuffix omp\n# suffix kk\n"
        let prepared = ScriptPreparation.prepare(script)
        let lines = prepared.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "units lj")
        #expect(lines[1].hasPrefix("# suffix kk"))
        #expect(lines[2].hasPrefix("#   suffix\tkk # fast"))
        #expect(lines[3].hasPrefix("# suffix kk#x"))
        #expect(lines[4] == "suffix omp")
        #expect(lines[5] == "# suffix kk")
        #expect(lines.last == "")
    }

    @Test func leavesOtherScriptsUntouched() {
        let script = "units lj\r\nrun 10"
        #expect(ScriptPreparation.prepare(script) == script)
        #expect(ScriptPreparation.prepare("") == "")
    }
}

@Suite struct ExampleColoringTests {
    @Test func decodesAColoringUnderAtomifyMetal() throws {
        let json = """
        {"examples":[{"id":"a","title":"A","description":"d","inputScript":"a.in","files":[],
        "atomifyMetal":{"color":{"quantity":"c_ke","colormap":"inferno","range":[0,30]}}}]}
        """
        let catalog = try ExampleCatalog.decode(Data(json.utf8), directory: URL(fileURLWithPath: "/tmp"))
        let color = try #require(catalog.example(id: "a")?.atomifyMetal?.color)
        #expect(color == ExampleColoring(quantity: "c_ke", colormap: "inferno", range: [0, 30]))
        #expect(color.colorRange == 0...30)
    }

    @Test func ignoresARangeThatIsNotTwoOrderedNumbers() {
        #expect(ExampleColoring(quantity: "speed").colorRange == nil)
        #expect(ExampleColoring(quantity: "speed", range: [1]).colorRange == nil)
        #expect(ExampleColoring(quantity: "speed", range: [5, 5]).colorRange == nil)
        #expect(ExampleColoring(quantity: "speed", range: [9, 1]).colorRange == nil)
        #expect(ExampleColoring(quantity: "speed", range: [0, .infinity]).colorRange == nil)
    }
}
