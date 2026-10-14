// SPDX-License-Identifier: Apache-2.0
@testable import SimUse
@testable import iOSSimBackend
import ArgumentParser
import Foundation
import Testing
@testable import SimUseCore

// `batch --stdin` and `--file` input lives in the caller: the daemon runs
// with stdin on /dev/null (LINEIOS-216940) and in its own working
// directory. These modes used to bypass the daemon, but on the CoreDevice
// (dtuhidd) HID transport a short-lived process exits before dtuhidd
// activates its connection, so every touch it sent was dropped. The
// client now reads the steps and forwards them inline as `--step`.

@Suite("Batch — caller-side step input is inlined for the daemon")
struct BatchDaemonForwardingTests {
    private static let udid = "FAKE-UDID"

    private func writeStepFile(_ contents: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-forward-\(UUID().uuidString).steps").path
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test("No step source bypasses the daemon", arguments: [
        ["--stdin"],
        ["--file", "./steps.txt"],
        ["--step", "tap -x 1 -y 1"],
    ])
    func noSourceBypassesDaemon(source: [String]) throws {
        let cmd = try IOSSimBatchCommand.parse(source + ["--udid", Self.udid])
        #expect(cmd.daemonBypass == false)
    }

    @Test("--file is read in the client and forwarded as one --step per executable line")
    func fileIsInlined() throws {
        let path = try writeStepFile("tap @1\n\n# a comment\n  tap -x 1 -y 2  \n")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let argv = ["ios", "batch", "--file", path, "--continue-on-error", "--device", Self.udid]
        let cmd = try IOSSimBatchCommand.parse(Array(argv.dropFirst(2)))

        let forwarded = try cmd.daemonArguments(from: argv)

        #expect(forwarded == [
            "ios", "batch", "--continue-on-error", "--device", Self.udid,
            "--step=tap @1", "--step=tap -x 1 -y 2",
        ])
        let daemonSide = try IOSSimBatchCommand.parse(Array(forwarded.dropFirst(2)))
        #expect(daemonSide.steps == ["tap @1", "tap -x 1 -y 2"])
        #expect(daemonSide.file == nil)
        #expect(daemonSide.useStdin == false)
        #expect(daemonSide.continueOnError)
    }

    @Test("--stdin lines are forwarded the same way")
    func stdinLinesAreInlined() throws {
        let argv = ["ios", "batch", "--stdin", "--device", Self.udid]
        let forwarded = try IOSSimBatchCommand.inliningSteps(
            ["tap -x 160 -y 350", "", "tap -x 200 -y 410"],
            into: argv
        )
        #expect(forwarded == [
            "ios", "batch", "--device", Self.udid,
            "--step=tap -x 160 -y 350", "--step=tap -x 200 -y 410",
        ])
    }

    @Test("Input with no executable step fails in the client with the in-process message")
    func emptyInputFails() throws {
        #expect(throws: CLIError.self) {
            try IOSSimBatchCommand.inliningSteps(["", "# only a comment"], into: ["ios", "batch", "--stdin"])
        }
    }

    @Test("An unreadable --file fails in the client")
    func unreadableFileFails() throws {
        let argv = ["ios", "batch", "--file", "/nonexistent/steps.txt", "--device", Self.udid]
        let cmd = try IOSSimBatchCommand.parse(Array(argv.dropFirst(2)))
        #expect(throws: CLIError.self) { try cmd.daemonArguments(from: argv) }
    }

    @Test("--step input is forwarded unchanged")
    func stepsAreUnchanged() throws {
        let argv = ["ios", "batch", "--step", "tap -x 1 -y 1", "--device", Self.udid]
        let cmd = try IOSSimBatchCommand.parse(Array(argv.dropFirst(2)))
        #expect(try cmd.daemonArguments(from: argv) == argv)
    }
}
