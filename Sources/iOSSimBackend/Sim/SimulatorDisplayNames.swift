// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Presentation aliases only. Addressing and structured output keep the
/// original CoreDevice names and ids.
/// Work record: docs/ai/010-display-routing/003-readable-display-names.md.
struct SimulatorDisplayNames {
    static let duoDeviceTypeIdentifier = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"

    private let displays: [SimulatorDisplay]

    init(deviceTypeIdentifier: String?, topology: SimulatorDisplayTopology?) {
        let integrated = topology?.integratedDisplays ?? []
        guard deviceTypeIdentifier == Self.duoDeviceTypeIdentifier,
              integrated.count == 2,
              integrated.filter(\.isPrimary).count == 1,
              topology?.displays.filter(\.isPrimary).count == 1,
              integrated.filter(\.isActive).count <= 1,
              Set(integrated.map(\.displayID)).count == 2,
              Set(integrated.map { $0.uniqueID.lowercased() }).count == 2
        else {
            displays = []
            return
        }
        displays = integrated
    }

    func label(for display: SimulatorDisplay) -> String? {
        guard display.kind == .integrated, displays.contains(where: {
            $0.displayID == display.displayID &&
                $0.uniqueID.caseInsensitiveCompare(display.uniqueID) == .orderedSame &&
                $0.isPrimary == display.isPrimary
        }) else { return nil }
        return display.isPrimary ? "cover display" : "inner display"
    }

    func headerTag(for routing: RoutingDisplay) -> String? {
        switch routing {
        case .main:
            guard let active = displays.first(where: \.isActive), active.isPrimary else { return nil }
            return label(for: active)
        case .secondary(let display):
            return label(for: display) ?? routing.headerTag
        case .resizable:
            return routing.headerTag
        }
    }
}
