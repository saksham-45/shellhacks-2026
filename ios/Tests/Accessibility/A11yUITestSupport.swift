// XCODE-ONLY. Compiled into the `MyAmericanDreamUITests` target (its sources include ios/Tests/Accessibility/).
// Needs XCTest UI automation (XCUIApplication): not buildable on Linux, not part of any SwiftPM package.
// Depends on `ADAccessibility` (A11yID, A11yLabelLint, FactSlot) and `ADCore` (StringKey, ADCoreStrings);
// Lead links both packages to the UI test target (NOTES.md; project.yml lists ADAccessibility only, ADCore pending).
// ADVoice is NOT linked: the "Play in Kreyòl" action name (ADVoice `kreyol.play`) is read from ADVoice's
// String Catalog JSON in the source tree, with a mirrored constant table as fallback (`ADVoiceKreyolPlay`).
// No @testable import of the app: UI tests see the app only through the accessibility tree.

import ADAccessibility
import ADCore
import XCTest

// MARK: - Launch configuration

/// Surface languages under test (docs/accessibility.md A11Y-L10N-*). Named apart from ADLocale's
/// `SurfaceLanguage` so the two never collide if ADLocale is linked here later.
enum A11yLanguage: String, CaseIterable, Sendable {
    case es, en, ht

    /// `-AppleLanguages` value. The app bundle must contain an `ht` localization for `(ht)` to resolve;
    /// iOS has no Creole system UI, so this is app-level only (verify on simulator, NOTES.md).
    var appleLanguages: String { "(\(rawValue))" }
    /// `-AppleLocale` value: US region formats in every language.
    /// OPEN QUESTION (NOTES.md): confirm `ht_US` behaves on device; fallback `en_US`.
    var appleLocale: String { "\(rawValue)_US" }
}

/// Dynamic Type sizes under test. Raw values are `UIContentSizeCategory.rawValue` strings (what
/// `-UIPreferredContentSizeCategoryName` expects); an unknown string is silently ignored by iOS.
enum TextSizeUnderTest: String, CaseIterable, Sendable {
    /// Explicit "Large" (the iOS default) so a simulator left at another size does not leak in.
    /// `UIContentSizeCategory.large.rawValue`.
    case standard = "UICTContentSizeCategoryL"
    /// AX5, the largest accessibility size. `UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue`.
    case ax5 = "UICTContentSizeCategoryAccessibilityXXXL"
}

/// Test-plan switches (Environment Variables of the UI test plan, read in the test runner process).
/// Each one turns a missing prerequisite from a failure into a skip, and only while it is set to "1".
/// Status 2026-09-25: both prerequisites have shipped (the test UI sets the A11yID contract and the app's
/// voice-script stub shows `a11y.voice.stub`), and ios/Accessibility.xctestplan sets neither variable, so a
/// missing anchor or stub FAILS. The gates stay as a documented escape hatch; do not set them again.
enum A11yPending {
    /// "1" until ADVoice's stub hook (`a11y.voice.stub`) and the bundled voice scripts ship.
    static let voiceStubVariable = "MYAD_VOICE_STUB_PENDING"
    /// "1" until the app's views set the A11yID contract (the Household list anchor exists).
    static let appIDsVariable = "MYAD_APP_IDS_PENDING"

    static var voiceStub: Bool { isSet(voiceStubVariable) }
    static var appIDs: Bool { isSet(appIDsVariable) }

    private static func isSet(_ name: String) -> Bool { ProcessInfo.processInfo.environment[name] == "1" }
}

/// Demo seed contract (docs §9, "Demo seed"). Change values here only.
enum A11ySeed {
    /// 2 people (student + parent), Kendall pin, all cards.
    static let demoHousehold = "demoHousehold"
    /// Fresh install: no household, the app opens on onboarding.
    static let none = "none"
    /// The seeded card that must show `a11y.card.call` (docs §9). Confirmed by Lead: `DemoSeed.officesCard`
    /// in the app. Rows use `A11yID.Cards.row(phoneCardID)`. (App finding: its facts have no phone fact yet;
    /// the call control is the desk's call, confirmed by the router first.)
    static let phoneCardID = "offices"
}

