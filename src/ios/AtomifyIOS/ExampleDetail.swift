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

/// An example before you run it, in two panes: its picture (tap to run),
/// script and files on the leading side, title and description on the
/// trailing side, and Run in the bar.
struct ExampleDetail: View {
    let model: AppModel
    let example: Example
    @Environment(\.layoutMetrics) private var metrics

    private var isLoaded: Bool {
        model.session.example?.id == example.id && model.session.status != .idle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(spacing: 12) {
                hero
                rows
            }
            .frame(width: metrics.detailLeading)

            // The text scrolls on its own, down under the home indicator,
            // and ends with room above it.
            ScrollView {
                text
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.bottom, 24, for: .scrollContent)
            .scrollIndicatorsFlash(onAppear: true)
            .frame(maxWidth: metrics.isWide ? 560 : .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.top, 8)
        .safeAreaPadding(.horizontal, metrics.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(example.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The trailing pane shows the title; keep the bar clear.
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isLoaded {
                    Button {
                        model.restartAndShow()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityLabel("Restart")
                    Button {
                        model.returnToSimulation()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                } else {
                    Button {
                        model.run(example)
                    } label: {
                        Label("Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
        }
    }

    /// The picture with a play button; the whole picture runs (or resumes)
    /// the example.
    private var hero: some View {
        Button {
            if isLoaded {
                model.returnToSimulation()
            } else {
                model.run(example)
            }
        } label: {
            ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 14)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .glass(in: Circle())
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLoaded ? "Resume \(example.title)" : "Run \(example.title)")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            NavigationLink(value: ExampleRoute.script(example)) {
                detailRow("Input script", value: example.inputScript, systemImage: "doc.text")
            }
            Divider().padding(.leading, 44)
            NavigationLink(value: ExampleRoute.files(example)) {
                detailRow("Files", value: "\(example.files.count)", systemImage: "folder")
            }
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(example.title)
                    .font(.title2.bold())
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                ExampleSource(model: model, example: example, prefix: "From the Atomify examples")
                if let keywords = example.keywords, !keywords.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(keywords, id: \.self) { keyword in
                                Text(keyword)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            DescriptionText(text: example.description, font: .callout, spacing: 9)
            if let analysis = example.analysisDescription, !analysis.isEmpty {
                DescriptionText(text: analysis, font: .callout, spacing: 9)
            }
        }
    }

    private func detailRow(_ title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .contentShape(Rectangle())
    }
}

/// Where an example comes from: its author (a link when it has one), or
/// `prefix` and its gallery section.
struct ExampleSource: View {
    let model: AppModel
    let example: Example
    let prefix: String

    var body: some View {
        if let author = example.author {
            if let url = example.authorUrl.flatMap({ URL(string: $0) }) {
                Link(destination: url) {
                    Text("By \(author) \(Image(systemName: "arrow.up.right"))")
                }
                .font(.footnote)
            } else {
                Text("By \(author)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            let section = model.sections.first { $0.examples.contains { $0.id == example.id } }?.title
            Text([prefix, section].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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
