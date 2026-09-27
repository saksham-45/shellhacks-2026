// XCODE-ONLY. UI test target `MyAmericanDreamUITests`. Runs on an iOS 18+ simulator on the captain's Mac.
// performAccessibilityAudit (iOS 17+): https://developer.apple.com/videos/play/wwdc2023/10035/
// Rules referenced: docs/accessibility.md (A11Y-*). Helpers: A11yUITestSupport.swift.

import ADAccessibility
import ADCore
import XCTest

@MainActor
final class AccessibilityAuditTests: XCTestCase {

    /// Scroll pages checked per screen (audits only see on-screen elements; AX5 pushes most content off).
    /// Reaching this while the screen still changes is a failure: part of the screen went unchecked.
    private let maxPages = 12

    // MARK: Audit sweeps: every screen x {es, en, ht} x {default, AX5}

    func test_audit_es_default() throws { try sweep(A11yLaunch(language: .es, size: .standard)) }
    func test_audit_es_AX5() throws { try sweep(A11yLaunch(language: .es, size: .ax5)) }
    func test_audit_en_default() throws { try sweep(A11yLaunch(language: .en, size: .standard)) }
    func test_audit_en_AX5() throws { try sweep(A11yLaunch(language: .en, size: .ax5)) }
    func test_audit_ht_default() throws { try sweep(A11yLaunch(language: .ht, size: .standard)) }
    func test_audit_ht_AX5() throws { try sweep(A11yLaunch(language: .ht, size: .ax5)) }

    // MARK: Contract checks

    /// Exemptions must name one screen at least (`a11y.<screen>.`), never "" or "a11y.". No app launch.
    func test_exemptionsAreWellFormed() {
        for exemption in A11yExemptions.all {
            if let problem = exemption.problem { XCTFail("Bad exemption: \(problem)") }
        }
        // The guard itself: these shapes are rejected.
        let bad = ["", " ", "a11y", "a11y.", "a11y.card", "card.fact.", "a11y.nowhere.x", "a11y.card..x"]
        for id in bad {
            let e = A11yExemption(check: .label, identifier: id, language: nil, reason: "r", owner: "o")
            XCTAssertNotNil(e.problem, "exemption identifier '\(id)' should be rejected")
            XCTAssertFalse(e.matches(.label, identifier: "a11y.card.title", language: .en))
        }
        let ok = A11yExemption(check: .label, identifier: "a11y.card.fact.", language: nil, reason: "r", owner: "o")
        XCTAssertNil(ok.problem)
    }

    /// A11Y-L10N-02: the surface really switches. Catches an ht (or es) build silently falling back to the
    /// development language, which String Catalogs do when a translation is missing.
    func test_surfaceLanguageChangesVisibleLabels() throws {
        continueAfterFailure = true
        var labels: [A11yLanguage: [String]] = [:]
        for language in A11yLanguage.allCases {
            let app = launch(A11yLaunch(language: language, size: .standard))
            try skipIfAppIDsPending(app)
            let nav = A11yNavigator(app: app)
            guard nav.waitFor(A11yID.Household.list) else { app.terminate(); continue }
            labels[language] = [A11yID.Household.addPerson, A11yID.Household.settings, A11yID.Household.cards,
                                A11yID.Voice.mic]
                .map { nav.element($0).label }
            app.terminate()
        }
        guard let es = labels[.es], let en = labels[.en], let ht = labels[.ht] else { return }
        for i in es.indices {
            XCTAssertNotEqual(es[i], en[i], "es and en labels identical ('\(es[i])'): untranslated?")
            XCTAssertNotEqual(ht[i], en[i], "ht label equals en ('\(ht[i])'): Creole fell back to English")
            XCTAssertNotEqual(ht[i], es[i], "ht label equals es ('\(ht[i])'): Creole fell back to Spanish")
        }
    }