/// Launch arguments the app must honor (contract in NOTES.md and docs §9).
struct A11yLaunch: Sendable {
    var language: A11yLanguage
    var size: TextSizeUnderTest
    var seed: String = A11ySeed.demoHousehold
    /// Voice script replayed by the app's voice stub (docs §9, VoiceScript). Nil for touch/audit tests.
    var voiceScript: String? = nil
    /// Lead's test-only screen route (`-uiTestScreen <name>`, docs §9). Used only where no identifier path
    /// exists (the clarify overlay); every other screen is reached by tapping contract identifiers.
    var screen: String? = nil

    var arguments: [String] {
        var args = [
            "-AppleLanguages", language.appleLanguages,
            "-AppleLocale", language.appleLocale,
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            // App-specific, read from the UserDefaults argument domain:
            "-myadUITest", "YES",                      // in-memory store, no network, leave-app actions recorded not opened
            "-myadSeed", seed,
            "-myadSurfaceLanguage", language.rawValue, // in-app surface language override
            "-myadVoiceStub", "YES",                   // no mic/speech permission prompts (system alerts break audits)
        ]
        if let voiceScript { args += ["-myadVoiceScript", voiceScript] }
        if let screen { args += ["-uiTestScreen", screen] }
        return args
    }

    var name: String { "\(language.rawValue)-\(size == .ax5 ? "AX5" : "default")" }
}

// MARK: - Screens and navigation (built only on the identifier contract)

enum A11yScreen: String, CaseIterable, Sendable {
    // `household` stays first: the sweep's MYAD_APP_IDS_PENDING gate runs on its launch.
    // `clarify`: the router's clarifying question (`a11y.router.clarify`) only appears after an ambiguous
    // spoken or typed request, so no control reaches it by identifier; it is opened with Lead's test-only
    // route `-uiTestScreen clarify` (three household cards as options) and never answered.
    case household, onboarding, addPerson, personDetail, settings, pin, cards, cardDetail, desk, confirm, clarify, voice

    /// Element that proves the screen is showing (and, when `isPaged`, the scroll container that pages it).
    var anchor: String {
        switch self {
        case .household: A11yID.Household.list
        case .onboarding: A11yID.Onboarding.form
        case .addPerson: A11yID.AddPerson.form
        case .personDetail: A11yID.PersonDetail.list
        case .settings: A11yID.Settings.form
        case .pin: A11yID.Pin.list
        case .cards: A11yID.Cards.list
        case .cardDetail: A11yID.Card.list
        case .desk: A11yID.Desk.panel
        case .confirm: A11yID.Router.confirm
        case .clarify: A11yID.Router.clarify
        case .voice: A11yID.Voice.panel
        }
    }

    /// `-uiTestScreen` route for screens with no identifier path (docs §9); nil = reached by taps.
    var launchRoute: String? { self == .clarify ? "clarify" : nil }

    /// Demo seed to launch with: onboarding only exists on a fresh install (docs §9, "Demo seed").
    var seed: String { self == .onboarding ? A11ySeed.none : A11ySeed.demoHousehold }

    /// False for overlays: their anchor is the question text, not a scroller, so they are one page
    /// (swiping them would scroll or dismiss the screen underneath).
    var isPaged: Bool { self != .confirm && self != .clarify }
}

@MainActor
struct A11yNavigator {
    let app: XCUIApplication
    var timeout: TimeInterval = 10

