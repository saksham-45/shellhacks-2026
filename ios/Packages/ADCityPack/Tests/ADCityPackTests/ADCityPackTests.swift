import XCTest
import ADCore
@testable import ADCityPack

private struct FakePack: RegionPack {
    let manifest: RegionPackManifest
    let inside: @Sendable (Pin) -> Bool
    var outcomes: [FactOutcome] = []
    func contains(_ pin: Pin) async throws -> Bool { inside(pin) }
    func answer(_ question: Question, at pin: Pin) async throws -> [FactOutcome] { outcomes }
}

private func pack(_ id: RegionPackID, _ parent: RegionPackID?, answers: [Question], outcomes: [FactOutcome] = [],
                  inside: @escaping @Sendable (Pin) -> Bool) -> FakePack {
    FakePack(manifest: RegionPackManifest(
        id: id, parent: parent,
        adapters: answers.isEmpty ? [] : [AdapterDescriptor(id: "\(id).adapter", answers: answers, sources: [])],
        sources: [], desks: [], languages: []), inside: inside, outcomes: outcomes)
}

final class ResolutionTests: XCTestCase {
    func testMostLocalGovernmentWinsPerQuestion() async throws {
        // Synthetic pins: latitude > 0 means "inside the city". No real coordinates.
        let registry = RegionPackRegistry(packs: [
            pack("us-fl-miami", "us-fl-miamidade", answers: ["trash.schedule"]) { $0.latitude > 0 },
            pack("us", nil, answers: ["emergency.number"]) { _ in true },
            pack("us-fl", "us", answers: []) { _ in true },
            pack("us-fl-miamidade", "us-fl", answers: ["trash.schedule"]) { _ in true },
        ])
        let city = Pin(latitude: 1, longitude: 0)
        let unincorporated = Pin(latitude: -1, longitude: 0)
        let ids = try await registry.applicablePacks(for: city).map(\.manifest.id)
        XCTAssertEqual(ids, ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"])
        let cityOwner = try await registry.owner(of: "trash.schedule", at: city)?.manifest.id
        let countyOwner = try await registry.owner(of: "trash.schedule", at: unincorporated)?.manifest.id
        let countryOwner = try await registry.owner(of: "emergency.number", at: city)?.manifest.id
        XCTAssertEqual(cityOwner, "us-fl-miami")
        XCTAssertEqual(countyOwner, "us-fl-miamidade")
        XCTAssertEqual(countryOwner, "us")
    }

    func testNotApplicableFallsThroughToParentButUnavailableNeverDoes() async throws {
        let desk = Desk(id: "us-fl-miami.solid-waste", regionPack: "us-fl-miami")
        let na = FactOutcome.notApplicable(reason: RegionStrings.key("regions.na.city-trash-not-serviced"), deferTo: nil)
        let countyAnswer = FactOutcome.unsourced(desk: Desk(id: "us-fl-miamidade.dswm", regionPack: "us-fl-miamidade"))
        let pin = Pin(latitude: 1, longitude: 0)

        let passing = RegionPackRegistry(packs: [
            pack("us", nil, answers: []) { _ in true },
            pack("us-fl-miamidade", "us", answers: ["trash.schedule"], outcomes: [countyAnswer]) { _ in true },
            pack("us-fl-miami", "us-fl-miamidade", answers: ["trash.schedule"], outcomes: [na]) { _ in true },
        ])
        let r1 = try await passing.resolve("trash.schedule", at: pin)
        XCTAssertEqual(r1.owner, "us-fl-miamidade")
        XCTAssertEqual(r1.passedOver, ["us-fl-miami"])
        XCTAssertEqual(r1.outcomes, [countyAnswer])

        let stopping = RegionPackRegistry(packs: [
            pack("us", nil, answers: []) { _ in true },
            pack("us-fl-miamidade", "us", answers: ["trash.schedule"], outcomes: [countyAnswer]) { _ in true },
            pack("us-fl-miami", "us-fl-miamidade", answers: ["trash.schedule"], outcomes: [.unavailable(desk: desk)]) { _ in true },
        ])
        let r2 = try await stopping.resolve("trash.schedule", at: pin)
        XCTAssertEqual(r2.owner, "us-fl-miami")  // the city's desk, never a silent county fallback
        XCTAssertEqual(r2.outcomes, [.unavailable(desk: desk)])
    }
}

final class ManifestTests: XCTestCase {
    func testBundledManifestsDecodeWithExtensions() throws {
        let ms = try BundledRegionData.manifests()
        XCTAssertEqual(ms.map(\.id), ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"])
        XCTAssertEqual(ms.map(\.level), [.country, .state, .county, .city])
        XCTAssertEqual(ms.map(\.parent), [nil, "us", "us-fl", "us-fl-miamidade"])
        let county = ms[2]
        XCTAssertEqual(county.boundary?.method, "fact_ok")
        XCTAssertEqual(ms[3].boundary, PackBoundary(method: "fact_equals", fact: "us-fl-miamidade.government.municipality-id", value: "01"))
        XCTAssertTrue(county.answers("trash.schedule"))
        XCTAssertEqual(county.factIDs(answering: "places.parks").count, 6)
        let elementary = county.adapter(emitting: "us-fl-miamidade.school.elementary.phone")
        XCTAssertEqual(elementary?.desk, "us-fl-miamidade.m-dcps-transportation")
        XCTAssertEqual(elementary?.facts.first?.topics, ["schools"])
        for m in ms {
            XCTAssertEqual(m.desksPlaceholder, true)
            XCTAssertEqual(Set(m.languages), ["es", "en", "ht"])
            for a in m.adapters { XCTAssertTrue(m.desks.contains(a.desk!), a.id) }
        }
    }

    func testSkeletonManifestShapeStillDecodes() throws {
        let legacy = #"{"id":"us-fl-miami","parent":"us-fl-miamidade","adapters":[{"id":"a","answers":["trash.schedule"],"sources":[]}],"sources":[],"desks":[],"languages":["es","en","ht"]}"#
        let m = try JSONDecoder().decode(RegionPackManifest.self, from: Data(legacy.utf8))
        XCTAssertNil(m.level)
        XCTAssertNil(m.boundary)
        XCTAssertEqual(m.adapters.first?.facts, [])
        let bareFacts = #"{"id":"a","answers":[],"sources":[],"facts":["us.x.y"]}"#
        XCTAssertEqual(try JSONDecoder().decode(AdapterDescriptor.self, from: Data(bareFacts.utf8)).facts, [AdapterFact(id: "us.x.y")])
    }
}

final class MappingTests: XCTestCase {
    private func result(_ json: String) throws -> RegionFactResult {
        try JSONDecoder().decode(RegionFactResult.self, from: Data(json.utf8))
    }