    /// A11Y-SPK-01 / A11Y-VO-04 / A11Y-FACT-01/02 / A11Y-LIT-04 on the seeded phone card, in every language.
    /// Scope = the demo seed (docs §9): `.shown` (verified/stale/demo) and `.handedToDesk` lines. No source
    /// names are invented here; the slot is checked by its localized lead-in from ADCore's catalog.
    func test_cardDetailContract() throws {
        continueAfterFailure = true
        for language in A11yLanguage.allCases {
            let app = launch(A11yLaunch(language: language, size: .standard))
            try skipIfAppIDsPending(app)
            let nav = A11yNavigator(app: app)
            guard nav.goToCard(A11ySeed.phoneCardID) else { app.terminate(); continue }

            // Read-this-card action exists, is a button, and has a real label.
            let read = nav.element(A11yID.Card.readAloud)
            XCTAssertTrue(read.waitForExistence(timeout: 5), "[\(language)] card has no read-aloud control")
            if read.exists {
                XCTAssertEqual(read.elementType, .button, "[\(language)] read-aloud must be a button")
                XCTAssertTrue(A11yLabelLint.problems(label: read.label, identifier: read.identifier).isEmpty,
                              "[\(language)] read-aloud label '\(read.label)'")
            }

            // The slot lead-ins this surface must show (ADCore keys, resolved in `language`).
            let keys = FactSlot.seedLeadInKeys
            let leadIns = keys.compactMap { A11yCatalog.resolve($0, in: language) }
            if leadIns.count < keys.count {
                let missing = keys.filter { A11yCatalog.resolve($0, in: language) == nil }.map(\.key)
                XCTFail("[\(language)] ADCore catalog has no \(language) value for \(missing) (myAD Language)")
            }

            // Page the whole card slowly; collect every combined fact element and the call action.
            var facts: [String: String] = [:]
            var call: (type: XCUIElement.ElementType, text: String)?
            let reachedEnd = nav.forEachPage(of: .cardDetail, maxPages: maxPages) { _ in
                for e in A11yCustomChecks.elements(app: app, withPrefix: A11yID.Card.factPrefix) { facts[e.id] = e.text }
                if call == nil, let c = A11yCustomChecks.elements(app: app, withPrefix: A11yID.Card.call).first(where: { $0.id == A11yID.Card.call }) {
                    call = (c.type, c.text)
                }
            }
            XCTAssertTrue(reachedEnd, "[\(language)] card detail still scrolling after \(maxPages) pages: facts beyond were not checked")

            // Each fact: non-empty id, one combined element whose label/value carries the source slot.
            XCTAssertFalse(facts.isEmpty, "[\(language)] seeded card '\(A11ySeed.phoneCardID)' shows no a11y.card.fact.<id> element")
            for (id, text) in facts.sorted(by: { $0.key < $1.key }) {
                let factID = String(id.dropFirst(A11yID.Card.factPrefix.count))
                XCTAssertFalse(factID.trimmingCharacters(in: .whitespaces).isEmpty, "[\(language)] fact element with empty id '\(id)'")
                XCTAssertTrue(A11yLabelLint.problems(label: text, identifier: id).isEmpty,
                              "[\(language)] fact '\(factID)' label '\(text)'")
                XCTAssertTrue(leadIns.contains { text.localizedCaseInsensitiveContains($0) },
                              "[\(language)] fact '\(factID)' reads '\(text)' with no source slot (expected one of \(leadIns); A11Y-FACT-01/02)")
            }

            // The seeded card must offer the call action (docs §9, A11Y-LIT-04): a button or link.
            if let call {
                XCTAssertTrue([XCUIElement.ElementType.button, .link].contains(call.type),
                              "[\(language)] a11y.card.call is not a button/link (A11Y-LIT-04)")
                XCTAssertTrue(A11yLabelLint.problems(label: call.text, identifier: A11yID.Card.call).isEmpty,
                              "[\(language)] call label '\(call.text)'")
            } else {
                XCTFail("[\(language)] seeded phone card '\(A11ySeed.phoneCardID)' has no a11y.card.call (A11Y-LIT-04)")
            }
            app.terminate()
        }
    }

