import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ADCore
@testable import ADCityPack

/// Fee Check and Listing Check (FM-MYAD-DEMO-FEE). Offline; the live county test is opt-in (MYAD_LIVE=1).
final class ChecksTests: XCTestCase {
    static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ADCityPack/Resources/ADCityPack.xcstrings")

    var strings: CatalogCheckStrings { get throws { try CatalogCheckStrings(xcstrings: Data(contentsOf: Self.catalogURL)) } }
    let money: CheckMoneyFormat = { amount, _, _ in
        var a = amount, r = Decimal()
        NSDecimalRound(&r, &a, 2, .plain)
        let s = NSDecimalNumber(decimal: r).stringValue
        let parts = s.split(separator: ".")
        return "$" + parts[0] + "." + (parts.count > 1 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00")
    }
    let chipMoney: CheckMoneyFormat = { amount, _, _ in "$" + NSDecimalNumber(decimal: amount).stringValue }

    // MARK: Ledger

    func testBundledLedgerLoadsVerifiedFeesAndDesks() throws {
        let ledger = try CheckLedger.bundled()
        XCTAssertEqual(ledger.value("us-fl.flhsmv.fee.class-e-original"), .money(amount: 48, currency: "USD"))
        XCTAssertEqual(ledger.value(FeeCheckIDs.serviceFee), .money(amount: Decimal(string: "6.25")!, currency: "USD"))
        let fee = try XCTUnwrap(ledger.fact("us-fl.flhsmv.fee.class-e-original"))
        XCTAssertEqual(fee.status, .verified)
        XCTAssertEqual(fee.source?.url.host, "www.flhsmv.gov")
        XCTAssertNotNil(fee.retrievedAt)
        XCTAssertNotNil(ledger.desk(FeeCheckIDs.taxCollectorDesk))
        XCTAssertNotNil(ledger.desk("us.ftc"))
        XCTAssertNotNil(ledger.desk("us-fl-miamidade.311"))
    }

    func testUnverifiedLedgerRowNeverShowsAValue() throws {
        let json = #"{"facts":[{"id":"x.fee","status":"unsourced","value":{"kind":"money","amount":1,"currency":"USD"}}],"desks":[]}"#
        let ledger = try CheckLedger.decode(Data(json.utf8))
        XCTAssertNil(ledger.value("x.fee"))
    }

    func testVerifiedRowWithoutQuoteFailsToLoad() {
        let json = #"{"facts":[{"id":"x.fee","status":"verified","value":{"kind":"money","amount":1,"currency":"USD"},"source":{"id":"s","url":"https://e.gov","publisher":"P"},"retrieved_at":"2026-09-25T18:00:00-04:00"}],"desks":[]}"#
        XCTAssertThrowsError(try CheckLedger.decode(Data(json.utf8)))
    }

    // MARK: Fee Check

    func testParserReadsTheStageLineInEachLanguage() {
        XCTAssertEqual(FeeAskParser.parse("Son 300 dólares y le saco la licencia. ¿Eso es normal?"), FeeAsk(quotedAmount: 300, topic: .license))
        XCTAssertEqual(FeeAskParser.parse("He wants $1,200.50 to renew my license"), FeeAsk(quotedAmount: Decimal(string: "1200.50"), topic: .licenseRenewal))
        XCTAssertEqual(FeeAskParser.parse("Li mande m 300 dola pou lisans lan"), FeeAsk(quotedAmount: 300, topic: .license))
        XCTAssertEqual(FeeAskParser.parse("Cuánto cuesta la tarjeta de identificación"), FeeAsk(quotedAmount: nil, topic: .idCard))
        XCTAssertEqual(FeeAskParser.parse("ruido del escenario"), FeeAsk(quotedAmount: nil, topic: nil))
    }

    func testChipShowsWhatWasHeard() throws {
        let chip = FeeChip(FeeAsk(quotedAmount: 300, topic: .license))
        XCTAssertEqual(chip.text(.es, strings: try strings, money: chipMoney), "¿Eso es normal? · $300 · licencia")
        XCTAssertEqual(chip.text(.en, strings: try strings, money: chipMoney), "Is that normal? · $300 · license")
    }

    func testStageAnswerComesFromTheLedgerInThreeLanguages() throws {
        let ledger = try CheckLedger.bundled()
        let answer = try XCTUnwrap(FeeCheck.answer(FeeAsk(quotedAmount: 300, topic: .license), ledger: ledger))
        XCTAssertEqual(answer.desk.desk.id.rawValue, FeeCheckIDs.taxCollectorDesk)
        let es = answer.lines(.es, strings: try strings, money: money)
        XCTAssertEqual(es.first, "El estado cobra $48.00 por la primera licencia, más hasta $6.25 en una oficina del Tax Collector. Fuente: FLHSMV.")
        XCTAssertTrue(es.last!.contains("305-375-5448"), es.last!)
        for lang in CheckLanguage.allCases {
            let lines = answer.lines(lang, strings: try strings, money: money)
            XCTAssertTrue(lines[0].contains("$48.00") && lines[0].contains("$6.25") && lines[0].contains("FLHSMV"), "\(lang): \(lines)")
            XCTAssertFalse(lines.joined().contains("$300"), "the quoted price is never repeated as if judged")
            XCTAssertFalse(lines.joined().contains("regions."), "missing catalog key in \(lang)")
        }
        XCTAssertEqual(answer.facts.map(\.id.rawValue), ["us-fl.flhsmv.fee.class-e-original", FeeCheckIDs.serviceFee])
    }

    func testNoVerifiedFeeMeansDeskAndNoNumber() throws {
        let json = #"{"facts":[{"id":"us-fl.flhsmv.fee.class-e-original","status":"unsourced"}],"desks":[{"id":"us-fl-miamidade.tax-collector","pack":"us-fl-miamidade","names":{"en":"Tax Collector"},"desk_facts":[]},{"id":"us-fl-miamidade.311","pack":"us-fl-miamidade","names":{"en":"311"},"desk_facts":[]}]}"#
        let ledger = try CheckLedger.decode(Data(json.utf8))
        let a = try XCTUnwrap(FeeCheck.answer(FeeAsk(quotedAmount: 300, topic: .license), ledger: ledger))
        XCTAssertEqual(a.lines(.en, strings: try strings, money: money), ["I don't have the official fee for that. Ask Tax Collector."])
        let unknown = try XCTUnwrap(FeeCheck.answer(FeeAsk(quotedAmount: 300, topic: nil), ledger: ledger))
        XCTAssertEqual(unknown.desk.desk.id.rawValue, "us-fl-miamidade.311")
    }

    func testLiveTurnWinsInsideTheDeadline() async throws {
        let ledger = try CheckLedger.bundled(), replay = try FeeReplay.bundled()
        let r = try await XCTUnwrapAsync(await FeeCheckRun.run(deadline: .seconds(2), ledger: ledger, replay: replay) {
            "He wants 300 dollars for the license"
        })
        XCTAssertEqual(r.origin, .live)
        XCTAssertEqual(r.ask.quotedAmount, 300)
    }

    func testSlowTurnFallsBackToLabeledReplay() async throws {
        let ledger = try CheckLedger.bundled(), replay = try FeeReplay.bundled()
        let start = ContinuousClock.now
        let r = try await XCTUnwrapAsync(await FeeCheckRun.run(deadline: .milliseconds(100), ledger: ledger, replay: replay) {
            try await Task.sleep(for: .seconds(10)); return "late"
        })
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the slow turn is cancelled, not awaited")
        XCTAssertEqual(r.origin, .cachedReplay(because: .timedOut))
        XCTAssertEqual(r.heard, replay.transcript)
        XCTAssertEqual(replay.kind, "demo-script")
        XCTAssertEqual(r.answer.facts.first?.displayValue, .money(amount: 48, currency: "USD"))
    }

    func testFailedOrGarbledTurnFallsBackWithItsReason() async throws {
        struct Offline: Error {}
        let ledger = try CheckLedger.bundled(), replay = try FeeReplay.bundled()
        let failed = await FeeCheckRun.run(deadline: .seconds(2), ledger: ledger, replay: replay) { throw Offline() }
        XCTAssertEqual(failed?.origin, .cachedReplay(because: .failed))
        let garbled = await FeeCheckRun.run(deadline: .seconds(2), ledger: ledger, replay: replay) { "mmm ruido" }
        XCTAssertEqual(garbled?.origin, .cachedReplay(because: .unusable))
    }

    // MARK: Listing Check

    func testAddressKeyMatchesCountyForm() {
        XCTAssertEqual(ListingCheck.addressKey("111 Northwest 1st Street, Miami, FL 33128"),
                       .init(street: "111 NW 1 ST", zip: "33128", unit: nil))
        XCTAssertEqual(ListingCheck.addressKey("11200 SW 137th Ave, Miami, FL 33186")?.street, "11200 SW 137 AVE")
        XCTAssertEqual(ListingCheck.addressKey("1000 Brickell Ave Apt 1203, Miami, FL 33131")?.unit, "1203")
        XCTAssertEqual(ListingCheck.addressKey("1000 Brickell Ave #1203")?.street, "1000 BRICKELL AVE")
        XCTAssertNil(ListingCheck.addressKey("Brickell Avenue"))
        // Quotes and SQL never reach the where clause: the key alphabet is [A-Z0-9 ].
        let hostile = ListingCheck.addressKey("1 X' OR '1'='1 ST")!
        XCTAssertTrue(hostile.street.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " })
    }

    func testOwnerKindAndVerdictRules() {
        XCTAssertEqual(ListingCheck.ownerKind(owners: ["MIAMI-DADE COUNTY"], landUse: "COUNTY : OFFICE BUILDING"), .government)
        XCTAssertEqual(ListingCheck.ownerKind(owners: ["SUNSHINE HOLDINGS LLC"], landUse: "RESIDENTIAL"), .company)
        XCTAssertEqual(ListingCheck.ownerKind(owners: ["PEREZ CARLOS", "GARCIA ANA"], landUse: nil), .person)
        XCTAssertEqual(ListingCheck.ownerKind(owners: [], landUse: nil), .unknown)
        // Synthetic owner strings; no real record.
        XCTAssertEqual(ListingCheck.verdict(claimedName: "Carlos Pérez García", owners: ["PEREZ CARLOS"], kind: .person), .matches)
        XCTAssertEqual(ListingCheck.verdict(claimedName: "Carlos Pérez", owners: ["GARCIA ANA"], kind: .person), .doesNotMatch)
        XCTAssertEqual(ListingCheck.verdict(claimedName: "Carlos de la Cruz", owners: ["DE LA TORRE MARIA"], kind: .person), .doesNotMatch)
        XCTAssertEqual(ListingCheck.verdict(claimedName: "Carlos", owners: ["SUNSHINE HOLDINGS LLC"], kind: .company), .ownedByCompany)
        XCTAssertEqual(ListingCheck.verdict(claimedName: "Carlos Pérez", owners: ["MIAMI-DADE COUNTY"], kind: .government), .doesNotMatch)
    }

    func testCachedCountyBuildingReplayIsOwnerFreeAndLabeled() throws {
        let cached = try ListingCheck.CachedParcel.bundled()
        XCTAssertEqual(cached.folio, "0141370230020")
        XCTAssertEqual(cached.ownerKind, .government)
        let r = cached.replay(ListingClaim(address: "111 NW 1st St, Miami, FL 33128", claimedName: "Carlos Pérez"), because: .chosen)
        XCTAssertEqual(r.verdict, .doesNotMatch)
        XCTAssertEqual(r.origin, .cachedReplay(because: .chosen))
        XCTAssertEqual(r.groupedFolio, "01-4137-023-0020")
        XCTAssertGreaterThan(r.retrievedAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(cached.replay(ListingClaim(address: "x", claimedName: "Miami-Dade County"), because: .chosen).verdict, .noVerdict)
        let raw = try String(contentsOf: Bundle.module.url(forResource: "listing-county-building", withExtension: "json", subdirectory: "Checks")!, encoding: .utf8)
        XCTAssertFalse(raw.uppercased().contains("TRUE_OWNER"))
        XCTAssertFalse(raw.uppercased().contains("MIAMI-DADE COUNTY\""), "no owner string in the cache")
    }

    func testListingLinesNameDesksQuoteFTCAndNeverSayScam() throws {
        let ledger = try CheckLedger.bundled()
        let r = try ListingCheck.CachedParcel.bundled().replay(ListingClaim(address: "111 NW 1st St", claimedName: "Carlos Pérez"), because: .chosen)
        let es = r.lines(.es, strings: try strings, ledger: ledger)
        XCTAssertEqual(es[0], "Según el registro del condado, el dueño de esa propiedad no se llama Carlos Pérez.")
        XCTAssertEqual(es[1], "Pida prueba de que administra la propiedad para el dueño.")
        XCTAssertTrue(es[2].hasPrefix("La FTC dice: «Pero cuando pide ver la propiedad"), es[2])
        XCTAssertTrue(es[3].contains("311") || es[3].contains("Miami-Dade"), es[3])
        for lang in CheckLanguage.allCases {
            let text = r.lines(lang, strings: try strings, ledger: ledger).joined(separator: " ").lowercased()
            for word in ["scam", "estafa", "fwod"] where !text.contains("ftc") {
                XCTAssertFalse(text.contains(word), "\(lang) calls it a scam outside the FTC quote")
            }
            XCTAssertFalse(text.contains("regions."), "missing catalog key in \(lang)")
        }
    }

    func testLiveDecisionDropsOwnerText() async throws {
        struct Canned: ParcelFetching {
            let body: String
            func get(_ url: URL) async throws -> Data {
                XCTAssertTrue(url.absoluteString.contains("111%20NW%201%20ST") || url.absoluteString.contains("111+NW+1+ST"), url.absoluteString)
                return Data(body.utf8)
            }
        }
        let body = #"{"features":[{"attributes":{"FOLIO":"0100000000001","TRUE_SITE_ADDR":"111 NW 1 ST","CONDO_FLAG":"N","DOR_DESC":"RESIDENTIAL","TRUE_OWNER1":"GARCIA ANA"}}]}"#
        let r = try await ListingCheck.live(ListingClaim(address: "111 NW 1st St, Miami, FL 33128", claimedName: "Carlos Pérez"), fetch: Canned(body: body))
        XCTAssertEqual(r.verdict, .doesNotMatch)
        XCTAssertEqual(r.origin, .live)
        XCTAssertFalse(String(describing: r).contains("GARCIA"), "the result carries no owner text")
        XCTAssertFalse(r.sourceURL.absoluteString.contains("OWNER"), "the shareable source link has no owner fields")
        let condo = #"{"features":[{"attributes":{"FOLIO":"0100000000002","TRUE_SITE_ADDR":"111 NW 1 ST","CONDO_FLAG":"Y","DOR_DESC":"CONDOMINIUM","TRUE_OWNER1":"GARCIA ANA"}}]}"#
        let c = try await ListingCheck.live(ListingClaim(address: "111 NW 1st St", claimedName: "Ana García"), fetch: Canned(body: condo))
        XCTAssertEqual(c.verdict, .condoNeedsUnit)
    }

    func testUnreachableCountyFallsBackToCachedReplay() async throws {
        struct Down: ParcelFetching { func get(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) } }
        let r = await ListingCheck.run(ListingClaim(address: "111 NW 1st St", claimedName: "Carlos Pérez"), fetch: Down(),
                                       cached: try ListingCheck.CachedParcel.bundled(), deadline: .seconds(2))
        XCTAssertEqual(r.origin, .cachedReplay(because: .failed))
        XCTAssertEqual(r.verdict, .doesNotMatch)
        XCTAssertEqual(r.folio, "0141370230020")
        let other = await ListingCheck.run(ListingClaim(address: "500 Brickell Ave, Miami, FL 33131", claimedName: "Carlos Pérez"),
                                           fetch: Down(), cached: try ListingCheck.CachedParcel.bundled(), deadline: .seconds(2))
        XCTAssertEqual(other.verdict, .noRecord)
        XCTAssertNil(other.folio)
        XCTAssertNotEqual(other.siteAddress, "111 NW 1 ST")
    }

    func testDemoEntryRunsTheThreeBeatsFromTheLedger() throws {
        let beats = try DemoChecks.scripted(language: .en, strings: try strings)
        XCTAssertEqual(beats.map(\.id), DemoChecks.beatOrder)
        let fee = beats[0].lines.joined(separator: "\n")
        XCTAssertTrue(fee.contains("$48.00") && fee.contains("$6.25") && fee.contains("305-375-5448"), fee)
        XCTAssertTrue(fee.contains("Replay · not live"), fee)
        XCTAssertFalse(fee.contains("$300"))
        let listing = beats[1].lines.joined(separator: " ")
        XCTAssertFalse(listing.uppercased().contains("TRUE_OWNER"))
        XCTAssertTrue(listing.contains("Replay · not live"), listing)
        let address = beats[2].lines.joined(separator: "\n")
        XCTAssertTrue(address.contains("Unincorporated Miami-Dade") || address.localizedCaseInsensitiveContains("unincorporated"), address)
        XCTAssertTrue(address.contains("Miami") && address.contains("Tuesday"), address)
        XCTAssertTrue(address.contains("Replay · not live"), address)
    }

    func testLiveCountyBuilding() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYAD_LIVE"] == "1", "opt-in: MYAD_LIVE=1")
        struct Net: ParcelFetching {
            func get(_ url: URL) async throws -> Data { try await URLSession.shared.data(from: url).0 }
        }
        let r = try await ListingCheck.live(ListingClaim(address: "111 NW 1st St, Miami, FL 33128", claimedName: "Carlos Pérez"), fetch: Net())
        XCTAssertEqual(r.folio, "0141370230020")
        XCTAssertEqual(r.verdict, .doesNotMatch)
    }

    // MARK: Catalog

    func testEveryCheckKeyHasThreeLanguagesAndSpanishIsFlaggedUntilReviewed() throws {
        let s = try strings
        let keys = s.keys.filter { $0.hasPrefix("regions.fee.") || $0.hasPrefix("regions.listing.") || $0.hasPrefix("regions.check.") || $0.hasPrefix("regions.beat.") }
        XCTAssertGreaterThan(keys.count, 25)
        for k in keys { for l in CheckLanguage.allCases { XCTAssertNotNil(s.template(k, l), "\(k) \(l)") } }
        for v in ListingVerdict.allCases { XCTAssertNotNil(s.template(v.lineKey, .es), v.rawValue) }
        for t in FeeTopic.allCases { XCTAssertNotNil(s.template(t.chipKey, .ht)); XCTAssertNotNil(s.template(t.phraseKey, .ht)) }
    }
}

func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
