// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Verified staging for both classic Simulator and CoreDevice-owned clipboards.
/// Work record: docs/ai/011-device-hub-paste/001-implementation-plan.md.
struct SimulatorPasteboard: Sendable {
    enum Backend: String, Sendable {
        case simctl, coreDevice

        func arguments(write: Bool, udid: String) -> [String] {
            switch self {
            case .simctl:
                ["simctl", write ? "pbcopy" : "pbpaste", udid]
            case .coreDevice:
                ["devicectl", "device", "pasteboard", write ? "copy" : "paste",
                 "--device", udid, "--timeout", "8", "--quiet"]
            }
        }
    }

    typealias Runner = @Sendable ([String], Data?, Int) async throws -> PasteboardProcess.Output
    private let run: Runner

    init(run: @escaping Runner = { arguments, input, limit in
        try await PasteboardProcess.run(arguments: arguments, input: input, outputLimit: limit)
    }) {
        self.run = run
    }

    func write(text: String, udid: String) async throws -> Backend {
        // Old tools need no CoreDevice capability or version probe. A successful
        // exit alone is not evidence: Hub can discard simctl's snapshot.
        do {
            try await stage(text: text, udid: udid, backend: .simctl)
            return .simctl
        } catch is CancellationError {
            throw CancellationError()
        } catch PasteboardProcess.Failure.timeout {
            throw PasteboardProcess.Failure.timeout
        } catch {
            try await stage(text: text, udid: udid, backend: .coreDevice)
            return .coreDevice
        }
    }

    private func stage(text: String, udid: String, backend: Backend) async throws {
        let bytes = Data(text.utf8)
        let output = try await run(backend.arguments(write: true, udid: udid), bytes, max(65_536, bytes.count + 4096))
        guard output.status == 0 else {
            throw CLIError(errorDescription: "\(backend.rawValue) pasteboard copy failed (exit \(output.status)). No paste action was sent.")
        }
        try await verify(text: text, udid: udid, backend: backend)
    }

    func verify(text: String, udid: String, backend: Backend) async throws {
        let bytes = Data(text.utf8)
        if backend == .simctl {
            // simctl can echo its cached snapshot even when the guest rejects
            // that snapshot. Only inactive CoreDevice ownership permits the
            // legacy readback to establish delivery to the guest pasteboard.
            let key = "com.apple.coredevice.pasteboard.active"
            let ownership = try await run(["simctl", "spawn", udid, "notifyutil", "-g", key], nil, 65_536)
            let fields = String(data: ownership.stdout, encoding: .utf8)?.split(whereSeparator: \.isWhitespace).map(String.init)
            guard ownership.status == 0, fields == [key, "0"] else {
                throw CLIError(errorDescription: "Legacy pasteboard ownership is not confirmed. CoreDevice staging is required.")
            }
        }
        let output = try await run(backend.arguments(write: false, udid: udid), nil, max(65_536, bytes.count + 4096))
        guard output.status == 0 else {
            throw CLIError(errorDescription: "\(backend.rawValue) pasteboard readback failed (exit \(output.status)). No paste action was sent.")
        }
        guard output.stdout == bytes else {
            // stdout can be unrelated private host text. Neither stream belongs
            // in an error or log, even when the mismatch is useful evidence.
            throw CLIError(errorDescription: "Simulator pasteboard readback did not match the requested UTF-8 bytes. The clipboard may have changed in another app or device. No paste action was sent.")
        }
    }
}
