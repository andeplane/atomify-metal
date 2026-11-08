import SwiftUI

extension View {
    /// Liquid Glass on iOS 26, a material on earlier systems.
    @ViewBuilder
    func glass(in shape: some Shape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }

    /// Tinted Liquid Glass on iOS 26, a solid tint on earlier systems, for
    /// the one control people press most.
    @ViewBuilder
    func tintedGlass(_ tint: Color, in shape: some Shape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self.background(tint, in: shape)
        }
        #else
        self.background(tint, in: shape)
        #endif
    }
}

extension View {
    /// The background of text-heavy floating surfaces (panels, the welcome):
    /// regular Liquid Glass on iOS 26, the regular material before, so
    /// text stays legible over the atoms.
    @ViewBuilder
    func panelBackground(in shape: some Shape) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
        #else
        self.background(.regularMaterial, in: shape)
        #endif
    }
}

/// A round glass button with an SF Symbol, for controls that float over the atoms.
struct RoundGlassButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle())
        .accessibilityLabel(label)
    }
}

/// A 44 pt symbol button inside a glass rail, with a soft disc behind it
/// while what it opens is showing.
struct RailButton: View {
    let systemImage: String
    let label: String
    var isSelected = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 44, height: 44)
                .background {
                    if isSelected {
                        Circle().fill(.white.opacity(0.2))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sizes that change between a phone and a wide window (an iPad in
/// landscape). Keyed off the window's width, never the device, so windows
/// of any size work.
struct LayoutMetrics: Equatable {
    var isWide = false

    init(width: CGFloat = 0) {
        isWide = width >= 1000
    }

    /// Between the safe area and the floating controls.
    var margin: CGFloat { isWide ? 24 : 12 }
    var panelWidth: CGFloat { isWide ? 400 : 340 }
    /// Between a side panel and the window's edges.
    var panelInset: CGFloat { isWide ? 16 : 8 }
    var cardSize: CGSize { isWide ? CGSize(width: 200, height: 125) : CGSize(width: 168, height: 105) }
    /// The width of an example's leading pane.
    var detailLeading: CGFloat { isWide ? 420 : 300 }
}

extension EnvironmentValues {
    @Entry var layoutMetrics = LayoutMetrics()
}

extension View {
    /// Measures the window's width (safe area included) and hands the
    /// matching `LayoutMetrics` to the views inside.
    func readsLayoutMetrics() -> some View {
        modifier(LayoutMetricsReader())
    }
}

private struct LayoutMetricsReader: ViewModifier {
    @State private var metrics = LayoutMetrics()

    func body(content: Content) -> some View {
        content
            .environment(\.layoutMetrics, metrics)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            } action: { width in
                let next = LayoutMetrics(width: width)
                if next != metrics { metrics = next }
            }
    }
}

extension View {
    /// Offers this view at most `width` and lets it keep its own size, so
    /// a capsule hugs short text and truncates long text at `width`.
    /// (`frame(maxWidth:)` would grow the view to `width`.)
    func widthCap(_ width: CGFloat) -> some View {
        WidthCap(maxWidth: width) { self }
    }
}

private struct WidthCap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return view.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension Color {
    /// The canvas behind the atoms, Atomify 2's near-black (`#121214`), as
    /// the renderer clears to.
    static let canvas = Color(.sRGB, red: 18 / 255, green: 18 / 255, blue: 20 / 255)
}