    /// Element by exact accessibilityIdentifier (explicit predicate, never matches on label).
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@", identifier))
            .firstMatch
    }

    /// First element whose identifier starts with `prefix` (dynamic rows).
    func first(withPrefix prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// Navigates from a fresh launch (with `screen.seed`) to `screen`. Returns false (and records a failure)
    /// if a step fails. If Lead's navigation differs (e.g. cards live under person detail), change only this switch.
    @discardableResult
    func go(to screen: A11yScreen, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let root = A11yScreen.household
        switch screen {
        case .onboarding:
            // `-myadSeed none`: a fresh install opens on onboarding, no taps needed.
            return waitFor(screen.anchor, file: file, line: line)
        case .clarify:
            // Launched with `-uiTestScreen clarify` (A11yScreen.launchRoute): the overlay is already up.
            return waitFor(screen.anchor, file: file, line: line)
        case .household:
            return waitFor(root.anchor, file: file, line: line)
        case .addPerson:
            return waitFor(root.anchor, file: file, line: line)
                && tap(element(A11yID.Household.addPerson), named: A11yID.Household.addPerson, on: root, thenExpect: screen, file: file, line: line)
        case .personDetail:
            return waitFor(root.anchor, file: file, line: line)
                && tap(first(withPrefix: A11yID.Household.rowPrefix), named: "first household row", on: root, thenExpect: screen, file: file, line: line)
        case .settings:
            return waitFor(root.anchor, file: file, line: line)
                && tap(element(A11yID.Household.settings), named: A11yID.Household.settings, on: root, thenExpect: screen, file: file, line: line)
        case .pin:
            return waitFor(root.anchor, file: file, line: line)
                && tap(element(A11yID.Household.pin), named: A11yID.Household.pin, on: root, thenExpect: screen, file: file, line: line)
        case .cards:
            return waitFor(root.anchor, file: file, line: line)
                && tap(element(A11yID.Household.cards), named: A11yID.Household.cards, on: root, thenExpect: screen, file: file, line: line)
        case .cardDetail:
            guard go(to: .cards, file: file, line: line) else { return false }
            return tap(first(withPrefix: A11yID.Cards.rowPrefix), named: "first card row", on: .cards, thenExpect: screen, file: file, line: line)
        case .desk:
            // The seeded phone card's desk row opens its desk panel (Destination.desk).
            guard goToCard(A11ySeed.phoneCardID, file: file, line: line) else { return false }
            return tap(element(A11yID.Card.desk), named: A11yID.Card.desk, on: .cardDetail, thenExpect: screen, file: file, line: line)
        case .confirm:
            // Calling from the seeded phone card asks first (AppAction.callDesk -> Router.pendingConfirmation).
            // Nothing leaves the app: the audit never answers the question.
            guard goToCard(A11ySeed.phoneCardID, file: file, line: line) else { return false }
            return tap(element(A11yID.Card.call), named: A11yID.Card.call, on: .cardDetail, thenExpect: screen, file: file, line: line)
        case .voice:
            // The mic is on every screen (voice-first); from the root it opens the voice panel.
            return waitFor(root.anchor, file: file, line: line)
                && tap(element(A11yID.Voice.mic), named: A11yID.Voice.mic, on: root, thenExpect: screen, file: file, line: line)
        }
    }

    /// Opens one seeded card by its stable id (paging the card list slowly until its row appears).
    @discardableResult
    func goToCard(_ cardID: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard go(to: .cards, file: file, line: line) else { return false }
        return tap(element(A11yID.Cards.row(cardID)), named: A11yID.Cards.row(cardID), on: .cards,
                   thenExpect: .cardDetail, file: file, line: line)
    }

    func waitFor(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        if element(identifier).waitForExistence(timeout: timeout) { return true }
        XCTFail("Missing element '\(identifier)' (identifier contract, docs/accessibility.md §9)", file: file, line: line)
        return false
    }

    private func tap(_ target: XCUIElement, named name: String, on current: A11yScreen, thenExpect screen: A11yScreen,
                     file: StaticString, line: UInt) -> Bool {
        if !target.waitForExistence(timeout: timeout) { scrollIntoView(target, on: current) }
        guard target.exists else {
            XCTFail("Cannot reach \(screen): '\(name)' not found on \(current)", file: file, line: line)
            return false
        }
        scrollIntoView(target, on: current)
        guard target.isHittable else {
            XCTFail("Cannot reach \(screen): '\(name)' exists but is not hittable (off-screen or obscured, A11Y-KB-02)",
                    file: file, line: line)
            return false
        }
        target.tap()
        return waitFor(screen.anchor, file: file, line: line)
    }

    /// At AX5 most targets start off-screen: page the current screen's anchor (never "the first
    /// scroller in the app", which may be a different, hidden list) until the target is hittable.
    func scrollIntoView(_ target: XCUIElement, on screen: A11yScreen, maxSwipes: Int = 12) {
        let scroller = element(screen.anchor)
        var swipes = 0
        while !(target.exists && target.isHittable) && swipes < maxSwipes && scroller.exists {
            scroller.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    /// Runs `body` on each page of `screen`, swiping its anchor slowly between pages. Returns true when
    /// the end was reached (a swipe no longer changes what is visible) and false when `maxPages` ran
    /// out while the content was still changing (the caller fails: part of the screen went unchecked).
    func forEachPage(of screen: A11yScreen, maxPages: Int, _ body: (Int) -> Void) -> Bool {
        guard screen.isPaged else { body(0); return true }   // overlays are one page
        let scroller = element(screen.anchor)
        var last = A11yCustomChecks.visibleFingerprint(app: app)
        for page in 0..<maxPages {
            body(page)
            guard scroller.exists else { return true }   // a screen that does not scroll is one page
            scroller.swipeUp(velocity: .slow)
            let now = A11yCustomChecks.visibleFingerprint(app: app)
            if now == last { return true }
            last = now
        }
        return false
    }
}

// MARK: - Localized expectations (package catalogs, resolved per surface language)

/// Named apart from ADAccessibility's `A11yStrings` (keys + bundle of ADAccessibility.xcstrings) so that name is
/// never shadowed in this target; `ADAccessibility.A11yStrings` can't be spelled because the module also has an
/// `ADAccessibility` enum.
enum A11yCatalog {
    /// Resolves an ADCore-table key in `language` from ADCore's resource bundle. Nil when the catalog
    /// has no value for that language (a parity gap for myAD Language, reported by the caller).
    static func resolve(_ key: StringKey, in language: A11yLanguage) -> String? {
        guard key.table == StringKey.adCoreTable else { return nil }
        return resolve(key.key, table: key.table, bundle: ADCoreStrings.bundle, in: language)
    }

    /// "Jwe an Kreyòl" / "Play in Kreyòl" / "Escuchar en Kreyòl": the VoiceOver custom action every Kreyòl
    /// card must offer (A11Y-LANG-03 part 3). Its one label key is ADVoice's `kreyol.play` (`VoiceKey.kreyolPlay`);
    /// ADAccessibility's `a11y.card.playInKreyol` is retired. Read from ADVoice's catalog JSON when the runner
    /// can see the source tree (simulator on the Mac), else from the mirrored table. Nil = no value (a gap).
    static func playInKreyol(in language: A11yLanguage) -> String? {
        if let catalog = ADVoiceKreyolPlay.catalogValues() { return catalog[language] }
        return ADVoiceKreyolPlay.expected[language]
    }

    /// `key` in `table` of `bundle`'s compiled `<language>.lproj`; nil when missing or empty (no fallback).
    static func resolve(_ key: String, table: String, bundle: Bundle, in language: A11yLanguage) -> String? {
        guard let path = bundle.path(forResource: language.rawValue, ofType: "lproj"),
              let lproj = Bundle(path: path) else { return nil }
        let missing = "\u{1}missing"
        let value = lproj.localizedString(forKey: key, value: missing, table: table)
        return value == missing || value.isEmpty ? nil : value
    }
}

/// ADVoice's `VoiceKey.kreyolPlay`, the single label key of the "Play in Kreyòl" card action (A11Y-LANG-03
/// part 3, agreed between myAD Access and myAD Language on 2026-09-25). The UI test target does not link ADVoice
/// (no project.yml change): the values come from ADVoice's String Catalog JSON, found from this file's path,
/// and `expected` mirrors them for runs that cannot read the source tree (a physical device).
enum ADVoiceKreyolPlay {
    static let key = "kreyol.play"
    static let table = "ADVoice"
    /// Mirror of `kreyol.play` in ios/Packages/ADVoice/Sources/ADVoice/Resources/ADVoice.xcstrings (ht is
    /// needs_review until a native-speaker pass, decision D9). `test_creoleCardsOfferPlayInKreyol` fails when the
    /// catalog and this table disagree: update both together with myAD Language.
    static let expected: [A11yLanguage: String] = [
        .es: "Escuchar en Kreyòl",
        .en: "Play in Kreyòl",
        .ht: "Jwe an Kreyòl",
    ]

    /// ios/Packages/ADVoice/Sources/ADVoice/Resources/ADVoice.xcstrings, relative to ios/Tests/Accessibility/.
    static func catalogURL(sourceFile: String = #filePath) -> URL {
        URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()   // ios/Tests/Accessibility
            .deletingLastPathComponent()   // ios/Tests
            .deletingLastPathComponent()   // ios
            .appendingPathComponent("Packages/ADVoice/Sources/ADVoice/Resources/ADVoice.xcstrings")
    }

    /// The es/en/ht values of `kreyol.play` in ADVoice's catalog (an empty value counts as missing). Nil when
    /// the file cannot be read or has no such key: the caller then uses `expected` and says so.
    static func catalogValues(at url: URL = catalogURL()) -> [A11yLanguage: String]? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let strings = root["strings"] as? [String: Any],
              let entry = strings[key] as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any] else { return nil }
        var values: [A11yLanguage: String] = [:]
        for language in A11yLanguage.allCases {
            guard let localization = localizations[language.rawValue] as? [String: Any],
                  let unit = localization["stringUnit"] as? [String: Any],
                  let value = unit["value"] as? String, !value.isEmpty else { continue }
            values[language] = value
        }
        return values
    }
}

