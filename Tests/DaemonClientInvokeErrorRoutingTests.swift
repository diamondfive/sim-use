// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
@testable import SimUseCore
import ArgumentParser
import Darwin
import Foundation
import Testing

// Coverage for `DaemonClient.invoke`'s error routing on the fast path
// (a daemon is already live):
//
//   1. A `remote` error (the daemon answered `ok=false`) is the
//      command's outcome. It must surface verbatim — the client must
//      NOT treat it as a stale daemon, must NOT remove the live
//      daemon's socket/pidfile, and must NOT respawn + re-execute the
//      command (double side effects, orphaned daemon).
//   2. `transient_booting` is the one documented exception: the client
//      retries the request once against the same daemon (post-`simctl
//      boot` accessibility-readiness gap), then gives up.
//
// Regression context: the fast-path catch used to swallow every
// classify error, delete the live daemon's files, spawn a fresh
// daemon, and re-send the request — observed live as a doubled tap
// search, a ~1.8s failure round trip, and an orphaned daemon process.

// MARK: - Fixtures

private func makeTempDirectory() throws -> URL {
    let suffix = String(UUID().uuidString.prefix(6))
    let dir = URL(fileURLWithPath: "/tmp/sim-use-er-\(suffix)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Shared mutable state driving the fake commands below. MainActor so
/// the daemon dispatch (MainActor) and the test body touch it safely.
@MainActor
private enum FakeCommandState {
    static var executeCount = 0
    static var failuresRemaining = 0
    static var failureMessage = ""

    static func reset(failures: Int, message: String) {
        executeCount = 0
        failuresRemaining = failures
        failureMessage = message
    }
}

/// Minimal daemon-dispatchable command: fails `failuresRemaining`
/// times with `failureMessage`, then succeeds.
private struct FakeFlakyCommand: SimUseExecutableCommand {
    struct Payload: Codable { var value: String }
    typealias ExecutionResult = Payload

    static let configuration = CommandConfiguration(commandName: "fake-flaky")

    var jsonOutput: Bool { false }

    func execute() async throws -> Payload {
        let failure: String? = await MainActor.run {
            FakeCommandState.executeCount += 1
            guard FakeCommandState.failuresRemaining > 0 else { return nil }
            FakeCommandState.failuresRemaining -= 1
            return FakeCommandState.failureMessage
        }
        if let failure {
            throw CLIError(errorDescription: failure)
        }
        return Payload(value: "ok")
    }

    func format(_ result: Payload) -> CommandOutput { .line(result.value) }
}

@MainActor
private enum FakePasteState {
    static var executions = 0
    static var actions: [String] = []
    static var failDuringSend = false
}

private struct FakePasteCompletionCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "fake-paste-completion")
    var jsonOutput: Bool { false }

    @MainActor
    func execute() async throws -> FakeFlakyCommand.Payload {
        FakePasteState.executions += 1
        try await PasteDelivery.perform(
            send: {
                FakePasteState.actions.append("Paste")
                if FakePasteState.failDuringSend {
                    throw CLIError(errorDescription: "No translation object returned for simulator fixture")
                }
            },
            waitForCompletion: {
                throw CLIError(errorDescription: "No translation object returned for simulator fixture")
            }
        )
        return .init(value: "ok")
    }

    func format(_ result: FakeFlakyCommand.Payload) -> CommandOutput { .line(result.value) }
}

@MainActor
private enum FakeBatchReplayState {
    static var executions = 0
    static var actions: [String] = []
    static var continueOnError = false
}

