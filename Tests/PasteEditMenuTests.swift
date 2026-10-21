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

    @Test("Empty identifiers do not make unrelated controls identical")
    func emptyIdentifiersUseGeometry() throws {
        let baseline = PasteEditMenu.items(in: [try element("Paste", id: "", x: 20)])
        let roots = [try element("Paste", type: "MenuItem", id: "", x: 100)]
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: baseline)?.frame.minX == 100)
    }

    @Test("Disabled, empty and non-menu roles cannot be tapped")
    func excludesInvalidTargets() throws {
        for target in [try element("Paste", type: "MenuItem", enabled: false), try element("Paste", type: "MenuItem", width: 0), try element("Paste", type: "TextField")] {
            #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: [target], excluding: []) == nil)
        }
    }

    @Test("Localized menu items work", arguments: ["Paste", "粘贴", "ペースト", "Coller", "Вставить", "Colar"])
    func localization(label: String) throws {
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: [try element(label, type: "MenuItem")], excluding: [])?.label == label)
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

    @Test("App controls outside a native menu are not menu actions", arguments: ["Paste", "Copy"])
    func nativeMenuExcludesAppControls(nativeLabel: String) throws {
        let menu = try JSONDecoder().decode(AccessibilityElement.self, from: Data("""
        {"type":"Menu","children":[{"type":"MenuItem","AXLabel":"\(nativeLabel)","frame":{"x":100,"y":200,"width":70,"height":40}}]}
        """.utf8))
        let roots = [try element("Paste", id: "app-paste-button"), menu]
        let match = PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: [])
        if nativeLabel == "Paste" {
            #expect(match?.frame.minX == 100)
            #expect(match?.identifier == nil)
        } else {
            #expect(match == nil)
        }
    }

    @Test("Modal menu action groups exclude app controls and refuse ambiguous groups", arguments: ["Paste", "Copy", "Copiar", "Скопировать"])
    func modalMenuExcludesAppControls(nativeLabel: String) throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Button","AXLabel":"Paste","AXUniqueId":"app-paste-button","frame":{"x":20,"y":60,"width":70,"height":40}},
          {"type":"Group","children":[{"type":"Button","AXLabel":"\(nativeLabel)","frame":{"x":100,"y":200,"width":70,"height":40}}]},
          {"type":"Button","AXLabel":"Dismiss context menu","frame":{"x":0,"y":0,"width":400,"height":800}}
        ]}]
        """.utf8))
        let match = PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: [])
        #expect(PasteEditMenu.isPresented(in: roots))
        if nativeLabel == "Paste" {
            #expect(match?.frame.minX == 100)
        } else {
            #expect(match == nil)
        }
        let app = try JSONDecoder().decode(AccessibilityElement.self, from: Data("""
        {"type":"Group","children":[{"type":"Button","AXLabel":"Paste","frame":{"x":20,"y":60,"width":70,"height":40}}]}
        """.utf8))
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots + [app], excluding: []) == nil)
        #expect(PasteEditMenu.dismissalTarget(in: roots + [app]) == nil)
    }

    @Test("A full-screen app button is not a menu during replacement or retargeting preparation", arguments: [false, true])
    @MainActor
    func ordinaryFullScreenButtonDoesNotDismiss(groupedCaption: Bool) async throws {
        let caption = """
        {"type":"TextField","AXUniqueId":"caption","AXValue":"Existing caption","traits":["TextEntry","IsEditing"],"frame":{"x":40,"y":100,"width":300,"height":40}}
        """
        let field = groupedCaption ? "{\"type\":\"Group\",\"children\":[\(caption)]}" : caption
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Button","AXLabel":"Preview","frame":{"x":0,"y":0,"width":400,"height":800}},
          \(field)
        ]}]
        """.utf8))
        #expect(!PasteEditMenu.isPresented(in: roots))
        #expect(PasteEditMenu.dismissalTarget(in: roots) == nil)
        var instant = ContinuousClock.now
        var dismissalCount = 0
        let prepared = try? await PasteEditMenu.prepare(
            fetch: { roots }, dismiss: { _ in dismissalCount += 1 }, timeout: 1,
            now: { instant }, sleep: { instant = instant.advanced(by: .milliseconds(120)) }
        )
        #expect(dismissalCount == 0)
        #expect(prepared?.count == roots.count)
    }

    @Test("Ordinary editor Copy and Paste groups stay in the app baseline without dismissal", arguments: ["Copy", "Paste"])
    @MainActor
    func ordinaryEditingToolbarIsNotMenu(label: String) async throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Button","AXLabel":"Preview","frame":{"x":0,"y":0,"width":400,"height":800}},
          {"type":"TextField","AXValue":"Existing caption","traits":["TextEntry","IsEditing"],"frame":{"x":40,"y":100,"width":300,"height":40}},
          {"type":"Group","children":[{"type":"Button","AXLabel":"\(label)","frame":{"x":290,"y":60,"width":70,"height":40}}]}
        ]}]
        """.utf8))
        let existingMenu = PasteEditMenu.isPresented(in: roots)
        let existingActions = existingMenu ? PasteEditMenu.actionItems(in: roots, excluding: []) : []
        let baseline = PasteEditMenu.items(in: roots).filter { !existingActions.contains($0) }
        #expect(!existingMenu)
        #expect(baseline == PasteEditMenu.items(in: roots))
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: baseline) == nil)
        #expect(PasteEditMenu.actionItems(in: roots, excluding: []).isEmpty)
        #expect(PasteEditMenu.dismissalTarget(in: roots) == nil)
        var instant = ContinuousClock.now
        var dismissalCount = 0
        let prepared = try? await PasteEditMenu.prepare(
            fetch: { roots }, dismiss: { _ in dismissalCount += 1 }, timeout: 1,
            now: { instant }, sleep: { instant = instant.advanced(by: .milliseconds(120)) }
        )
        #expect(dismissalCount == 0)
        #expect(prepared?.count == roots.count)
    }

    @Test("A newly visible unscoped app Paste button is not a native action")
    func unscopedAppActionIsRefused() throws {
        #expect(PasteEditMenu.actionItems(in: [try element("Paste")], excluding: []).isEmpty)
    }

    @Test("A generic app group or non-action editing label does not establish a native menu", arguments: ["Button", "StaticText"])
    func unrelatedActionGroupIsNotMenu(type: String) throws {
        let label = type == "Button" ? "Save caption" : "Copy"
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Button","AXLabel":"Preview","frame":{"x":0,"y":0,"width":400,"height":800}},
          {"type":"Group","children":[{"type":"\(type)","AXLabel":"\(label)","frame":{"x":40,"y":600,"width":300,"height":40}}]}
        ]}]
        """.utf8))
        #expect(!PasteEditMenu.isPresented(in: roots))
        #expect(PasteEditMenu.dismissalTarget(in: roots) == nil)
    }

    @Test("Unverified or ambiguous modal trees refuse before any dismissal", arguments: [
        "unknown-backdrop", "cross-container", "editor-conflict", "multiple-groups", "multiple-containers",
    ])
    @MainActor
    func unverifiedModalRefusesGestures(scenario: String) async throws {
        let group = """
        {"type":"Group","children":[{"type":"Button","AXLabel":"Paste","frame":{"x":100,"y":200,"width":70,"height":40}}]}
        """
        let label = scenario == "unknown-backdrop" ? "Unknown dismissal" : "Dismiss context menu"
        let backdrop = """
        {"type":"Button","AXLabel":"\(label)","frame":{"x":0,"y":0,"width":400,"height":800}}
        """
        let editor = """
        {"type":"TextField","traits":["TextEntry","IsEditing"],"frame":{"x":40,"y":100,"width":300,"height":40}}
        """
        func container(_ children: String, type: String = "Application") -> String {
            """
            {"type":"\(type)","frame":{"x":0,"y":0,"width":400,"height":800},"children":[\(children)]}
            """
        }
        let json: String
        switch scenario {
        case "cross-container": json = "[\(container(backdrop)),\(container(group, type: "Window"))]"
        case "editor-conflict": json = "[\(container("\(group),\(backdrop),\(editor)"))]"
        case "multiple-groups": json = "[\(container("\(group),\(group),\(backdrop)"))]"
        case "multiple-containers": json = "[\(container("\(group),\(backdrop)")),\(container("\(group),\(backdrop)"))]"
        default: json = "[\(container("\(group),\(backdrop)"))]"
        }
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data(json.utf8))
        #expect(throws: (any Error).self) { try PasteEditMenu.validatePresentation(in: roots) }
        #expect(PasteEditMenu.actionItems(in: roots, excluding: []).isEmpty)
        #expect(PasteEditMenu.dismissalTarget(in: roots) == nil)
        var dismissalCount = 0
        await #expect(throws: (any Error).self) {
            try await PasteEditMenu.prepare(fetch: { roots }, dismiss: { _ in dismissalCount += 1 }, timeout: 1)
        }
        #expect(dismissalCount == 0)
    }

    @Test("Localized native dismissal controls preserve Copy-only menus", arguments: [
        "Dismiss context menu", "Fechar menu contextual", "Закрыть контекстное меню",
        "コンテクストメニューを閉じる", "关闭关联菜单", "關閉特色選單",
        "Kontextmenü schließen", "Fermer le menu contextuel", "빠른 메뉴 닫기",
    ])
    func localizedModalDismissal(label: String) throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Group","children":[{"type":"Button","AXLabel":"Copy","frame":{"x":100,"y":200,"width":70,"height":40}}]},
          {"type":"Button","AXLabel":"\(label)","frame":{"x":0,"y":0,"width":400,"height":800}}
        ]}]
        """.utf8))
        try PasteEditMenu.validatePresentation(in: roots)
        #expect(PasteEditMenu.isPresented(in: roots))
        #expect(PasteEditMenu.dismissalTarget(in: roots) != nil)
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: []) == nil)
    }

    @Test("A modal dismissal point must not hit a menu action")
    func dismissalAvoidsMenuActions() throws {
        let roots = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","frame":{"x":0,"y":0,"width":400,"height":800},"children":[
          {"type":"Group","children":[
            {"type":"Button","AXLabel":"Paste","frame":{"x":250,"y":150,"width":80,"height":40}},
            {"type":"Button","AXLabel":"Search Web","AXUniqueId":"dd-search-web","frame":{"x":100,"y":380,"width":200,"height":40}}
          ]},
          {"type":"Button","AXLabel":"Dismiss context menu","frame":{"x":0,"y":0,"width":400,"height":800}}
        ]}]
        """.utf8))
        let target = try #require(PasteEditMenu.dismissalTarget(in: roots))
        #expect(target.frame.midX == 8)
        #expect(target.frame.midY == 400)
        #expect(PasteEditMenu.item(labels: PasteEditMenu.pasteLabels, in: roots, excluding: []) != nil)
        #expect(PasteEditMenu.dismissalTarget(in: [try element("Paste")]) == nil)
    }

    @Test("Replacement captures an app baseline after the existing menu closes")
    @MainActor
    func existingMenuIsDismissed() async throws {
        var dismissed = false
        var instant = ContinuousClock.now
        let menu = [try element("Paste", type: "MenuItem")]
        let app = [try element("Paste", id: "app-paste-button")]
        let roots = try await PasteEditMenu.prepare(
            fetch: { dismissed ? app : menu },
            dismiss: { _ in dismissed = true }, timeout: 1,
            now: { instant }, sleep: { instant = instant.advanced(by: .milliseconds(120)) }
        )
        #expect(dismissed)
        #expect(PasteEditMenu.items(in: roots).first?.identifier == "app-paste-button")
    }

    @Test("A menu that cannot be dismissed is refused before Paste")
    @MainActor
    func persistentMenuIsRefused() async throws {
        let menu = [try element("Paste", type: "MenuItem")]
        var instant = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await PasteEditMenu.prepare(
                fetch: { menu }, dismiss: { _ in }, timeout: 0.01,
                now: { instant }, sleep: { instant = instant.advanced(by: .milliseconds(120)) }
            )
        }
    }

    @Test("Replacement without Select All requires positive empty-field evidence")
    func missingSelectAllIsRefused() throws {
        #expect(throws: (any Error).self) {
            try PasteEditMenu.validateReplacement(selectAll: nil, emptyTargetConfirmed: false)
        }
        try PasteEditMenu.validateReplacement(selectAll: nil, emptyTargetConfirmed: true)
        try PasteEditMenu.validateReplacement(
            selectAll: PasteEditMenu.Item(label: "Select All", frame: .zero), emptyTargetConfirmed: false
        )
    }

    @Test("Only an explicit empty value on one editing text control proves emptiness")
    func emptyEditingTarget() throws {
        func field(value: String = "\"\"", type: String = "TextField", traits: String = "[\"TextEntry\",\"IsEditing\"]") throws -> AccessibilityElement {
            try JSONDecoder().decode(AccessibilityElement.self, from: Data("""
            {"type":"\(type)","AXValue":\(value),"traits":\(traits)}
            """.utf8))
        }
        #expect(PasteEditMenu.emptyEditingTargetConfirmed(in: [try field()]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: []))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(value: "null")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(value: "\"existing\"")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(value: "\" \"")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(type: "SecureTextField")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(traits: "[\"TextEntry\",\"IsEditing\",\"SecureTextField\"]")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(traits: "[]")]))
        #expect(!PasteEditMenu.emptyEditingTargetConfirmed(in: [try field(), try field()]))
    }

    @Test("Native Select All translations include Japanese, German, Russian and Portuguese",
          arguments: ["すべてを選択", "Alles", "Выбрать все", "Selecionar Tudo", "Selecionar tudo"])
    func selectAllLocalization(label: String) throws {
        #expect(PasteEditMenu.item(labels: PasteEditMenu.selectAllLabels, in: [try element(label, type: "MenuItem")], excluding: [])?.label == label)
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