// MARK: - Known false positives (keep tiny; every entry needs a reason and an owner)

struct A11yExemption: Sendable {
    enum Check: Sendable, Equatable {
        case audit(XCUIAccessibilityAuditType)
        case label
        case hitTarget
    }

    let check: Check
    /// Exact identifier, or a prefix ending in "." for dynamic rows. Never empty; at least `a11y.<screen>.`.
    let identifier: String
    /// Restrict to one language (e.g. an ht-only wrap issue); nil = all.
    let language: A11yLanguage?
    let reason: String
    let owner: String

    /// Screen segments an exemption may name (the `<screen>` in `a11y.<screen>.<element>`).
    static let screens: Set<String> = [
        "household", "onboarding", "addPerson", "personDetail", "settings", "pin", "cards", "card",
        "desk", "router", "voice",
    ]

    /// Why this entry is not allowed, or nil when it is well formed.
    var problem: String? {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if identifier.trimmingCharacters(in: .whitespaces).isEmpty { return "empty identifier" }
        guard parts.count >= 3, parts[0] == "a11y", A11yExemption.screens.contains(parts[1]) else {
            return "'\(identifier)' is not scoped to one screen (needs at least 'a11y.<screen>.')"
        }
        // "a11y.card." (a prefix for one screen) is the widest allowed; no empty inner segments.
        if parts.dropFirst(2).dropLast().contains(where: \.isEmpty) { return "'\(identifier)' has an empty segment" }
        if reason.trimmingCharacters(in: .whitespaces).isEmpty { return "'\(identifier)' has no reason" }
        if owner.trimmingCharacters(in: .whitespaces).isEmpty { return "'\(identifier)' has no owner" }
        return nil
    }

