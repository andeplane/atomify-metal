import Foundation

/// Atomify 2's run-time directives, `#/speed N` (timesteps per displayed
/// frame) and `#/label TEXT` (a status line), which take effect where they
/// stand in the script, between its runs.
///
/// LAMMPS skips comments, so `ScriptPreparation` turns each into a
/// `print "@atomify ..."` command on the same line. LAMMPS prints the
/// marker when it reaches that line, and `ScriptEventFilter` takes the
/// marker out of the output and reports it.
public enum ScriptEvent: Sendable, Equatable {
    case speed(Double)
    case label(String)

    /// Marks output lines that carry an event.
    public static let marker = "@atomify"

    /// The directive as it stands in the script, for a console.
    public var directive: String {
        switch self {
        case .speed(let steps):
            let number = steps == steps.rounded() && abs(steps) < 1e15 ? String(Int64(steps)) : String(steps)
            return "#/speed \(number)"
        case .label(let text):
            return "#/label \(text)"
        }
    }

    /// The print command for a `#/speed` or `#/label` line, or nil for
    /// any other line.
    public static func command(forDirective line: Substring) -> String? {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard body.hasPrefix("#/") else { return nil }
        let words = body.dropFirst(2).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let name = words.first else { return nil }
        let argument = words.count > 1 ? words[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        switch name {
        case "speed":
            guard let value = Double(argument), value.isFinite, value > 0 else { return nil }
            return "print \"\(marker) speed \(argument)\""
        case "label":
            // Double quotes would end the string and $ would start a
            // variable, so they are dropped. A single quote makes LAMMPS fail
            // (print parses its text again, and turns ’ into '), so
            // apostrophes travel as backticks; `parse` turns them back.
            let text = argument.filter { $0 != "\"" && $0 != "$" }.replacingOccurrences(of: "'", with: "`")
            return "print \"\(marker) label \(text)\""
        default:
            return nil
        }
    }

    /// The event an output line carries, or nil.
    public static func parse(line: Substring) -> ScriptEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker + " ") else { return nil }
        let rest = trimmed.dropFirst(marker.count + 1)
        if rest.hasPrefix("speed ") {
            guard let value = Double(rest.dropFirst(6).trimmingCharacters(in: .whitespaces)),
                  value.isFinite, value > 0 else { return nil }
            return .speed(value)
        }
        if rest.hasPrefix("label") {
            return .label(rest.dropFirst(5).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "`", with: "\u{2019}"))
        }
        return nil
    }
}

/// Removes event markers from LAMMPS output as it arrives in pieces, and
/// reports the events. It holds back an unfinished last line until the
/// rest arrives (or `flush()`).
public struct ScriptEventFilter: Sendable {
    private var partial = ""
    /// Writes each event's `directive` into the text where its marker was,
    /// for a console that should still show them.
    public var echoesEvents: Bool

    public init(echoesEvents: Bool = false) {
        self.echoesEvents = echoesEvents
    }

    public mutating func filter(_ chunk: String) -> (text: String, events: [ScriptEvent]) {
        guard !chunk.isEmpty else { return ("", []) }
        let combined = partial + chunk
        var text = ""
        var events: [ScriptEvent] = []
        var lineStart = combined.startIndex
        var index = combined.startIndex
        while index < combined.endIndex {
            let character = combined[index]
            let next = combined.index(after: index)
            if character == "\n" || character == "\r\n" {
                let line = combined[lineStart..<index]
                if let event = ScriptEvent.parse(line: line) {
                    events.append(event)
                    if echoesEvents { text += event.directive + "\n" }
                } else if !Self.isEcho(line) {
                    text += combined[lineStart..<next]
                }
                lineStart = next
            }
            index = next
        }
        partial = String(combined[lineStart...])
        return (text, events)
    }

    /// The held back unfinished line, unless it is a marker.
    public mutating func flush() -> (text: String, events: [ScriptEvent]) {
        defer { partial = "" }
        if let event = ScriptEvent.parse(line: Substring(partial)) {
            return (echoesEvents ? event.directive : "", [event])
        }
        return (Self.isEcho(Substring(partial)) ? "" : partial, [])
    }

    /// The print command itself, when LAMMPS echoes input lines.
    private static func isEcho(_ line: Substring) -> Bool {
        line.contains("print \"\(ScriptEvent.marker) ")
    }
}
