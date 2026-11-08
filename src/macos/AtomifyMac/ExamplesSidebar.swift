import AppKit
import AtomifyKit
import SwiftUI

/// The bundled examples, with search and a keyword filter. Picking one runs it.
struct ExamplesSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedExampleID) {
            if let error = model.catalogError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            let examples = model.visibleExamples
            if examples.isEmpty && model.catalogError == nil {
                Text("No examples match.")
                    .foregroundStyle(.secondary)
            }
            ForEach(examples) { example in
                ExampleRow(example: example, imageURL: model.catalog.imageURL(for: example))
                    .tag(example.id)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search examples")
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Keyword", selection: $model.keyword) {
                Text("All keywords").tag(String?.none)
                Divider()
                ForEach(model.catalog.keywords, id: \.self) { keyword in
                    Text(keyword).tag(String?.some(keyword))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .navigationTitle(model.catalog.title ?? "Examples")
    }
}

struct ExampleRow: View {
    let example: Example
    let imageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(url: imageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(example.title)
                    .font(.headline)
                    .lineLimit(2)
                if let keywords = example.keywords, !keywords.isEmpty {
                    Text(keywords.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let author = example.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .help(example.description)
    }
}

/// A small preview from the example's `imageUrl`, or a placeholder.
struct Thumbnail: View {
    let url: URL?
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "atom")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 64, height: 46)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            image = url.flatMap { NSImage(contentsOf: $0) }
        }
    }
}
