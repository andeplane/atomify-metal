/// A group of examples for a gallery row ("Water", "Materials").
public struct ExampleSection: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var examples: [Example]

    public init(id: String, title: String, examples: [Example]) {
        self.id = id
        self.title = title
        self.examples = examples
    }
}

/// Gallery sections for the bundled examples. `examples.json` has keywords
/// but no categories, so the grouping is a curated list of example ids.
public enum ExampleSections {
    /// One curated section: its id, title and example ids in display order.
    public struct Definition: Sendable, Equatable, Codable {
        public var id: String
        public var title: String
        public var exampleIDs: [String]

        public init(id: String, title: String, exampleIDs: [String]) {
            self.id = id
            self.title = title
            self.exampleIDs = exampleIDs
        }
    }

    /// Where examples that no section lists end up.
    public static let otherID = "more"
    public static let otherTitle = "More"

    /// The sections of the bundled catalog, in display order.
    public static let curated: [Definition] = [
        Definition(id: "water", title: "Water", exampleIDs: [
            "singlewater", "watervapor", "ice_crystal", "water_nacl", "nacl-solution", "nanotube_water",
            "water_isobutane", "reversibly-adsorbing-particles",
        ]),
        Definition(id: "materials", title: "Materials", exampleIDs: [
            "sic_nanoparticle", "sic_faceted_nanoparticle", "betacristobalite", "generate_nanoporous",
            "zeolite_zsm5", "cnt_deformation", "go-nanoparticle",
        ]),
        Definition(id: "chemistry", title: "Chemistry", exampleIDs: [
            "reax_rdf", "reax_cho", "reax_ab", "reax_feoh3", "reax_ssz13", "reax_voh", "reax_znoh2", "peptide",
            "benzene", "alkane_chain_single", "cmap", "micelle", "abstract_translocation",
        ]),
        Definition(id: "liquids", title: "Liquids and diffusion", exampleIDs: [
            "3D-lj-fluid", "2D-lj-fluid", "diffusion", "2d-msd-diffusion", "2d-vacf-diffusion", "large_diffusion",
            "2d-lj-walls", "3d-lj-walls",
        ]),
        Definition(id: "classic", title: "Classic LAMMPS", exampleIDs: [
            "crack", "flow_couette", "flow_poiseuille", "friction", "obstacle", "shear", "shear_void",
            "deposit_atom", "deposit_molecule",
        ]),
        Definition(id: "granular", title: "Granular", exampleIDs: [
            "granular_patterns", "pour_2d", "pour_2d_molecule", "pour_3d",
        ]),
        Definition(id: "large", title: "Large systems", exampleIDs: [
            "lj-melt-108k", "lj-melt-500k", "lj-melt-1m",
        ]),
    ]

    /// Candidates for the featured card, best first.
    public static let featuredIDs = ["nanotube_water", "sic_nanoparticle", "singlewater"]

    /// The examples grouped by `definitions`, in their order. Ids that are not
    /// among `examples` are skipped, empty sections are left out, and
    /// examples no section lists go to a last "More" section in their
    /// original order.
    public static func sections(for examples: [Example], definitions: [Definition] = curated) -> [ExampleSection] {
        var byID: [String: Example] = [:]
        for example in examples where byID[example.id] == nil {
            byID[example.id] = example
        }
        var listed = Set<String>()
        var result: [ExampleSection] = []
        for definition in definitions {
            let members = definition.exampleIDs.compactMap { byID[$0] }
            listed.formUnion(members.map(\.id))
            if !members.isEmpty {
                result.append(ExampleSection(id: definition.id, title: definition.title, examples: members))
            }
        }
        let rest = examples.filter { !listed.contains($0.id) }
        if !rest.isEmpty {
            result.append(ExampleSection(id: otherID, title: otherTitle, examples: rest))
        }
        return result
    }

    /// The first of `candidates` that is among `examples`, else the first example.
    public static func featured(in examples: [Example], candidates: [String] = featuredIDs) -> Example? {
        for id in candidates {
            if let example = examples.first(where: { $0.id == id }) { return example }
        }
        return examples.first
    }
}
