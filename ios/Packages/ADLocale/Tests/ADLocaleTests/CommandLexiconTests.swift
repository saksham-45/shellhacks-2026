import XCTest
@testable import ADLocale

final class CommandLexiconTests: XCTestCase {
    let lexicon = try! CommandLexicon.bundled()

    func testKeySetsEqualLeadsContract() throws {
        let url = try XCTUnwrap(contractFile(), "contracts/intent/command_keys.json not found")
        struct Contract: Decodable { var command_keys: [String] }
        let keys = Set(try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url)).command_keys)
        XCTAssertTrue(keys.contains("ordinal_first"))
        for l in SurfaceLanguage.allCases { XCTAssertEqual(lexicon.commandKeys(l), keys, l.rawValue) }
    }

    func testNoEmptyListsNoConflicts() {
        for (l, table) in lexicon.tables {
            XCTAssertTrue(table.conflicts.isEmpty, "\(l): \(table.conflicts)")
            for (k, phrases) in table.commands { XCTAssertFalse(phrases.isEmpty, "\(l) \(k)") }
        }
    }

    func testCreolePhrasesAreAllMarkedForReview() {
        XCTAssertTrue(lexicon.tables[.ht]!.commands.values.joined().allSatisfy(\.needsReview))
        XCTAssertEqual(lexicon.needsReviewCounts[.en], 0)
    }

    func testSwitchLanguageFromAnySurface() {
        for l in SurfaceLanguage.allCases {
            XCTAssertEqual(lexicon.command(for: "Kreyòl", language: l)?.command, "switch_language_ht", l.rawValue)
            XCTAssertEqual(lexicon.command(for: "kreyol", language: l)?.command, "switch_language_ht", l.rawValue)
            XCTAssertEqual(lexicon.command(for: "en español", language: l)?.command, "switch_language_es", l.rawValue)
            XCTAssertEqual(lexicon.command(for: "English", language: l)?.command, "switch_language_en", l.rawValue)
        }
    }

    func testNormalizationAndFillers() {
        XCTAssertEqual(lexicon.command(for: "¿Qué dijiste?", language: .es)?.command, "repeat")
        XCTAssertEqual(lexicon.command(for: "que dijiste", language: .es)?.command, "repeat")
        XCTAssertEqual(lexicon.command(for: "Go back, please.", language: .en)?.command, "back")
        XCTAssertEqual(lexicon.command(for: "Dale", language: .es)?.command, "yes")
        XCTAssertEqual(lexicon.command(for: "the second one", language: .en)?.command, "ordinal_second")
        XCTAssertEqual(lexicon.command(for: "la tercera", language: .es)?.command, "ordinal_third")
        XCTAssertEqual(lexicon.command(for: "tanpri tounen", language: .ht)?.command, "back")
        // Creole spelling variants: long and short pronouns match each other.
        XCTAssertEqual(lexicon.command(for: "li l pou m", language: .ht)?.command, "read_this")
        XCTAssertEqual(lexicon.command(for: "montre mwen kat la", language: .ht)?.command, "open_map")
    }

    func testMatchReportsLanguage() {
        let m = lexicon.match("no")
        XCTAssertEqual(Set(m.map(\.language)), [.es, .en])
        XCTAssertTrue(m.allSatisfy { $0.command == "no" })
        XCTAssertEqual(lexicon.match("wi").map(\.language), [.ht])
        XCTAssertTrue(lexicon.match("where do I get my kid's shots").isEmpty)
        XCTAssertTrue(lexicon.match("   ").isEmpty)
    }

    func testMalformedFilesAreRejected() {
        XCTAssertThrowsError(try CommandLexicon(files: [.es: Data(#"{"language":"en","commands":{}}"#.utf8)]))
        XCTAssertThrowsError(try CommandLexicon(files: [.es: Data("nope".utf8)]))
    }
}
