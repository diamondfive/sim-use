// SPDX-License-Identifier: Apache-2.0
import Foundation

extension CodingUserInfoKey {
    /// Allows optional text-formatting metadata on the internal daemon
    /// response. Public JSON encoders do not set this key.
    public static let simUseDaemonResponse = CodingUserInfoKey(rawValue: "sim-use.daemon-response")!
}
