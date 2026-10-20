// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import iOSSimBackend

@Suite("Paste edit-menu matching")
struct PasteEditMenuTests {
    private func element(_ label: String, type: String = "Button", enabled: Bool = true, width: Double = 70, id: String? = nil, x: Double = 20) throws -> AccessibilityElement {
        let identifier = id.map { "\"\($0)\"" } ?? "null"
        return try JSONDecoder().decode(AccessibilityElement.self, from: Data("""
        {"type":"\(type)","AXLabel":"\(label)","AXUniqueId":\(identifier),"enabled":\(enabled),"frame":{"x":\(x),"y":100,"width":\(width),"height":40}}
        """.utf8))
    }

    @Test("An existing app Paste control is not a new menu item")
    func excludesAppControl() throws {
        let roots = [try element("Paste")]
        let baseline = PasteEditMenu.items(in: roots)
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: baseline) == nil)
        #expect(!PasteEditMenu.isPresented(in: roots))
    }

    @Test("An app's identified Paste control remains excluded after layout changes")
    func excludesMovedAppControl() throws {
        let baseline = PasteEditMenu.items(in: [try element("Paste", id: "app-paste")])
        let moved = [try element("Paste", id: "app-paste", x: 90)]
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: moved, excluding: baseline) == nil)
    }

    @Test("Disabled, empty and non-menu roles cannot be tapped")
    func excludesInvalidTargets() throws {
        for target in [try element("Paste", enabled: false), try element("Paste", width: 0), try element("Paste", type: "TextField")] {
            #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: [target], excluding: []) == nil)
        }
    }

    @Test("Localized menu items work", arguments: ["Paste", "粘贴", "ペースト", "Coller"])
    func localization(label: String) throws {
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: [try element(label)], excluding: [])?.label == label)
    }

    @Test("Visible AX items must remain stable for the interaction window")
    func readinessWindow() {
        let start = ContinuousClock.now
        let paste = PasteEditMenu.Item(label: "Paste", frame: CGRect(x: 20, y: 100, width: 70, height: 40))
        var readiness = PasteEditMenu.Readiness()
        func observe(_ items: [PasteEditMenu.Item], after duration: Duration) -> Bool {
            readiness.observe(items, at: start.advanced(by: duration), selectAllMustDisappear: false)
        }
        #expect(!observe([paste], after: .zero))
        #expect(!observe([paste], after: .milliseconds(999)))
        #expect(observe([paste], after: .seconds(1)))
        #expect(!observe([], after: .seconds(2)))
        #expect(!observe([paste], after: .seconds(3)))
        let moved = PasteEditMenu.Item(label: "Paste", frame: paste.frame.offsetBy(dx: 20, dy: 0))
        #expect(!observe([moved], after: .seconds(4)))
        #expect(observe([moved], after: .seconds(5)))
    }

    @Test("The old Select All menu is not a ready replacement menu")
    func replacementReadiness() {
        let start = ContinuousClock.now
        let paste = PasteEditMenu.Item(label: "Paste", frame: CGRect(x: 20, y: 100, width: 70, height: 40))
        let all = PasteEditMenu.Item(label: "Select All", frame: paste.frame.offsetBy(dx: 70, dy: 0))
        var readiness = PasteEditMenu.Readiness()
        func observe(_ items: [PasteEditMenu.Item], after duration: Duration) -> Bool {
            readiness.observe(items, at: start.advanced(by: duration), selectAllMustDisappear: true)
        }
        #expect(!observe([paste, all], after: .zero))
        #expect(!observe([paste, all], after: .seconds(2)))
        #expect(!observe([paste], after: .seconds(3)))
        #expect(observe([paste], after: .seconds(4)))
    }

    @Test("Native MenuItem roles identify a menu already on screen")
    func existingMenu() throws {
        #expect(PasteEditMenu.isPresented(in: [try element("Paste", type: "MenuItem")]))
    }
}

@Suite("Paste duration validation")
@MainActor
struct PasteDurationValidationTests {
    @Test("Invalid waits are rejected before any clipboard or HID action", arguments: [-1.0, 0.0, Double.nan, Double.infinity, Double.greatestFiniteMagnitude])
    func invalidWait(value: Double) {
        #expect(throws: (any Error).self) {
            try IOSSimPasteCommand.validateOptions(text: "text", useStdin: false, inputFile: nil, viaMenu: true,
                targetID: "field", targetX: nil, targetY: nil, longPressDuration: value)
        }
        #expect(throws: (any Error).self) {
            try IOSSimPasteCommand.validateOptions(text: "text", useStdin: false, inputFile: nil, viaMenu: false,
                targetID: nil, targetX: nil, targetY: nil, menuTimeout: value)
        }
    }
}

@Suite("Host-wide pasteboard lock")
struct PasteboardLockTests {
    @Test("A second lease waits, times out, and succeeds after release")
    func serialization() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var first: PasteboardLock? = try await PasteboardLock.acquire(directory: directory)
        await #expect(throws: (any Error).self) {
            try await PasteboardLock.acquire(directory: directory, timeout: 0.05)
        }
        withExtendedLifetime(first) {}
        first = nil
        let second = try await PasteboardLock.acquire(directory: directory, timeout: 0.05)
        withExtendedLifetime(second) {}
    }

    @Test("A symlink is refused without touching its target")
    func rejectsSymlink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("paste-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("pasteboard.lock"), withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await PasteboardLock.acquire(directory: directory) }
        #expect(try Data(contentsOf: target) == Data("preserve".utf8))
    }
}
