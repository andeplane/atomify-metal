import SwiftUI

/// Atomify 2's welcome, over the running simulation on every launch (and
/// from Settings). A tap anywhere (on the card or outside it), the close
/// button or the escape gesture closes it.
struct WelcomeCard: View {
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture(perform: onClose)
                    .accessibilityHidden(true)
                card
                    .frame(width: max(min(520, geometry.size.width - 48), 0))
                    .frame(maxHeight: max(geometry.size.height - 40, 0))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityAction(.escape, onClose)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 12)
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
        .panelBackground(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("WaterMolecule")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 46, height: 42)
                .accessibilityHidden(true)
            Text("Welcome to Atomify")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("""
                We simulate how atoms and molecules behave with a physical model called molecular \
                dynamics. It uses Newton's laws to move atoms around following the laws of physics. \
                You can study gases, liquids and solids to see different properties and effects. \
                Atomify is open source and uses LAMMPS as physics engine.
                """)
                .font(.subheadline)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Image("UiOSeal")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Anders Hafreager and Svenn-Arne Dragly")
                        .font(.footnote.weight(.semibold))
                    Text("University of Oslo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
