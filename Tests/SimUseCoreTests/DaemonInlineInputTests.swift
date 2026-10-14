// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore
import Testing

@Suite("DaemonInlineInput — argv rewriting for caller-side input")
struct DaemonInlineInputTests {

    @Test("Removes a long flag")
    func removesFlag() {
        let args = ["ios", "batch", "--stdin", "--device", "X"]
        #expect(DaemonInlineInput.removingFlag("stdin", from: args) == ["ios", "batch", "--device", "X"])
    }

    @Test("Removes an option in both the separate-value and the = form")
    func removesOption() {
        #expect(DaemonInlineInput.removingOption("file", from: ["type", "--file", "a.txt", "--device", "X"])
            == ["type", "--device", "X"])
        #expect(DaemonInlineInput.removingOption("file", from: ["type", "--file=a.txt", "--device", "X"])
            == ["type", "--device", "X"])
    }

    @Test("Leaves tokens after a -- terminator untouched")
    func stopsAtTerminator() {
        let args = ["type", "--device", "X", "--", "--stdin"]
        #expect(DaemonInlineInput.removingFlag("stdin", from: args) == args)
        #expect(DaemonInlineInput.removingOption("device", from: args) == ["type", "--", "--stdin"])
    }

    @Test("Inserts options before a -- terminator, else appends them")
    func insertsOptions() {
        #expect(DaemonInlineInput.insertingOptions(["--step=tap @1"], into: ["ios", "batch", "--device", "X"])
            == ["ios", "batch", "--device", "X", "--step=tap @1"])
        #expect(DaemonInlineInput.insertingOptions(["--step=tap @1"], into: ["ios", "batch", "--"])
            == ["ios", "batch", "--step=tap @1", "--"])
    }

    @Test("Appends a positional after a -- terminator, so text that starts with - stays text")
    func appendsPositional() {
        #expect(DaemonInlineInput.appendingPositional("-5 apples", to: ["type", "--device", "X"])
            == ["type", "--device", "X", "--", "-5 apples"])
        #expect(DaemonInlineInput.appendingPositional("hi", to: ["type", "--"]) == ["type", "--", "hi"])
        #expect(DaemonInlineInput.appendingPositional("", to: ["type"]) == ["type", "--", ""])
    }

    @Test("Replaces a --stdin or --file text source with the text as a positional")
    func inlinesText() {
        #expect(DaemonInlineInput.inliningText("line 1\nline 2", into: ["type", "--stdin", "--device", "X"])
            == ["type", "--device", "X", "--", "line 1\nline 2"])
        #expect(DaemonInlineInput.inliningText("hi", into: ["paste", "--file", "in.txt", "--replace"])
            == ["paste", "--replace", "--", "hi"])
    }
}
