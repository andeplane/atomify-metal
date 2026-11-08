import Foundation

/// Authored questions and model provenance; observations come from live snapshots.
public struct DiscoveryTopic: Sendable {
    public let question: String
    public let look: String
    public let explore: String
    public let insight: String
    public let model: String

    public static func forDemo(_ id: String, interactive: Bool = true) -> Self {
        switch id {
        case "benzene":
            Self(question: "What holds this ring together?",
                 look: "Find the six carbon atoms. The smaller white atoms are hydrogen. A halo marks the atom we are inspecting.",
                 explore: interactive ? "Open your hand, pinch a highlighted atom, then pull gently. Watch the measured separation change. You can also choose atoms using the buttons below." : "Pause and use Next particle to trace the ring. Compare neighbouring separations. For pulling, return to the library and choose Shape with your hands.",
                 insight: "Moving one atom changes the forces on its neighbours. Gentle pulls disturb the ring; Reshape lets you explore a driven separation and return. A drawn bond is a distance rule, not a measurement of electronic bond order.",
                 model: "AIREBO carbon/hydrogen · 50 K initial bath · driven empirical dynamics. Reshape is not a prediction of arbitrary chemical reactions.")
        case "methane", "ethane":
            Self(question: id == "methane" ? "Why isn't methane flat?" : "How can a molecule twist?",
                 look: "Inspect a carbon and count its four nearby partners. Turn the structure to see the directions in three dimensions.",
                 explore: interactive ? "Compare the local angles below. Gently move a hydrogen, then release it. In ethane, look along the carbon–carbon connection." : "Compare the local angles below. Turn methane to reveal its four directions; in ethane, look along the carbon–carbon connection. Pause to inspect the geometry.",
                 insight: "Four neighbours around carbon form a tetrahedral arrangement: ideal angles are about 109.5°. The displayed mean is measured from all pairs of currently drawn neighbour directions. Thermal motion and your hands can change it.",
                 model: "AIREBO carbon/hydrogen · 50 K initial bath. Connections and angles use the displayed distance-based graph.")
        case "carbon-workshop", "diamond":
            Self(question: "Same carbon. Why different structures?",
                 look: "Choose an interior carbon. Compare its local neighbourhood with the side-by-side structures in Crystal worlds.",
                 explore: interactive ? "Use Next particle to inspect another site. Focus its neighbours, count the connections, and gently disturb the network." : "Use Next particle to inspect another site. Focus its neighbours and compare an interior site with a surface. Return to Crystal worlds to compare the two structures.",
                 insight: "A sheet's ideal interior has three neighbours in a plane; diamond's has four in three dimensions. Surface atoms can have fewer. Connectivity helps explain structure, but this small sample does not measure bulk hardness.",
                 model: "AIREBO carbon · 100 K initial bath · finite, unpassivated surfaces. Coordination uses distance thresholds.")
        case "dna-duplex":
            Self(question: "How do two strands make a double helix?",
                 look: "Trace the two strands. Each coloured particle represents one nucleotide. Across the strands, A pairs with T and C pairs with G.",
                 explore: "Turn the duplex and compare base identities in the inspector. Drawn links and the default inspected distance follow the backbone. Pause to trace its helical shape.",
                 insight: "DNA's shape combines backbone connections, stacking and complementary-base interactions. This coarse-grained model resolves nucleotides and their orientations; it does not show individual chemical atoms.",
                 model: "oxDNA2 coarse-grained DNA. Reduced units, implicit solvent; base-pair interactions depend on orientation, not a drawn distance bond.")
        case "peptide":
            Self(question: "How does a small protein fragment move?",
                 look: "Trace the five-amino-acid peptide among its surrounding water. The library preview hides solvent so you can see the chain.",
                 explore: "Pause, inspect a backbone atom and follow its neighbours. Resume to see thermal motion in explicit water.",
                 insight: "A peptide is a connected chain with many internal degrees of freedom. This short, fixed-topology model illustrates fluctuations; it does not simulate a full protein folding or make and break its chemical bonds.",
                 model: "CHARMM-style fixed topology · five-residue peptide plus 640 water molecules · 275 K bath · constrained bonds with SHAKE.")
        case "micelle":
            Self(question: "Why do these tiny chains gather?",
                 look: "Find the coloured head and tail beads among the solvent. Each bead represents a coarse-grained part, not an individual chemical atom.",
                 explore: "Follow the changing groups in this flat model. Inspect a head and compare it with the connected tail beads.",
                 insight: "Different attractions can make amphiphilic chains organise. This two-dimensional surfactant model illustrates self-organisation; it is not a complete biological membrane.",
                 model: "2D coarse-grained Lennard-Jones surfactant toy · reduced units · 150 three-bead chains and 750 solvent beads.")
        case "methane-oxidation":
            Self(question: "Where does a reaction's heat come from?",
                 look: "Start with four methane molecules and eight oxygen molecules. Preparation supplies ignition energy first. After preparation, the thermostat is removed.",
                 explore: "Open Tools → Graphs. Follow kinetic temperature and potential energy through the isolated trajectory. Look for water and carbon-oxide structures; drawn lines use geometric cutoffs.",
                 insight: "In this tested, ignited model, potential energy falls as oxidation products appear and average kinetic temperature rises. Total energy is redistributed. Fluctuations and induction times vary; the temperature need not rise monotonically.",
                 model: "Chenoweth C/H/O ReaxFF + QEq · 36 atoms in a compressed 14 Å box · nominal 5500 K ignition, then NVE. The observation ends at 10 ps; the structure and graphs remain available. Qualitative hot-reactor demonstration, not atmospheric flame temperature or validated reaction kinetics.")
        case "ice-melting":
            Self(question: "What disappears when ice melts?", look: "Each sphere is one whole water molecule. Follow the ordered ice-Ic network before heating rearranges it.",
                 explore: "Pause and inspect a few molecules. Resume to watch the lattice pattern disappear as molecules move away from their initial neighbours.",
                 insight: "Melting changes persistent order and mobility. Our tested trajectories lose the ice diffraction pattern and rearrange their neighbours. A temperature reading by itself cannot establish that a sample has melted.",
                 model: "mW coarse-grained water · one particle per H₂O · initially cubic ice, bath 200→380 K. Hydrogen atoms and electrostatic charges are not resolved; this is not the same model as Water vapor.")
        case "phase-melting", "phase-crystallization":
            Self(question: id == "phase-crystallization" ? "How does order grow?" : "What changes when a solid melts?",
                 look: "Follow the initial arrangement. Pause and inspect a small group, then resume to see how its neighbours move.",
                 explore: "Compare the early and late structure as the bath changes. Look for persistent local order or particles moving away from their original neighbours.",
                 insight: "A temperature reading alone does not identify a phase. Order and mobility are the evidence: a solid keeps a persistent network; a liquid rearranges. A seed can help an ordered region grow.",
                 model: id == "phase-crystallization" ? "Lennard-Jones model · reduced units. The 32 particles coloured gold form a fixed seed; 224 mobile particles cool around it. The global temperature includes the stationary seed." : "Lennard-Jones model material · reduced temperature and length units. This is not water or a calibrated real substance.")
        case "watervapor":
            Self(question: "Can you follow a tumbling molecule?", look: "Find an oxygen and its two hydrogen neighbours.",
                 explore: "Pause, inspect one oxygen, then resume and follow its motion.",
                 insight: "The molecule moves and rotates while its internal geometry responds to the model's forces. Many moving molecules make a gas.",
                 model: "Bundled Vashishta water model. A separate empirical model; not a general reaction mixture.")
        case "zeolite_zsm5":
            Self(question: "Why is empty space part of a crystal?", look: "Look through the repeating corridors in the framework.",
                 explore: "Inspect a local neighbourhood, then zoom out to follow a channel through the crystal.",
                 insight: "A repeating framework can contain connected pores. The empty channels are as important to its geometry as the solid network. This scene contains the framework; it does not simulate guest adsorption.",
                 model: "Vashishta silica · ZSM-5 framework. Separate from the water and carbon models.")
        default:
            Self(question: "What changes when matter moves?", look: "Choose one particle and look at its local surroundings.",
                 explore: "Pause to inspect, then resume and follow what changes.", insight: "Compare structure, motion and measured quantities. A simulation's conclusions depend on its model and conditions.",
                 model: "See the experiment's source and model notes.")
        }
    }
}
