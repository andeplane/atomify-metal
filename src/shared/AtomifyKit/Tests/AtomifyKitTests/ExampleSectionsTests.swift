import Foundation
import Testing
@testable import AtomifyKit

private func example(_ id: String) -> Example {
    Example(id: id, title: id.uppercased(), description: "", inputScript: "\(id).in",
            files: [ExampleFile(fileName: "\(id).in", url: "\(id).in")])
}

@Suite struct ExampleSectionsTests {
    let definitions = [
        ExampleSections.Definition(id: "a", title: "A", exampleIDs: ["x", "missing", "y"]),
        ExampleSections.Definition(id: "empty", title: "Empty", exampleIDs: ["gone"]),
        ExampleSections.Definition(id: "b", title: "B", exampleIDs: ["z"]),
    ]

    @Test func groupsInDefinitionOrderAndCollectsTheRest() {
        let examples = ["w", "z", "y", "x", "v"].map(example)
        let sections = ExampleSections.sections(for: examples, definitions: definitions)
        #expect(sections.map(\.id) == ["a", "b", ExampleSections.otherID])
        #expect(sections.map(\.title) == ["A", "B", ExampleSections.otherTitle])
        #expect(sections[0].examples.map(\.id) == ["x", "y"])
        #expect(sections[1].examples.map(\.id) == ["z"])
        #expect(sections[2].examples.map(\.id) == ["w", "v"])     // catalog order
    }

    @Test func noRestSectionWhenEverythingIsListed() {
        let sections = ExampleSections.sections(for: ["x", "y", "z"].map(example), definitions: definitions)
        #expect(sections.map(\.id) == ["a", "b"])
        #expect(ExampleSections.sections(for: [], definitions: definitions).isEmpty)
        let duplicate = ExampleSections.sections(for: [example("x"), example("x")], definitions: definitions)
        #expect(duplicate.map(\.examples.count) == [1])
    }

    @Test func featuredPrefersTheCandidates() {
        let examples = ["a", "b", "c"].map(example)
        #expect(ExampleSections.featured(in: examples, candidates: ["nope", "c", "b"])?.id == "c")
        #expect(ExampleSections.featured(in: examples, candidates: [])?.id == "a")
        #expect(ExampleSections.featured(in: [], candidates: ["a"]) == nil)
    }

    @Test func curatedSectionsHaveUniqueIDs() {
        let ids = ExampleSections.curated.flatMap(\.exampleIDs)
        #expect(Set(ids).count == ids.count)
        let sectionIDs = ExampleSections.curated.map(\.id) + [ExampleSections.otherID]
        #expect(Set(sectionIDs).count == sectionIDs.count)
    }

    /// Every bundled example has a curated section, so "More" stays empty,
    /// and the featured example is bundled.
    @Test func curatedSectionsCoverTheBundledCatalog() throws {
        guard let directory = ExampleRunner.bundledExamplesDirectory(fromSourceFile: #filePath) else { return }
        let catalog = try ExampleCatalog.load(from: directory)
        let sections = ExampleSections.sections(for: catalog.examples)
        #expect(!sections.contains { $0.id == ExampleSections.otherID },
                "Not in a curated section: \(sections.last?.examples.map(\.id) ?? [])")
        #expect(sections.map(\.examples.count).reduce(0, +) == catalog.examples.count)
        let listed = Set(ExampleSections.curated.flatMap(\.exampleIDs))
        #expect(listed == Set(catalog.examples.map(\.id)), "Curated ids that are not bundled")
        #expect(ExampleSections.featured(in: catalog.examples)?.id == ExampleSections.featuredIDs.first)
    }
}