    func matches(_ check: Check, identifier id: String, language lang: A11yLanguage) -> Bool {
        guard problem == nil, self.check == check, !id.isEmpty else { return false }
        if let language, language != lang { return false }
        return identifier.hasSuffix(".") ? id.hasPrefix(identifier) : id == identifier
    }
}

enum A11yExemptions {
    /// Empty on purpose. Add an entry ONLY after a manual VoiceOver / Accessibility Inspector check proves a
    /// false positive, and record it in docs/accessibility.md §11. `test_exemptionsAreWellFormed` fails on
    /// an entry with an empty or unscoped identifier. Example shape (not active):
    ///   A11yExemption(check: .audit(.contrast), identifier: "a11y.card.fact.", language: nil,
    ///                 reason: "Audit samples the material behind text; measured 7.4:1 by hand",
    ///                 owner: "myAD Access")
    static let all: [A11yExemption] = []

    static func isExempt(_ check: A11yExemption.Check, identifier: String, language: A11yLanguage) -> Bool {
        all.contains { $0.matches(check, identifier: identifier, language: language) }
    }
}

// MARK: - Custom checks over one snapshot of the accessibility tree

@MainActor
enum A11yCustomChecks {
    static let interactiveTypes: Set<XCUIElement.ElementType> = [
        .button, .link, .textField, .secureTextField, .searchField, .textView, .switch, .toggle,
        .slider, .stepper, .picker, .pickerWheel, .segmentedControl, .menuButton, .popUpButton,
        .radioButton, .checkBox, .incrementArrow, .decrementArrow, .tab,
    ]

