import Foundation
import Testing
import ADCore
@testable import ADRouter

@Suite("Golden intent files (contracts/intent)")
struct GoldenTests {
    static let kinds = ["destination", "app_action", "intent_resolution", "utterance"]

    static func goldenFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Paths.intent, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && kinds.contains(String($0.lastPathComponent.split(separator: ".")[0])) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func roundTrip<T: Codable>(_ type: T.Type, _ value: JSONValue, raw: Data) throws -> JSONValue {
        // Re-extract the "value" member as bytes, decode it as T, encode, and parse back.
        let object = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        let valueData = try JSONSerialization.data(withJSONObject: object["value"]!, options: [.fragmentsAllowed])
        let decoded = try IntentWire.decoder.decode(T.self, from: valueData)
        return try JSONValue.parse(try IntentWire.encoder.encode(decoded))
    }

    @Test func everyGoldenFileDecodesAndReencodesToTheSameJSON() throws {
        let files = try Self.goldenFiles()
        #expect(files.count >= 40)
        for file in files {
            let raw = try Data(contentsOf: file)
            let doc = try JSONValue.parse(raw)
            let value = try #require(doc["value"], "\(file.lastPathComponent) has no value")
            let kind = try #require(doc["type"]?.string)
            let again: JSONValue
            switch kind {
            case "destination": again = try Self.roundTrip(Destination.self, value, raw: raw)
            case "app_action": again = try Self.roundTrip(AppAction.self, value, raw: raw)
            case "intent_resolution": again = try Self.roundTrip(IntentResolution.self, value, raw: raw)
            case "utterance": again = try Self.roundTrip(Utterance.self, value, raw: raw)
            default: Issue.record("unknown kind \(kind)"); continue
            }
            #expect(again == value, "\(file.lastPathComponent) is not byte-stable as JSON")
        }
    }

    /// Every Destination case and every AppAction case has at least one golden file.
    @Test func goldensCoverEveryCase() throws {
        var destinationTypes = Set<String>(), actionTypes = Set<String>(), mapTargets = Set<String>()
        var resolutionNames = Set<String>()
        for file in try Self.goldenFiles() {
            let doc = try JSONValue.parse(try Data(contentsOf: file))
            let name = file.deletingPathExtension().lastPathComponent
            switch doc["type"]?.string {
            case "destination": destinationTypes.insert(doc["value"]?["type"]?.string ?? "")
            case "app_action":
                let t = doc["value"]?["type"]?.string ?? ""
                actionTypes.insert(t)
                if t == "open_map" { mapTargets.insert(doc["value"]?["target"]?["type"]?.string ?? "") }
            case "intent_resolution": resolutionNames.insert(name)
            default: break
            }
        }
        #expect(destinationTypes == ["household", "person", "add_person", "edit_person", "onboarding", "stage", "card", "cards",
                                     "desk", "pin", "settings", "language", "voice"])
        #expect(actionTypes == ["navigate", "back", "home", "read_aloud", "stop_speaking", "repeat_last", "next_step",
                                "previous_step", "call_desk", "open_map", "set_surface_language", "set_think_in",
                                "answer_onboarding", "choose", "set_pin", "set_mode", "confirm",
                                "save_person", "delete_person", "undo"])
        #expect(mapTargets == ["desk", "place"])
        #expect(resolutionNames.isSuperset(of: ["intent_resolution.confident_navigate", "intent_resolution.card_grounding",
                                                "intent_resolution.desk_handoff", "intent_resolution.clarification_three_options",
                                                "intent_resolution.low_confidence"]))
    }

    @Test func clarificationWithFourOptionsDoesNotDecode() throws {
        let option = #"{"id":"x%d","label":{"key":"k","table":"ADRouter"},"action":{"type":"back"}}"#
        let four = (1...4).map { String(format: option, $0) }.joined(separator: ",")
        let json = #"{"question":{"key":"q","table":"ADRouter"},"options":[\#(four)]}"#
        #expect(throws: DecodingError.self) { try IntentWire.decoder.decode(Clarification.self, from: Data(json.utf8)) }
        let one = #"{"question":{"key":"q","table":"ADRouter"},"options":[\#(String(format: option, 1))]}"#
        #expect(throws: DecodingError.self) { try IntentWire.decoder.decode(Clarification.self, from: Data(one.utf8)) }
    }

    @Test func clarificationInitEnforcesTwoOrThree() {
        let o = { (i: Int) in ClarifyOption(id: ClarifyOptionID(rawValue: "o\(i)"), label: RouterText.opened, action: .back) }
        #expect(throws: ClarificationError.optionCount(1)) { try Clarification(question: RouterText.opened, options: [o(1)]) }
        #expect(throws: ClarificationError.optionCount(4)) { try Clarification(question: RouterText.opened, options: (1...4).map(o)) }
        #expect(throws: ClarificationError.duplicateOption("o1")) { try Clarification(question: RouterText.opened, options: [o(1), o(1)]) }
        #expect((try? Clarification(question: RouterText.opened, options: [o(1), o(2)])) != nil)
        #expect((try? Clarification(question: RouterText.opened, options: (1...3).map(o))) != nil)
    }

    @Test func confidenceOutsideZeroToOneDoesNotDecode() {
        let json = #"{"action":null,"grounding":null,"confidence":1.5,"clarification":null,"reply_language":"en"}"#
        #expect(throws: DecodingError.self) { try IntentWire.decoder.decode(IntentResolution.self, from: Data(json.utf8)) }
    }
}
