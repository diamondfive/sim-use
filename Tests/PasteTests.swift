// SPDX-License-Identifier: Apache-2.0
import Testing
import Foundation
@testable import iOSSimBackend

// All enabled cases must insert the expected text. A visible software keyboard
// is not a reason to skip, and append is not an acceptable replacement result.
@Suite("Paste Command Tests", .serialized, .enabled(if: isE2EEnabled))
struct PasteTests {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func settlePaste(udid: String, expected: String, timeout: TimeInterval = 8) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        while Date() < deadline {
            let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
            last = UIStateParser.findElement(in: ui, withIdentifier: "paste-content-echo")?.value
            if last == expected { return last }
            // Only permission alerts can authorize an allow action. Never tap
            // an arbitrary app button merely because it is labelled Paste.
            if let alert = UIStateParser.findElement(in: ui, matching: { ["Alert", "Dialog"].contains($0.type) }),
               let allow = UIStateParser.findElement(in: alert, matching: { element in
                   element.type == "Button" && ["Allow Paste", "Paste", "允许粘贴", "允許貼上", "ペースト"].contains(element.label ?? "")
               }), let frame = allow.frame {
                _ = try await TestHelpers.runSimUseCommand("tap --x \(frame.x + frame.width / 2) --y \(frame.y + frame.height / 2)", simulatorUDID: udid)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return last
    }

    private func setup(multiline: Bool = false) async throws -> String {
        let udid = try TestHelpers.requireSimulatorUDID()
        try await TestHelpers.launchPlaygroundApp(to: "paste-test", simulatorUDID: udid)
        if multiline {
            _ = try await TestHelpers.runSimUseCommand("tap --id paste-multiline-toggle", simulatorUDID: udid)
        }
        _ = try await TestHelpers.runSimUseCommand("tap --id paste-input-field", simulatorUDID: udid)
        return udid
    }

    private func paste(_ text: String, udid: String, options: String = "", namespace: String = "") async throws {
        _ = try await TestHelpers.runSimUseCommand("\(namespace)paste \(Self.quote(text)) \(options)", simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: text) == text)
    }

    @Test("Default ASCII paste inserts with any keyboard mode")
    func basicAsciiPaste() async throws {
        let udid = try await setup()
        let text = "SIMUSE-PASTE-ASCII 123"
        try await paste(text, udid: udid)
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        #expect(UIStateParser.findElement(in: ui, withIdentifier: "paste-char-count")?.value == "\(text.count)")
    }

    @Test("Unicode and quoting work through both command surfaces", arguments: ["", "ios "])
    func unicodePaste(namespace: String) async throws {
        let udid = try await setup()
        try await paste("SIMUSE-PASTE-日本語 Кириллица 👩‍🍳 é '$HOME' `false` \\", udid: udid, namespace: namespace)
    }

    @Test("Default replacement works on empty and populated fields")
    func replacePaste() async throws {
        let udid = try await setup()
        try await paste("SIMUSE-PASTE-FIRST VALUE", udid: udid, options: "--replace")
        try await paste("SIMUSE-PASTE-SECOND", udid: udid, options: "--replace")
    }

    @Test("Menu targeting by id supports Unicode")
    func pasteViaMenuByID() async throws {
        let udid = try await setup()
        try await paste("SIMUSE-PASTE-日本語 👩‍🍳", udid: udid, options: "--via-menu --target-id paste-input-field")
    }

    @Test("Menu replacement strictly overwrites, including an empty field")
    func replacePasteViaMenu() async throws {
        let udid = try await setup()
        let options = "--replace --via-menu --target-id paste-input-field"
        try await paste("SIMUSE-PASTE-FIRST PASTE", udid: udid, options: options)
        try await paste("SIMUSE-PASTE-SECOND", udid: udid, options: options)
    }

    @Test("Menu targeting accepts current coordinates")
    func pasteViaCoordinates() async throws {
        let udid = try await setup()
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        let frame = try #require(UIStateParser.findElement(in: ui, withIdentifier: "paste-input-field")?.frame)
        try await paste("SIMUSE-PASTE-COORDINATES", udid: udid,
                        options: "--via-menu --target-x \(frame.x + frame.width / 2) --target-y \(frame.y + frame.height / 2)")
    }

