// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import Testing
@testable import iOSSimBackend

@Suite("Verified simulator pasteboard")
struct SimulatorPasteboardTests {
    private let text = "SIMUSE-PASTE-日本語 👩‍🍳 e\u{0308}\r\n\t"

    @Test("A verified legacy write needs no CoreDevice command")
    func legacy() async throws {
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(Data(text.utf8))])
        let board = SimulatorPasteboard(run: runner.run)
        let backend = try await board.write(text: text, udid: "target")
        #expect(backend == .simctl)
        #expect(await runner.arguments == [
            ["simctl", "pbcopy", "target"],
            ["simctl", "spawn", "target", "notifyutil", "-g", "com.apple.coredevice.pasteboard.active"],
            ["simctl", "pbpaste", "target"],
        ])
        #expect(await runner.inputs.first == Data(text.utf8))
    }

    @Test("A stale legacy read switches to verified CoreDevice")
    func staleLegacy() async throws {
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(Data("private host text".utf8)), .ok(), .ok(Data(text.utf8))])
        let board = SimulatorPasteboard(run: runner.run)
        #expect(try await board.write(text: text, udid: "target") == .coreDevice)
        let arguments = await runner.arguments
        #expect(arguments[3] == ["devicectl", "device", "pasteboard", "copy", "--device", "target", "--timeout", "8", "--quiet"])
        #expect(arguments[4][3] == "paste")
    }

    @Test("A failed legacy operation can use CoreDevice", arguments: [true, false])
    func failedLegacy(copyFails: Bool) async throws {
        let outputs: [PasteboardProcess.Output] = copyFails
            ? [.init(status: 1, stdout: Data(), stderr: Data()), .ok(), .ok(Data(text.utf8))]
            : [.ok(), .init(status: 1, stdout: Data(), stderr: Data()), .ok(), .ok(Data(text.utf8))]
        let runner = PasteboardRunnerStub(outputs: outputs)
        #expect(try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target") == .coreDevice)
    }

    @Test("Mismatched CoreDevice bytes fail without exposing clipboard contents")
    func mismatchIsPrivate() async throws {
        let secret = "PRIVATE-HOST-CONTENT"
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(), .ok(), .ok(Data(secret.utf8))])
        do {
            _ = try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target")
            Issue.record("stale clipboard must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("readback"))
            #expect(!error.localizedDescription.contains(secret))
        }
    }

    @Test("A CoreDevice copy error stops before readback")
    func copyFailure() async throws {
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(), .init(status: 7, stdout: Data(), stderr: Data("private diagnostic".utf8))])
        await #expect(throws: (any Error).self) {
            try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target")
        }
        #expect(await runner.arguments.count == 4)
    }

    @Test("A CoreDevice read error is final and does not leak diagnostics")
    func coreReadFailure() async throws {
        let diagnostic = "PRIVATE-READ-DIAGNOSTIC"
        let runner = PasteboardRunnerStub(outputs: [.init(status: 1, stdout: Data(), stderr: Data()), .ok(), .init(status: 9, stdout: Data(), stderr: Data(diagnostic.utf8))])
        do {
            _ = try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target")
            Issue.record("read failure must reject staging")
        } catch {
            #expect(error.localizedDescription.contains("readback"))
            #expect(!error.localizedDescription.contains(diagnostic))
        }
        #expect(await runner.arguments.count == 3)
    }

    @Test("Readback preserves final newlines and Unicode byte sequences")
    func byteEquality() async throws {
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(Data(text.dropLast().utf8)), .ok(), .ok(Data(text.utf8))])
        #expect(try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target") == .coreDevice)
    }

    @Test("Active or unknown ownership cannot trust a legacy cache", arguments: ["1", "unknown"])
    func ownership(state: String) async throws {
        let probe = PasteboardProcess.Output.ok(Data("com.apple.coredevice.pasteboard.active \(state)\n".utf8))
        let runner = PasteboardRunnerStub(outputs: [.ok(), .ok(), .ok(Data(text.utf8))], ownership: probe)
        #expect(try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target") == .coreDevice)
        #expect(await !runner.arguments.contains(["simctl", "pbpaste", "target"]))
    }

    @Test("A process timeout is final, not a fallback retry")
    func timeoutIsFinal() async throws {
        let runner = PasteboardRunnerStub(outputs: [], failure: .timeout)
        await #expect(throws: PasteboardProcess.Failure.self) {
            try await SimulatorPasteboard(run: runner.run).write(text: text, udid: "target")
        }
        #expect(await runner.arguments.count == 1)
    }

    @Test("A changed clipboard is rejected before delivery")
    func revalidation() async throws {
        let runner = PasteboardRunnerStub(outputs: [.ok(Data("changed".utf8))])
        await #expect(throws: (any Error).self) {
            try await SimulatorPasteboard(run: runner.run).verify(text: text, udid: "target", backend: .simctl)
        }
    }
}

