// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Sends one DTX selector and resolves its reply. Kept abstract so the
/// selector layer can be exercised without a device attached.
public protocol DTXInvoking: Sendable {
    func invoke(_ selector: String, arguments: [AXAuditValue], expectsReply: Bool) async throws -> AXAuditValue
}

public extension DTXInvoking {
    func invoke(_ selector: String, _ arguments: AXAuditValue...) async throws -> AXAuditValue {
        try await invoke(selector, arguments: arguments, expectsReply: true)
    }

    func send(_ selector: String, _ arguments: AXAuditValue...) async throws {
        _ = try await invoke(selector, arguments: arguments, expectsReply: false)
    }
}

public enum AXAuditError: Error, LocalizedError, CustomStringConvertible {
    case noRootElement
    case hierarchyUnavailable
    case unsupportedSelector(String)
    case malformedReply(selector: String)

    public var errorDescription: String? { description }

    public var description: String {
        switch self {
        case .noRootElement:
            return "the foreground app exposed no root accessibility element — ensure the device is unlocked and the app is development-signed (get-task-allow=true)"
        case .hierarchyUnavailable:
            return "the foreground app exposed no accessibility hierarchy — ensure the device is unlocked and use a development-signed app with get-task-allow=true; distribution-signed and system apps are unsupported"
        case let .unsupportedSelector(selector):
            return "the device does not support '\(selector)'"
        case let .malformedReply(selector):
            return "the device did not answer '\(selector)' as expected — this is what a locked screen looks like; unlock it and try again"
        }
    }
}

/// Selector-level API for `com.apple.accessibility.axAuditDaemon.remoteserver`.
///
/// Reachable over plain usbmux lockdown: sim-use installs and signs no runner
/// and needs no Developer Disk Image. The foreground target app must itself be
/// development-signed (`get-task-allow=true`). Element geometry is unavailable
/// on this channel, so there is intentionally no frame accessor.
public struct AXAuditClient: Sendable {
    /// Extra reads after the immediate one. A launch race that is still null
    /// on the fifth read is the standing failure, not a longer outage.
    private static let transientRootRetries = 4
    /// Pause between null roots. Clamped to whatever the budget has left so
    /// the last wait cannot run past the deadline.
    private static let transientRootDelay: Duration = .milliseconds(500)
    /// Measured from the first attempt. Limits retry scheduling only — a
    /// slow `deviceFetchSpecialElement:` is never abandoned or cancelled.
    private static let transientRootBudget: Duration = .seconds(2)

    private let transport: any DTXInvoking

    public init(transport: any DTXInvoking) {
        self.transport = transport
    }

    /// Must run before anything else: without it the daemon answers element
    /// queries with nil even though the connection is healthy.
    public func prepare() async throws {
        try await transport.send("deviceInspectorEnable:", .bool(true))
        try await transport.send("deviceSetAppMonitoringEnabled:", .bool(true))
        try await transport.send("deviceInspectorShowVisuals:", .bool(false))
    }

    /// Releases the daemon's inspector state. Skipping this leaves the device
    /// wedged: later sessions connect and answer, but every element query comes
    /// back empty until something calls it. Abruptly dropping several sessions
    /// at once is enough to trigger that.
    public func finish() async {
        try? await transport.send("deviceInspectorEnable:", .bool(false))
        try? await transport.send("deviceSetAppMonitoringEnabled:", .bool(false))
        try? await transport.send("devicePerformFinalCleanup")
    }

    public func capabilities() async throws -> [String] {
        let reply = try await transport.invoke("deviceCapabilities")
        guard case let .list(values) = reply.unwrapped else {
            throw AXAuditError.malformedReply(selector: "deviceCapabilities")
        }
        return values.compactMap(\.stringValue)
    }

    public func apiVersion() async throws -> Int? {
        try await transport.invoke("deviceApiVersion").intValue
    }

