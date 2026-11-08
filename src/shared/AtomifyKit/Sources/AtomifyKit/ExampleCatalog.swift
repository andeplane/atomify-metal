import AtomifyEngine
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

/// Atomify Metal's own settings for an example, under `"atomifyMetal"` in
/// examples.json (the web app ignores the key).
public struct ExampleOptions: Codable, Sendable, Hashable {
    /// Why the example checks (`atomify-check-examples`, ExampleRunTests)
    /// skip this example, e.g. a package this build lacks. Nil runs it.
    public var skip: String?
    /// Which Atomify the script's `#/atom` lines were written for; web when nil.
    public var dialect: ScriptDialect?
    /// Timesteps per displayed frame at normal speed, as Atomify 2's
    /// "simulation speed" (it drew 60 frames per second). The script's
    /// `#/speed N` lines change it while it runs. Nil runs as fast as the
    /// device can.
    public var stepsPerFrame: Double?
    /// The starting view; overrides the script's `#/camera` lines.
    public var camera: ExampleCamera?
    /// Dashboard panels in display order.
    public var dashboard: [DashboardPanel]?
    /// Copies of the box to draw along x, y and z (Atomify 2's
    /// `periodicImagesX/Y/Z`); one each when nil.
    public var periodicImages: [Int]?
    /// Atom colors shaded along one axis (Atomify 2's custom color shaders).
    public var colorRamp: ColorRamp?

    public init(skip: String? = nil, dialect: ScriptDialect? = nil, stepsPerFrame: Double? = nil,
                camera: ExampleCamera? = nil, dashboard: [DashboardPanel]? = nil, periodicImages: [Int]? = nil,
                colorRamp: ColorRamp? = nil) {
        self.skip = skip
        self.dialect = dialect
        self.stepsPerFrame = stepsPerFrame
        self.camera = camera
        self.dashboard = dashboard
        self.periodicImages = periodicImages
        self.colorRamp = colorRamp
    }

    /// `periodicImages` as counts, when it asks for more than one copy.
    public var imageCounts: SIMD3<Int>? {
        guard let values = periodicImages, values.count == 3, values.contains(where: { $0 > 1 }) else { return nil }
        return SIMD3(max(values[0], 1), max(values[1], 1), max(values[2], 1))
    }
}

/// One dashboard panel of an example, as an Atomify 2 controller: its kind
/// ("summary", "thermometer", "pressure", "thermostat", "angle", ...) and
/// its QML settings as written ("xLabel": "Time [fs]", "atom1": "1").
public struct DashboardPanel: Codable, Sendable, Hashable {
    public var kind: String
    public var parameters: [String: String]?

    public init(kind: String, parameters: [String: String]? = nil) {
        self.kind = kind
        self.parameters = parameters
    }
}

/// An example's starting view, as Atomify 2's `initialCameraPosition`,
/// `initialViewCenter` and `initialUpVector`.
public struct ExampleCamera: Codable, Sendable, Hashable {
    public var position: [Double]?
    /// The point looked at; the box center when nil.
    public var target: [Double]?
    public var up: [Double]?
    /// Vertical field of view in degrees.
    public var fieldOfView: Double?
    /// Position and target are offsets from the box center (Atomify 2 drew
    /// the box centered on the origin).
    public var relativeToBoxCenter: Bool?

    public init(position: [Double]? = nil, target: [Double]? = nil, up: [Double]? = nil,
                fieldOfView: Double? = nil, relativeToBoxCenter: Bool? = nil) {
        self.position = position
        self.target = target
        self.up = up
        self.fieldOfView = fieldOfView
        self.relativeToBoxCenter = relativeToBoxCenter
    }

    /// As the engine's camera hint; vectors that are not three finite
    /// numbers are left out.
    public var hint: CameraHint {
        CameraHint(position: Self.vector(position), target: Self.vector(target), up: Self.vector(up),
                   fieldOfView: fieldOfView, relativeToBoxCenter: relativeToBoxCenter ?? false)
    }

    static func vector(_ values: [Double]?) -> SIMD3<Double>? {
        guard let values, values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
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
    /// Settings that only Atomify Metal reads.
    public var atomifyMetal: ExampleOptions?

    public init(id: String, title: String, description: String, imageUrl: String? = nil, inputScript: String,
                keywords: [String]? = nil, files: [ExampleFile], author: String? = nil, authorUrl: String? = nil,
                analysisDescription: String? = nil, analysisScript: String? = nil,
                atomifyMetal: ExampleOptions? = nil) {
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
        self.atomifyMetal = atomifyMetal
    }

    /// Why the example checks skip this example, or nil.
    public var skipReason: String? { atomifyMetal?.skip }

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
    /// The catalog's own gallery rows, under `"atomifyMetalSections"`;
    /// nil uses `ExampleSections.curated`.
    public var sections: [ExampleSections.Definition]?

    private struct File: Codable {
        var baseUrl: String?
        var title: String?
        var descriptionFile: String?
        var examples: [Example]
        var atomifyMetalSections: [ExampleSections.Definition]?
    }

    public init(directory: URL, title: String? = nil, examples: [Example],
                sections: [ExampleSections.Definition]? = nil) {
        self.directory = directory
        self.title = title
        self.examples = examples
        self.sections = sections
    }

    /// Reads `examples.json` from `directory`.
    public static func load(from directory: URL) throws -> ExampleCatalog {
        let data = try Data(contentsOf: directory.appendingPathComponent("examples.json"))
        return try decode(data, directory: directory)
    }

    /// Decodes the contents of an examples.json whose relative urls resolve against `directory`.
    public static func decode(_ data: Data, directory: URL) throws -> ExampleCatalog {
        let file = try JSONDecoder().decode(File.self, from: data)
        return ExampleCatalog(directory: directory, title: file.title, examples: file.examples,
                              sections: file.atomifyMetalSections)
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

    /// Where a bundled file of an example is, or nil when its location
    /// leaves the catalog. The file itself may still be missing.
    public func fileURL(for file: ExampleFile) -> URL? {
        try? resolve(file.url)
    }

    /// The example's input script among its files, for showing it.
    public func inputScriptURL(for example: Example) -> URL? {
        example.files.first { $0.fileName == example.inputScript }.flatMap { fileURL(for: $0) }
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
    /// has no KOKKOS package, so such lines are commented out. Atomify 2's
    /// `#/speed` and `#/label` lines become print commands that report
    /// them when LAMMPS reaches them (see `ScriptEvent`). Lines keep their
    /// numbers.
    public static func prepare(_ script: String) -> String {
        var changed = false
        // "\r\n" is a single Character in Swift, so split on it explicitly.
        let lines = script.split(omittingEmptySubsequences: false,
                                 whereSeparator: { $0 == "\n" || $0 == "\r\n" }).map { line -> String in
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if words.count >= 2, words[0] == "suffix", words[1] == "kk" || words[1].hasPrefix("kk#") {
                changed = true
                return "# \(line)  (KOKKOS is not in this build)"
            }
            if let command = ScriptEvent.command(forDirective: line) {
                changed = true
                return command
            }
            return String(line)
        }
        return changed ? lines.joined(separator: "\n") : script
    }
}