    private let evidence = #""source_id":"us-fl-miamidade.gis-parcels","publisher":"Miami-Dade County (GIS)","url":"https://gisweb.miamidade.gov/x/query?f=json","retrieved_at":"2026-09-25T17:30:00-04:00","quote":"YEAR_BUILT: 1984","jurisdiction":"us-fl-miamidade","desk":"us-fl-miamidade.property-appraiser","check_every":"P30D""#

    func testOkMapsToFactWithEvidence() throws {
        let r = try result(#"{"fact_id":"us-fl-miamidade.parcel.year-built","ledger_id":"us-fl-miamidade.parcel.year-built","pack":"us-fl-miamidade","status":"ok","is_demo":false,"value":{"type":"quantity","amount":1984,"unit":"year"},"# + evidence + "}")
        guard case .fact(let fact) = RegionOutcomeMapper.outcome(for: r) else { return XCTFail("expected a fact") }
        XCTAssertEqual(fact.displayValue, .quantity(1984, unit: "year"))
        XCTAssertEqual(fact.status, .verified)
        XCTAssertEqual(fact.checkEveryDays, 30)
        XCTAssertEqual(fact.source?.publisher, "Miami-Dade County (GIS)")
        XCTAssertNotNil(fact.retrievedAt)
    }

    func testOkWithoutUrlOrRetrievedAtNeverShowsAValue() throws {
        let r = try result(#"{"fact_id":"us-fl-miamidade.parcel.year-built","ledger_id":"us-fl-miamidade.parcel.year-built","pack":"us-fl-miamidade","status":"ok","is_demo":false,"value":{"type":"quantity","amount":1984,"unit":"year"},"quote":"q","jurisdiction":"us-fl-miamidade","desk":"us-fl-miamidade.property-appraiser"}"#)
        XCTAssertEqual(RegionOutcomeMapper.outcome(for: r), .unavailable(desk: Desk(id: "us-fl-miamidade.property-appraiser", regionPack: "us-fl-miamidade")))
    }

    func testErrorAndUnavailableMapToUnavailableWithDesk() throws {
        for status in ["error", "unavailable"] {
            let r = try result(#"{"fact_id":"us-fl-miami.trash.day","ledger_id":"us-fl-miami.trash.day","pack":"us-fl-miami","status":""# + status + #"","is_demo":false,"value":null,"source_id":"us-fl-miami.gis-trash-routes","publisher":"City of Miami (GIS)","url":"https://gis.miami.gov/x","retrieved_at":"2026-09-25T17:19:00-04:00","jurisdiction":"us-fl-miami","desk":"us-fl-miami.solid-waste","error":"TRASHDAY value is not in the layer's domain"}"#)
            XCTAssertEqual(RegionOutcomeMapper.outcome(for: r), .unavailable(desk: Desk(id: "us-fl-miami.solid-waste", regionPack: "us-fl-miami")))
        }
    }

    func testValueTagsAreExactlyTheTenAdcoreCases() throws {
        for bad in [#"{"type":"verbatim","text":"x"}"#, #"{"type":"number","value":"1","unit":"year"}"#, #"{"type":"url","url":"https://x"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(RegionValue.self, from: Data(bad.utf8)), bad)
        }
        let good: [(String, FactValue)] = [
            (#"{"type":"code","code":"0141370230020"}"#, .code("0141370230020")),
            (#"{"type":"codes","codes":["MMI","MMO"]}"#, .codes(["MMI", "MMO"])),
            (#"{"type":"flag","value":false}"#, .flag(false)),
            (#"{"type":"weekdays","days":["tuesday","friday"]}"#, .weekdays([.tuesday, .friday])),
            (#"{"type":"phone","digits":"3053714687"}"#, .phone(digits: "3053714687")),
        ]
        for (json, expected) in good {
            XCTAssertEqual(try JSONDecoder().decode(RegionValue.self, from: Data(json.utf8)).factValue, expected)
        }
        XCTAssertNil(RegionValue.weekdays(["funday"]).factValue)
    }
}

final class FixturePackTests: XCTestCase {
    private func pins() throws -> (a: Pin, b: Pin, registry: RegionPackRegistry) {
        let p = try BundledRegionData.demoPins()
        return (p[0].asPin, p[1].asPin, try BundledRegionData.demoRegistry())
    }

    private func value(_ outcomes: [FactOutcome], _ id: FactID) -> FactValue? {
        for case .fact(let f) in outcomes where f.id == id { return f.displayValue }
        return nil
    }

    func testPackChainsForBothPins() async throws {
        let (a, b, registry) = try pins()
        let chainA = try await registry.applicablePacks(for: a).map(\.manifest.id)
        let chainB = try await registry.applicablePacks(for: b).map(\.manifest.id)
        XCTAssertEqual(chainA, ["us", "us-fl", "us-fl-miamidade"])
        XCTAssertEqual(chainB, ["us", "us-fl", "us-fl-miamidade", "us-fl-miami"])
    }

    func testTrashMostLocalWinsAndCountyDefersToCity() async throws {
        let (a, b, registry) = try pins()
        let atB = try await registry.resolve("trash.schedule", at: b)
        XCTAssertEqual(atB.owner, "us-fl-miami")
        XCTAssertEqual(value(atB.outcomes, "us-fl-miami.trash.day"), .weekdays([.tuesday]))

        let county = registry.packs.first { $0.manifest.id == "us-fl-miamidade" }!
        let countyAtB = try await county.answer("trash.schedule", at: b)
        XCTAssertEqual(countyAtB.count, 3)
        for outcome in countyAtB {
            XCTAssertEqual(outcome, .notApplicable(reason: StringKey(key: "regions.na.county-trash-not-serviced", table: "ADCityPack"),
                                                   deferTo: FactRef(regionPackID: "us-fl-miami", ledgerFactID: "us-fl-miami.trash.day")))
        }

        let atA = try await registry.resolve("trash.schedule", at: a)
        XCTAssertEqual(atA.owner, "us-fl-miamidade")
        XCTAssertEqual(value(atA.outcomes, "us-fl-miamidade.trash.garbage-days"), .weekdays([.tuesday, .friday]))
        XCTAssertEqual(value(atA.outcomes, "us-fl-miamidade.trash.recycling-day"), .weekdays([.friday]))
    }

    func testFixtureAnswersForBothPins() async throws {
        let (a, b, registry) = try pins()
        func v(_ q: Question, _ pin: Pin, _ id: String) async throws -> FactValue? {
            value(try await registry.resolve(q, at: pin).outcomes, FactID(rawValue: id))
        }
        let md = "us-fl-miamidade"
        let municipalityA = try await v("government.which", a, "\(md).government.municipality-id")
        XCTAssertEqual(municipalityA, .code("30"))
        let municipalityB = try await v("government.which", b, "\(md).government.municipality-id")
        XCTAssertEqual(municipalityB, .code("01"))
        let folioB = try await v("building.parcel", b, "\(md).parcel.folio")
        XCTAssertEqual(folioB, .code("0141370230020"))
        let yearB = try await v("building.parcel", b, "\(md).parcel.year-built")
        XCTAssertEqual(yearB, .quantity(1984, unit: "year"))
        let yearA = try await v("building.parcel", a, "\(md).parcel.year-built")
        XCTAssertEqual(yearA, .quantity(1990, unit: "year"))
        let condoA = try await v("building.parcel", a, "\(md).parcel.condo")
        XCTAssertEqual(condoA, .flag(false))
        guard case .place(let school)? = try await v("school.zoned", b, "\(md).school.elementary") else { return XCTFail() }
        XCTAssertEqual(school.name, "Frederick Douglass Elementary")
        guard case .place(let park)? = try await v("places.parks", b, "\(md).parks.nearest-municipal.1") else { return XCTFail() }
        XCTAssertEqual(park.name, "Paul S Walker Park")
        guard case .place(let lib)? = try await v("places.libraries", a, "\(md).library.nearest.1") else { return XCTFail() }
        XCTAssertEqual(lib.name, "West Kendall Regional")
        let routes = try await v("transit.nearby", a, "\(md).transit.nearest-stop.1.routes")
        XCTAssertEqual(routes, .codes(["137"]))
        let house = try await v("representatives.state-house", b, "\(md).rep.state-house.district")
        XCTAssertEqual(house, .code("109"))
    }

    func testDemoFactsAreDemoStatusAndSchoolsNameTheTransportationDesk() throws {
        for answers in try BundledRegionData.demoPins() {
            for r in answers.results {
                if r.basis?.lookup == "ledger" {  // Fee Check: myAD Research's own ledger row, the same at every pin
                    XCTAssertFalse(r.isDemo)
                    XCTAssertEqual(r.ledgerID, r.factID.rawValue)
                    continue
                }
                XCTAssertTrue(r.isDemo)
                XCTAssertEqual(r.ledgerID, "\(r.factID.rawValue).demo.\(answers.pinID.rawValue)")
                if r.factID.rawValue.contains(".school.") { XCTAssertEqual(r.desk, "us-fl-miamidade.m-dcps-transportation") }
                if r.status == .ok, case .fact(let f) = RegionOutcomeMapper.outcome(for: r) {
                    XCTAssertEqual(f.status, .demo)
                } else if r.status == .ok {
                    XCTFail("ok result \(r.factID) did not map to a fact")
                }
                if let reason = r.notApplicable?.reason { XCTAssertTrue(RegionStrings.notApplicableReasons.contains(reason), reason) }
            }
        }
    }

    func testFeeCheckFactsComeFromTheLedgerOrStayUnsourcedWithTheirDesk() throws {
        let desks = ["us.uscis.": "us.uscis", "us.ftc.": "us.ftc", "us-fl.flhsmv.fee.": "us-fl.flhsmv",
                     "us-fl.landlord.deposit.": "us-fl.bar-lawyer-referral", "us-fl-miamidade.mia.taxi.": "us-fl-miamidade.mia-information"]
        for answers in try BundledRegionData.demoPins() {
            let fees = answers.results.filter { $0.basis?.lookup == "ledger" }
            XCTAssertEqual(fees.count, 11)
            for r in fees {
                let want: String? = desks.first(where: { r.factID.rawValue.hasPrefix($0.key) })?.value
                XCTAssertEqual(r.desk.rawValue, want ?? "missing desk mapping")
                XCTAssertFalse(r.isDemo)  // a ledger fact is never a demo value
                XCTAssertTrue(r.status == .ok || r.status == .unsourced, r.factID.rawValue)
                if r.status == .ok {
                    XCTAssertNotNil(r.value); XCTAssertNotNil(r.url); XCTAssertNotNil(r.retrievedAt); XCTAssertNotNil(r.quote)
                } else {
                    XCTAssertNil(r.value)
                }
            }
        }
    }

    func testRentAtPinAIsCountyUnsourcedAndNoCityFactAppears() async throws {
        let (a, _, registry) = try pins()
        let rent = try await registry.resolve("rent.line", at: a)
        XCTAssertEqual(rent.owner, "us-fl-miamidade")
        XCTAssertEqual(rent.outcomes, [.unsourced(desk: Desk(id: "us-fl-miamidade.housing", regionPack: "us-fl-miamidade"))])
        let pinA = try BundledRegionData.demoPins()[0]
        XCTAssertFalse(pinA.results.contains { $0.pack == "us-fl-miami" || $0.factID.rawValue.hasPrefix("us-fl-miami.") })
    }
}
