import AtomifyKit
import SwiftUI

/// Info, Dashboard and View in one card along the trailing edge, like a
/// Maps card: the atoms stay in view beside it and still answer taps and
/// drags. The ×, a drag to the right on the header, the title capsule or
/// escape closes it.
struct SidePanelView: View {
    let model: AppModel
    let tab: SidePanel
    @AccessibilityFocusState private var headerFocused: Bool
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .panelBackground(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, x: -4)
        .offset(x: dragOffset)
        .accessibilityAction(.escape) { close() }
        .onAppear { headerFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("Panel", selection: Binding(get: { tab }, set: { model.panel = $0 })) {
                ForEach(SidePanel.allCases) { panel in
                    Text(panel.title).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityFocused($headerFocused)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
        .padding(.top, 12)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onChanged { value in
                    dragOffset = max(value.translation.width, 0)
                }
                .onEnded { value in
                    if value.translation.width > 60 || value.predictedEndTranslation.width > 120 {
                        close()
                    }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { dragOffset = 0 }
                }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .info:
            PanelScroll { InfoPanel(model: model, session: model.session) }
        case .dashboard:
            PanelScroll { DashboardSheet(session: model.session) }
        case .view:
            ViewOptionsSheet(model: model, session: model.session)
                .panelFade()
        }
    }

    private func close() {
        model.panel = nil
    }
}

/// A side panel tab's scrolling body: 14 pt sides, room at the bottom and
/// a soft fade where the content runs under the panel's edge.
struct PanelScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.bottom, 20, for: .scrollContent)
        .panelFade()
    }
}

extension View {
    /// Fades the bottom 26 pt of a side panel's body out.
    func panelFade() -> some View {
        mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 26)
            }
        }
    }
}
