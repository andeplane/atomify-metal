import AtomifyKit
import SwiftUI

/// The input script, read only and monospaced, with Atomify's `#/` hints
/// and the LAMMPS commands highlighted. Share exports the file.
struct ScriptView: View {
    let model: AppModel
    let example: Example
    @State private var lines: [ScriptHighlighting.Line] = []
    @State private var failed = false

    private var url: URL? { model.catalog.inputScriptURL(for: example) }

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("No Script", systemImage: "doc.questionmark",
                                       description: Text("\(example.inputScript) is not in the app."))
            } else {
                ScrollView([.vertical, .horizontal]) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(numbers)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityHidden(true)
                        Text(code)
                            .textSelection(.enabled)
                    }
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(3)
                    .fixedSize()
                    .padding(16)
                }
                .safeAreaPadding(.horizontal, 12)
            }
        }
        .navigationTitle(example.inputScript)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let url, !failed {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url)
                }
            }
        }
        .task(id: example.id) {
            guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
                failed = true
                return
            }
            lines = ScriptHighlighting.lines(text)
        }
    }

    private var numbers: String {
        lines.indices.map { String($0 + 1) }.joined(separator: "\n")
    }

    private var code: AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += styled(line)
        }
        return result
    }

    private func styled(_ line: ScriptHighlighting.Line) -> AttributedString {
        var indent = AttributedString(line.indent)
        indent.foregroundColor = .primary
        switch line.kind {
        case .blank:
            return indent
        case .directive:
            var rest = AttributedString(line.rest)
            rest.foregroundColor = .teal
            return indent + rest
        case .comment:
            var rest = AttributedString(line.rest)
            rest.foregroundColor = .secondary
            return indent + rest
        case .command:
            var command = AttributedString(line.command)
            command.foregroundColor = .pink
            command.font = .system(.footnote, design: .monospaced).weight(.semibold)
            var rest = AttributedString(line.rest)
            rest.foregroundColor = .primary
            return indent + command + rest
        }
    }
}
