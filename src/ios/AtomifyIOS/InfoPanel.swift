import AtomifyKit
import SwiftUI

/// The side panel's Info tab: what the running example is, where it comes
/// from, its description and its input script.
struct InfoPanel: View {
    let model: AppModel
    let session: SimulationSession
    @State private var showsScript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let example = session.example {
                VStack(alignment: .leading, spacing: 2) {
                    Text(example.title)
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                    ExampleSource(model: model, example: example, prefix: "Atomify 2 example")
                }
                DescriptionText(text: example.description)
                if let analysis = example.analysisDescription, !analysis.isEmpty {
                    DescriptionText(text: analysis)
                }
                scriptButton(example)
            } else {
                Text(session.title ?? "Atomify")
                    .font(.title3.bold())
                Text("A LAMMPS script.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let atom = session.selectedAtom {
                selection(atom)
            }
        }
        .padding(.top, 4)
        .fullScreenCover(isPresented: $showsScript) {
            if let example = session.example {
                NavigationStack {
                    ScriptView(model: model, example: example)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { showsScript = false }
                            }
                        }
                }
            }
        }
    }

    private func scriptButton(_ example: Example) -> some View {
        Button {
            showsScript = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundStyle(.tint)
                Text("Input script")
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(example.inputScript)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.subheadline)
            .padding(.horizontal, 12)
            .frame(minHeight: 42)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    /// The selected atom's radius and quantity, which the atom card has no
    /// room for.
    @ViewBuilder
    private func selection(_ atom: AtomInfo) -> some View {
        let units = session.stats.units
        let radius = atom.radius.flatMap { $0.isFinite && $0 > 0 ? Format.length(Double($0), units: units) : nil }
        let value = atom.quantity.flatMap { quantity in atom.value.map { "\(quantity) \(Format.number(Double($0)))" } }
        if radius != nil || value != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected atom")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let radius { LabeledContent("Radius", value: radius) }
                if let value { Text(value).monospacedDigit() }
            }
            .font(.subheadline)
            .padding(.top, 6)
        }
    }
}

/// An example's description as paragraphs, with a paragraph that is all
/// bold ("**What to look for**") as a heading.
struct DescriptionText: View {
    let text: String
    var font: Font = .subheadline
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(ExampleText.blocks(of: text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let heading):
                    Text(heading)
                        .font(font.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                case .paragraph(let paragraph):
                    Text(Markdown.inline(paragraph))
                        .font(font)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
