import Foundation

/// One file of an example: where it lives in the catalog and the name LAMMPS
/// reads it by. Same fields as the web app's `examples.json`.
public struct ExampleFile: Codable, Sendable, Hashable {
    /// Name in the working directory, which is what scripts refer to.
    public var fileName: String
    /// Location relative to the catalog folder (the folder holding examples.json).
    public var url: String

    public init(fileName: String, url: String) {
        self.fileName = fileName
        self.url = url
    }
}

/// An example simulation in the web app's `examples.json` format.
public struct Example: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var description: String
    /// Thumbnail, relative to the catalog folder.
    public var imageUrl: String?
    /// File name (one of `files`) of the script to run.
    public var inputScript: String
    public var keywords: [String]?
    public var files: [ExampleFile]
    public var author: String?
    public var authorUrl: String?
    public var analysisDescription: String?
    public var analysisScript: String?

    public init(id: String, title: String, description: String, imageUrl: String? = nil, inputScript: String,
                keywords: [String]? = nil, files: [ExampleFile], author: String? = nil, authorUrl: String? = nil,
                analysisDescription: String? = nil, analysisScript: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.imageUrl = imageUrl
        self.inputScript = inputScript
        self.keywords = keywords
        self.files = files
        self.author = author
        self.authorUrl = authorUrl
        self.analysisDescription = analysisDescription
        self.analysisScript = analysisScript
    }

    /// Whether the example matches a search: every word of `query` appears in
    /// the title, id, description, author or a keyword (case and diacritics
    /// insensitive). An empty query matches everything.
    public func matches(query: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let haystack = ([title, id, description, author ?? ""] + (keywords ?? [])).joined(separator: "\n")
        return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Whether the example carries this keyword (case insensitive); nil matches all.
    public func hasKeyword(_ keyword: String?) -> Bool {
        guard let keyword else { return true }
        return (keywords ?? []).contains { $0.caseInsensitiveCompare(keyword) == .orderedSame }
    }
}

public enum ExampleCatalogError: Error, Equatable, LocalizedError {
    /// A file listed in examples.json is not in the catalog folder.
    case missingFile(String)
    /// A file location is absolute, remote or leaves the catalog folder.
    case unsupportedLocation(String)
    /// The input script is not among the example's files.
    case missingInputScript(String)

    public var errorDescription: String? {
        switch self {
        case .missingFile(let path): "The example file \(path) is missing."
        case .unsupportedLocation(let path): "The example file location \(path) is not a relative path in the catalog."
        case .missingInputScript(let name): "The input script \(name) is not one of the example's files."
        }
    }
}

/// The examples in a folder with an `examples.json` (the web app's layout:
/// file urls are relative to that folder).
public struct ExampleCatalog: Sendable, Equatable {
    /// The folder holding examples.json.
    public var directory: URL
    public var title: String?
    public var examples: [Example]

    private struct File: Codable {
        var baseUrl: String?
        var title: String?
        var descriptionFile: String?
        var examples: [Example]
    }

    public init(directory: URL, title: String? = nil, examples: [Example]) {
        self.directory = directory
        self.title = title
        self.examples = examples
    }

    /// Reads `examples.json` from `directory`.
    public static func load(from directory: URL) throws -> ExampleCatalog {
        let data = try Data(contentsOf: directory.appendingPathComponent("examples.json"))
        return try decode(data, directory: directory)
    }

    /// Decodes the contents of an examples.json whose relative urls resolve against `directory`.
    public static func decode(_ data: Data, directory: URL) throws -> ExampleCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        return ExampleCatalog(directory: directory, title: file.title, examples: file.examples)
    }

    public func example(id: String) -> Example? { examples.first { $0.id == id } }

    /// All keywords, each once (first spelling wins), sorted.
    public var keywords: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for keyword in examples.flatMap({ $0.keywords ?? [] }) where seen.insert(keyword.lowercased()).inserted {
            result.append(keyword)
        }
        return result.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Examples matching a search and an optional keyword, in catalog order.
    public func filtered(query: String, keyword: String? = nil) -> [Example] {
        examples.filter { $0.hasKeyword(keyword) && $0.matches(query: query) }
    }

    /// The thumbnail file of an example, if it has one.
    public func imageURL(for example: Example) -> URL? {
        guard let path = example.imageUrl, let url = try? resolve(path) else { return nil }
        return url
    }

    /// Copies an example's files into a fresh writable folder under `scratch`
    /// (bundles are read only, and scripts write logs and dumps), each under
    /// its `fileName`, and returns the folder and its input script.
    ///
    /// The input script is lightly adapted for this LAMMPS build (see
    /// `ScriptPreparation`). The caller removes the folder when the run ends.
    public func workingCopy(of example: Example,
                            into scratch: URL = FileManager.default.temporaryDirectory) throws
        -> (folder: URL, script: URL) {
        guard example.files.contains(where: { $0.fileName == example.inputScript }) else {
            throw ExampleCatalogError.missingInputScript(example.inputScript)
        }
        let manager = FileManager.default
        let folder = scratch.appendingPathComponent("atomify-\(Self.safeName(example.id))-\(UUID().uuidString)",
                                                    isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            for file in example.files {
                let source = try resolve(file.url)
                guard manager.fileExists(atPath: source.path) else {
                    throw ExampleCatalogError.missingFile(file.url)
                }
                guard Self.isPlainName(file.fileName) else {
                    throw ExampleCatalogError.unsupportedLocation(file.fileName)
                }
                let destination = folder.appendingPathComponent(file.fileName)
                if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
                try manager.copyItem(at: source, to: destination)
            }
            let script = folder.appendingPathComponent(example.inputScript)
            let text = try String(contentsOf: script, encoding: .utf8)
            let prepared = ScriptPreparation.prepare(text)
            if prepared != text {
                try prepared.write(to: script, atomically: true, encoding: .utf8)
            }
            return (folder, script)
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    /// A catalog-relative path as a file URL; refuses absolute, remote and
    /// parent-escaping paths.
    func resolve(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !path.hasPrefix("/"), !path.contains("://"), !components.isEmpty,
              !components.contains(where: { $0 == ".." }) else {
            throw ExampleCatalogError.unsupportedLocation(path)
        }
        return components.reduce(directory) { $0.appendingPathComponent(String($1)) }
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    static func safeName(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
    }
}

/// Small source edits that let web app scripts run on this LAMMPS build.
public enum ScriptPreparation {
    /// The web app opts scripts into KOKKOS with a `suffix kk` line. This build
    /// has no KOKKOS package, so such lines are commented out.
    public static func prepare(_ script: String) -> String {
        var changed = false
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if words.count >= 2, words[0] == "suffix", words[1] == "kk" || words[1].hasPrefix("kk#") {
                changed = true
                return "# \(line)  (KOKKOS is not in this build)"
            }
            return String(line)
        }
        return changed ? lines.joined(separator: "\n") : script
    }
}
