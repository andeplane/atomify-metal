import AtomifyKit
import SwiftUI

/// The view for a gallery navigation route.
struct ExampleRouteView: View {
    let model: AppModel
    let route: ExampleRoute

    var body: some View {
        switch route {
        case .detail(let example): ExampleDetail(model: model, example: example)
        case .script(let example): ScriptView(model: model, example: example)
        case .files(let example): ExampleFilesView(model: model, example: example)
        }
    }
}

/// An example before you run it: picture, title, credit, keywords,
/// description, script and files, with the Run button pinned at the bottom.
struct ExampleDetail: View {
    let model: AppModel
    let example: Example

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 0)
                    .frame(height: 236)

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(example.title)
                            .font(.largeTitle.weight(.bold))
                            .fixedSize(horizontal: false, vertical: true)
                        credit
                    }
                    if let keywords = example.keywords, !keywords.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(keywords, id: \.self) { keyword in
                                    Text(keyword)
                                        .font(.footnote)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                    }
                    Text(Markdown.inline(example.description))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)

                VStack(spacing: 0) {
                    NavigationLink(value: ExampleRoute.script(example)) {
                        detailRow("Input script", value: example.inputScript, systemImage: "doc.text")
                    }
                    Divider().padding(.leading, 52)
                    NavigationLink(value: ExampleRoute.files(example)) {
                        detailRow("Files", value: "\(example.files.count)", systemImage: "folder")
                    }
                }
                .buttonStyle(.plain)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 20)

                if let analysis = example.analysisDescription, !analysis.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Things to look at")
                            .font(.headline)
                        Text(Markdown.inline(analysis))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .safeAreaInset(edge: .bottom) {
            RunBar(model: model, example: example)
        }
        .navigationTitle(example.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private var credit: some View {
        if let author = example.author {
            if let url = example.authorUrl.flatMap({ URL(string: $0) }) {
                Link(destination: url) {
                    Text("By \(author)") + Text(Image(systemName: "arrow.up.right")).font(.caption)
                }
                .font(.subheadline)
            } else {
                Text("By \(author)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("From the Atomify examples")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func detailRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

/// The pinned action: Run Simulation, or Back to Simulation with Restart
/// when this example is the one loaded.
private struct RunBar: View {
    let model: AppModel
    let example: Example

    var body: some View {
        let session = model.session
        let isLoaded = session.example?.id == example.id && session.status != .idle
        HStack(spacing: 10) {
            if isLoaded {
                Button {
                    model.returnToSimulation()
                } label: {
                    Text("Back to Simulation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    model.restartAndShow()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Restart")
            } else {
                Button {
                    model.run(example)
                } label: {
                    Text("Run Simulation")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

/// The example's files, each shareable.
struct ExampleFilesView: View {
    let model: AppModel
    let example: Example

    var body: some View {
        List(example.files, id: \.fileName) { file in
            let url = model.catalog.fileURL(for: file)
            HStack {
                Label(file.fileName, systemImage: file.fileName == example.inputScript ? "doc.text" : "doc")
                Spacer()
                if let url, FileManager.default.fileExists(atPath: url.path) {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Share \(file.fileName)")
                }
            }
        }
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Inline Markdown for the catalog's descriptions: headings dropped (the
/// view supplies its own), links and emphasis kept.
enum Markdown {
    static func inline(_ text: String) -> AttributedString {
        let body = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: body, options: options)) ?? AttributedString(body)
    }
}
