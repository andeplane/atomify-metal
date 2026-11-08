import Foundation

/// A bundled example simulation: a folder with a LAMMPS input script and the
/// data and potential files it reads.
public struct Demo: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var summary: String
    public var category: String
    /// Folder name inside the demos directory.
    public var folder: String
    public var inputScript: String
    public var credit: String?
    /// Interaction modes the demo suits ("watch", "touch"); all if nil.
    public var modes: [String]?
    /// "billboards" for systems too large for sphere geometry; the app
    /// switches renderer when such a demo loads.
    public var renderer: String?
    /// Periodic copies drawn along each axis (billboards only), so a
    /// periodic system looks this many times larger while only one copy
    /// is simulated. 1 if nil.
    public var copies: Int?
    public var chapter: String?
    public var observation: String?
    public var interactionNote: String?
    public var releaseOrder: Int?
    public var reactive: Bool?
    public var previewNote: String?
    /// Simulation steps to run per second of wall time; the app's default if nil.
    public var stepsPerSecond: Double?
    /// How the demo is framed when it opens; the app's default if nil.
    public var frame: String?
    /// Whether to draw the simulation box outline; the app's default if nil.
    public var showsBox: Bool?
    /// A short line telling the wearer what to try.
    public var hint: String?
    /// Draw molecules whole across periodic faces (display only); off if nil.
    public var wholeMolecules: Bool?

    public init(id: String, title: String, summary: String, category: String, folder: String,
                inputScript: String, credit: String? = nil, modes: [String]? = nil, renderer: String? = nil,
                copies: Int? = nil) {
        self.id = id; self.title = title; self.summary = summary; self.category = category
        self.folder = folder; self.inputScript = inputScript; self.credit = credit; self.modes = modes
        self.renderer = renderer
        self.copies = copies
    }

    public func suits(mode: String) -> Bool { modes?.contains(mode) ?? true }
}

public struct DemoCatalog: Codable, Sendable {
    public var demos: [Demo]

    public init(demos: [Demo]) { self.demos = demos }

    /// Only reviewed experiences appear at launch. Stress tests remain in source.
    public var releaseDemos: [Demo] {
        demos.filter { $0.releaseOrder != nil }.sorted { ($0.releaseOrder ?? 0) < ($1.releaseOrder ?? 0) }
    }

    /// Reads `demos.json` from a demos directory.
    public static func load(from directory: URL) throws -> DemoCatalog {
        let data = try Data(contentsOf: directory.appendingPathComponent("demos.json"))
        return try JSONDecoder().decode(DemoCatalog.self, from: data)
    }

    /// Categories in first-appearance order.
    public var categories: [String] {
        var seen = Set<String>()
        return demos.map(\.category).filter { seen.insert($0).inserted }
    }

    /// Copies a demo into a fresh writable folder (bundles are read only and
    /// scripts may write files) and returns the folder and its input script.
    public static func makeWorkingCopy(of demo: Demo, from directory: URL,
                                       into scratch: URL = FileManager.default.temporaryDirectory)
        throws -> (folder: URL, script: URL) {
        let source = directory.appendingPathComponent(demo.folder, isDirectory: true)
        let destination = scratch.appendingPathComponent("atomify-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let script = destination.appendingPathComponent(demo.inputScript)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: script.path])
        }
        return (destination, script)
    }
}
