import Testing
@testable import ADAccessibility

@Suite("Label lint")
struct A11yLabelLintTests {
    @Test(arguments: ["household.add", "a11y.household.list", "card.detail.title", "card_detail_title",
                      "addPerson_save", "a11y.x", "Household.AddPerson",
                      // language codes are not TLDs here; underscores never appear in domains
                      "settings.language.ht", "surface.es", "fact_status.gov", "card.contact_us.gov"])
    func flagsRawKeys(_ s: String) {
        #expect(A11yLabelLint.looksLikeRawKey(s))
    }

    @Test(arguments: ["Agregar persona", "Add person", "Ajoute yon moun", "$0.66", "4.5", "U.S.", "p.m.",
                      "miamidade.gov", "311", "Claude Pepper", "Tomorrow · trash", "Kreyòl", "I-20", "OK"])
    func acceptsRealLabels(_ s: String) {
        #expect(!A11yLabelLint.looksLikeRawKey(s))
    }

    /// Dotted tokens ending in a real TLD are web addresses (source names), not leaked keys.
    @Test(arguments: ["www.uscis.gov", "dos.myflorida.com", "www.miamidade.gov", "flhsmv.gov", "usa.gov",
                      "portal.miamidade.us", "www.211.org", "Example.COM", "studyinthestates.dhs.gov",
                      "news.example.net", "www.fiu.edu", "status.github.io", "www.stateofflorida.info"])
    func acceptsDomains(_ s: String) {
        #expect(!A11yLabelLint.looksLikeRawKey(s))
        #expect(A11yLabelLint.problems(label: s, identifier: nil).isEmpty)
    }

    @Test func emptyAndIdentifierEquality() {
        #expect(A11yLabelLint.problems(label: "  ", identifier: nil) == [.empty])
        let p = A11yLabelLint.problems(label: "a11y.card.readAloud", identifier: "a11y.card.readAloud")
        #expect(p.contains(.equalsIdentifier("a11y.card.readAloud")))
        #expect(p.contains(.looksLikeRawKey("a11y.card.readAloud")))
        #expect(A11yLabelLint.problems(label: "Leer esta tarjeta", identifier: "a11y.card.readAloud").isEmpty)
    }
}

@Suite("Identifier contract")
struct A11yIDTests {
    @Test func identifiersAreUniqueAndWellFormed() {
        #expect(Set(A11yID.allStatic).count == A11yID.allStatic.count)
        for id in A11yID.allStatic {
            #expect(id.hasPrefix("a11y."), "\(id)")
            #expect(id.range(of: #"^a11y(\.[a-z][A-Za-z0-9]*)+$"#, options: .regularExpression) != nil, "\(id)")
        }
    }

    @Test func dynamicIdentifiers() {
        #expect(A11yID.Household.row("p1") == "a11y.household.row.p1")
        #expect(A11yID.Card.fact("us-fl-miamidade.311.phone") == "a11y.card.fact.us-fl-miamidade.311.phone")
        #expect(A11yID.Router.clarifyOption(2) == "a11y.router.clarify.option2")
    }

    @Test func micIsTheSameIdentifierEverywhere() {
        #expect(A11yID.Voice.mic == "a11y.voice.mic")
    }

    /// Onboarding has exactly ADCore's four steps; none is a status question.
    @Test func onboardingStepsAreTheFourQuestions() {
        #expect(A11yID.Onboarding.allSteps == [
            "a11y.onboarding.step.pin", "a11y.onboarding.step.people",
            "a11y.onboarding.step.originAndLanguage", "a11y.onboarding.step.goal",
        ])
        #expect(!A11yID.Onboarding.allSteps.contains { $0.lowercased().contains("status") })
    }

    /// One scheme: Lead's `identifier(forCard:)` and the UI tests' `A11yID.Cards.row` agree.
    @Test func cardIdentifierIsTheContractRow() {
        #expect(ADAccessibility.identifier(forCard: "tolls") == A11yID.Cards.row("tolls"))
    }
}
