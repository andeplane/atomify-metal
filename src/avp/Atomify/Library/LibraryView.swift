import AtomifyVision
import SwiftUI

/// The launch window: one experiment at a time in a swipeable row. The next
/// one peeks in from the right, so the way forward is obvious.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(Self.selectionKey) private var storedID = ""
    @State private var selectedID: String?
    @State private var opening = false
    @State private var launchMessage: String?
    @State private var width = Self.defaultSize.width
    /// The card restored at launch, known before the carousel settles, so
    /// it is drawn in focus and loads first.
    private let initialID = UserDefaults.standard.string(forKey: Self.selectionKey)

    static let selectionKey = "library.selectedDemoID"
    static let defaultSize = CGSize(width: 1280, height: 720)
    static let minimumSize = CGSize(width: 1100, height: 700)
    static let maximumSize = CGSize(width: 1680, height: 900)
    // Cards keep a fixed size so their portals never rebuild; the window's
    // width only changes how much of the neighbours shows.
    private static let cardWidth: CGFloat = 704
    private static let cardHeight: CGFloat = 592
    private static let cardSpacing: CGFloat = 32
    private static let cardPadding: CGFloat = 24
    /// Concentric corners: portal radius = card radius − card padding.
    private static let cardRadius: CGFloat = 48
    private static let portalSize = CGSize(width: cardWidth - 2 * cardPadding, height: 304)
    private static let dimmedOpacity = 0.45

    private var demos: [Demo] { model.boxDemos }

    var body: some View {
        VStack(spacing: 0) {
            Text("ATOMIFY")
                .font(.subheadline.weight(.semibold)).tracking(6)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 24).padding(.bottom, 16)
            Spacer(minLength: 0)
            carousel.frame(height: Self.cardHeight)
            pageDots.padding(.top, 16)
            Group {
                if let message = model.catalogError ?? model.errorMessage ?? launchMessage {
                    Label(message, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else { Text(" ").accessibilityHidden(true) }
            }
            .font(.footnote).lineLimit(1).padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(minWidth: Self.minimumSize.width, idealWidth: Self.defaultSize.width, maxWidth: Self.maximumSize.width,
               minHeight: Self.minimumSize.height, idealHeight: Self.defaultSize.height,
               maxHeight: Self.maximumSize.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        // A scroll position set before the first layout is ignored, so the
        // remembered card is restored once the carousel exists.
        .task { settleSelection() }
        .onChange(of: demos.map(\.id)) { _, _ in settleSelection() }
        .onChange(of: selectedID) { _, id in if let id { storedID = id } }
    }

    private var carousel: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Self.cardSpacing) {
                ForEach(demos) { demo in card(demo) }
            }
            .scrollTargetLayout()
        }
        // Centres the selected card; its neighbours peek in at both sides.
        .contentMargins(.horizontal, max(0, (width - Self.cardWidth) / 2), for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
        .scrollPosition(id: $selectedID)
        .scrollIndicators(.hidden)
    }

    /// The selected card's only control is Start. Any other card is one
    /// tappable element that brings it to the centre.
    private var focusedID: String? {
        selectedID ?? demos.first { $0.id == initialID }?.id ?? demos.first?.id
    }

    /// The card in focus loads first, once its opening has had a moment to
    /// draw (so atoms never appear before the portal); each step away waits
    /// a little longer.
    private func loadDelay(_ demo: Demo) -> Duration {
        guard let i = demos.firstIndex(where: { $0.id == demo.id }),
              let f = demos.firstIndex(where: { $0.id == focusedID }) else { return .milliseconds(300) }
        return .milliseconds(300 + 120 * abs(i - f))
    }

    private func card(_ demo: Demo) -> some View {
        let isSelected = demo.id == focusedID
        return VStack(alignment: .leading, spacing: 0) {
            PortalPreview(structureURL: previewURL(demo), scriptURL: scriptURL(demo), size: Self.portalSize,
                          cornerRadius: Self.cardRadius - Self.cardPadding, isDimmed: !isSelected,
                          loadDelay: loadDelay(demo))
            // Only the 2D parts fade here; the portal fades its own content,
            // as SwiftUI opacity would turn the opening into a grey pane.
            VStack(alignment: .leading, spacing: 8) {
                Text(demo.title)
                    .font(.extraLargeTitle).foregroundStyle(.primary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(demo.summary)
                    .font(.title3).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button { launch(demo) } label: {
                    Label(buttonTitle, systemImage: model.labIsOpen ? "arrow.uturn.backward" : "play.fill")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(opening)
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
            }
            .padding(.top, 24)
            .opacity(isSelected ? 1 : Self.dimmedOpacity)
        }
        .padding(Self.cardPadding)
        .frame(width: Self.cardWidth, height: Self.cardHeight, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Self.cardRadius).fill(.regularMaterial)
                .opacity(isSelected ? 1 : Self.dimmedOpacity)
        }
        .animation(.easeInOut(duration: 0.3), value: isSelected)
        // A side card is one tap target with one hover shape. The selected
        // card has neither, so gaze reaches its atoms and its Start button.
        .contentShape(.hoverEffect, .rect(cornerRadius: Self.cardRadius))
        .gesture(TapGesture().onEnded { select(demo.id) }, isEnabled: !isSelected)
        .hoverEffect(isEnabled: !isSelected)
        .accessibilityElement(children: isSelected ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? [] : .isButton)
        .accessibilityAction { if !isSelected { select(demo.id) } }
        .id(demo.id)
    }

    /// Display only: swiping pages, and the peeking card shows there is more.
    private var pageDots: some View {
        HStack(spacing: 10) {
            ForEach(demos) { demo in
                Circle()
                    .fill(demo.id == focusedID ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: focusedID)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Experiment \((demos.firstIndex { $0.id == focusedID } ?? 0) + 1) of \(demos.count)")
    }

    private var buttonTitle: String {
        if opening { return "Opening…" }
        return model.labIsOpen ? "Return to lab" : "Start"
    }

    private func select(_ id: String) {
        withAnimation(.easeInOut(duration: 0.45)) { selectedID = id }
    }

    /// Restores the last experiment, or starts at the first.
    private func settleSelection() {
        guard !demos.isEmpty, !demos.contains(where: { $0.id == selectedID }) else { return }
        selectedID = demos.first { $0.id == storedID }?.id ?? demos[0].id
    }

    private func previewURL(_ demo: Demo) -> URL? {
        guard let folder = model.demosDirectory?.appendingPathComponent(demo.folder) else { return nil }
        let url = folder.appendingPathComponent("preview.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func scriptURL(_ demo: Demo) -> URL? {
        model.demosDirectory?.appendingPathComponent(demo.folder).appendingPathComponent(demo.inputScript)
    }

    private func launch(_ demo: Demo) {
        if model.labIsOpen {
            openWindow(id: AppModel.controlsWindowID)
            dismissWindow(id: AppModel.windowID)
            return
        }
        guard !opening else { return }
        opening = true
        launchMessage = nil
        model.load(demo)
        Task { @MainActor in
            defer { opening = false }
            guard model.run != nil, !model.labIsOpen else { return }
            switch await openImmersiveSpace(id: AppModel.labSpaceID) {
            case .opened:
                model.restoreLibrary = {
                    openWindow(id: AppModel.windowID)
                    dismissWindow(id: AppModel.controlsWindowID)
                }
                openWindow(id: AppModel.controlsWindowID)
                dismissWindow(id: AppModel.windowID)
            case .userCancelled:
                model.stop()
            default:
                model.stop()
                launchMessage = "The experiment could not open. Please try again."
            }
        }
    }
}
