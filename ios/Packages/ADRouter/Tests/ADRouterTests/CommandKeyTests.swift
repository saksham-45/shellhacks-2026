import Foundation
import Testing
import ADCore
@testable import ADRouter

@Suite("Command keys (contracts/intent/command_keys.json)")
struct CommandKeyTests {
    static func canonicalKeys() throws -> [String] {
        struct File: Decodable { let version: Int; let command_keys: [String] }
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: Paths.intent.appendingPathComponent("command_keys.json"))).command_keys
    }

    @Test func routerKeysAreExactlyTheCanonicalKeys() throws {
        #expect(Set(try Self.canonicalKeys()) == Set(CommandKey.allCases.map(\.rawValue)))
        #expect(try Self.canonicalKeys().count == CommandKey.allCases.count)
    }

    @Test func everyCanonicalKeyMapsToAnAction() throws {
        let context = RouteContext(destination: .card("tolls", person: nil), cardID: "tolls", deskID: "test.desk.311",
                                   choiceIDs: ["a", "b", "c"], awaitingConfirmation: true)
        for raw in try Self.canonicalKeys() {
            let key = try #require(CommandKey(rawValue: raw), "no CommandKey for \(raw)")
            #expect(key.action(in: context) != nil, "\(raw) maps to no action")
        }
    }

    @Test func testLexiconUsesExactlyTheCanonicalKeysInEveryLanguage() throws {
        let canonical = Set(try Self.canonicalKeys())
        for language in ["en", "es", "ht"] {
            #expect(Set(testLexicon.table[language]!.keys) == canonical, "\(language)")
        }
    }

    @Test func keyNameLexiconIsEnglishOnly() {
        #expect(KeyNameLexicon().phrases(for: .nextStep, language: "en") == ["next step"])
        #expect(KeyNameLexicon().phrases(for: .nextStep, language: "es").isEmpty)
        #expect(KeyNameLexicon().phrases(for: .nextStep, language: "ht").isEmpty)
    }

    @Test func contextFreeKeysNeedNoContextAndContextKeysNeedIt() {
        let empty = RouteContext()
        #expect(CommandKey.callDesk.action(in: empty) == nil)
        #expect(CommandKey.openMap.action(in: empty) == nil)
        #expect(CommandKey.ordinalFirst.action(in: empty) == nil)
        #expect(CommandKey.readThis.action(in: empty) == .readAloud(.screen))
        #expect(CommandKey.ordinalThird.action(in: RouteContext(choiceIDs: ["a", "b"])) == nil)
    }
}