    @Test("File and stdin preserve multiline text and final LF", arguments: ["--file", "--stdin"])
    func fileAndStdin(option: String) async throws {
        let udid = try await setup(multiline: true)
        let text = "SIMUSE-PASTE-INPUT 日本語 👩‍🍳\n\nquotes ' \" $HOME `false`\ttab\n"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paste-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(text.utf8).write(to: file)
        let input = option == "--file" ? "--file \(Self.quote(file.path))" : "--stdin < \(Self.quote(file.path))"
        let response = try await TestHelpers.runSimUseCommand("paste \(input) --json", simulatorUDID: udid)
        #expect(response.output.contains("\"ok\":true"))
        #expect(try await Self.settlePaste(udid: udid, expected: text) == text)
    }

    @Test("A large Unicode stdin payload is actually inserted")
    func largePayload() async throws {
        let udid = try await setup(multiline: true)
        let text = "SIMUSE-PASTE-LARGE\n" + String(repeating: "日本語 👩‍🍳 é\n", count: 4000)
        #expect(text.utf8.count > 94_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paste-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(text.utf8).write(to: file)
        _ = try await TestHelpers.runSimUseCommand("paste --stdin < \(Self.quote(file.path))", simulatorUDID: udid)
        let actual = try await Self.settlePaste(udid: udid, expected: text, timeout: 15)
        #expect(actual.map { Data($0.utf8) } == Data(text.utf8), "large field value must match exact bytes")
    }

    private func selectSuffix(udid: String) async throws {
        _ = try await TestHelpers.runSimUseCommand("ios key 80", simulatorUDID: udid)
        for _ in 0..<3 {
            _ = try await TestHelpers.runSimUseCommand("ios key-combo --modifiers 225 --key 80", simulatorUDID: udid)
        }
    }

