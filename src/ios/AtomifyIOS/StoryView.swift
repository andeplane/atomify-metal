import AtomifyKit
import SwiftUI

/// An example told as a story: what you are looking at, why it matters and
/// what to watch for, then (as "More about this example") the description
/// Atomify 2 had. Examples without a story show their description alone.
struct StoryView: View {
    let example: Example
    var font: Font = .subheadline
    var spacing: CGFloat = 12
    /// Hides the description behind a disclosure, for the narrow Info panel.
    var collapsesDescription = false
    @State private var showsDescription = false

    var body: some View {
        if let story = example.story {
            VStack(alignment: .leading, spacing: spacing) {
                Text(story.seeing)
                    .font(font)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                StorySection(title: "Why it matters", font: font) {
                    Text(story.matters)
                        .font(font)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                StorySection(title: "What to look for", font: font) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(story.lookFor.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "eye")
                                    .font(.caption)
                                    .foregroundStyle(.tint)
                                    .frame(width: 18)
                                    .accessibilityHidden(true)
                                Text(item)
                                    .font(font)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                description
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) {
                DescriptionText(text: example.description, font: font, spacing: spacing - 2)
                analysis
            }
        }
    }

    @ViewBuilder
    private var description: some View {
        if collapsesDescription {
            DisclosureGroup(isExpanded: $showsDescription) {
                fullDescription
                    .padding(.top, 6)
            } label: {
                Text("More about this example")
                    .font(font.weight(.semibold))
            }
            .tint(.secondary)
        } else {
            StorySection(title: "More about this example", font: font) { fullDescription }
        }
    }

    private var fullDescription: some View {
        VStack(alignment: .leading, spacing: spacing - 2) {
            DescriptionText(text: example.description, font: font, spacing: spacing - 2)
                .foregroundStyle(.secondary)
            analysis
        }
    }

    @ViewBuilder
    private var analysis: some View {
        if let analysis = example.analysisDescription, !analysis.isEmpty {
            DescriptionText(text: analysis, font: font, spacing: spacing - 2)
        }
    }
}

/// A small heading over a block of the story.
private struct StorySection<Content: View>: View {
    let title: String
    let font: Font
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
    }
}
