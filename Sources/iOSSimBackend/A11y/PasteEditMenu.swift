// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Menu items must appear after menu invocation, not merely share a label with
/// an existing app control. A native modal menu can also be reused as-is.
enum PasteEditMenu {
    struct Item: Equatable {
        let label: String
        let frame: CGRect
        let identifier: String?

        init(label: String, frame: CGRect, identifier: String? = nil) {
            self.label = label
            self.frame = frame
            self.identifier = identifier
        }

        func isPreexisting(in baseline: [Item]) -> Bool {
            baseline.contains { previous in
                if let identifier, let oldIdentifier = previous.identifier {
                    return identifier == oldIdentifier
                }
                return self == previous
            }
        }
    }

    struct Readiness {
        private var previous: [Item] = []
        private var stableSince: ContinuousClock.Instant?

        mutating func observe(_ items: [Item], at now: ContinuousClock.Instant, selectAllMustDisappear: Bool) -> Bool {
            let ready = items.contains { pasteLabels.contains($0.label) }
                && (!selectAllMustDisappear || !items.contains { selectAllLabels.contains($0.label) })
            guard ready else {
                previous = []
                stableSince = nil
                return false
            }
            if items != previous { stableSince = now }
            previous = items
            // UIKit publishes final AX geometry before its context menu
            // accepts touches. Two adjacent snapshots are not sufficient.
            return stableSince.map { $0.duration(to: now) >= .seconds(1) } ?? false
        }
    }

    static let pasteLabels: Set<String> = [
        "Paste", "粘贴", "貼上", "ペースト", "붙여넣기",
        "Einsetzen", "Coller", "Pegar", "Incolla",
    ]
    static let selectAllLabels: Set<String> = [
        "Select All", "全选", "全選", "すべて選択", "전체 선택",
        "Alles auswählen", "Tout sélectionner", "Seleccionar todo", "Seleziona tutto",
    ]

    static func items(in roots: [AccessibilityElement]) -> [Item] {
        roots.flatMap { $0.flattened() }.compactMap { element in
            guard element.enabled != false,
                  let type = element.type, ["Button", "MenuItem", "StaticText"].contains(type),
                  let label = element.normalizedLabel, let frame = element.frame,
                  frame.width > 0, frame.height > 0 else { return nil }
            return Item(label: label, frame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), identifier: element.normalizedUniqueId)
        }
    }

    static func item(labels: Set<String>, in roots: [AccessibilityElement], excluding baseline: [Item]) -> Item? {
        items(in: roots).first { labels.contains($0.label) && !$0.isPreexisting(in: baseline) }
    }

    static func isPresented(in roots: [AccessibilityElement]) -> Bool {
        let flat = roots.flatMap { $0.flattened() }
        if flat.contains(where: { $0.type == "Menu" || $0.type == "MenuItem" }) { return true }
        guard items(in: roots).contains(where: { pasteLabels.contains($0.label) }) else { return false }
        // iOS 27's modal edit menu exposes an anonymous full-screen dismissal
        // button. Its label is localized, so use topology instead of English.
        return roots.contains { root in
            guard root.type == "Application" || root.type == "Window",
                  let screen = root.frame else { return false }
            return flat.contains { element in
                guard element.type == "Button", element.normalizedUniqueId?.isEmpty != false,
                      let frame = element.frame else { return false }
                return frame.x == screen.x && frame.y == screen.y && frame.width == screen.width && frame.height == screen.height
            }
        }
    }
}