    @Test("Default paste preserves a middle caret")
    func insertionAtCaret() async throws {
        let udid = try await setup(multiline: true)
        try await paste("SIMUSE-PASTE-AB", udid: udid)
        _ = try await TestHelpers.runSimUseCommand("ios key 80", simulatorUDID: udid)
        _ = try await TestHelpers.runSimUseCommand("paste \(Self.quote("\n"))", simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-A\nB") == "SIMUSE-PASTE-A\nB")
    }

    @Test("Default paste preserves a selected range")
    func replacesSelection() async throws {
        let udid = try await setup(multiline: true)
        try await paste("SIMUSE-PASTE-AoldZ", udid: udid)
        try await selectSuffix(udid: udid)
        _ = try await TestHelpers.runSimUseCommand("paste \(Self.quote("\n"))", simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-A\nZ") == "SIMUSE-PASTE-A\nZ")
    }

    @Test("Replace selects the whole field even with a prior partial selection")
    func replacePartialSelection() async throws {
        let udid = try await setup()
        try await paste("SIMUSE-PASTE-AoldZ", udid: udid)
        try await selectSuffix(udid: udid)
        try await paste("SIMUSE-PASTE-ALL", udid: udid, options: "--replace")
    }

    @Test("Repeated replacement does not reuse stale menu coordinates")
    func repeatedPaste() async throws {
        let udid = try await setup()
        for index in 0..<3 { try await paste("SIMUSE-PASTE-REPEAT-\(index)", udid: udid, options: "--replace") }
    }

    @Test("Batch flushes earlier HID and shares default, replace and targeted delivery")
    func batchPaste() async throws {
        let udid = try await setup()
        let steps = [
            "tap --id paste-input-field",
            "paste SIMUSE-PASTE-BATCH-FIRST",
            "paste --replace SIMUSE-PASTE-BATCH-SECOND",
            "paste --replace --via-menu --target-id paste-input-field SIMUSE-PASTE-BATCH-FINAL",
        ].map { "--step \(Self.quote($0))" }.joined(separator: " ")
        _ = try await TestHelpers.runSimUseCommand("ios batch \(steps)", simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-BATCH-FINAL") == "SIMUSE-PASTE-BATCH-FINAL")
    }

    @Test("Replacement without Select All only accepts a confirmed empty field", arguments: [false, true])
    func replacementWithoutSelectAll(batch: Bool) async throws {
        let udid = try await setup()
        _ = try await TestHelpers.runSimUseCommand("tap --id paste-restrict-select-all", simulatorUDID: udid)
        _ = try await TestHelpers.runSimUseCommand("tap --id paste-input-field", simulatorUDID: udid)
        func command(_ payload: String) -> String {
            let step = "paste --replace \(payload)"
            return batch ? "ios batch --step \(Self.quote(step))" : step
        }
        _ = try await TestHelpers.runSimUseCommand(command("SIMUSE-PASTE-RESTRICTED-FIRST"), simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-RESTRICTED-FIRST") == "SIMUSE-PASTE-RESTRICTED-FIRST")
        let response = try await TestHelpers.runSimUseCommandAllowFailure(command("SIMUSE-PASTE-MUST-NOT-APPEND") + " --json", simulatorUDID: udid)
        #expect(response.exitCode != 0)
        #expect(response.output.contains("Cannot replace"))
        // The refused command leaves the native menu open, hiding the app's
        // AX fields. Dismiss outside every menu action before reading the value.
        struct MenuEnvelope: Decodable {
            struct Payload: Decodable { let raw: [AccessibilityElement] }
            let data: Payload
        }
        let snapshot = try await TestHelpers.runSimUseCommand("ui --json", simulatorUDID: udid)
        let roots = try JSONDecoder().decode(MenuEnvelope.self, from: Data(snapshot.output.utf8)).data.raw
        if let target = PasteEditMenu.dismissalTarget(in: roots) {
            _ = try await TestHelpers.runSimUseCommand("tap --x \(target.frame.midX) --y \(target.frame.midY) --duration 0.05", simulatorUDID: udid)
        } else {
            _ = try await TestHelpers.runSimUseCommand("ios key 41", simulatorUDID: udid)
        }
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-RESTRICTED-FIRST") == "SIMUSE-PASTE-RESTRICTED-FIRST")
    }

    @Test("An existing native menu preserves the range without activating an app Paste control")
    func existingMenuWithDecoy() async throws {
        let udid = try await setup(multiline: true)
        try await paste("SIMUSE-PASTE-AoldZ", udid: udid)
        try await selectSuffix(udid: udid)
        _ = try await TestHelpers.runSimUseCommand("ios key 101", simulatorUDID: udid)
        try await Task.sleep(for: .seconds(1))
        let before = try await TestHelpers.getUIState(simulatorUDID: udid)
        #expect(UIStateParser.findElement(in: before, matching: { $0.label == "Paste" }) != nil)
        _ = try await TestHelpers.runSimUseCommand("paste \(Self.quote("\n"))", simulatorUDID: udid)
        #expect(try await Self.settlePaste(udid: udid, expected: "SIMUSE-PASTE-A\nZ") == "SIMUSE-PASTE-A\nZ")
        let after = try await TestHelpers.getUIState(simulatorUDID: udid)
        #expect(UIStateParser.findElement(in: after, withIdentifier: "paste-decoy-button")?.value == "0")
    }

    @Test("No focus fails without tapping an app's same-label Paste button", arguments: [false, true])
    func noFocusedField(replace: Bool) async throws {
        let udid = try await setup()
        _ = try await TestHelpers.runSimUseCommand("tap --id paste-decoy-button", simulatorUDID: udid)
        let response = try await TestHelpers.runSimUseCommandAllowFailure("paste SIMUSE-PASTE-NO-FOCUS --json \(replace ? "--replace" : "")", simulatorUDID: udid)
        #expect(response.exitCode != 0)
        #expect(response.output.contains("\"ok\":false"))
        let ui = try await TestHelpers.getUIState(simulatorUDID: udid)
        #expect(UIStateParser.findElement(in: ui, withIdentifier: "paste-decoy-button")?.value == "1")
        #expect(UIStateParser.findElement(in: ui, withIdentifier: "paste-content-echo")?.value == "empty")
    }
}
