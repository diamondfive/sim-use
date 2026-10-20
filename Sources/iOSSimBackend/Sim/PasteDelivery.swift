// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// The shared standalone/batch boundary after Paste can have side effects.
enum PasteDelivery {
    @MainActor
    static func perform(send: () async throws -> Void, waitForCompletion: () async throws -> Void) async throws {
        do {
            try await send()
            try await waitForCompletion()
        } catch {
            // A partial HID send can already insert text. Do not retain the
            // underlying message: daemon retry classification uses substrings.
            throw CLIError(errorDescription: "Paste may have been sent, but completion could not be confirmed. Verify the field before retrying; do not paste again without checking.")
        }
    }
}
