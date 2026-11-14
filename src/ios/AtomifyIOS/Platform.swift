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