    /// Controls whose system frame is not the hit area (or whose parts are measured as a group):
    /// left to the audit's `.hitRegion` check instead of the 44x44 frame check.
    static let frameCheckSkippedTypes: Set<XCUIElement.ElementType> = [
        .switch, .toggle, .stepper, .incrementArrow, .decrementArrow,
        .textField, .secureTextField, .searchField, .textView,
    ]

    /// Minimum target in points (HIG default 44x44; stricter than WCAG 2.5.8's 24x24). A11Y-TGT-01.
    static let minTarget: CGFloat = 44
    /// Frames are floating point; allow sub-point rounding only.
    static let tolerance: CGFloat = 0.5

    struct Finding: CustomStringConvertible {
        let rule: String
        let identifier: String
        let type: XCUIElement.ElementType
        let message: String
        var description: String {
            "\(rule) [\(identifier.isEmpty ? "<no identifier>" : identifier) type=\(type.rawValue)] \(message)"
        }
    }

    /// Label + target checks on every visible, enabled interactive element. One IPC round trip (snapshot).
    static func run(app: XCUIApplication, language: A11yLanguage) throws -> [Finding] {
        let root = try app.snapshot()
        let window = root.frame
        var findings: [Finding] = []
        visit(root, parent: nil) { node, parent in
            guard interactiveTypes.contains(node.elementType), node.isEnabled else { return }
            let frame = node.frame
            guard !frame.isEmpty, window.intersects(frame) else { return }   // on screen now
            let id = node.identifier

            if !A11yExemptions.isExempt(.label, identifier: id, language: language) {
                for problem in A11yLabelLint.problems(label: node.label, identifier: id) {
                    findings.append(Finding(rule: "A11Y-VO-02", identifier: id, type: node.elementType,
                                            message: problem.description))
                }
            }
            // Segment buttons, switches, steppers and text fields: see frameCheckSkippedTypes.
            let skipFrame = frameCheckSkippedTypes.contains(node.elementType)
                || parent == .segmentedControl || parent == .stepper
            // A target clipped by the screen edge is only measured when fully on screen.
            if !skipFrame, window.contains(frame),
               !A11yExemptions.isExempt(.hitTarget, identifier: id, language: language),
               frame.width + tolerance < minTarget || frame.height + tolerance < minTarget {
                findings.append(Finding(rule: "A11Y-TGT-01", identifier: id, type: node.elementType,
                                        message: "target \(Int(frame.width))x\(Int(frame.height))pt < 44x44pt, label='\(node.label)'"))
            }
        }
        return findings
    }

    /// Depth-first walk with the parent's type; skips the software keyboard (system UI, not ours).
    private static func visit(_ node: any XCUIElementSnapshot, parent: XCUIElement.ElementType?,
                              _ body: (any XCUIElementSnapshot, XCUIElement.ElementType?) -> Void) {
        if node.elementType == .keyboard { return }
        body(node, parent)
        for child in node.children { visit(child, parent: node.elementType, body) }
    }

    /// Every on-screen element whose identifier starts with `prefix`: identifier -> "label value".
    static func elements(app: XCUIApplication, withPrefix prefix: String) -> [(id: String, text: String, type: XCUIElement.ElementType, frame: CGRect)] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [(id: String, text: String, type: XCUIElement.ElementType, frame: CGRect)] = []
        func walk(_ n: any XCUIElementSnapshot) {
            if n.identifier.hasPrefix(prefix) {
                let value = (n.value as? String) ?? ""
                out.append((n.identifier, [n.label, value].filter { !$0.isEmpty }.joined(separator: " "), n.elementType, n.frame))
            }
            n.children.forEach(walk)
        }
        walk(root)
        return out
    }

    /// Fingerprint of what is on screen; paging stops when a swipe no longer changes it.
    static func visibleFingerprint(app: XCUIApplication) -> String {
        guard let root = try? app.snapshot() else { return "" }
        var parts: [String] = []
        func walk(_ n: any XCUIElementSnapshot) {
            if root.frame.intersects(n.frame), !n.identifier.isEmpty || !n.label.isEmpty {
                parts.append("\(n.identifier)|\(n.label)|\(Int(n.frame.minY))")
            }
            n.children.forEach(walk)
        }
        walk(root)
        return parts.joined(separator: ";")
    }
}
