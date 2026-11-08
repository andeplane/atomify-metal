import AtomifyKit
import SwiftUI
import UIKit

/// The app's root: the examples gallery, with the running simulation over
/// it full screen, and the welcome on first launch.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.hasSeenWelcome) private var hasSeenWelcome = false
    @State private var showsWelcome = false

    var body: some View {
        @Bindable var model = model
        GalleryScreen(model: model, showsWelcome: $showsWelcome)
            .fullScreenCover(isPresented: $model.showsSimulation) {
                SimulationScreen()
                    .environment(model)
            }
            .sheet(isPresented: $showsWelcome, onDismiss: { hasSeenWelcome = true }) {
                WelcomeSheet()
            }
            .onAppear {
                if !hasSeenWelcome { showsWelcome = true }
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: model.enterForeground()
                case .background: model.enterBackground()
                default: break
                }
            }
            .preferredColorScheme(.dark)
    }
}

/// Where a tap in the gallery leads.
enum ExampleRoute: Hashable {
    case detail(Example)
    case script(Example)
    case files(Example)
}

/// The examples by topic, as in Atomify 2: a row of cards per section, the
/// simulation that is loaded on top, and search. A card opens the
/// example's detail, where Run starts it.
struct GalleryScreen: View {
    let model: AppModel
    @Binding var showsWelcome: Bool
    @State private var path: [ExampleRoute] = []
    @State private var query = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if let error = model.catalogError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                    if query.isEmpty {
                        if model.session.title != nil {
                            NowSimulatingCard(model: model, session: model.session)
                                .padding(.horizontal, 16)
                        }
                        ForEach(model.sections) { section in
                            SectionRow(model: model, section: section)
                        }
                    } else {
                        SearchResults(model: model, query: query)
                    }
                }
                .padding(.vertical, 12)
            }
            .navigationTitle("Atomify")
            .searchable(text: $query, prompt: "Search examples")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsWelcome = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About Atomify")
                }
            }
            .navigationDestination(for: ExampleRoute.self) { route in
                ExampleRouteView(model: model, route: route)
            }
        }
    }
}

/// One section: its title and a horizontally scrolling row of cards.
private struct SectionRow: View {
    let model: AppModel
    let section: ExampleSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.title2.weight(.bold))
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(section.examples) { example in
                        NavigationLink(value: ExampleRoute.detail(example)) {
                            GalleryCard(model: model, example: example)
                        }
                        .buttonStyle(.plain)
                        .containerRelativeFrame(.horizontal) { length, _ in min(length * 0.62, 300) }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// An example in a section row: its picture, title and first sentence.
private struct GalleryCard: View {
    let model: AppModel
    let example: Example

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ExampleThumbnail(url: model.catalog.imageURL(for: example), cornerRadius: 12)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if model.session.example?.id == example.id && model.session.title != nil {
                        LoadedBadge()
                            .padding(8)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(example.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(ExampleText.summary(of: example.description))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private struct LoadedBadge: View {
    var body: some View {
        Text("Loaded")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// The simulation that is loaded, with a way back to it.
private struct NowSimulatingCard: View {
    let model: AppModel
    let session: SimulationSession

    var body: some View {
        Button {
            model.returnToSimulation()
        } label: {
            HStack(spacing: 14) {
                ExampleThumbnail(url: session.example.flatMap { model.catalog.imageURL(for: $0) }, cornerRadius: 8)
                    .frame(width: 72, height: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Currently simulating")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(session.title ?? "")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Return")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.tint, in: Capsule())
                    .foregroundStyle(.white)
            }
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Returns to the simulation.")
    }
}

/// Examples whose title, description or keywords match the search.
private struct SearchResults: View {
    let model: AppModel
    let query: String

    var body: some View {
        let matches = model.catalog.filtered(query: query)
        if matches.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            VStack(spacing: 0) {
                ForEach(matches) { example in
                    NavigationLink(value: ExampleRoute.detail(example)) {
                        HStack(spacing: 12) {
                            ExampleThumbnail(url: model.catalog.imageURL(for: example))
                                .frame(width: 88, height: 55)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(2)
                                Text(ExampleText.summary(of: example.description))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Short forms of the catalog's Markdown descriptions.
enum ExampleText {
    /// The first paragraph without Markdown emphasis, for cards.
    static func summary(of description: String) -> String {
        let paragraph = description
            .components(separatedBy: "\n\n")
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
        return paragraph
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Atomify 2's welcome, shown on first launch and from the info button.
struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "atom")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .accessibilityHidden(true)
                    Text("Welcome to Atomify")
                        .font(.largeTitle.weight(.bold))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                    Text("""
                        We simulate how atoms and molecules behave with a physical model called molecular \
                        dynamics. It uses Newton's laws to move atoms around following the laws of physics. \
                        You can study gases, liquids and solids to see different properties and effects. \
                        Atomify is open source and uses LAMMPS as physics engine.
                        """)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anders Hafreager and Svenn-Arne Dragly")
                            .font(.subheadline.weight(.semibold))
                        Text("University of Oslo")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    dismiss()
                } label: {
                    Text("Explore Examples")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
        }
        .presentationDetents([.large])
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
                image = url.flatMap { ThumbnailCache.image(at: $0) }
            }
    }
}

/// Thumbnails are read once and kept while memory allows.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(at url: URL) -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
