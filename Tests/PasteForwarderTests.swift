// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import AndroidBackend
import ArgumentParser
import Foundation
import SimUseCore
import Testing

// Pins the contract between top-level `Paste`, `IOSSimPasteCommand`,
// and `AndroidPasteCommand`. Mirrors `TapForwarderTests`.
@Suite("Paste forwarder")
@MainActor
struct PasteForwarderTests {

    // MARK: - Validation parity

    @Test("Empty positional text is rejected")
    func emptyTextRejected() {
        do {
            try IOSSimPasteCommand.validateOptions(
                text: "", useStdin: false, inputFile: nil,
                viaMenu: false, targetID: nil, targetX: nil, targetY: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("empty"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("--via-menu without target is rejected")
    func viaMenuRequiresTarget() {
        do {
            try IOSSimPasteCommand.validateOptions(
                text: "hi", useStdin: false, inputFile: nil,
                viaMenu: true, targetID: nil, targetX: nil, targetY: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--via-menu requires a target"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("--via-menu with --target-id AND --target-x/y together is rejected")
    func targetIdAndCoordsExclusive() {
        do {
            try IOSSimPasteCommand.validateOptions(
                text: "hi", useStdin: false, inputFile: nil,
                viaMenu: true, targetID: "field-1", targetX: 100, targetY: 200
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("--target-id OR --target-x/--target-y"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    @Test("target-id without --via-menu is rejected")
    func targetIdRequiresViaMenu() {
        do {
            try IOSSimPasteCommand.validateOptions(
                text: "hi", useStdin: false, inputFile: nil,
                viaMenu: false, targetID: "field-1", targetX: nil, targetY: nil
            )
            Issue.record("expected ValidationError")
        } catch let error as ValidationError {
            #expect(error.message.contains("only valid with --via-menu"))
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
    }

    // MARK: - Symmetric forwarder contract

    @Test("AndroidPasteCommand.performPaste is callable with the forwarder's argument shape")
    func androidPastePerformContract() {
        let _: (
            String,
            String,
            Bool,
            AndroidDeviceController
        ) throws -> Void = AndroidPasteCommand.performPaste
    }

    // MARK: - Caller-side input is inlined for the daemon

    @Test("--stdin does not bypass the daemon on either surface")
    func stdinGoesThroughDaemon() throws {
        let top = try Paste.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        let sub = try IOSSimPasteCommand.parse([
            "--stdin",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
        ])
        #expect(top.daemonBypass == false)
        #expect(sub.daemonBypass == false)
    }

    @Test("--file is read in the client and forwarded as the positional, keeping the other flags")
    func fileIsInlined() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("paste-forward-\(UUID().uuidString).txt").path
        try "日本語\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let udid = "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"
        let argv = ["paste", "--file", path, "--replace", "--device", udid]
        let top = try Paste.parse(Array(argv.dropFirst()))

        let forwarded = try top.daemonArguments(from: argv)

        #expect(forwarded == ["paste", "--replace", "--device", udid, "--", "日本語\n"])
        let daemonSide = try Paste.parse(Array(forwarded.dropFirst()))
        #expect(daemonSide.text == "日本語\n")
        #expect(daemonSide.replace)
        #expect(daemonSide.inputFile == nil)
    }

    @Test("An unreadable --file fails in the client with a readable message")
    func unreadableFileFails() throws {
        let argv = ["paste", "--file", "/nonexistent/in.txt", "--device", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0"]
        let top = try Paste.parse(Array(argv.dropFirst()))
        #expect(throws: CLIError.self) { try top.daemonArguments(from: argv) }
    }

    // MARK: - Flag-surface parity

    @Test("ArgumentParser parses both top-level Paste and IOSSimPasteCommand with same flags")
    func flagSurfaceParses() throws {
        let argv = [
            "Hello",
            "--replace",
            "--via-menu",
            "--target-id", "field-1",
            "--long-press-duration", "1.0",
            "--menu-timeout", "3.0",
            "--udid", "9CD7C6E7-45B3-4E59-BBF2-4D12A9457CD0",
            "--json"
        ]
        let topLevel = try Paste.parse(argv)
        let subCmd = try IOSSimPasteCommand.parse(argv)

        #expect(topLevel.text == "Hello")
        #expect(subCmd.text == "Hello")
        #expect(topLevel.replace && topLevel.viaMenu)
        #expect(subCmd.replace && subCmd.viaMenu)
        #expect(topLevel.targetID == "field-1")
        #expect(subCmd.targetID == "field-1")
        #expect(topLevel.longPressDuration == 1.0)
        #expect(subCmd.longPressDuration == 1.0)
        #expect(topLevel.menuTimeout == 3.0)
        #expect(subCmd.menuTimeout == 3.0)
        #expect(topLevel.jsonOutput)
        #expect(subCmd.jsonOutput)
    }
}