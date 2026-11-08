import Testing
@testable import AtomifyKit

@Suite struct ScriptHighlightingTests {
    @Test func classifiesLines() {
        let lines = ScriptHighlighting.lines("#/atom 1 oxygen\n# a comment\n\n  pair_style lj/cut 2.5 # cut\nrun 100\n")
        #expect(lines.map(\.kind) == [.directive, .comment, .blank, .command, .command])
        #expect(lines[0].rest == "#/atom 1 oxygen")
        #expect(lines[3].indent == "  ")
        #expect(lines[3].command == "pair_style")
        #expect(lines[3].rest == " lj/cut 2.5 # cut")
        #expect(lines[4].command == "run")
        #expect(lines[4].rest == " 100")
    }

    @Test func keepsTheTextAsWritten() {
        let script = "units lj\r\n\t  # tab comment\nvariable x equal 1\n   \nfix 1 all nve"
        let lines = ScriptHighlighting.lines(script)
        #expect(lines.map(\.text) == ["units lj", "\t  # tab comment", "variable x equal 1", "   ", "fix 1 all nve"])
        #expect(lines[1].kind == .comment)
        #expect(lines[1].indent == "\t  ")
        #expect(lines[3].kind == .blank)
    }

    @Test func commandWordStopsAtAComment() {
        let line = ScriptHighlighting.line("run#now")
        #expect(line.kind == .command)
        #expect(line.command == "run")
        #expect(line.rest == "#now")
    }

    @Test func emptyScriptIsOneBlankLine() {
        #expect(ScriptHighlighting.lines("") == [ScriptHighlighting.Line(kind: .blank)])
        #expect(ScriptHighlighting.lines("run 1\n").count == 1)
    }
}
