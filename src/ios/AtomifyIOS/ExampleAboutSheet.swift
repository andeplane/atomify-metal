import AtomifyKit
import SwiftUI

/// What the running example is: its picture, description and author.
struct ExampleAboutSheet: View {
    let model: AppModel
    let session: SimulationSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let example = session.example {
                    Section {
                        ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 12)
                            .aspectRatio(4 / 3, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    Section {
                        Text(example.description)
                        if let author = example.author {
                            if let link = example.authorUrl.flatMap({ URL(string: $0) }) {
                                Link(destination: link) {
                                    LabeledContent("Author", value: author)
                                }
                            } else {
                                LabeledContent("Author", value: author)
                            }
                        }
                    }
                    if let analysis = example.analysisDescription, !analysis.isEmpty {
                        Section("Things to look at") {
                            Text(analysis)
                        }
                    }
                } else {
                    Text("A LAMMPS script.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button {
                        session.restart()
                        dismiss()
                    } label: {
                        Label("Run Again", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(session.title == nil)
                    Button {
                        model.sheet = .examples
                    } label: {
                        Label("Choose Another Example", systemImage: "square.grid.2x2")
                    }
                }
            }
            .navigationTitle(session.title ?? "Atomify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