    /// A11Y-LANG-03 part 3 (Play in Kreyòl) and A11Y-VC-04 (Magic Tap), on the Kreyòl surface.
    ///
    /// What XCUITest can and cannot see (checked 2026-09-25): `XCUIElement` has no accessibility custom-action
    /// API (no list, no perform), and Xcode 27's `XCUIVoiceOverService` (iOS 27+) only enables VoiceOver, moves
    /// focus, and returns speech. Neither can synthesize Magic Tap. So this test automates the parts it can
    /// observe and then SKIPS with the manual step: the presence of a custom action named exactly the ADVoice
    /// `kreyol.play` value ("Jwe an Kreyòl") on every ht card row and card detail, its playback, the no-recording notice, and
    /// Magic Tap are Manual M11 (and M10 for Magic Tap elsewhere), docs/accessibility.md §11. Any failure
    /// recorded before the skip still fails the test.
    func test_creoleCardsOfferPlayInKreyol() throws {
        continueAfterFailure = true

        // 1) The action name is ADVoice's `kreyol.play` (the retired a11y.card.playInKreyol is not used): read from
        //    ADVoice's catalog JSON when the runner can see it, else from the mirrored table; ht plus es/en names.
        let catalog = ADVoiceKreyolPlay.catalogValues()
        if let catalog {
            for language in A11yLanguage.allCases where catalog[language] != ADVoiceKreyolPlay.expected[language] {
                XCTFail("[\(language)] ADVoice '\(ADVoiceKreyolPlay.key)' is '\(catalog[language] ?? "nil")' but "
                        + "ADVoiceKreyolPlay.expected says '\(ADVoiceKreyolPlay.expected[language] ?? "nil")': update the "
                        + "mirror with myAD Language (docs A11Y-LANG-03 part 3)")
            }
        } else {
            let note = XCTAttachment(string: "ADVoice.xcstrings not readable at \(ADVoiceKreyolPlay.catalogURL().path) "
                                     + "(device run?): action names taken from ADVoiceKreyolPlay.expected.")
            note.name = "Play in Kreyòl name source"
            note.lifetime = .keepAlways
            add(note)
        }
        let names = Dictionary(uniqueKeysWithValues: A11yLanguage.allCases.map { ($0, A11yCatalog.playInKreyol(in: $0)) })
        for (language, name) in names {
            guard let name else {
                XCTFail("[\(language)] ADVoice '\(ADVoiceKreyolPlay.key)' has no \(language) value (table "
                        + "\(ADVoiceKreyolPlay.table)); a parity gap for myAD Language")
                continue
            }
            XCTAssertTrue(A11yLabelLint.problems(label: name, identifier: nil).isEmpty, "[\(language)] action name '\(name)'")
            XCTAssertTrue(name.contains("Kreyòl"), "[\(language)] action name '\(name)' must keep the autonym 'Kreyòl'")
        }
        if let ht = names[.ht] ?? nil, let en = names[.en] ?? nil {
            XCTAssertNotEqual(ht, en, "ht action name equals en ('\(ht)'): Creole fell back to English")
        }
        let expected = (names[.ht] ?? nil) ?? "?"

        // 2) Kreyòl surface: every card row is reachable and labeled (Creole text is never hidden from VoiceOver).
        let app = launch(A11yLaunch(language: .ht, size: .standard))
        try skipIfAppIDsPending(app)
        let nav = A11yNavigator(app: app)
        guard nav.go(to: .cards) else { app.terminate(); return }
        var rows: [String: String] = [:]
        let reachedEnd = nav.forEachPage(of: .cards, maxPages: maxPages) { _ in
            for e in A11yCustomChecks.elements(app: app, withPrefix: A11yID.Cards.rowPrefix) { rows[e.id] = e.text }
        }
        XCTAssertTrue(reachedEnd, "[ht] card list still scrolling after \(maxPages) pages: rows beyond were not checked")
        XCTAssertFalse(rows.isEmpty, "[ht] the card list shows no a11y.cards.row.<id> element")
        for (id, text) in rows.sorted(by: { $0.key < $1.key }) {
            XCTAssertTrue(A11yLabelLint.problems(label: text, identifier: id).isEmpty,
                          "[ht] card row '\(id)' reads '\(text)': Creole text must be exposed, never hidden or a key")
        }
        app.terminate()

        // 3) One card detail (the seeded phone card): title and facts are exposed in Creole.
        let detail = launch(A11yLaunch(language: .ht, size: .standard))
        let detailNav = A11yNavigator(app: detail)
        if detailNav.goToCard(A11ySeed.phoneCardID) {
            let title = detailNav.element(A11yID.Card.title)
            XCTAssertTrue(title.exists && !title.label.trimmingCharacters(in: .whitespaces).isEmpty,
                          "[ht] card title is missing or hidden from VoiceOver (A11Y-LANG-03 part 2)")
            XCTAssertFalse(A11yCustomChecks.elements(app: detail, withPrefix: A11yID.Card.factPrefix).isEmpty,
                           "[ht] card detail exposes no fact element")
        }
        detail.terminate()

        // 4) The custom action itself: not observable from XCUITest. Hand the exact list to Manual M11.
        let checklist = (rows.keys.sorted() + [A11yID.Card.list + " (" + A11ySeed.phoneCardID + ")"])
            .map { "\($0): rotor Actions lists '\(expected)'; it plays the reviewed clip or announces the no-recording notice" }
            .joined(separator: "\n")
        let attachment = XCTAttachment(string: "Manual M11 (VoiceOver on, Kreyòl surface):\n" + checklist
                                       + "\nMagic Tap on a focused ht card plays it; elsewhere it toggles listening (M10).")
        attachment.name = "M11 Play in Kreyòl checklist"
        attachment.lifetime = .keepAlways
        add(attachment)
        throw XCTSkip("Play in Kreyòl: catalog name and Creole rows checked. XCUITest cannot list or perform custom "
                      + "actions or synthesize Magic Tap; verify '\(expected)' on every ht card by Manual M11 "
                      + "(checklist attached), Magic Tap by M10/M11.")
    }

