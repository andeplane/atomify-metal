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

/// A round glass button with an SF Symbol, for controls that float over the atoms.
struct RoundGlassButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.medium))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(in: Circle())
        .accessibilityLabel(label)
    }
}
