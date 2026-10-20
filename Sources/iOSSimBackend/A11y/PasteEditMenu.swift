// SPDX-License-Identifier: Apache-2.0
import Foundation
import SimUseCore

/// Match only native menu subtrees, not app controls with the same label.
/// Modal menus require verified provenance and an app-control baseline.
/// Work record: docs/ai/011-device-hub-paste/006-modal-menu-provenance.md.
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
                if let identifier, !identifier.isEmpty, let oldIdentifier = previous.identifier, !oldIdentifier.isEmpty {
                    return identifier == oldIdentifier
                }
                return self == previous
            }
        }
    }

    private struct ModalMenu {
        let frame: CGRect
        let groups: [AccessibilityElement]
        let verifiedBackdrop: Bool
        let exposesEditor: Bool
    }

    private enum Presentation {
        case absent
        case typed
        case modal(ModalMenu)
        case ambiguous
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

    // UIKitCore Localizable.strings (iOS 18.6, 26.5 and 27.x), plus older
    // observed variants. Keep exact labels; a fuzzy match can tap app content.
    static let pasteLabels: Set<String> = [
        "Paste", "粘贴", "貼上", "ペースト", "붙여넣기", "Einsetzen", "Coller", "Pegar", "Incolla",
        "لصق", "Постави", "পেস্ট", "Enganxa", "Vložit", "Sæt ind", "Επικόλληση", "Sijoita",
        "પેસ્ટ કરો", "הדבקה", "पेस्ट", "Zalijepi", "Beillesztés", "Tempel", "Қою", "ಪೇಸ್ಟ್",
        "Įklijuoti", "പേസ്റ്റ്", "पेस्ट करा", "Tampal", "Plak", "Lim inn", "ପେଷ୍ଟ୍ କରନ୍ତୁ", "ਪੇਸਟ",
        "Wklej", "Colar", "Lipiți", "Вставить", "Vložiť", "Prilepi", "Klistra in", "ஒட்டு",
        "పేస్ట్", "วาง", "Yapıştır", "Вставити", "پیسٹ کریں", "Dán",
    ]
    static let selectAllLabels: Set<String> = [
        "Select All", "全选", "全選", "すべて選択", "すべてを選択", "전체 선택", "Alles", "Alles auswählen",
        "Tout sélectionner", "Seleccionar todo", "Selec. todo", "Seleziona tutto", "تحديد الكل",
        "Избери всичко", "সবকটি বেছে নিন", "Selecciona‑ho tot", "Vybrat vše", "Vælg alt", "Επιλογή όλων",
        "Valitse kaikki", "તમામ સિલેક્ટ કરો", "בחירת הכול", "सभी चुनें", "Odaberi sve",
        "Az összes kijelölése", "Pilih Semua", "Барлығын таңдау", "ಎಲ್ಲವನ್ನೂ ಆಯ್ಕೆಮಾಡಿ", "Pasirinkti viską",
        "എല്ലാം സെലക്റ്റ് ചെയ്യൂ", "सर्व सिलेक्ट करा", "Selecteer alles", "Marker alt", "ସବୁ ଚୟନ କରନ୍ତୁ",
        "ਸਭ ਚੁਣੋ", "Zaznacz wszystko", "Selecionar Tudo", "Selecionar tudo", "Selectați tot", "Выбрать все",
        "Vybrať všetko", "Izberi vse", "Markera allt", "அனைத்தையும் தேர்ந்தெடு", "అన్నింటినీ ఎంచుకోండి",
        "เลือกทั้งหมด", "Tümünü Seç", "Вибрати все", "سبھی کو منتخب کریں", "Chọn tất cả",
    ]

    // UIKit.axbundle Accessibility.strings, context.menu.dismiss (iOS 18/26/27).
    private static let dismissalLabels: Set<String> = [
        "Atmesti konteksto meniu", "Avfärda kontextmeny", "Bağlamsal menüyü kapat", "Bỏ qua menu ngữ cảnh",
        "Cerrar menú contextual", "Cerrar menú de contexto", "Chiudi menu contestuale", "Descartar menu contextual",
        "Dismiss context menu", "Fechar menu contextual", "Fermer le menu contextuel", "Kontextmenü schließen",
        "Környezetfüggő menü bezárása", "Loại bỏ menu ngữ cảnh", "Luk genvejsmenu", "Lukk kontekstmeny",
        "Odbaci kontekstni izbornik", "Opusti kontekstni meni", "Sluit contextmenu", "Sulje kontekstivalikko",
        "Tanca el menú contextual", "Tutup menu konteks", "Zamknij menu kontekstowe", "Zatvoriť kontextové menu",
        "Zavřít kontextovou nabídku", "Închideți meniul contextual", "Απόρριψη θεματικού μενού",
        "Закрыть контекстное меню", "Затвори контекстно меню", "Контекстік мәзірді жабу", "Прибрати контекстне меню",
        "סגירת התפריט ההקשרי", "استبعاد قائمة السياق", "سیاق و سباق کا مینو بر طرف کریں",
        "प्रासंगिक मेनू को ख़ारिज करें", "प्रासंगिक मेन्यू को ख़ारिज करें", "संदर्भ मेन्यू डिस्मिस करा",
        "প্রসঙ্গ মেনু খারিজ করুন", "ਸੰਦਰਭ ਮੈਨਿਊ ਨੂੰ ਖ਼ਾਰਜ ਕਰੋ", "સંદર્ભ મેન્યૂ ડિસમિસ કરો",
        "ପ୍ରସଙ୍ଗ ମେନ୍ୟୁ ଖାରଜ କରନ୍ତୁ", "ପ୍ରସଙ୍ଗ ମେନ୍ୟୂ ଖାରଜ କରନ୍ତୁ", "சூழல் மெனுவை மூடுக",
        "కాంటెక్స్ట్ మెన్యూని విస్మరించండి", "ಸಂದರ್ಭದ ಮೆನುವನ್ನು ವಜಾಗೊಳಿಸಿ", "കോൺടെക്സ്റ്റ് മെനു നിരാകരിക്കൂ",
        "ปิดทิ้งเมนูตามบริบท", "コンテクストメニューを閉じる", "关闭关联菜单", "關閉特色選單", "빠른 메뉴 닫기",
    ]

    private static let editingLabels = pasteLabels.union(selectAllLabels).union([
        "Ausschneiden", "Copia", "Copiar", "Copiați", "Copier", "Copy",
        "Cortar", "Couper", "Cut", "Cắt", "Izreži", "Iškirpti",
        "Kes", "Kivágás", "Klip", "Klipp ut", "Knip", "Kopieer",
        "Kopier", "Kopiera", "Kopieren", "Kopijuoti", "Kopioi", "Kopiraj",
        "Kopiuj", "Kopyala", "Kopírovat", "Kopírovať", "Leikkaa", "Másolás",
        "Potong", "Retalla", "Salin", "Sao chép", "Taglia", "Tăiați",
        "Vyjmout", "Vystrihnúť", "Wytnij", "Zkopírovat", "Αντιγραφή", "Αποκοπή",
        "Вирізати", "Вырезать", "Изрежи", "Кесу", "Копирай", "Көшіру",
        "Скопировать", "Скопіювати", "גזירה", "העתקה", "قص", "نسخ",
        "کاپی", "کٹ", "कट", "कट करा", "कॉपी", "कॉपी करा",
        "কপি", "কাট করুন", "ਕਾਪੀ", "ਕੱਟ", "કટ કરો", "કૉપિ કરો",
        "କଟ୍ କରନ୍ତୁ", "କପି କରନ୍ତୁ", "நகலெடு", "வெட்டு", "కట్", "కాపీ",
        "ಕಟ್", "ಕಾಪಿ", "കട്ട്", "കോപ്പി", "คัดลอก", "ตัด",
        "カット", "コピー", "剪下", "剪切", "拷貝", "拷贝", "複製", "복사하기", "오려두기",
    ])

    static func validateReplacement(selectAll: Item?, emptyTargetConfirmed: Bool) throws {
        guard selectAll != nil || emptyTargetConfirmed else {
            throw CLIError(errorDescription: "Cannot replace: Select All is unavailable and the focused field is not confirmed empty. No paste action was sent.")
        }
    }

    static func emptyEditingTargetConfirmed(in roots: [AccessibilityElement]) -> Bool {
        let editing = roots.flatMap { $0.flattened() }.filter {
            $0.traits?.contains("IsEditing") == true && $0.traits?.contains("TextEntry") == true
        }
        guard editing.count == 1, let target = editing.first,
              target.enabled != false, target.type != "SecureTextField",
              target.traits?.contains("SecureTextField") != true else { return false }
        // Nil, placeholders and normalized whitespace are not proof of emptiness.
        return target.AXValue == ""
    }

    @MainActor
    static func prepare(
        fetch: () async throws -> [AccessibilityElement],
        dismiss: ([AccessibilityElement]) async throws -> Void,
        timeout: Double,
        now: () -> ContinuousClock.Instant = { .now },
        sleep: () async throws -> Void = { try await Task.sleep(for: .milliseconds(120)) }
    ) async throws -> [AccessibilityElement] {
        let before = try await fetch()
        try validatePresentation(in: before)
        guard isPresented(in: before) else { return before }
        try await dismiss(before)
        let deadline = now().advanced(by: .seconds(timeout))
        var absentSince: ContinuousClock.Instant?
        while now() < deadline {
            let roots = try await fetch()
            if isPresented(in: roots) {
                absentSince = nil
            } else {
                if let absentSince, absentSince.duration(to: now()) >= .milliseconds(300) { return roots }
                if absentSince == nil { absentSince = now() }
            }
            try await sleep()
        }
        throw CLIError(errorDescription: "The existing edit menu did not close. No paste action was sent.")
    }

    static func items(in roots: [AccessibilityElement]) -> [Item] {
        roots.flatMap { $0.flattened() }.compactMap { element in
            guard element.enabled != false,
                  let type = element.type, ["Button", "MenuItem", "StaticText"].contains(type),
                  let label = element.normalizedLabel, let frame = element.frame,
                  frame.width > 0, frame.height > 0 else { return nil }
            return Item(label: label, frame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), identifier: element.normalizedUniqueId)
        }
    }

    static func actionItems(in roots: [AccessibilityElement], excluding baseline: [Item]) -> [Item] {
        // Older trees expose Menu/MenuItem. Anonymous UIKit modal buttons need
        // verified dismissal provenance as well as the pre-invocation baseline.
        func menuRoots(in elements: [AccessibilityElement]) -> [AccessibilityElement] {
            elements.flatMap { element in
                if element.type == "Menu" || element.type == "MenuItem" { return [element] }
                return menuRoots(in: element.children ?? [])
            }
        }
        let menus = menuRoots(in: roots)
        let candidates: [Item]
        if !menus.isEmpty {
            candidates = items(in: menus)
        } else if case .modal(let menu) = presentation(in: roots) {
            candidates = items(in: menu.groups)
        } else {
            candidates = []
        }
        return candidates.filter { !$0.isPreexisting(in: baseline) }
    }

    static func item(labels: Set<String>, in roots: [AccessibilityElement], excluding baseline: [Item]) -> Item? {
        actionItems(in: roots, excluding: baseline).first { labels.contains($0.label) }
    }

    static func isPresented(in roots: [AccessibilityElement]) -> Bool {
        if case .absent = presentation(in: roots) { return false }
        return true
    }

    static func validatePresentation(in roots: [AccessibilityElement]) throws {
        if case .ambiguous = presentation(in: roots) {
            throw CLIError(errorDescription: "Cannot identify a unique native edit menu. No paste action was sent. Close the menu, focus the field and open its native edit menu before retrying.")
        }
    }

    static func dismissalTarget(in roots: [AccessibilityElement]) -> Item? {
        guard case .modal(let menu) = presentation(in: roots) else { return nil }
        let screen = menu.frame
        let controls = roots.flatMap { $0.flattened() }.compactMap { element -> CGRect? in
            guard ["Button", "MenuItem", "StaticText", "TextField", "TextArea", "SecureTextField"].contains(element.type ?? ""),
                  let frame = element.frame else { return nil }
            let rect = CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
            return rect == screen ? nil : rect
        }
        let points = [
            CGPoint(x: screen.minX + 8, y: screen.midY),
            CGPoint(x: screen.maxX - 8, y: screen.midY),
            CGPoint(x: screen.midX, y: screen.midY),
            CGPoint(x: screen.midX, y: screen.minY + screen.height / 4),
        ]
        guard let point = points.first(where: { point in
            screen.contains(point) && !controls.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
        }) else { return nil }
        return Item(label: "Dismiss edit menu", frame: CGRect(x: point.x - 0.5, y: point.y - 0.5, width: 1, height: 1))
    }

    private static func modalActionGroups(in roots: [AccessibilityElement]) -> [AccessibilityElement] {
        // These are candidates only. The sibling dismissal control and modal
        // context below establish provenance, not the editing labels alone.
        roots.filter { element in
            guard element.type == "Group", element.normalizedUniqueId?.isEmpty != false,
                  element.normalizedLabel?.isEmpty != false,
                  let children = element.children, !children.isEmpty else { return false }
            return children.allSatisfy {
                guard ["Button", "MenuItem", "StaticText"].contains($0.type ?? "") else { return false }
                let isEditAction = pasteLabels.contains($0.normalizedLabel ?? "") || selectAllLabels.contains($0.normalizedLabel ?? "")
                return !isEditAction || $0.normalizedUniqueId?.isEmpty != false
            } && items(in: children.filter { $0.type != "StaticText" }).contains {
                editingLabels.contains($0.label) && $0.identifier?.isEmpty != false
            }
        }
    }

    private static func presentation(in roots: [AccessibilityElement]) -> Presentation {
        let flat = roots.flatMap { $0.flattened() }
        if flat.contains(where: { $0.type == "Menu" || $0.type == "MenuItem" }) { return .typed }
        var candidates: [ModalMenu] = []
        for container in flat {
            guard container.type == "Application" || container.type == "Window",
                  let screen = container.frame, screen.width > 0, screen.height > 0 else { continue }
            let children = container.children ?? []
            let groups = modalActionGroups(in: children)
            let backdrops = children.filter { element in
                guard element.type == "Button", element.enabled != false,
                      element.normalizedUniqueId?.isEmpty != false,
                      let frame = element.frame else { return false }
                return frame.x == screen.x && frame.y == screen.y && frame.width == screen.width && frame.height == screen.height
            }
            let nativeBackdrops = backdrops.filter { dismissalLabels.contains($0.normalizedLabel ?? "") }
            guard !backdrops.isEmpty, !groups.isEmpty || !nativeBackdrops.isEmpty else { continue }
            let exposesEditor = children.flatMap { $0.flattened() }.contains {
                ["TextField", "TextArea", "SecureTextField"].contains($0.type ?? "") || $0.traits?.contains("TextEntry") == true
            }
            // UIKit's modal tree hides the app editor. A visible editor and
            // an ordinary background button belong to the app baseline.
            if exposesEditor && nativeBackdrops.isEmpty { continue }
            candidates.append(ModalMenu(
                frame: CGRect(x: screen.x, y: screen.y, width: screen.width, height: screen.height),
                groups: groups, verifiedBackdrop: backdrops.count == 1 && nativeBackdrops.count == 1,
                exposesEditor: exposesEditor
            ))
        }
        guard !candidates.isEmpty else { return .absent }
        guard candidates.count == 1, let menu = candidates.first,
              menu.verifiedBackdrop, !menu.exposesEditor, menu.groups.count == 1,
              modalActionGroups(in: roots).isEmpty else { return .ambiguous }
        return .modal(menu)
    }
}