    // MARK: - Sweep implementation

    private func sweep(_ config: A11yLaunch) throws {
        continueAfterFailure = true
        var householdMissing = false
        for screen in A11yScreen.allCases {
            // Every demoHousehold screen is reached from the household root; after one clear failure, only
            // the screens that do not need it (onboarding) still run.
            if householdMissing, screen.seed == A11ySeed.demoHousehold { continue }
            // Fresh launch per screen: one broken screen cannot hide problems on the next.
            var launchConfig = config
            launchConfig.seed = screen.seed
            launchConfig.screen = screen.launchRoute   // only the clarify overlay needs a route (docs §9)
            let app = launch(launchConfig)
            let nav = A11yNavigator(app: app)
            if screen == .household, !nav.element(A11yID.Household.list).waitForExistence(timeout: nav.timeout) {
                app.terminate()
                if A11yPending.appIDs {
                    throw XCTSkip("[\(config.name)] \(A11yPending.appIDsVariable)=1 and '\(A11yID.Household.list)' did not "
                                  + "appear \(Int(nav.timeout)) s after launch: the app views do not set the A11yID contract yet "
                                  + "(docs/accessibility.md §9). Audit sweep skipped; unset \(A11yPending.appIDsVariable) in the "
                                  + "test plan once the views ship.")
                }
                XCTFail("[\(config.name)] '\(A11yID.Household.list)' did not appear \(Int(nav.timeout)) s after launch "
                        + "(identifier contract, docs/accessibility.md §9). Screens reached from the household are not "
                        + "audited. Set \(A11yPending.appIDsVariable)=1 in the test plan only while the views are not written.")
                householdMissing = true
                continue
            }
            XCTContext.runActivity(named: "\(config.name) \(screen.rawValue)") { _ in
                guard nav.go(to: screen) else { return }
                // Voice-first: the mic is on every screen with a real label (A11Y-VC-05).
                let mic = nav.element(A11yID.Voice.mic)
                XCTAssertTrue(mic.exists, "[\(config.name) \(screen.rawValue)] no a11y.voice.mic on this screen")
                if mic.exists {
                    XCTAssertTrue(A11yLabelLint.problems(label: mic.label, identifier: mic.identifier).isEmpty,
                                  "[\(config.name) \(screen.rawValue)] mic label '\(mic.label)'")
                }
                auditAllPages(app: app, nav: nav, screen: screen, config: config)
            }
            app.terminate()
        }
    }

