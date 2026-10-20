// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import iOSSimBackend
import SimUseCore
import Testing

@Suite("Readable Duo display names")
struct DisplayNamesTests {
    private let duo = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    private func display(
        id: UInt32 = 41, primary: Bool = true, active: Bool = false,
        name: String = "Renamed panel", kind: SimulatorDisplay.Kind = .integrated,
        uniqueID: String? = nil
    ) -> SimulatorDisplay {
        SimulatorDisplay(
            displayID: id, uniqueID: uniqueID ?? "panel-\(id)", name: name,
            kind: kind, isPrimary: primary, isActive: active,
            backlightState: "active", rotation: .rot0,
            pixelWidth: 1200, pixelHeight: 1800, pointScale: 3
        )
    }

    private func topology(_ displays: [SimulatorDisplay]) -> SimulatorDisplayTopology {
        SimulatorDisplayTopology(displays: displays, deviceOrientation: "portrait")
    }

    @Test("roles follow primary status, not raw names, ids or display order")
    func roleMapping() {
        let cover = display(active: true, name: "LCD-1")
        let inner = display(id: 87, primary: false, name: "LCD")
        let virtual = display(id: 99, primary: false, name: "Resizable", kind: .virtual)
        let names = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: topology([inner, virtual, cover]))
        #expect(names.label(for: cover) == "cover display")
        #expect(names.label(for: inner) == "inner display")
        #expect(names.label(for: virtual) == nil)
        #expect(names.headerTag(for: .main) == "cover display")
        #expect(names.headerTag(for: .secondary(inner)) == "inner display")
        #expect(names.label(for: display(id: 87, primary: false, name: "A different raw name")) == "inner display")
        #expect(names.label(for: display(id: 87, primary: false, kind: .virtual)) == nil)
        #expect(names.headerTag(for: .secondary(display(id: 88, primary: false))) == "display Renamed panel")
    }

    @Test("only a verified Duo model receives role aliases", arguments: [
        "com.apple.CoreSimulator.SimDeviceType.iPhone-17", "iPhone Duo", "unknown", "",
    ])
    func unknownModel(identifier: String) {
        let cover = display(active: true)
        let inner = display(id: 87, primary: false)
        let names = SimulatorDisplayNames(deviceTypeIdentifier: identifier, topology: topology([cover, inner]))
        #expect(names.label(for: inner) == nil)
        #expect(names.headerTag(for: .main) == nil)
        #expect(names.headerTag(for: .secondary(inner)) == "display Renamed panel")
    }

    @Test("unavailable and malformed layouts keep generic names")
    func malformedLayouts() {
        let cover = display(active: true)
        let inner = display(id: 87, primary: false)
        let layouts: [SimulatorDisplayTopology?] = [
            nil, topology([]), topology([cover]),
            topology([cover, inner, display(id: 88, primary: false)]),
            topology([cover, display(id: 87, primary: true)]),
            topology([display(primary: false, active: true), inner]),
            topology([cover, display(primary: false)]),
            topology([cover, display(id: 87, primary: false, uniqueID: cover.uniqueID)]),
            topology([cover, display(id: 87, primary: false, active: true)]),
            topology([cover, inner, display(id: 99, primary: true, kind: .virtual)]),
        ]
        for layout in layouts {
            let names = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: layout)
            #expect(names.label(for: cover) == nil)
            #expect(names.headerTag(for: .main) == nil)
            #expect(names.headerTag(for: .secondary(inner)) == "display Renamed panel")
        }
    }

    @Test("an unknown active screen does not imply an active cover")
    func missingActiveDisplay() {
        let cover = display()
        let inner = display(id: 87, primary: false)
        let layout = topology([cover, inner])
        let names = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: layout)
        #expect(names.headerTag(for: .main) == nil)
        let report = PostureReport(topology: layout, session: nil, deviceTypeIdentifier: duo)
        #expect(!report.summary.contains("cover display active"))
    }

    @Test("fold and rotate text names the observed screen without claiming hinge posture")
    func postureText() {
        let inner = display(id: 87, primary: false, active: true)
        let report = PostureReport(topology: topology([display(), inner]), session: nil, deviceTypeIdentifier: duo)
        #expect(report.summary == "inner display active; portrait")
        let fold = IOSSimFoldCommand.ExecutionResult(fold: nil, posture: report)
        #expect(IOSSimFoldCommand().format(fold).stdout == "Posture: inner display active; portrait\n")
        let outcome = PostureController.RotateOutcome(
            requested: "portrait", deviceOrientation: "portrait", orientation: "portrait", confirmed: true, posture: report
        )
        let rotate = IOSSimRotateCommand.ExecutionResult(rotate: outcome)
        #expect(IOSSimRotateCommand().format(rotate).stdout == "Rotated to portrait on inner display (device portrait).\n")
        let cover = PostureReport(
            topology: topology([display(active: true), display(id: 87, primary: false)]),
            session: nil, deviceTypeIdentifier: duo
        )
        #expect(cover.summary == "cover display active; portrait")
    }

    @Test("Resize Mode and single-screen headers keep their existing names")
    func unchangedHeaders() {
        let cover = display(active: true)
        let inner = display(id: 87, primary: false)
        let virtual = display(id: 99, primary: false, name: "Resizable", kind: .virtual)
        let names = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: topology([cover, inner, virtual]))
        let session = ResizableAppSession(
            displayUniqueID: virtual.uniqueID, displayName: virtual.name, preferredWidth: 560, preferredHeight: 874
        )
        #expect(names.headerTag(for: .resizable(session, virtual)) == "display Resizable 560x874")
        #expect(names.headerTag(for: .resizable(session, nil)) == "display Resizable 560x874")
        let single = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: topology([cover, virtual]))
        #expect(single.headerTag(for: .main) == nil)
    }

    @Test("outline headers name both Duo screens without changing raw routing data")
    func outlineHeaders() throws {
        let cover = display(active: true)
        let inner = display(id: 87, primary: false, name: "LCD-1")
        let names = SimulatorDisplayNames(deviceTypeIdentifier: duo, topology: topology([cover, inner]))
        let tree = try JSONDecoder().decode([AccessibilityElement].self, from: Data("""
        [{"type":"Application","AXLabel":"Fixture","frame":{"x":0,"y":0,"width":400,"height":600}}]
        """.utf8))
        let coverOutline = OutlineFormatter.render(tree: tree, displayTag: names.headerTag(for: .main))
        #expect(coverOutline.text.hasPrefix("App: Fixture  400x600  (cover display)\n"))
        let innerOutline = OutlineFormatter.render(
            tree: tree, orientationTag: "portrait-upside-down", displayTag: names.headerTag(for: .secondary(inner))
        )
        #expect(innerOutline.text.hasPrefix("App: Fixture  400x600  (portrait-upside-down, inner display)\n"))
        #expect(RoutingDisplay.secondary(inner).info?.name == "LCD-1")
        #expect(RoutingDisplay.main.info == nil)
    }

    @Test("the production daemon response encoder preserves labels for client-side formatting")
    @MainActor
    func daemonResponse() async throws {
        var command = DisplayNameEchoCommand()
        command.report = PostureReport(
            topology: topology([display(active: true), display(id: 87, primary: false)]),
            session: nil, deviceTypeIdentifier: duo
        )
        let data = try await command.executeAsDaemonResponse(id: "naming-test")
        struct Response: Decodable { let data: PostureReport }
        let response = try JSONDecoder().decode(Response.self, from: data)
        #expect(response.data.summary == "cover display active; portrait")
        let publicData = try JSONEncoder().encode(response.data)
        #expect(!String(decoding: publicData, as: UTF8.self).contains("_displayLabel"))
    }

    @Test("public JSON keeps the exact raw posture data; daemon round trips retain text names")
    func encodingBoundaries() throws {
        let layout = topology([display(), display(id: 87, primary: false, active: true, name: "LCD-1")])
        let report = PostureReport(topology: layout, session: nil, deviceTypeIdentifier: duo)
        let legacy = PostureReport(topology: layout, session: nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(report) == encoder.encode(legacy))

        encoder.userInfo[.simUseDaemonResponse] = true
        let response = try encoder.encode(IOSSimFoldCommand.ExecutionResult(fold: nil, posture: report))
        let decoded = try JSONDecoder().decode(IOSSimFoldCommand.ExecutionResult.self, from: response)
        #expect(decoded.posture.summary == "inner display active; portrait")
        #expect(decoded.posture.activeDisplay?.name == "LCD-1")
        #expect(decoded.posture.activeDisplay?.id == 87)
        encoder.userInfo = [:]
        #expect(try encoder.encode(decoded.posture) == encoder.encode(legacy))

        let outcome = PostureController.RotateOutcome(
            requested: "portrait", deviceOrientation: "portrait", orientation: "portrait", confirmed: true, posture: report
        )
        encoder.userInfo[.simUseDaemonResponse] = true
        let rotation = try encoder.encode(IOSSimRotateCommand.ExecutionResult(rotate: outcome))
        let decodedRotation = try JSONDecoder().decode(IOSSimRotateCommand.ExecutionResult.self, from: rotation)
        #expect(IOSSimRotateCommand().format(decodedRotation).stdout.contains("on inner display"))
        let legacyDecoded = try JSONDecoder().decode(PostureReport.self, from: encoder.encode(legacy))
        #expect(legacyDecoded.summary == legacy.summary)
    }
}

private struct DisplayNameEchoCommand: SimUseExecutableCommand {
    var report: PostureReport?
    var jsonOutput: Bool { false }

    init() {}

    func execute() async throws -> PostureReport {
        try #require(report)
    }

    func format(_ result: PostureReport) -> CommandOutput {
        .line(result.summary)
    }
}
