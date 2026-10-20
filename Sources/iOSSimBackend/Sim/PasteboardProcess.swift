// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore

/// Raw, bounded subprocess I/O for pasteboard commands. No payload enters argv.
/// Unlike JSON probes, reads and writes must progress together for large text.
enum PasteboardProcess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    enum Failure: Error, LocalizedError, Equatable {
        case launch, timeout, outputLimit, io, inputClosed

        var errorDescription: String? {
            switch self {
            case .launch: "Could not start the pasteboard tool. Check the selected Xcode."
            case .timeout: "The pasteboard tool timed out. No paste action was sent."
            case .outputLimit: "The pasteboard tool exceeded the readback limit."
            case .io: "Could not transfer pasteboard data."
            case .inputClosed: "The pasteboard tool closed its input before receiving all text."
            }
        }
    }

    static func run(
        arguments: [String], input: Data?, outputLimit: Int,
        executable: String = "/usr/bin/xcrun", timeout: TimeInterval = 10
    ) async throws -> Output {
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try blockingRun(arguments: arguments, input: input ?? Data(), outputLimit: outputLimit,
                                executable: executable, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func blockingRun(
        arguments: [String], input: Data, outputLimit: Int,
        executable: String, timeout: TimeInterval, cancellation: CancellationFlag
    ) throws -> Output {
        if cancellation.isCancelled() { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            for handle in [stdin.fileHandleForReading, stdin.fileHandleForWriting,
                           stdout.fileHandleForReading, stdout.fileHandleForWriting,
                           stderr.fileHandleForReading, stderr.fileHandleForWriting] {
                try? handle.close()
            }
        }
        do { try process.run() } catch { throw Failure.launch }
        try stdin.fileHandleForReading.close()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        let errorFD = stderr.fileHandleForReading.fileDescriptor
        for fd in [inputFD, outputFD, errorFD] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw Failure.io }
        }
        // An unsupported command can exit before consuming stdin. Surface its
        // status instead of terminating the daemon with SIGPIPE.
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.io }
        var descriptors = [
            pollfd(fd: inputFD, events: Int16(POLLOUT), revents: 0),
            pollfd(fd: outputFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: errorFD, events: Int16(POLLIN), revents: 0),
        ]
        var offset = 0
        if input.isEmpty {
            try stdin.fileHandleForWriting.close()
            descriptors[0].fd = -1
        }
        var outputs = [Data(), Data()]
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while process.isRunning || descriptors[1].fd >= 0 || descriptors[2].fd >= 0 {
            if cancellation.isCancelled() { throw CancellationError() }
            guard clock.now < deadline else { throw Failure.timeout }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 10)
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.io
            }
            // A descendant can inherit a pipe after the tool exits. Do not
            // wait for that unrelated process to close it.
            if ready == 0, !process.isRunning { break }
            for index in 1...2 where descriptors[index].fd >= 0 && descriptors[index].revents != 0 {
                let count = Darwin.read(descriptors[index].fd, &buffer, buffer.count)
                if count > 0 {
                    guard count <= outputLimit - outputs[index - 1].count else { throw Failure.outputLimit }
                    outputs[index - 1].append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    descriptors[index].fd = -1
                } else if errno != EAGAIN && errno != EINTR {
                    throw Failure.io
                }
            }
            if descriptors[0].fd >= 0, descriptors[0].revents != 0 {
                let count = input.withUnsafeBytes { bytes in
                    Darwin.write(inputFD, bytes.baseAddress!.advanced(by: offset), min(16_384, input.count - offset))
                }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR && errno != EPIPE { throw Failure.io }
                if offset == input.count || (count < 0 && errno == EPIPE) {
                    try stdin.fileHandleForWriting.close()
                    descriptors[0].fd = -1
                }
            }
        }
        process.waitUntilExit()
        if process.terminationStatus == 0, offset != input.count { throw Failure.inputClosed }
        return Output(status: process.terminationStatus, stdout: outputs[0], stderr: outputs[1])
    }
}