    private func auditAllPages(app: XCUIApplication, nav: A11yNavigator, screen: A11yScreen, config: A11yLaunch) {
        let reachedEnd = nav.forEachPage(of: screen, maxPages: maxPages) { page in
            let tag = "\(config.name) \(screen.rawValue) p\(page)"

            // 1) Apple's audit: all iOS types (contrast, dynamicType, elementDetection, hitRegion,
            //    sufficientElementDescription, textClipped, trait).
            do {
                try app.performAccessibilityAudit(for: .all) { issue in
                    let id = issue.element?.identifier ?? ""
                    let ignore = A11yExemptions.isExempt(.audit(issue.auditType), identifier: id, language: config.language)
                    if !ignore {
                        // Context for triage in the test report; the audit itself records the failure.
                        print("A11Y-AUDIT \(tag) type=\(issue.auditType.rawValue) id=\(id) \(issue.compactDescription)")
                    }
                    return ignore
                }
            } catch {
                XCTFail("[\(tag)] audit could not run: \(error)")
            }

            // 2) Our checks: labels (non-empty, not identifier, not raw key) and 44x44 targets.
            do {
                for finding in try A11yCustomChecks.run(app: app, language: config.language) {
                    XCTFail("[\(tag)] \(finding)")
                }
            } catch {
                XCTFail("[\(tag)] snapshot failed: \(error)")
            }

            attachScreenshot(app: app, name: tag, keep: config.size == .ax5)
        }
        if !reachedEnd {
            XCTFail("[\(config.name) \(screen.rawValue)] still scrolling after \(maxPages) pages: the rest was not audited")
        }
    }

    // MARK: - Helpers

    private func launch(_ config: A11yLaunch) -> XCUIApplication {
        let app = XCUIApplication()   // target application = MyAmericanDream (set in the UI test target)
        app.launchArguments = config.arguments
        app.launch()
        return app
    }

    /// AX5 screenshots are kept on success too: they are the evidence for manual check M5.
    private func attachScreenshot(app: XCUIApplication, name: String, keep: Bool) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = keep ? .keepAlways : .deleteOnSuccess
        add(attachment)
    }
}

extension AccessibilityAuditTests {
    /// While MYAD_APP_IDS_PENDING=1, a missing Household anchor skips (views not written yet) instead of
    /// failing. Unset, this does nothing and the navigator's own XCTFail reports the gap.
    func skipIfAppIDsPending(_ app: XCUIApplication) throws {
        guard A11yPending.appIDs else { return }
        if A11yNavigator(app: app).element(A11yID.Household.list).waitForExistence(timeout: 10) { return }
        app.terminate()
        throw XCTSkip("\(A11yPending.appIDsVariable)=1 and '\(A11yID.Household.list)' did not appear "
                      + "(docs/accessibility.md §9). Unset it in the test plan once the views ship.")
    }
}
