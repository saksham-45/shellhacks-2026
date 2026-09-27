import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ADCore
@testable import ADCityPack

/// Who handles my address (FM-MYAD-ADDR). Offline; the live county test is opt-in (MYAD_LIVE=1).
final class AddressCheckTests: XCTestCase {
    var strings: CatalogCheckStrings { get throws { try CatalogCheckStrings(xcstrings: Data(contentsOf: ChecksTests.catalogURL)) } }

    func cached(_ pin: String) throws -> AddressCached {
        try XCTUnwrap(try AddressCached.bundled().first { $0.pinID == pin })
    }

    /// The bundled rules with every rule marked verified, to exercise the verified branches.
    func verifiedRules() throws -> AddressRules {
        let u = try XCTUnwrap(Bundle.module.url(forResource: "address-rules", withExtension: "json", subdirectory: "Checks"))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any])
        obj["rules"] = (obj["rules"] as? [[String: Any]] ?? []).map { r in
            var r = r
            r["status"] = "verified"
            r["municipalities"] = (r["municipalities"] as? [String] ?? []) + (r["unconfirmed"] as? [String] ?? [])
            r["unconfirmed"] = [String]()
            return r
        }
        return try JSONDecoder().decode(AddressRules.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    func findings(_ r: AddressCheckResult, _ t: AddressTopic) -> [AddressFinding] { r.row(t).map(\.finding) }

    // MARK: Interpretation of the cached county answers

    func testUnincorporatedPinReadsCountyLayers() throws {
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        let r = AddressCheck.replay(try cached("pin-sw137"), rules: rules, ledger: ledger)
        XCTAssertEqual(r.origin, .cachedReplay(because: .chosen))
        XCTAssertEqual(findings(r, .government), [.municipality("UNINCORPORATED MIAMI-DADE")])
        XCTAssertEqual(findings(r, .garbage), [.garbage(days: [.tuesday, .friday], label: "Tuesday Friday")])
        XCTAssertEqual(findings(r, .recycling), [.recycling(day: .friday, week: "A", label: "FRIDAY")])
        XCTAssertEqual(findings(r, .bulky), [.bulkyBook("21")])
        XCTAssertEqual(findings(r, .school), [.school(name: "Claude Pepper ES", address: "14550 SW 96 St., Miami, 33186",
                                                     phone: "305-386-5244", grades: "PK-5")])
        if case let .utility(name, _)? = findings(r, .water).first { XCTAssertEqual(name, "Miami Dade Water and Sewer") }
        else { XCTFail("water utility missing") }
        // Research's verified quotes name unincorporated Miami-Dade for both Sheriff rules.
        XCTAssertEqual(findings(r, .police), [.policeAgency(desk: "us-fl-miamidade.sheriff"), .policeDistrict("HAMMOCKS")])
        XCTAssertEqual(findings(r, .onlineReport), [.onlineReport(covered: true)])
        for row in r.rows where row.finding != .notReturned && row.finding != .policeAskFallback {
            if row.ruleFact != nil { XCTAssertNotNil(try CheckLedger.bundled().fact(try XCTUnwrap(row.ruleFact))) }
            let src = try XCTUnwrap(row.source, "\(row.topic) has no source")
            XCTAssertTrue(src.url.absoluteString.hasPrefix("https://giswspro.miamidade.gov/"), src.url.absoluteString)
            XCTAssertGreaterThan(src.retrievedAt, Date(timeIntervalSince1970: 1_780_000_000))
            XCTAssertFalse(src.quote.isEmpty)
        }
    }

    func testCityPinReadsCityTrashAndHidesGridDistrict() throws {
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        let r = AddressCheck.replay(try cached("pin-nw1st"), rules: rules, ledger: ledger)
        XCTAssertEqual(findings(r, .government), [.municipality("MIAMI")])
        XCTAssertEqual(findings(r, .garbage), [.garbage(days: [.monday, .thursday], label: "MON/THU")])
        XCTAssertEqual(findings(r, .recycling), [.recycling(day: .thursday, week: nil, label: "Thursday 1 & 3")])
        XCTAssertEqual(findings(r, .bulky), [.bulkyDays([.tuesday], code: "T")])
        // The City of Miami's own police page is verified for MIAMI, and the county grid district never shows under it.
        // The online report's list is exact, so MIAMI is not on it.
        XCTAssertEqual(findings(r, .police), [.policeAgency(desk: "us-fl-miami.police")])
        XCTAssertEqual(findings(r, .onlineReport), [.onlineReport(covered: false)])
        // Even with verified rules, the county grid district never shows under City of Miami police.
        let v = AddressCheck.replay(try cached("pin-nw1st"), rules: try verifiedRules(), ledger: ledger)
        XCTAssertEqual(findings(v, .police), [.policeAgency(desk: "us-fl-miami.police")])
        XCTAssertEqual(findings(v, .onlineReport), [.onlineReport(covered: false)])
    }

    func testVerifiedRulesGiveSheriffAndDistrictForUnincorporated() throws {
        let r = AddressCheck.replay(try cached("pin-sw137"), rules: try verifiedRules(), ledger: try CheckLedger.bundled())
        XCTAssertEqual(findings(r, .police), [.policeAgency(desk: "us-fl-miamidade.sheriff"), .policeDistrict("HAMMOCKS")])
        XCTAssertEqual(findings(r, .onlineReport), [.onlineReport(covered: true)])
        XCTAssertNotNil(r.row(.police).first?.ruleFact)
    }

    func testUnconfirmedAreaIsNeverAnsweredEitherWay() throws {
        let u = try XCTUnwrap(Bundle.module.url(forResource: "address-rules", withExtension: "json", subdirectory: "Checks"))
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as? [String: Any])
        obj["rules"] = (obj["rules"] as? [[String: Any]] ?? []).map { r in
            var r = r
            if r["id"] as? String == "online-report" { r["municipalities"] = ["CUTLER BAY"]; r["unconfirmed"] = ["UNINCORPORATED MIAMI-DADE"] }
            if r["id"] as? String == "police.sheriff" { r["status"] = "unsourced"; r["municipalities"] = [String](); r["unconfirmed"] = ["UNINCORPORATED MIAMI-DADE"] }
            return r
        }
        let rules = try JSONDecoder().decode(AddressRules.self, from: JSONSerialization.data(withJSONObject: obj))
        let r = AddressCheck.replay(try cached("pin-sw137"), rules: rules, ledger: try CheckLedger.bundled())
        XCTAssertEqual(findings(r, .onlineReport), [.notReturned])
        XCTAssertEqual(findings(r, .police), [.policeAskFallback], "no grid district without a Sheriff answer")
    }

    func testEmptyOrConflictingLayerIsNotReturned() throws {
        let c = try cached("pin-sw137").raw
        var layers = c.layers
        let g = try XCTUnwrap(layers["county-garbage"])
        layers["county-garbage"] = .init(url: g.url, retrievedAt: g.retrievedAt, features: [["WEEKDAYS": "Monday"], ["WEEKDAYS": "Friday"]])
        layers["elementary"] = .init(url: g.url, retrievedAt: g.retrievedAt, features: [])
        layers["water"] = .init(url: g.url, retrievedAt: g.retrievedAt, features: [["UTILITYNAME": "XYZ"]])
        let raw = AddressRaw(address: c.address, locator: c.locator, layers: layers, domains: [:])
        let r = AddressCheck.interpret(raw, typed: c.address, rules: try AddressRules.bundled(), ledger: try CheckLedger.bundled(), origin: .live)
        XCTAssertEqual(findings(r, .garbage), [.notReturned])
        XCTAssertEqual(findings(r, .school), [.notReturned])
        // An unknown code is shown as the code the layer returned, with no desk attached.
        XCTAssertEqual(findings(r, .water), [.utility(name: "XYZ", desk: nil)])
    }

    // MARK: Query URLs

    func testSwiftQueryURLsMatchTheRecordedCountyQueries() throws {
        let rules = try AddressRules.bundled()
        func items(_ u: URL) -> Set<String> {
            Set((URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { "\($0.name)=\(($0.value ?? "").replacingOccurrences(of: "+", with: " "))" })  // Python writes spaces as +
        }
        for pin in try AddressCached.bundled() {
            XCTAssertEqual(Set(pin.raw.layers.keys), Set(AddressLayer.allCases.map(\.rawValue)))
            for spec in rules.layers {
                let recorded = try XCTUnwrap(pin.raw.layers[spec.key]?.url)
                let mine = spec.queryURL(lat: pin.raw.locator.lat, lon: pin.raw.locator.lon)
                XCTAssertEqual(mine.path, recorded.path, spec.key)
                XCTAssertEqual(items(mine), items(recorded), spec.key)
                XCTAssertTrue(items(mine).contains("spatialRel=esriSpatialRelIntersects"))
            }
            XCTAssertEqual(items(AddressCheck.locatorURL(pin.raw.address)), items(pin.raw.locator.url))
        }
    }

    // MARK: Live path against canned county answers, fallback, timeout

    /// Answers each county URL from a recorded pin, the way the county did.
    struct Replayer: ParcelFetching {
        let pin: AddressRaw
        func get(_ url: URL) async throws -> Data {
            let s = url.absoluteString
            if s.contains("findAddressCandidates") {
                let obj: [String: Any] = ["candidates": [["address": pin.locator.matched, "score": pin.locator.score,
                                                          "location": ["x": pin.locator.lon, "y": pin.locator.lat],
                                                          "attributes": ["Addr_type": "PointAddress", "Score": pin.locator.score]]]]
                return try JSONSerialization.data(withJSONObject: obj)
            }
            if s.hasSuffix("?f=json") {
                guard let d = pin.domains.values.first(where: { $0.url == url }) else { return Data(#"{"fields":[]}"#.utf8) }
                let obj: [String: Any] = ["fields": [["name": d.field, "domain": ["codedValues": d.codes.map { ["code": $0.key, "name": $0.value] }]]]]
                return try JSONSerialization.data(withJSONObject: obj)
            }
            let base = s.components(separatedBy: "?").first ?? s
            guard let layer = pin.layers.values.first(where: { $0.url.absoluteString.hasPrefix(base + "?") }) else {
                throw URLError(.badURL)
            }
            let feats = layer.features.map { ["attributes": $0] }
            return try JSONSerialization.data(withJSONObject: ["features": feats])
        }
    }

    func testLivePathGivesTheSameRowsAsTheRecordedAnswer() async throws {
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        for pin in try AddressCached.bundled() {
            let out = await AddressCheck.run(pin.raw.address, rules: rules, ledger: ledger, fetch: Replayer(pin: pin.raw), cached: [])
            guard case let .answer(live) = out else { return XCTFail("\(pin.pinID): \(out)") }
            XCTAssertEqual(live.origin, .live)
            let replay = AddressCheck.replay(pin, rules: rules, ledger: ledger)
            XCTAssertEqual(live.rows.map(\.finding), replay.rows.map(\.finding), pin.pinID)
        }
    }

    func testNoZIPAndWeakMatchAreRefused() async throws {
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        struct Weak: ParcelFetching {
            func get(_ url: URL) async throws -> Data {
                Data(#"{"candidates":[{"address":"111 NW 1ST ST","score":99,"location":{"x":-80.2,"y":25.8},"attributes":{"Addr_type":"StreetAddress"}}]}"#.utf8)
            }
        }
        let noZIP = await AddressCheck.run("111 NW 1st St, Miami", rules: rules, ledger: ledger, fetch: Weak(), cached: [])
        XCTAssertEqual(noZIP, .needsZIP)
        let weak = await AddressCheck.run("111 NW 1st St, Miami, FL 33128", rules: rules, ledger: ledger, fetch: Weak(), cached: [])
        XCTAssertEqual(weak, .notFound)
    }

    func testUnreachableCountyFallsBackToCachedDemoAnswer() async throws {
        struct Down: ParcelFetching { func get(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) } }
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled(), cache = try AddressCached.bundled()
        let out = await AddressCheck.run("111 Northwest 1st Street, Miami, FL 33128", rules: rules, ledger: ledger, fetch: Down(),
                                         cached: cache, deadline: .seconds(2))
        guard case let .answer(r) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(r.origin, .cachedReplay(because: .failed))
        XCTAssertEqual(findings(r, .government), [.municipality("MIAMI")])
        let other = await AddressCheck.run("500 Brickell Ave, Miami, FL 33131", rules: rules, ledger: ledger, fetch: Down(),
                                           cached: cache, deadline: .seconds(2))
        XCTAssertEqual(other, .unavailable(because: .failed))
    }

    func testSlowCountyTimesOutToCachedDemoAnswer() async throws {
        struct Slow: ParcelFetching {
            func get(_ url: URL) async throws -> Data { try await Task.sleep(for: .seconds(10)); return Data() }
        }
        let start = Date()
        let out = await AddressCheck.run("11200 SW 137th Ave, Miami, FL 33186", rules: try AddressRules.bundled(), ledger: try CheckLedger.bundled(),
                                         fetch: Slow(), cached: try AddressCached.bundled(), deadline: .milliseconds(300))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        guard case let .answer(r) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(r.origin, .cachedReplay(because: .timedOut))
        XCTAssertEqual(findings(r, .government), [.municipality("UNINCORPORATED MIAMI-DADE")])
    }

    /// A county call that ignores cancellation must not hold the answer past the deadline.
    func testDeadlineHoldsWhenCountyIgnoresCancellation() async throws {
        struct Stuck: ParcelFetching {
            func get(_ url: URL) async throws -> Data {
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { k.resume() }
                }
                return Data()
            }
        }
        let start = Date()
        let out = await AddressCheck.run(
            "11200 SW 137th Ave, Miami, FL 33186",
            rules: try AddressRules.bundled(),
            ledger: try CheckLedger.bundled(),
            fetch: Stuck(),
            cached: try AddressCached.bundled(),
            deadline: .milliseconds(150)
        )
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8, "race waited for a county call that ignores cancellation")
        guard case let .answer(r) = out else { return XCTFail("\(out)") }
        XCTAssertEqual(r.origin, .cachedReplay(because: .timedOut))
    }

    // MARK: Lines in every language

    func testEveryLanguageRendersWithNoMissingKeyAndSchoolAlwaysSaysConfirm() throws {
        let s = try strings, rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        for pin in try AddressCached.bundled() {
            for rs in [rules, try verifiedRules()] {
                let r = AddressCheck.replay(pin, rules: rs, ledger: ledger)
                for lang in CheckLanguage.allCases {
                    let lines = r.lines(lang, strings: s, ledger: ledger, rules: rs)
                    let text = lines.joined(separator: "\n")
                    XCTAssertFalse(text.contains("regions."), "missing key \(lang) \(pin.pinID): \(text)")
                    XCTAssertFalse(text.contains("%"), "unfilled template \(lang): \(text)")
                    XCTAssertTrue(text.contains("M-DCPS") || text.contains("Public Schools") || text.contains("305"), text)
                    XCTAssertTrue(text.contains("2026-09-25"), "replay shows its date")
                    if pin.pinID == "pin-nw1st" { XCTAssertFalse(text.uppercased().contains("GOVERNMENT SERVICES BUREAU"), text) }
                }
            }
        }
        let en = AddressCheck.replay(try cached("pin-sw137"), rules: rules, ledger: ledger).lines(.en, strings: s, ledger: ledger, rules: rules)
        XCTAssertTrue(en.contains("Garbage pickup: Tuesday and Friday."), en.joined(separator: "\n"))
        let es = AddressCheck.replay(try cached("pin-nw1st"), rules: rules, ledger: ledger).lines(.es, strings: s, ledger: ledger, rules: rules)
        XCTAssertTrue(es.contains("Recogida de basura: lunes y jueves."), es.joined(separator: "\n"))
        let ht = AddressCheck.replay(try cached("pin-nw1st"), rules: rules, ledger: ledger).lines(.ht, strings: s, ledger: ledger, rules: rules)
        XCTAssertTrue(ht.contains("Gwo fatra: madi."), ht.joined(separator: "\n"))
    }

    func testTitleCase() {
        XCTAssertEqual(AddressFormat.title("UNINCORPORATED MIAMI-DADE"), "Unincorporated Miami-Dade")
        XCTAssertEqual(AddressFormat.title("MIAMI BEACH"), "Miami Beach")
    }

    // MARK: Live (opt-in)

    func testLiveCountyAnswersBothDemoAddresses() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYAD_LIVE"] == "1", "opt-in: MYAD_LIVE=1")
        struct Net: ParcelFetching { func get(_ url: URL) async throws -> Data { try await URLSession.shared.data(from: url).0 } }
        let rules = try AddressRules.bundled(), ledger = try CheckLedger.bundled()
        for pin in try AddressCached.bundled() {
            let out = await AddressCheck.run(pin.raw.address, rules: rules, ledger: ledger, fetch: Net(), cached: [], deadline: .seconds(20))
            guard case let .answer(r) = out else { return XCTFail("\(pin.pinID): \(out)") }
            XCTAssertEqual(r.origin, .live)
            XCTAssertEqual(r.row(.government).map(\.finding), AddressCheck.replay(pin, rules: rules, ledger: ledger).row(.government).map(\.finding))
        }
    }
}
