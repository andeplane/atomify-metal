/// Splits a LAMMPS input script into lines for a read-only, highlighted
/// view: Atomify's `#/` directives, comments, and commands with their
/// first word (the LAMMPS command) set apart.
public enum ScriptHighlighting {
    public enum Kind: Sendable, Equatable {
        case blank
        /// `#/atom`, `#/bond`, `#/camera` and other Atomify hints.
        case directive
        case comment
        case command
    }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        /// Leading whitespace.
        public var indent: String
        /// The command word of a command line ("pair_style"); empty otherwise.
        public var command: String
        /// Everything after the command word, or the whole trimmed line for
        /// other kinds.
        public var rest: String

        public init(kind: Kind, indent: String = "", command: String = "", rest: String = "") {
            self.kind = kind
            self.indent = indent
            self.command = command
            self.rest = rest
        }

        /// The line as written.
        public var text: String { indent + command + rest }
    }

    public static func lines(_ script: String) -> [Line] {
        // "\r\n" is a single Character in Swift, so split on both.
        var lines = script.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { line(String($0)) }
        // A trailing newline does not start another line.
        if lines.count > 1, lines.last == Line(kind: .blank) { lines.removeLast() }
        return lines
    }

    public static func line(_ raw: String) -> Line {
        let raw = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let body = raw.drop { $0 == " " || $0 == "\t" }
        let indent = String(raw.prefix(raw.count - body.count))
        if body.allSatisfy({ $0.isWhitespace }) {
            return Line(kind: .blank, indent: raw)
        }
        if body.hasPrefix("#/") {
            return Line(kind: .directive, indent: indent, rest: String(body))
        }
        if body.hasPrefix("#") {
            return Line(kind: .comment, indent: indent, rest: String(body))
        }
        let word = body.prefix { !$0.isWhitespace && $0 != "#" }
        return Line(kind: .command, indent: indent, command: String(word), rest: String(body.dropFirst(word.count)))
    }
}