private struct FakeMultiStepBatchCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "fake-multi-step-batch")
    var jsonOutput: Bool { false }
    var daemonAllowsTransientRetry: Bool { IOSSimBatchCommand().daemonAllowsTransientRetry }

    @MainActor
    func execute() async throws -> FakeFlakyCommand.Payload {
        FakeBatchReplayState.executions += 1
        let failThisExecution = FakeBatchReplayState.executions == 1
        var failures: [String] = []
        do {
            try await PasteDelivery.perform(
                send: { FakeBatchReplayState.actions.append("first Paste") },
                waitForCompletion: {
                    if failThisExecution && FakeBatchReplayState.continueOnError {
                        throw CLIError(errorDescription: "No translation object returned for simulator fixture")
                    }
                }
            )
        } catch {
            guard FakeBatchReplayState.continueOnError else { throw error }
            failures.append("Step 1 failed: [paste] -> \(error.localizedDescription)")
        }
        if failThisExecution {
            let message = "No translation object returned for simulator fixture"
            if FakeBatchReplayState.continueOnError {
                failures.append("Step 2 failed: [paste] -> \(message)")
                throw CLIError(errorDescription: "Batch completed with \(failures.count) failure(s):\n\(failures.joined(separator: "\n"))")
            }
            throw CLIError(errorDescription: "Step 2 failed: [paste]\n\(message)")
        }
        try await PasteDelivery.perform(
            send: { FakeBatchReplayState.actions.append("second Paste") }, waitForCompletion: {}
        )
        return .init(value: "ok")
    }

    func format(_ result: FakeFlakyCommand.Payload) -> CommandOutput { .line(result.value) }
}

private struct FakeHintedFailure: LocalizedError, HintProviding {
    let errorDescription: String?
    var hint: String? { "fixture: inspect completed steps" }
}

private struct FakeRetryOptOutCommand: SimUseExecutableCommand {
    static let configuration = CommandConfiguration(commandName: "fake-retry-opt-out")
    var jsonOutput: Bool { false }
    var daemonAllowsTransientRetry: Bool { IOSSimBatchCommand().daemonAllowsTransientRetry }

    @MainActor
    func execute() async throws -> FakeFlakyCommand.Payload {
        throw FakeHintedFailure(errorDescription: FakeCommandState.failureMessage)
    }

    func format(_ result: FakeFlakyCommand.Payload) -> CommandOutput { .line(result.value) }
}

// MARK: - Suite

// Serialised for the same reason as `DaemonClientEnsureCompatibleDaemonTests`:
// concurrent DaemonServers in one process step on each other's signal
// handling, and the suite mutates the process-global
// `DaemonDispatch.commandParser`.
@Suite("DaemonClient.invoke error routing", .serialized)
@MainActor
struct DaemonClientInvokeErrorRoutingTests {

    private func startTestDaemon(
        udid: String,
        baseDirectory: URL
    ) async throws -> (DaemonPaths, Task<Void, Error>) {
        let paths = DaemonPaths(udid: udid, baseDirectory: baseDirectory)
        try paths.ensureBaseDirectory()
        let server = DaemonServer(udid: udid, idleTimeout: 30, paths: paths)
        let task = Task { try await server.run() }
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: paths.socketURL.path),
               paths.readPidfile() != nil {
                return (paths, task)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        throw TestError.daemonNeverReady
    }

    enum TestError: Error { case daemonNeverReady }

    // Delegates to the shared gate so this suite's parser window can't
    // overlap another suite's (they all mutate the process-global
    // `DaemonDispatch.commandParser` across `await`s).
    private func withParser(
        _ parser: ((@MainActor ([String]) throws -> ParsableCommand))?,
        body: () async throws -> Void
    ) async throws {
        try await withExclusiveCommandParser(parser, body: body)
    }

    private struct SuccessEnvelope: Decodable {
        let ok: Bool
        let data: FakeFlakyCommand.Payload
    }

