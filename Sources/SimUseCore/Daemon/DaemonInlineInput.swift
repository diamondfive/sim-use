// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Rewrites a forwarded argv tail so that input only the caller can read
/// travels inline to the daemon.
///
/// The daemon runs with stdin on `/dev/null` and in its own working
/// directory, so `--stdin` and a caller-relative `--file` cannot be read
/// there. Running such a command in-process instead is not an option: on
/// the CoreDevice (`dtuhidd`) HID transport, a short-lived process exits
/// before `dtuhidd` activates its new connection, and the events it sent
/// are dropped. A command reads that input in the client and rewrites its
/// arguments with these helpers in `daemonArguments(from:)`.
///
/// Every helper scans only up to a `--` terminator; tokens after it are
/// positionals and stay as they are.
public enum DaemonInlineInput {
    /// `arguments` without the long flag `--<name>`.
    public static func removingFlag(_ name: String, from arguments: [String]) -> [String] {
        let flag = "--\(name)"
        return rewritingOptions(in: arguments) { options in
            options.filter { $0 != flag }
        }
    }

    /// `arguments` without the long option `--<name>` and its value, in
    /// either the `--name value` or the `--name=value` form.
    public static func removingOption(_ name: String, from arguments: [String]) -> [String] {
        let option = "--\(name)"
        return rewritingOptions(in: arguments) { options in
            var kept: [String] = []
            var index = options.startIndex
            while index < options.endIndex {
                let token = options[index]
                if token == option {
                    index += 2
                    continue
                }
                if !token.hasPrefix(option + "=") {
                    kept.append(token)
                }
                index += 1
            }
            return kept
        }
    }

    /// `arguments` with `options` added before any `--` terminator.
    public static func insertingOptions(_ options: [String], into arguments: [String]) -> [String] {
        rewritingOptions(in: arguments) { $0 + options }
    }

    /// `arguments` with `text` as the positional argument, after a `--`
    /// terminator so that text which starts with `-` is not parsed as an
    /// option.
    public static func appendingPositional(_ text: String, to arguments: [String]) -> [String] {
        if arguments.contains("--") {
            return arguments + [text]
        }
        return arguments + ["--", text]
    }

    /// `arguments` with a `--stdin` / `--file` text source replaced by
    /// `text` as the positional argument.
    public static func inliningText(_ text: String, into arguments: [String]) -> [String] {
        appendingPositional(
            text,
            to: removingOption("file", from: removingFlag("stdin", from: arguments))
        )
    }

    private static func rewritingOptions(
        in arguments: [String],
        _ transform: ([String]) -> [String]
    ) -> [String] {
        guard let terminator = arguments.firstIndex(of: "--") else {
            return transform(arguments)
        }
        return transform(Array(arguments[..<terminator])) + arguments[terminator...]
    }
}
