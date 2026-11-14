import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// The few places where iPhone and iPad differ from the Mac. The views use
// these helpers so they compile for both, and on iOS each one is exactly
// the modifier it replaces.

#if os(iOS)
typealias PlatformImage = UIImage
#else
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

enum Platform {
    /// The side of a floating control: a 44 pt touch target on iOS, a
    /// smaller one for the Mac's pointer.
    #if os(iOS)
    static let controlSide: CGFloat = 44
    #else
    static let controlSide: CGFloat = 36
    #endif

    /// Off only in the Mac's offscreen screenshot tool: Liquid Glass draws
    /// on screen only, so offscreen pictures use the material fallback.
    nonisolated(unsafe) static var allowsLiquidGlass = true
}

extension ToolbarItemPlacement {
    /// The leading end of the navigation bar (the window's toolbar on Mac).
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// The trailing end of the navigation bar (the window's toolbar on Mac).
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

extension View {
    /// A small title in the navigation bar; Mac windows have only that kind.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Text typed as written, for search fields.
    @ViewBuilder
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// Less room between the sections of a grouped form (macOS has no such setting).
    @ViewBuilder
    func compactListSections() -> some View {
        #if os(iOS)
        listSectionSpacing(.compact)
        #else
        self
        #endif
    }

    /// Hides the home indicator and status bar on iOS while `hidden`.
    @ViewBuilder
    func systemOverlaysHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        persistentSystemOverlays(hidden ? .hidden : .automatic)
        #else
        self
        #endif
    }

    /// A light wash over a control while the pointer is on it (Mac only;
    /// touch has no hover).
    func pointerHighlight(in shape: some Shape) -> some View {
        #if os(iOS)
        self
        #else
        modifier(PointerHighlight(shape: AnyShape(shape)))
        #endif
    }

    /// The window's main button on Mac: its title shown beside the symbol
    /// (toolbars show symbols only) and Return pressing it. As is on iOS.
    @ViewBuilder
    func defaultActionLabel() -> some View {
        #if os(iOS)
        self
        #else
        labelStyle(.titleAndIcon)
            .keyboardShortcut(.defaultAction)
        #endif
    }

    /// A list as a centred column of readable width with inset rows on
    /// Mac, where a window can be very wide. As is on iOS.
    @ViewBuilder
    func readingColumn() -> some View {
        #if os(iOS)
        self
        #else
        listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 16, for: .scrollContent)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        #endif
    }

    /// A tooltip for the pointer on Mac; nothing on iOS.
    @ViewBuilder
    func tooltip(_ text: String) -> some View {
        #if os(iOS)
        self
        #else
        help(text)
        #endif
    }

    /// A screen over everything else in the window: a full-screen cover on
    /// iOS; on Mac a layer over the whole window, drawn by the nearest
    /// `hostsFullWindowCovers()` above (a sheet would be a small window).
    func fullWindowCover<Content: View>(isPresented: Binding<Bool>,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        modifier(FullWindowCoverModifier(isPresented: isPresented.wrappedValue, cover: content))
        #endif
    }

    /// Draws the Mac's `fullWindowCover`s of the views inside, over them.
    /// Nothing on iOS, where they are system covers.
    @ViewBuilder
    func hostsFullWindowCovers() -> some View {
        #if os(iOS)
        self
        #else
        overlayPreferenceValue(FullWindowCoverKey.self) { covers in
            ZStack {
                ForEach(covers) { cover in
                    cover.content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: covers.map(\.id))
        }
        #endif
    }
}

#if os(macOS)
private struct PointerHighlight: ViewModifier {
    let shape: AnyShape
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(shape.fill(.white.opacity(hovering ? 0.12 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct FullWindowCover: Identifiable {
    let id: UUID
    let content: AnyView
}

struct FullWindowCoverKey: PreferenceKey {
    static var defaultValue: [FullWindowCover] { [] }

    static func reduce(value: inout [FullWindowCover], nextValue: () -> [FullWindowCover]) {
        value.append(contentsOf: nextValue())
    }
}

private struct FullWindowCoverModifier<Cover: View>: ViewModifier {
    let isPresented: Bool
    let cover: () -> Cover
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content.transformPreference(FullWindowCoverKey.self) { covers in
            if isPresented {
                covers.append(FullWindowCover(id: id, content: AnyView(cover())))
            }
        }
    }
}
#endif
