import AtomifyKit
import SwiftUI

/// Where a tap in the gallery leads.
enum ExampleRoute: Hashable {
    case detail(Example)
    case script(Example)
    case files(Example)
    case settings
    case acknowledgements
}

/// The examples by topic, as in Atomify 2: a row of cards per section and
/// a search field that narrows them. A card opens the example's detail,
/// where Run starts it. It always opens at its root (`AppModel.galleryPath`).
struct GalleryScreen: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $model.galleryPath) {
            GalleryContent(model: model, query: query)
                .navigationTitle("Simulations")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .barLeading) {
                        Button {
                            model.returnToSimulation()
                        } label: {
                            Label(model.session.title ?? "Simulation", systemImage: "chevron.backward")
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                        }
                        .accessibilityHint("Returns to the simulation.")
                        .tooltip("Back to the running simulation")
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .barTrailing) {
                        GallerySearchField(text: $query)
                    }
                    #endif
                    ToolbarItem(placement: .barTrailing) {
                        NavigationLink(value: ExampleRoute.settings) {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
                .navigationDestination(for: ExampleRoute.self) { route in
                    ExampleRouteView(model: model, route: route)
                }
                #if os(macOS)
                .searchable(text: $query, placement: .toolbar, prompt: "Search simulations")
                #endif
        }
        .readsLayoutMetrics()
    }
}

/// The section rows, narrowed to the examples that match the search.
private struct GalleryContent: View {
    let model: AppModel
    let query: String
    @Environment(\.layoutMetrics) private var metrics

    #if os(iOS)
    private static let sectionSpacing: CGFloat = 14
    #else
    private static let sectionSpacing: CGFloat = 32
    #endif

    var body: some View {
        let sections = visibleSections
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Self.sectionSpacing) {
                if let error = model.catalogError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(.horizontal, metrics.margin)
                }
                ForEach(sections) { section in
                    SectionRow(model: model, section: section)
                }
            }
            #if os(iOS)
            .padding(.top, 6)
            .padding(.bottom, 12)
            #else
            // A page of sections, as wide as reads well on a large display.
            .padding(.horizontal, metrics.margin)
            .padding(.top, 16)
            .padding(.bottom, 28)
            .frame(maxWidth: 1400)
            .frame(maxWidth: .infinity)
            #endif
        }
        .scrollIndicatorsFlash(onAppear: true)
        .overlay {
            if sections.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private var visibleSections: [ExampleSection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.sections }
        let matches = Set(model.catalog.filtered(query: trimmed).map(\.id))
        return model.sections.compactMap { section in
            var section = section
            section.examples = section.examples.filter { matches.contains($0.id) }
            return section.examples.isEmpty ? nil : section
        }
    }
}

#if os(iOS)
/// Search in the bar: a small glass field, since `.searchable` turns into
/// a bar over the cards at the bottom of the screen on iOS 26.
private struct GallerySearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .noAutocapitalization()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(width: 200, height: 36)
        .glass(in: Capsule())
        .accessibilityLabel("Search examples")
    }
}

#endif

#if os(iOS)
/// One section: its title and a horizontally scrolling row of cards.
private struct SectionRow: View {
    let model: AppModel
    let section: ExampleSection
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(metrics.isWide ? .title2.bold() : .title3.bold())
                .padding(.horizontal, metrics.margin)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: metrics.isWide ? 14 : 12) {
                    ForEach(section.examples) { example in
                        NavigationLink(value: ExampleRoute.detail(example)) {
                            GalleryCard(model: model, example: example)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

#else
/// One section on Mac: its title over a grid of cards that fills the
/// window's width and scrolls with the page (a sideways row is for touch).
private struct SectionRow: View {
    let model: AppModel
    let section: ExampleSection

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 20, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(section.examples) { example in
                    NavigationLink(value: ExampleRoute.detail(example)) {
                        MacGalleryCard(model: model, example: example)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// An example in a Mac grid: a 16:10 picture, the title and a line of its
/// description, lifted a little under the pointer.
private struct MacGalleryCard: View {
    let model: AppModel
    let example: Example
    @State private var hovering = false

    var body: some View {
        let running = model.session.example?.id == example.id && model.session.title != nil
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay {
                    ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.35 : 0.08), lineWidth: 1)
                }
                .overlay(alignment: .topLeading) {
                    if running {
                        RunningBadge()
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(example.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(ExampleText.summary(of: example.description))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "Running" : "")
    }
}
#endif

#if os(iOS)
/// An example in a section row: its picture and title.
private struct GalleryCard: View {
    let model: AppModel
    let example: Example
    @Environment(\.layoutMetrics) private var metrics

    var body: some View {
        let size = metrics.cardSize
        let running = model.session.example?.id == example.id && model.session.title != nil
        VStack(alignment: .leading, spacing: 6) {
            ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 10)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .topLeading) {
                    if running {
                        RunningBadge()
                            .padding(6)
                    }
                }
            Text(example.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .frame(width: size.width, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(running ? "Running" : "")
    }
}

#endif

/// Marks the example that is loaded in the simulation.
private struct RunningBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text("Running")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.black.opacity(0.6), in: Capsule())
        .accessibilityHidden(true)
    }
}

/// Reading the catalog's Markdown descriptions.
enum ExampleText {
    /// A paragraph of a description, or a heading: a paragraph that is all
    /// bold.
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
    }

    /// The first paragraph of a description as plain text on one line,
    /// for a card's subtitle.
    static func summary(of description: String) -> String {
        for block in blocks(of: description) {
            if case .paragraph(let text) = block {
                return String(Markdown.inline(text).characters)
                    .replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    /// A description split on blank lines. Markdown heading lines (`#`)
    /// are left out, as `Markdown.inline` does.
    static func blocks(of description: String) -> [Block] {
        var blocks: [Block] = []
        var lines: [Substring] = []
        func flush() {
            let paragraph = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            lines = []
            guard !paragraph.isEmpty else { return }
            if paragraph.count > 4, paragraph.hasPrefix("**"), paragraph.hasSuffix("**") {
                let inner = paragraph.dropFirst(2).dropLast(2)
                if !inner.contains("**") {
                    blocks.append(.heading(inner.trimmingCharacters(in: .whitespacesAndNewlines)))
                    return
                }
            }
            blocks.append(.paragraph(paragraph))
        }
        let text = description.replacingOccurrences(of: "\r\n", with: "\n")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
            } else if !trimmed.hasPrefix("#") {
                lines.append(line)
            }
        }
        flush()
        return blocks
    }
}

/// An example's picture from its `imageUrl`, or an atom symbol.
struct ExampleThumbnail: View {
    let url: URL?
    var cornerRadius: CGFloat = 8
    @State private var image: PlatformImage?

    var body: some View {
        // The picture is an overlay, so it fills the frame it is given
        // without growing it.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image {
                    Image(platformImage: image)
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
                image = url.flatMap { ThumbnailCache.image(at: $0) }
            }
    }
}

/// Thumbnails are read once and kept while memory allows.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, PlatformImage>()

    static func image(at url: URL) -> PlatformImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = PlatformImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
