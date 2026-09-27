import Foundation
import Testing
@testable import ADAccessibility

@Suite("String Catalog parity")
struct StringCatalogParityTests {
    let checker = StringCatalogParity()

    func check(_ json: String) throws -> [StringCatalogParity.Issue] {
        try checker.check(data: Data(json.utf8))
    }

    @Test func completeCatalogPasses() throws {
        let json = """
        { "sourceLanguage": "en", "version": "1.0", "strings": {
          "household.addPerson": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "Add person" } },
            "es": { "stringUnit": { "state": "translated", "value": "Agregar persona" } },
            "ht": { "stringUnit": { "state": "translated", "value": "Ajoute yon moun" } } } },
          "Claude Pepper Elementary": { "shouldTranslate": false },
          "old.key": { "extractionState": "stale" },
          "Save": { "localizations": {
            "es": { "stringUnit": { "state": "translated", "value": "Guardar" } },
            "ht": { "stringUnit": { "state": "translated", "value": "Anrejistre" } } } }
        } }
        """
        #expect(try check(json).isEmpty)
    }

    @Test func missingCreoleIsReported() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "card.readAloud": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "Read this card" } },
            "es": { "stringUnit": { "state": "translated", "value": "Leer esta tarjeta" } } } } } }
        """
        let issues = try check(json)
        #expect(issues.map(\.kind) == [.missing])
        #expect(issues.first?.language == "ht")
    }

    @Test func semanticKeyWithoutSourceValueIsReported() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "card.readAloud": { "localizations": {
            "es": { "stringUnit": { "state": "translated", "value": "Leer esta tarjeta" } },
            "ht": { "stringUnit": { "state": "translated", "value": "Li kat sa a" } } } } } }
        """
        #expect(try check(json).map(\.kind) == [.rawKeyAsSource])
    }

    @Test func emptyAndUntranslatedStatesAreReported() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "k.a": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "Trash" } },
            "es": { "stringUnit": { "state": "needs_review", "value": "Basura" } },
            "ht": { "stringUnit": { "state": "translated", "value": "  " } } } } } }
        """
        let kinds = Set(try check(json).map(\.kind))
        #expect(kinds == [.notTranslated, .empty])
        // needs_review can be allowed explicitly (e.g. while a translation pass is in progress)
        let lenient = StringCatalogParity(acceptedStates: ["translated", "needs_review"])
        #expect(try lenient.check(data: Data(json.utf8)).map(\.kind) == [.empty])
    }

    @Test func pluralVariationsMustAllBeFilled() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "people.count %lld": { "localizations": {
            "en": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "%lld person" } },
                "other": { "stringUnit": { "state": "translated", "value": "%lld people" } } } } },
            "es": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "%lld persona" } },
                "other": { "stringUnit": { "state": "translated", "value": "" } } } } },
            "ht": { "stringUnit": { "state": "translated", "value": "%lld moun" } } } } } }
        """
        let issues = try check(json)
        #expect(issues.count == 1)
        #expect(issues.first?.kind == .empty)
        #expect(issues.first?.path == "variations.plural.other.stringUnit")
    }

    @Test func formatSpecifierMismatchIsReported() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "toll.price": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "%1$@ with sticker, %2$@ by plate" } },
            "es": { "stringUnit": { "state": "translated", "value": "%1$@ con sticker, %2$@ por placa" } },
            "ht": { "stringUnit": { "state": "translated", "value": "%1$@ ak sticker" } } } } } }
        """
        let issues = try check(json)
        #expect(issues.map(\.kind) == [.formatMismatch])
        #expect(issues.first?.language == "ht")
    }

    @Test func formatSpecifierExtraction() {
        #expect(StringCatalogParity.formatSpecifiers(in: "%lld of %@ (100%%)") == ["%lld", "%@"])
        #expect(StringCatalogParity.formatSpecifiers(in: "%2$@ %1$lld") == ["%2$@", "%1$lld"])
    }

    /// Flags, width, and precision are part of one specifier, not text plus a bare conversion.
    @Test(arguments: [
        ("%.2f", ["%.2f"]), ("%02d", ["%02d"]), ("%5.1f", ["%5.1f"]), ("%-8@", ["%-8@"]),
        ("%+d", ["%+d"]), ("%'lld", ["%'lld"]), ("%1$.2f and %2$05lld", ["%1$.2f", "%2$05lld"]),
        ("%#@files@ in %1$#@folders@", ["%#@files@", "%1$#@folders@"]),
        ("%arg files", ["%arg"]), ("50% off, 100%% sure", [String]()),
    ])
    func specifiersWithFlagsWidthPrecision(_ s: String, _ expected: [String]) {
        #expect(StringCatalogParity.formatSpecifiers(in: s) == expected)
    }

    /// `%arg` is the substitution argument, never `%a` (hex float) followed by "rg".
    @Test func percentArgIsNotMisread() {
        #expect(StringCatalogParity.formatSignature(in: "%arg archivos") == ["arg"])
        #expect(StringCatalogParity.formatSignature(in: "%a") == ["1$f"])
        #expect(StringCatalogParity.formatSignature(in: "%args") == ["1$f"])   // not the %arg token
    }

    /// Positions are explicit or sequential; flags/width/precision do not matter; types do.
    @Test func signaturesArePositionAware() {
        typealias P = StringCatalogParity
        #expect(Set(P.formatSignature(in: "%@ paid %lld")) == Set(P.formatSignature(in: "%2$lld pagado por %1$@")))
        #expect(P.formatSignature(in: "%.2f") == P.formatSignature(in: "%5.1f"))
        #expect(P.formatSignature(in: "%02d") == ["1$d"])
        #expect(P.formatSignature(in: "%d") != P.formatSignature(in: "%lld"))
        #expect(P.formatSignature(in: "%@ %d") != P.formatSignature(in: "%d %@"))   // swapped types
        #expect(P.formatSignature(in: "%#@n@ de %@") == ["1$#@n@", "2$@"])
    }

    @Test func reorderingWithPositionalArgumentsPasses() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "paid.by %@ %lld": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "%1$@ paid %2$lld" } },
            "es": { "stringUnit": { "state": "translated", "value": "%2$lld pagado por %1$@" } },
            "ht": { "stringUnit": { "state": "translated", "value": "%@ peye %lld" } } } } } }
        """
        #expect(try check(json).isEmpty)
    }

    @Test func precisionDifferencesAreFineTypeDifferencesAreNot() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "toll.amount": { "localizations": {
            "en": { "stringUnit": { "state": "translated", "value": "$%.2f" } },
            "es": { "stringUnit": { "state": "translated", "value": "%5.1f dólares" } },
            "ht": { "stringUnit": { "state": "translated", "value": "%lld dola" } } } } } }
        """
        let issues = try check(json)
        #expect(issues.map(\.kind) == [.formatMismatch])
        #expect(issues.first?.language == "ht")
    }

    /// Every leaf is compared, not only the first: a plural `one` that drops %lld but keeps a
    /// non-positional %@ shifts that %@ to position 1 (a crash on device). Dropping args is fine.
    @Test func everyPluralLeafIsCompared() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "items.in %lld %@": { "localizations": {
            "en": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "One item in %2$@" } },
                "other": { "stringUnit": { "state": "translated", "value": "%lld items in %@" } } } } },
            "es": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "Un artículo en %@" } },
                "other": { "stringUnit": { "state": "translated", "value": "%lld artículos en %@" } } } } },
            "ht": { "variations": { "plural": {
                "other": { "stringUnit": { "state": "translated", "value": "%lld atik nan %@" } } } } } } } } }
        """
        let issues = try check(json)
        #expect(issues.count == 1)
        #expect(issues.first?.kind == .formatMismatch)
        #expect(issues.first?.language == "es")
        #expect(issues.first?.path == "variations.plural.one.stringUnit")
    }

    @Test func everyVariationGroupNeedsOther() throws {
        let json = """
        { "sourceLanguage": "en", "strings": { "people %lld": { "localizations": {
            "en": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "%lld person" } },
                "other": { "stringUnit": { "state": "translated", "value": "%lld people" } } } } },
            "es": { "variations": { "plural": {
                "one": { "stringUnit": { "state": "translated", "value": "%lld persona" } },
                "many": { "stringUnit": { "state": "translated", "value": "%lld personas" } } } } },
            "ht": { "variations": { "device": {
                "iphone": { "stringUnit": { "state": "translated", "value": "%lld moun" } } } } } } } } }
        """
        let missing = try check(json).filter { $0.kind == .missingOther }
        #expect(missing.map(\.language).sorted() == ["es", "ht"])
        #expect(Set(missing.map(\.path)) == ["variations.plural", "variations.device"])
    }

    @Test func substitutionsAreCheckedAndPercentArgAccepted() throws {
        func catalog(ht: String, htSubs: String = "files") -> String {
            """
            { "sourceLanguage": "en", "strings": { "files.count": { "localizations": {
                "en": { "stringUnit": { "state": "translated", "value": "%#@files@" },
                        "substitutions": { "files": { "argNum": 1, "formatSpecifier": "lld", "variations": { "plural": {
                          "one": { "stringUnit": { "state": "translated", "value": "%arg file" } },
                          "other": { "stringUnit": { "state": "translated", "value": "%arg files" } } } } } } },
                "es": { "stringUnit": { "state": "translated", "value": "%#@files@" },
                        "substitutions": { "files": { "argNum": 1, "formatSpecifier": "lld", "variations": { "plural": {
                          "one": { "stringUnit": { "state": "translated", "value": "%arg archivo" } },
                          "other": { "stringUnit": { "state": "translated", "value": "%arg archivos" } } } } } } },
                "ht": { "stringUnit": { "state": "translated", "value": "\(ht)" },
                        "substitutions": { "\(htSubs)": { "argNum": 1, "formatSpecifier": "lld", "variations": { "plural": {
                          "other": { "stringUnit": { "state": "translated", "value": "%arg fichye" } } } } } } } } } } }
            """
        }
        #expect(try check(catalog(ht: "%#@files@")).isEmpty)
        // Renamed token: differs from the reference and has no matching substitution.
        let renamed = try check(catalog(ht: "%#@fichye@", htSubs: "fichye"))
        #expect(renamed.count == 1 && renamed.first?.kind == .formatMismatch && renamed.first?.language == "ht")
        let dangling = try check(catalog(ht: "%#@files@", htSubs: "other_name"))
        #expect(dangling.map(\.kind) == [.formatMismatch])
        #expect(dangling.first?.detail.contains("no substitutions.files") == true)
    }

    @Test func languageListParsing() {
        #expect(StringCatalogParity.parseLanguages("es,en,ht") == ["es", "en", "ht"])
        #expect(StringCatalogParity.parseLanguages(" es , ht ") == ["es", "ht"])
        #expect(StringCatalogParity.parseLanguages("") == nil)
        #expect(StringCatalogParity.parseLanguages(",") == nil)
        #expect(StringCatalogParity.parseLanguages("es,,ht") == nil)
        #expect(StringCatalogParity.parseLanguages("es, ") == nil)
    }

    @Test func notACatalogThrows() {
        #expect(throws: StringCatalogParity.LoadError.self) { try check("[1,2]") }
        #expect(throws: StringCatalogParity.LoadError.self) { try check(#"{"version":"1.0"}"#) }
    }
}