private actor PasteboardRunnerStub {
    var outputs: [PasteboardProcess.Output]
    let ownership: PasteboardProcess.Output
    let failure: PasteboardProcess.Failure?
    var arguments: [[String]] = []
    var inputs: [Data?] = []

    init(outputs: [PasteboardProcess.Output],
         ownership: PasteboardProcess.Output = .ok(Data("com.apple.coredevice.pasteboard.active 0\n".utf8)),
         failure: PasteboardProcess.Failure? = nil) {
        self.outputs = outputs
        self.ownership = ownership
        self.failure = failure
    }

    nonisolated var run: SimulatorPasteboard.Runner {
        { arguments, input, _ in try await self.record(arguments, input) }
    }

    private func record(_ arguments: [String], _ input: Data?) throws -> PasteboardProcess.Output {
        self.arguments.append(arguments)
        inputs.append(input)
        if let failure { throw failure }
        if arguments.contains("notifyutil") { return ownership }
        guard !outputs.isEmpty else { throw NSError(domain: "unexpected subprocess", code: 1) }
        return outputs.removeFirst()
    }
}

private extension PasteboardProcess.Output {
    static func ok(_ data: Data = Data()) -> Self { .init(status: 0, stdout: data, stderr: Data()) }
}

@Suite("Pasteboard subprocess I/O")
struct PasteboardProcessTests {
    @Test("Large stdin and both output streams drain together")
    func largeIO() async throws {
        let data = Data(repeating: 65, count: 200_000)
        let output = try await PasteboardProcess.run(
            arguments: ["-c", "dd if=/dev/zero bs=1000 count=100 >&2 2>/dev/null; cat"],
            input: data, outputLimit: 300_000, executable: "/bin/sh", timeout: 30
        )
        #expect(output.status == 0)
        #expect(output.stdout == data)
        #expect(output.stderr.count == 100_000)
    }

    @Test("A child that does not consume stdin is bounded")
    func timeout() async throws {
        await #expect(throws: PasteboardProcess.Failure.timeout) {
            try await PasteboardProcess.run(arguments: ["10"], input: Data(repeating: 65, count: 200_000), outputLimit: 1000, executable: "/bin/sleep", timeout: 0.1)
        }
    }

    @Test("Excess output is bounded")
    func outputLimit() async throws {
        await #expect(throws: PasteboardProcess.Failure.outputLimit) {
            try await PasteboardProcess.run(arguments: ["-c", "head -c 100000 /dev/zero"], input: nil, outputLimit: 1000, executable: "/bin/sh", timeout: 30)
        }
    }

    @Test("Cancellation stops an in-flight child")
    func cancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sim-use-paste-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let task = Task {
            try await PasteboardProcess.run(
                arguments: ["-c", "printf '%s' \"$$\" > \"$1.tmp\"; /bin/mv \"$1.tmp\" \"$1\"; exec /bin/sleep 60", "cancel-test", marker.path],
                input: nil, outputLimit: 1000, executable: "/bin/sh", timeout: 30
            )
        }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
    }

    @Test("Successful early exit cannot report a complete input transfer")
    func incompleteInput() async throws {
        await #expect(throws: PasteboardProcess.Failure.inputClosed) {
            try await PasteboardProcess.run(arguments: ["-c", "exit 0"], input: Data(repeating: 65, count: 200_000), outputLimit: 1000, executable: "/bin/sh", timeout: 30)
        }
    }

    @Test("A child that exits before reading stdin does not raise SIGPIPE")
    func earlyExit() async throws {
        let output = try await PasteboardProcess.run(arguments: ["-c", "exit 7"], input: Data(repeating: 65, count: 200_000), outputLimit: 1000, executable: "/bin/sh", timeout: 30)
        #expect(output.status == 7)
    }
}
