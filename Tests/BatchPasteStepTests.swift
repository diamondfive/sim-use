// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Batch paste uses the same verified clipboard and menu delivery as the
// standalone command. Runtime AX polling belongs to one host-action barrier;
// stdin remains reserved for the batch itself. Live coverage is in PasteTests.

@Suite("Batch — paste step parsing")
@MainActor
struct BatchPasteStepParsingTests {
    /// No live simulator in unit tests: a step that needs the tree (a
    /// default UI-space swipe calibrates) gets an error and degrades to an
    /// identity dispatch, as the batch does when the tree is unreachable.
    /// The default fetcher would query CoreSimulator, which on a CI runner
    /// with no booted simulator never answered and hung the job.
    private func makeContext() -> BatchContext {
        BatchContext(
            simulatorUDID: "FAKE-UDID",
            axCachePolicy: .none,
            typeSubmissionMode: .chunked,
            typeChunkSize: 200,
            fetchElements: { _, _ in throw CLIError(errorDescription: "no simulator in unit tests") },
            calibrator: { _, _, _ in
                Issue.record("calibration must not run without a tree")
                return .identity()
            }
        )
    }

    private func parse(_ tokens: [String]) async throws -> [BatchPrimitive] {
        try await BatchStepParser.parseStepTokens(
            tokens,
            globalUDID: "FAKE-UDID",
            context: makeContext(),
            logger: SimUseLogger(writeToStdErr: false)
        )
    }

    @Test("`paste` is a recognised batch step kind")
    func pasteKindIsRecognised() {
        #expect(BatchStepKind(rawValue: "paste") == .paste)
    }

    @Test("Default paste is one runtime host-action barrier")
    func defaultPathPrimitives() async throws {
        let primitives = try await parse(["paste", "hello"])
        #expect(primitives.count == 1)
        guard case .hostAction(let action) = primitives.first else {
            Issue.record("expected one complete paste host action")
            return
        }
        #expect(action.label == "paste (5 bytes)")
    }

    @Test("Replacement stays inside the same host-action barrier")
    func replacePathPrimitives() async throws {
        let primitives = try await parse(["paste", "--replace", "hello"])
        #expect(primitives.count == 1)
        guard case .hostAction = primitives.first else {
            Issue.record("expected the complete replacement action")
            return
        }
    }

    @Test("Targeted menu paste is accepted without compile-time AX access")
    func viaMenuAccepted() async throws {
        let primitives = try await parse(["paste", "--via-menu", "--target-id", "field", "hello"])
        #expect(primitives.count == 1)
        guard case .hostAction = primitives.first else {
            Issue.record("menu resolution must run at execution time")
            return
        }
    }

    @Test("Dash-prefixed payload is preserved after the option terminator")
    func dashPayload() async throws {
        let primitives = try await parse(["paste", "--", "--device=literal-text"])
        #expect(primitives.count == 1)
    }

    @Test("Per-step targets are rejected", arguments: ["--device", "--udid", "--device=other", "--udid=other"])
    func rejectsStepTarget(option: String) async throws {
        await #expect(throws: (any Error).self) { try await parse(["paste", option, "other"]) }
    }

    @Test("`paste --stdin` is rejected as a batch step")
    func stdinRejected() async throws {
        do {
            _ = try await parse(["paste", "--stdin"])
            Issue.record("expected --stdin to be rejected as a batch step")
        } catch {
            let message = String(describing: error).lowercased()
            #expect(message.contains("stdin"),
                    "error should mention --stdin; got: \(String(describing: error))")
        }
    }

    @Test("`paste` with no text and no --file is rejected")
    func emptyInputRejected() async throws {
        do {
            _ = try await parse(["paste"])
            Issue.record("expected empty paste to be rejected")
        } catch {
            // Either Paste's own validate() catches it, or BatchConvertible does;
            // either way the error reaches the user.
        }
    }

    @Test("`paste` accepts unicode + emoji text")
    func unicodePayload() async throws {
        let primitives = try await parse(["paste", "日本語 你好 🎉"])
        #expect(primitives.count == 1)
        guard case .hostAction(let action) = primitives.first else {
            Issue.record("first primitive should be a hostAction; got \(primitives)")
            return
        }
        // Label encodes the byte count — for unicode/emoji that's > the
        // visible character count, so use that as a sanity check that
        // the right text reached the action.
        let utf8Count = "日本語 你好 🎉".utf8.count
        #expect(action.label.contains("\(utf8Count)"),
                "expected paste label to mention the full \(utf8Count)-byte payload; got '\(action.label)'")
    }

    @Test("`swipe --from x,y --to x,y` is accepted as a batch step")
    func swipePairCoordinates() async throws {
        let primitives = try await parse(["swipe", "--from", "10,20", "--to", "30,40"])
        #expect(primitives.count == 1)
        guard case .hidMergeable = primitives[0] else {
            Issue.record("swipe should produce one mergeable HID primitive; got \(primitives)")
            return
        }
    }

    @Test("positional `swipe x,y x,y` is accepted as a batch step")
    func swipePositionalCoordinates() async throws {
        let primitives = try await parse(["swipe", "10,20", "30,40"])
        #expect(primitives.count == 1)
        guard case .hidMergeable = primitives[0] else {
            Issue.record("swipe should produce one mergeable HID primitive; got \(primitives)")
            return
        }
    }
}
