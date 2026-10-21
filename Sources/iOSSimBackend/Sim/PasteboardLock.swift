// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import SimUseCore

/// Per-host cooperation across per-device daemons. Other applications can still
/// change the shared clipboard; exact readback is checked again before Paste.
final class PasteboardLock: Sendable {
    private let fd: Int32
    private init(fd: Int32) { self.fd = fd }
    deinit { Darwin.close(fd) }

    static func acquire(directory: URL? = nil, timeout: TimeInterval = 30) async throws -> PasteboardLock {
        let paths = DaemonPaths(udid: "pasteboard", baseDirectory: directory)
        try paths.ensureBaseDirectory()
        let path = paths.baseDirectory.appendingPathComponent("pasteboard.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CLIError(errorDescription: "Could not open the shared pasteboard lock.") }
        let lease = PasteboardLock(fd: fd)
        defer { withExtendedLifetime(lease) {} }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o077 == 0,
              info.st_nlink == 1 else {
            throw CLIError(errorDescription: "The shared pasteboard lock is not a private regular file.")
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw CLIError(errorDescription: "Could not acquire the shared pasteboard lock.")
            }
            guard clock.now < deadline else {
                throw CLIError(errorDescription: "Timed out waiting for another sim-use paste operation.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        return lease
    }
}
