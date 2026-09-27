import ADCore
import ADLocale
import ADRouter
import Foundation
import XCTest

@testable import ADAgentsClient

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class ADAgentsClientTests: XCTestCase {
  private var root: URL {
    // #filePath -> package/Tests/ADAgentsClientTests/this-file.swift; goldens live at repo root.
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private func data(_ relativePath: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(relativePath))
  }

  private func goldenObject(_ relativePath: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: data(relativePath))
    return try XCTUnwrap(object as? [String: Any])
  }

  private func goldenValueData(_ relativePath: String) throws -> Data {
    let object = try goldenObject(relativePath)
    let value = try XCTUnwrap(object["value"])
    return try JSONSerialization.data(withJSONObject: value)
  }

  func testEveryIntentGoldenDecodes() throws {
    let directory = root.appendingPathComponent("contracts/intent")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertEqual(files.count, 51)
    for file in files {
      let name = file.lastPathComponent
      if name == "command_keys.json" {
        struct CommandKeys: Decodable {
          let version: Int
          let commandKeys: [String]
          enum CodingKeys: String, CodingKey {
            case version
            case commandKeys = "command_keys"
          }
        }
        _ = try JSONDecoder().decode(CommandKeys.self, from: Data(contentsOf: file))
      } else if name.hasPrefix("app_action.") {
        _ = try IntentWire.decoder.decode(
          AppAction.self, from: goldenValueData("contracts/intent/" + name))
      } else if name.hasPrefix("destination.") {
        _ = try IntentWire.decoder.decode(
          Destination.self, from: goldenValueData("contracts/intent/" + name))
      } else if name.hasPrefix("intent_resolution.") {
        _ = try IntentWire.decoder.decode(
          IntentResolution.self, from: goldenValueData("contracts/intent/" + name))
      } else if name == "utterance.with_context.json" {
        _ = try IntentWire.decoder.decode(
          Utterance.self, from: goldenValueData("contracts/intent/" + name))
      } else {
        XCTFail("unhandled intent golden \(name)")
      }
    }
  }

  func testEveryV1GoldenDecodes() throws {
    let directory = root.appendingPathComponent("contracts/v1")
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    XCTAssertEqual(files.count, 9)
    for file in files {
      switch file.lastPathComponent {
      case "README.md": continue
      case "ask.request.json":
        // Encode the same wire model AgentsAPI.resolve uses; the golden ids are opaque examples,
        // so this assertion intentionally compares the contract's key shape.
        let request = ResolveRequest(
          requestID: "0example0request0id0000000000001",
          text: "¿cuándo pasa el example truck?",
          language: "es",
          context: RouteContext(
            destination: .household,
            personID: PersonID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            cardID: CardID(rawValue: "example-card")),
          stage: .safeThisWeek,
          mode: .resident)
        let actual = try XCTUnwrap(
          try JSONSerialization.jsonObject(with: IntentWire.encoder.encode(request))
            as? [String: Any])
        let golden = try goldenObject("contracts/v1/ask.request.json")
        XCTAssertEqual(Set(actual.keys), Set(golden.keys))
        let actualUtterance = try XCTUnwrap(actual["utterance"] as? [String: Any])
        let goldenUtterance = try XCTUnwrap(golden["utterance"] as? [String: Any])
        XCTAssertEqual(Set(actualUtterance.keys), Set(goldenUtterance.keys))
        let actualContext = try XCTUnwrap(actualUtterance["context"] as? [String: Any])
        let goldenContext = try XCTUnwrap(goldenUtterance["context"] as? [String: Any])
        XCTAssertEqual(Set(actualContext.keys), Set(goldenContext.keys))
      case "ask.response.act.json", "ask.response.clarify.json", "ask.response.desk.json",
        "ask.response.none.json":
        _ = try IntentWire.decoder.decode(IntentResolution.self, from: Data(contentsOf: file))
      case "household_week.request.json":
        _ = try JSONDecoder().decode(HouseholdWeekRequest.self, from: Data(contentsOf: file))
      case "household_week.response.json":
        _ = try JSONDecoder().decode(HouseholdWeekResponse.self, from: Data(contentsOf: file))
      case "person_next_steps.request.json":
        _ = try JSONDecoder().decode(PersonNextStepsRequest.self, from: Data(contentsOf: file))
      case "person_next_steps.response.json":
        _ = try JSONDecoder().decode(PersonNextStepsResponse.self, from: Data(contentsOf: file))
      default: XCTFail("unhandled v1 golden \(file.lastPathComponent)")
      }
    }
  }

  func testRequestEncodingMatchesGoldenKeys() throws {
    let household = HouseholdWeekRequest(
      requestID: "0example0request0id0000000000002",
      pin: AgentPin(address: "1 Example Way, Exampletown (fictional)", lat: 0, lon: 0),
      surfaceLanguage: .es, thinkIn: "es", mode: .resident,
      household: HouseholdInputs(
        homeLanguage: "es",
        rent: HouseholdMoney(amount: 1000, currency: "USD"),
        car: HouseholdCar(gantryIDs: ["example-gantry-1"]), childAges: [7]))
    let golden = try goldenObject("contracts/v1/household_week.request.json")
    let encoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(household)) as? [String: Any]
    XCTAssertTrue(NSDictionary(dictionary: encoded ?? [:]).isEqual(to: golden))

    let person = PersonNextStepsRequest(
      requestID: "0example0request0id0000000000003",
      person: PersonContext(
        personID: "person-example-1", age: 30, originLenses: [.haiti], stage: .identification,
        mode: .resident, goal: .work),
      surfaceLanguage: .ht, thinkIn: "ht")
    let personGolden = try goldenObject("contracts/v1/person_next_steps.request.json")
    let personEncoded =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(person)) as? [String: Any]
    XCTAssertTrue(NSDictionary(dictionary: personEncoded ?? [:]).isEqual(to: personGolden))
  }

  func testAllFactValueCasesAndUnknownType() throws {
    let samples: [(String, [String: Any])] = [
      ("text", ["text": "example", "language": "es"]),
      ("code", ["code": "example-code"]),
      ("codes", ["codes": ["example-a", "example-b"]]),
      ("phone", ["digits": "5550100"]),
      ("date", ["date": "2026-09-25"]),
      ("money", ["amount": 10, "currency": "USD"]),
      ("quantity", ["amount": 1900, "unit": "year"]),
      ("weekdays", ["days": ["tuesday"]]),
      (
        "place",
        [
          "place": [
            "name": "Example Place", "coordinate": ["latitude": 0, "longitude": 0], "address": nil,
          ]
        ]
      ),
      ("flag", ["value": true]),
    ]
    for (type, fields) in samples {
      var object: [String: Any] = ["type": type]
      fields.forEach { object[$0.key] = $0.value }
      let value = try JSONSerialization.data(withJSONObject: object)
      XCTAssertNoThrow(
        try JSONDecoder().decode(ADAgentsClient.FactValue.self, from: value), "case \(type)")
      var extra = object
      extra["unexpected"] = true
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          ADAgentsClient.FactValue.self,
          from: JSONSerialization.data(withJSONObject: extra)), "case \(type)")
      if type == "place" {
        var place = try XCTUnwrap(extra["place"] as? [String: Any])
        var coordinate = try XCTUnwrap(place["coordinate"] as? [String: Any])
        coordinate["unexpected"] = true
        place["coordinate"] = coordinate
        extra["place"] = place
        XCTAssertThrowsError(
          try JSONDecoder().decode(
            ADAgentsClient.FactValue.self,
            from: JSONSerialization.data(withJSONObject: extra)), "place coordinate")
      }
    }
    let unknown = Data(#"{"type":"number","value":1,"unit":"x"}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ADAgentsClient.FactValue.self, from: unknown))
  }

  private func unknownKeyMutations(_ value: Any) throws -> [Data] {
    func copies(_ value: Any, underOpenMap: Bool = false) -> [Any] {
      if let object = value as? [String: Any] {
        guard !underOpenMap else { return [] }
        var result: [Any] = []
        var atThisLevel = object
        atThisLevel["__unknown_key__"] = true
        result.append(atThisLevel)
        for (key, child) in object where key != "basis" {
          for mutatedChild in copies(child) {
            var parent = object
            parent[key] = mutatedChild
            result.append(parent)
          }
        }
        return result
      }
      if let array = value as? [Any] {
        return array.indices.flatMap { index in
          copies(array[index]).map { mutatedChild in
            var parent = array
            parent[index] = mutatedChild
            return parent
          }
        }
      }
      return []
    }
    return try copies(value).map { try JSONSerialization.data(withJSONObject: $0) }
  }

  private func decodeAskResponse(_ data: Data) throws {
    try validateIntentResolutionResponse(data)
    _ = try IntentWire.decoder.decode(IntentResolution.self, from: data)
  }

  func testEveryResponseGoldenRejectsUnknownAtEveryObjectLevel() throws {
    let intentDirectory = root.appendingPathComponent("contracts/intent")
    let intentFiles = try FileManager.default.contentsOfDirectory(
      at: intentDirectory, includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix("intent_resolution.") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var mutationCount = 0
    for file in intentFiles {
      let wrapper = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
      let value = try XCTUnwrap(wrapper["value"])
      let baseline = try JSONSerialization.data(withJSONObject: value)
      XCTAssertNoThrow(try decodeAskResponse(baseline), file.lastPathComponent)
      for mutated in try unknownKeyMutations(value) {
        mutationCount += 1
        XCTAssertThrowsError(try decodeAskResponse(mutated), file.lastPathComponent)
      }
    }

    let v1Names = [
      "ask.response.act.json", "ask.response.clarify.json", "ask.response.desk.json",
      "ask.response.none.json"
    ]
    for name in v1Names {
      let value = try JSONSerialization.jsonObject(with: data("contracts/v1/" + name))
      let baseline = try data("contracts/v1/" + name)
      XCTAssertNoThrow(try decodeAskResponse(baseline), name)
      for mutated in try unknownKeyMutations(value) {
        mutationCount += 1
        XCTAssertThrowsError(try decodeAskResponse(mutated), name)
      }
    }

    for name in ["household_week.response.json", "person_next_steps.response.json"] {
      let value = try JSONSerialization.jsonObject(with: data("contracts/v1/" + name))
      let baseline = try data("contracts/v1/" + name)
      if name.hasPrefix("household") {
        XCTAssertNoThrow(try JSONDecoder().decode(HouseholdWeekResponse.self, from: baseline), name)
      } else {
        XCTAssertNoThrow(try JSONDecoder().decode(PersonNextStepsResponse.self, from: baseline), name)
      }
      for mutated in try unknownKeyMutations(value) {
        mutationCount += 1
        if name.hasPrefix("household") {
          XCTAssertThrowsError(try JSONDecoder().decode(HouseholdWeekResponse.self, from: mutated), name)
        } else {
          XCTAssertThrowsError(try JSONDecoder().decode(PersonNextStepsResponse.self, from: mutated), name)
        }
      }
    }
    XCTAssertEqual(mutationCount, 93)
  }

  func testResolveRejectsUnknownAskResponseBeforeRouterDecoder() async throws {
    var response = try goldenObject("contracts/v1/ask.response.act.json")
    response["unexpected"] = true
    let body = try JSONSerialization.data(withJSONObject: response)
    let transport = StubTransport(body: body)
    let api = AgentsAPI(baseURL: URL(string: "https://example.invalid/api")!, transport: transport)
    do {
      _ = try await api.resolve(
        utterance: "example", language: "es", routeContext: RouteContext(), stage: .safeThisWeek,
        mode: .resident)
      XCTFail("unknown ask response key was accepted")
    } catch {
      // Expected: validation runs before ADRouter's decoder.
    }
  }

  func testMalformedResponseEnvelopesThrow() throws {
    var mismatched = try goldenObject("contracts/v1/household_week.response.json")
    var facts = try XCTUnwrap(mismatched["facts"] as? [String: Any])
    let (originalKey, originalOutcome) = try XCTUnwrap(facts.first)
    facts.removeValue(forKey: originalKey)
    facts["wrong.fact.key"] = originalOutcome
    mismatched["facts"] = facts
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        HouseholdWeekResponse.self, from: JSONSerialization.data(withJSONObject: mismatched)))

    var extraEnvelope = try goldenObject("contracts/v1/household_week.response.json")
    extraEnvelope["unexpected"] = true
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        HouseholdWeekResponse.self, from: JSONSerialization.data(withJSONObject: extraEnvelope)))

    var extraFact = try goldenObject("contracts/v1/household_week.response.json")
    var extraFactMap = try XCTUnwrap(extraFact["facts"] as? [String: Any])
    let (factKey, rawOutcome) = try XCTUnwrap(
      extraFactMap.first { ($0.value as? [String: Any])?["fact"] != nil })
    var outcome = try XCTUnwrap(rawOutcome as? [String: Any])
    var wireFact = try XCTUnwrap(outcome["fact"] as? [String: Any])
    wireFact["unexpected"] = "drift"
    outcome["fact"] = wireFact
    extraFactMap[factKey] = outcome
    extraFact["facts"] = extraFactMap
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        HouseholdWeekResponse.self, from: JSONSerialization.data(withJSONObject: extraFact)))

    var unknownValue = try goldenObject("contracts/v1/household_week.response.json")
    var unknownFacts = try XCTUnwrap(unknownValue["facts"] as? [String: Any])
    let (valueKey, rawValueOutcome) = try XCTUnwrap(
      unknownFacts.first { ($0.value as? [String: Any])?["fact"] != nil })
    var valueOutcome = try XCTUnwrap(rawValueOutcome as? [String: Any])
    var valueFact = try XCTUnwrap(valueOutcome["fact"] as? [String: Any])
    valueFact["value"] = ["type": "unknown"]
    valueOutcome["fact"] = valueFact
    unknownFacts[valueKey] = valueOutcome
    unknownValue["facts"] = unknownFacts
    XCTAssertThrowsError(
      try JSONDecoder().decode(
        HouseholdWeekResponse.self, from: JSONSerialization.data(withJSONObject: unknownValue)))
  }

  func testTransportIsStubbedAndResolveUsesInjectedBaseURL() async throws {
    let body = try Data(
      contentsOf: root.appendingPathComponent("contracts/v1/ask.response.act.json"))
    let transport = StubTransport(body: body)
    let api = AgentsAPI(baseURL: URL(string: "https://example.invalid/api")!, transport: transport)
    let resolution = try await api.resolve(
      utterance: "example", language: "es", routeContext: RouteContext(), stage: .safeThisWeek,
      mode: .resident)
    XCTAssertEqual(resolution.confidence, 0.92)
    let request = await transport.request
    XCTAssertEqual(request?.httpMethod, "POST")
    XCTAssertEqual(request?.url?.absoluteString, "https://example.invalid/api/v1/ask")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    let object = try XCTUnwrap(
      request?.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])
    XCTAssertEqual(object["stage"] as? Int, 1)
    XCTAssertEqual(object["mode"] as? String, "resident")
    XCTAssertNotNil(object["utterance"])
  }

  func testServerMessageKeysHaveAllCatalogLanguages() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let keyData = try Data(contentsOf: packageRoot
      .appendingPathComponent("Tests/ADAgentsClientTests/server_message_keys.json"))
    let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: keyData) as? [String])
    let catalogData = try Data(contentsOf: packageRoot
      .appendingPathComponent("Sources/ADAgentsClient/Resources/ADAgentsClient.xcstrings"))
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogData) as? [String: Any])
    let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
    for key in keys {
      let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
      let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], key)
      for language in ["en", "es", "ht"] {
        let localization = try XCTUnwrap(localizations[language] as? [String: Any], "\(key) \(language)")
        XCTAssertNotNil(localization["stringUnit"], "\(key) \(language) value")
      }
    }
  }

  func testM5_hasDemoMustMatchDemoFacts() throws {
    var response = try goldenObject("contracts/v1/household_week.response.json")
    response["has_demo"] = false
    XCTAssertThrowsError(try JSONDecoder().decode(
      HouseholdWeekResponse.self, from: JSONSerialization.data(withJSONObject: response)))
  }

  func testM5_negativeDroppedClaimsRejected() throws {
    var response = try goldenObject("contracts/v1/person_next_steps.response.json")
    response["dropped_claims"] = -1
    XCTAssertThrowsError(try JSONDecoder().decode(
      PersonNextStepsResponse.self, from: JSONSerialization.data(withJSONObject: response)))
  }

  func testM5_moreThanThreeStepsRejected() throws {
    var response = try goldenObject("contracts/v1/person_next_steps.response.json")
    let steps = try XCTUnwrap(response["steps"] as? [[String: Any]])
    response["steps"] = Array(repeating: steps[0], count: 4)
    XCTAssertThrowsError(try JSONDecoder().decode(
      PersonNextStepsResponse.self, from: JSONSerialization.data(withJSONObject: response)))
  }

  func testM5_factRefMustBelongToPack() throws {
    var response = try goldenObject("contracts/v1/person_next_steps.response.json")
    var steps = try XCTUnwrap(response["steps"] as? [[String: Any]])
    var claims = try XCTUnwrap(steps[0]["claims"] as? [[String: Any]])
    claims[0]["fact_refs"] = [["pack_id": "us-fl-miami", "fact_id": "us.example-id-desk.url"]]
    steps[0]["claims"] = claims
    response["steps"] = steps
    XCTAssertThrowsError(try JSONDecoder().decode(
      PersonNextStepsResponse.self, from: JSONSerialization.data(withJSONObject: response)))
  }

  func testM5_impossibleGregorianDateRejected() throws {
    let bad = Data(#"{\"type\":\"date\",\"date\":\"2026-02-31\"}"#.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(ADAgentsClient.FactValue.self, from: bad))
  }

  func testPhonePolicyHelperUsesADRouterThresholds() {
    XCTAssertEqual(AgentsAPI.phoneIntentPolicy.performThreshold, 0.75)
    XCTAssertEqual(AgentsAPI.phoneIntentPolicy.clarifyThreshold, 0.40)
  }
}

private actor StubTransport: AgentsTransport {
  let body: Data
  var request: URLRequest?
  init(body: Data) { self.body = body }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    self.request = request
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (body, response)
  }
}
