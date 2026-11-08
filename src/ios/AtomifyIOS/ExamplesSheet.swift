import AtomifyKit
import SwiftUI
import UIKit

/// The bundled examples by topic, with search. Picking one runs it.
struct ExamplesSheet: View {
    let model: AppModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = model.catalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if query.isEmpty {
                    ForEach(ExampleSections.sections(for: model.catalog.examples)) { section in
                        Section(section.title) {
                            ForEach(section.examples) { example in
                                row(example)
                            }
                        }
                    }
                } else {
                    let matches = model.catalog.filtered(query: query)
                    if matches.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                    ForEach(matches) { example in
                        row(example)
                    }
                }
            }
            .navigationTitle("Examples")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search examples")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ example: Example) -> some View {
        Button {
            model.run(example)
        } label: {
            HStack(spacing: 12) {
                ExampleThumbnail(url: model.catalog.imageURL(for: example))
                    .frame(width: 64, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(example.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(example.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                if model.session.example?.id == example.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Running")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// An example's picture from its `imageUrl`, or an atom symbol.
struct ExampleThumbnail: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    @State private var image: UIImage?

    var body: some View {
        // The picture is an overlay, so it fills the frame it is given
        // without growing it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "atom")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
            .task(id: url) {
                image = url.flatMap { UIImage(contentsOfFile: $0.path) }
            }
    }
}