    @Test("A partial send or post-Paste AX failure never replays the request", arguments: ["paste", "batch"], [false, true])
    func pasteCompletionDoesNotReplay(command: String, failDuringSend: Bool) async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }
        let udid = "TEST-PASTE-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }
        FakePasteState.executions = 0
        FakePasteState.actions = []
        FakePasteState.failDuringSend = failDuringSend
        try await withParser({ _ in FakePasteCompletionCommand() }) {
            do {
                _ = try await DaemonClient.invoke(
                    command: command, args: [], udid: udid,
                    baseDirectory: tmp, transientRetryDelay: 0.01
                )
                Issue.record("Paste completion failure must be reported")
            } catch let error as DaemonClientError {
                guard case .remote(let message, let kind, _) = error else {
                    Issue.record("expected remote error, got \(error)")
                    return
                }
                #expect(kind == .other)
                #expect(message.contains("Verify the field before retrying"))
                #expect(!message.contains("No translation object"))
            }
        }
        #expect(FakePasteState.executions == 1)
        #expect(FakePasteState.actions == ["Paste"])
        await DaemonClient.stopDaemon(paths: paths, timeout: 2)
        _ = try? await task.value
    }

    @Test("A later batch failure never replays a completed or ambiguous Paste", arguments: [false, true])
    func laterBatchFailureDoesNotReplay(continueOnError: Bool) async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }
        let udid = "TEST-BATCH-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }
        FakeBatchReplayState.executions = 0
        FakeBatchReplayState.actions = []
        FakeBatchReplayState.continueOnError = continueOnError
        try await withParser({ _ in FakeMultiStepBatchCommand() }) {
            do {
                _ = try await DaemonClient.invoke(
                    command: "batch", args: [], udid: udid,
                    baseDirectory: tmp, transientRetryDelay: 0.01
                )
                Issue.record("A failed batch must not succeed after replay")
            } catch let error as DaemonClientError {
                guard case .remote(let message, let kind, _) = error else {
                    Issue.record("expected remote error, got \(error)")
                    return
                }
                #expect(kind == .permanent)
                #expect(message.contains("No translation object returned for simulator"))
                #expect(message.contains("Step 2 failed"))
                if continueOnError {
                    #expect(message.contains("Batch completed with 2 failure(s)"))
                    #expect(message.contains("Verify the field before retrying"))
                }
            }
        }
        #expect(FakeBatchReplayState.executions == 1)
        #expect(FakeBatchReplayState.actions == ["first Paste"])
        await DaemonClient.stopDaemon(paths: paths, timeout: 2)
        _ = try? await task.value
    }

    @Test("Parsed iOS batches opt out of transient request replay")
    func batchRetryPolicy() throws {
        let command = try IOSSimBatchCommand.parse(["--step", "paste first", "--step", "paste second"])
        #expect(!command.daemonAllowsTransientRetry)
    }

    @Test("Retry opt-out preserves diagnostics, hints and stale cleanup", arguments: [
        "No translation object returned for simulator fixture",
        "Simulator with UDID fixture not found in set.",
    ])
    func optedOutFailureRouting(message: String) async throws {
        FakeCommandState.reset(failures: 1, message: message)
        try await withParser({ _ in FakeRetryOptOutCommand() }) {
            let outcome = await DaemonDispatch.handle(
                DaemonRequest(cmd: "batch", args: []),
                snapshot: .init(pid: getpid(), startTime: Date(), udid: "TEST-RETRY-POLICY", simUseVersion: "fixture")
            )
            struct Failure: Decodable {
                let kind: DaemonErrorKind
                let error: String
                let hint: String?
            }
            let failure = try JSONDecoder().decode(Failure.self, from: outcome.responseData)
            #expect(failure.error.contains(message))
            if message.contains("not found in set") {
                #expect(failure.kind == .staleSimulator)
                #expect(outcome.shouldStopDaemon)
            } else {
                #expect(failure.kind == .permanent)
                #expect(failure.hint == "fixture: inspect completed steps")
                #expect(!outcome.shouldStopDaemon)
            }
        }
    }

    @Test("Remote error surfaces verbatim without killing or respawning the live daemon")
    func remoteErrorDoesNotRespawn() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-REMOTE-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }
        let pidBefore = paths.readPidfile()

        FakeCommandState.reset(failures: .max, message: "fixture: element not found")

        try await withParser({ _ in FakeFlakyCommand() }) {
            do {
                _ = try await DaemonClient.invoke(
                    command: "fake-flaky",
                    args: [],
                    udid: udid,
                    baseDirectory: tmp
                )
                Issue.record("invoke should have thrown the remote error")
            } catch let error as DaemonClientError {
                guard case .remote(let message, let kind, _) = error else {
                    Issue.record("expected .remote, got \(error)")
                    return
                }
                #expect(message.contains("fixture: element not found"))
                #expect(kind == .other)
            }
        }

        // The daemon answered; it is healthy. Its files must survive
        // and the command must have executed exactly once.
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(paths.readPidfile() == pidBefore)
        #expect(FakeCommandState.executeCount == 1)

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("transient_booting is retried once against the same daemon, then succeeds")
    func transientBootingRetriesOnce() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-TRANSIENT-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }
        let pidBefore = paths.readPidfile()

        // Message shape matches DaemonErrorKind.classify's
        // transient_booting detection.
        FakeCommandState.reset(
            failures: 1,
            message: "Simulator is unavailable as it is not booted"
        )

        try await withParser({ _ in FakeFlakyCommand() }) {
            let responseData = try await DaemonClient.invoke(
                command: "fake-flaky",
                args: [],
                udid: udid,
                baseDirectory: tmp,
                transientRetryDelay: 0.05
            )
            let envelope = try JSONDecoder().decode(SuccessEnvelope.self, from: responseData)
            #expect(envelope.ok == true)
            #expect(envelope.data.value == "ok")
        }

        #expect(FakeCommandState.executeCount == 2)
        #expect(paths.readPidfile() == pidBefore)

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("Cancellation during the retry delay propagates without killing the daemon")
    func cancellationDuringRetryDelayPropagates() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-CANCEL-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }
        let pidBefore = paths.readPidfile()

        FakeCommandState.reset(
            failures: .max,
            message: "Simulator is unavailable as it is not booted"
        )

        // The closure handles every error itself (invoke runs in an
        // unstructured Task whose result is consumed by do/catch); the
        // `try` is for `withParser` acquiring the shared parser gate.
        try await withParser({ _ in FakeFlakyCommand() }) {
            // Long retry delay so the cancel lands inside the retry
            // sleep — the only suspension point on the fast path.
            let invokeTask = Task {
                try await DaemonClient.invoke(
                    command: "fake-flaky",
                    args: [],
                    udid: udid,
                    baseDirectory: tmp,
                    transientRetryDelay: 30
                )
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            invokeTask.cancel()

            do {
                _ = try await invokeTask.value
                Issue.record("invoke should have thrown CancellationError")
            } catch is CancellationError {
                // Expected: cancellation is the caller's signal, not a
                // stale daemon.
            } catch {
                Issue.record("expected CancellationError, got \(error)")
            }
        }

        // A cancelled call must not be misread as a stale daemon: no
        // file cleanup, no respawn, no re-execution.
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))
        #expect(paths.readPidfile() == pidBefore)
        #expect(FakeCommandState.executeCount == 1)

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("Non-finite retry delay is tolerated instead of trapping")
    func nonFiniteRetryDelayIsTolerated() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-INF-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }

        FakeCommandState.reset(
            failures: 1,
            message: "Simulator is unavailable as it is not booted"
        )

        // `transientRetryDelay` is public API: a non-finite value must
        // not trap in the nanosecond conversion. Semantics: skip the
        // pause and retry immediately.
        try await withParser({ _ in FakeFlakyCommand() }) {
            let responseData = try await DaemonClient.invoke(
                command: "fake-flaky",
                args: [],
                udid: udid,
                baseDirectory: tmp,
                transientRetryDelay: .infinity
            )
            let envelope = try JSONDecoder().decode(SuccessEnvelope.self, from: responseData)
            #expect(envelope.ok == true)
        }
        #expect(FakeCommandState.executeCount == 2)

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }

    @Test("transient_booting persisting past one retry propagates without further attempts")
    func transientBootingRetryIsBounded() async throws {
        let tmp = try makeTempDirectory()
        defer { removeTempDirectory(tmp) }

        let udid = "TEST-TRANSIENT2-\(UUID().uuidString.prefix(8))"
        let (paths, task) = try await startTestDaemon(udid: udid, baseDirectory: tmp)
        defer { task.cancel() }

        FakeCommandState.reset(
            failures: .max,
            message: "Simulator is unavailable as it is not booted"
        )

        try await withParser({ _ in FakeFlakyCommand() }) {
            do {
                _ = try await DaemonClient.invoke(
                    command: "fake-flaky",
                    args: [],
                    udid: udid,
                    baseDirectory: tmp,
                    transientRetryDelay: 0.05
                )
                Issue.record("invoke should have thrown after the bounded retry")
            } catch let error as DaemonClientError {
                guard case .remote(_, let kind, _) = error else {
                    Issue.record("expected .remote, got \(error)")
                    return
                }
                #expect(kind == .transientBooting)
            }
        }

        // Exactly one retry: original attempt + one re-send.
        #expect(FakeCommandState.executeCount == 2)
        // The daemon stays up — booting is the simulator's problem,
        // not the daemon's.
        #expect(FileManager.default.fileExists(atPath: paths.socketURL.path))

        await DaemonClient.stopDaemon(paths: paths, timeout: 2.0)
        _ = try? await task.value
    }
}