    /// Foreground root (`deviceFetchSpecialElement: 0`).
    ///
    /// Right after launch a development-signed app can answer null and then,
    /// on this same connection, answer normally. A null reply is retried
    /// immediately and up to four more times, waiting 500 ms or the time left
    /// in a two-second budget measured from the first attempt, whichever is
    /// shorter. The attempt that was scheduled to land on the deadline still
    /// runs. A reply that itself arrives after the budget is spent does not
    /// start another read, and the in-flight read is not timed out. A present
    /// payload with no element token, a transport error, or cancellation
    /// returns immediately.
    public func rootElement() async throws -> AXAuditElement {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.transientRootBudget)
        var scheduledRetries = 0

        while true {
            try Task.checkCancellation()
            let reply = try await transport.invoke("deviceFetchSpecialElement:", .int(0))
            try Task.checkCancellation()

            if let element = AXAuditElement(payload: reply) {
                return element
            }
            // Only a null root is the launch race. Anything else that fails to
            // decode is the standing no-root failure.
            guard reply.unwrapped == .null else { throw AXAuditError.noRootElement }
            if scheduledRetries >= Self.transientRootRetries { throw AXAuditError.noRootElement }

            let remaining = deadline - clock.now
            // A slow reply can consume the whole budget. Do not start the
            // next read once the deadline has already passed.
            if remaining <= .zero { throw AXAuditError.noRootElement }
            scheduledRetries += 1
            try await clock.sleep(for: min(Self.transientRootDelay, remaining), tolerance: .zero)
        }
    }

    public func value(of attribute: AXAuditAttribute, for element: AXAuditElement) async throws -> AXAuditValue {
        try await transport.invoke("deviceElement:valueForAttribute:", element.encoded, attribute.encoded)
    }

    public func string(_ attribute: AXAuditAttribute, for element: AXAuditElement) async throws -> String? {
        try await value(of: attribute, for: element).stringValue
    }

    /// Direct children of `element`, already carrying their label and role so a
    /// tree walk needs one round trip per node rather than one per attribute.
    public func children(of element: AXAuditElement) async throws -> [AXAuditNode] {
        let reply = try await value(of: .hierarchy, for: element)
        return reply.descendants(taggedWith: "AXAuditNode_v1").compactMap { node in
            guard let child = node["AuditElementValue_v1"].flatMap(AXAuditElement.init(payload:)) else { return nil }
            return AXAuditNode(
                element: child,
                summary: node["HumanReadableDescriptionValue_v1"]?.stringValue ?? "",
                role: node["HumanReadableRoleDescriptionValue_v1"]?.stringValue ?? "",
                identifier: node["AuditElementValue_v1"]?["AccessibilityIdentifier_v1"]?.stringValue,
                isIgnored: node["IsIgnoredValue_v1"]?.boolValue ?? false
            )
        }
    }

    public func perform(_ action: AXAuditAttribute, on element: AXAuditElement) async throws {
        try await transport.send("deviceElement:performAction:withValue:", element.encoded, action.encoded, .int(0))
    }

    public func captureScreenshot() async throws -> DeviceScreenshot {
        let reply = try await transport.invoke("deviceCaptureScreenshot")
        guard let screenshot = DeviceScreenshot(payload: reply) else {
            throw AXAuditError.malformedReply(selector: "deviceCaptureScreenshot")
        }
        return screenshot
    }
}

/// A screenshot plus the display metadata the daemon returns alongside it —
/// the only geometry this channel offers.
public struct DeviceScreenshot: Sendable {
    public let pngData: Data
    public let nativeScale: Int?
    public let rotationRadians: Int?

    init?(payload: AXAuditValue) {
        guard let data = payload["imageData"]?.dataValue, data.starts(with: Self.pngMagic) else { return nil }
        pngData = data
        nativeScale = payload["displayNativeScale"]?.intValue
        rotationRadians = payload["rotationRadians"]?.intValue
    }

    private static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
}
