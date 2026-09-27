import Foundation
import ADCityPack

/// Drives the shipped check functions. Used when `swift test` cannot load XCTest.
@main
struct CheckProbe {
    static func main() async {
        let tally = ProbeTally()
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if ok { print("PASS \(name)") }
            else { print("FAIL \(name) \(detail)"); tally.fail() }
        }

        let catalogURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ADCityPack/Resources/ADCityPack.xcstrings")
        guard let strings = try? CatalogCheckStrings(xcstrings: Data(contentsOf: catalogURL)),
              let ledger = try? CheckLedger.bundled(),
              let rules = try? AddressRules.bundled(),
              let cachedPins = try? AddressCached.bundled(),
              let building = try? ListingCheck.CachedParcel.bundled() else {
            print("FAIL setup could not load bundled checks")
            exit(1)
        }

        let beats = (try? DemoChecks.scripted(language: .en, strings: strings)) ?? []
        check("demo order", beats.map(\.id) == DemoChecks.beatOrder, beats.map(\.id).joined(separator: ","))
        let fee = beats.first { $0.id == "fee_check" }?.lines.joined(separator: "\n") ?? ""
        check("fee ledger", fee.contains("$48.00") && fee.contains("$6.25") && fee.contains("305-375-5448") && !fee.contains("$300"), fee)
        check("fee replay label", fee.contains("Replay · not live"), fee)
        let listing = beats.first { $0.id == "listing_check" }?.lines.joined(separator: " ") ?? ""
        check("listing no owner", !listing.uppercased().contains("TRUE_OWNER") && listing.contains("Replay · not live"), listing)
        let address = beats.first { $0.id == "address_check" }?.lines.joined(separator: "\n") ?? ""
        check("pins disagree", address.localizedCaseInsensitiveContains("unincorporated") && address.contains("This address is in Miami."), address)
        check("address replay label", address.contains("Replay · not live"), address)

        struct Stuck: ParcelFetching {
            func get(_ url: URL) async throws -> Data {
                await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) { k.resume() }
                }
                return Data()
            }
        }
        let start = Date()
        let raced = await AddressCheck.run(
            "11200 SW 137th Ave, Miami, FL 33186",
            rules: rules, ledger: ledger, fetch: Stuck(), cached: cachedPins, deadline: .milliseconds(150)
        )
        let elapsed = Date().timeIntervalSince(start)
        if case let .answer(r) = raced {
            let gov = r.rows.compactMap { row -> String? in
                if case let .municipality(name) = row.finding { return name }
                return nil
            }
            print("deadline elapsed=\(String(format: "%.3f", elapsed))s origin=cachedReplay timedOut gov=\(gov.joined(separator: ","))")
            check("deadline race", elapsed < 0.8 && r.origin == .cachedReplay(because: .timedOut) && gov.contains("UNINCORPORATED MIAMI-DADE"),
                  "elapsed=\(elapsed) origin=\(r.origin) gov=\(gov)")
        } else {
            check("deadline race", false, "\(raced)")
        }

        struct Down: ParcelFetching { func get(_ url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) } }
        let other = await ListingCheck.run(
            ListingClaim(address: "500 Brickell Ave, Miami, FL 33131", claimedName: "Carlos Pérez"),
            fetch: Down(), cached: building, deadline: .seconds(2)
        )
        check("listing refuses other address", other.verdict == .noRecord && other.folio == nil, "\(other.verdict) \(other.folio ?? "nil")")
        let demoListing = await ListingCheck.run(
            ListingClaim(address: "111 NW 1st St", claimedName: "Carlos Pérez"),
            fetch: Down(), cached: building, deadline: .seconds(2)
        )
        check("listing demo building", demoListing.verdict == .doesNotMatch && demoListing.folio == "0141370230020", "\(demoListing.verdict)")

        let feeStart = Date()
        let slowFee = await FeeCheckRun.run(deadline: .milliseconds(150), ledger: ledger, replay: (try? FeeReplay.bundled())!) {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { k.resume() }
            }
            return "late"
        }
        let feeElapsed = Date().timeIntervalSince(feeStart)
        print("fee deadline elapsed=\(String(format: "%.3f", feeElapsed))s")
        check("fee deadline", feeElapsed < 0.8 && slowFee?.origin == .cachedReplay(because: .timedOut), "elapsed=\(feeElapsed)")
        let fastFee = await FeeCheckRun.run(deadline: .seconds(2), ledger: ledger, replay: (try? FeeReplay.bundled())!) {
            "He wants 300 dollars for the license"
        }
        check("fee live stays live", fastFee?.origin == .live, "\(String(describing: fastFee?.origin))")

        if ProcessInfo.processInfo.arguments.contains("--show") {
            if let shown = try? DemoChecks.scripted(language: .en, strings: strings) {
                for beat in shown {
                    print("BEAT \(beat.id)")
                    for line in beat.lines { print(line) }
                    print("---")
                }
            }
        }
        if tally.count != 0 { exit(1) }
    }
}

private final class ProbeTally: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func fail() { lock.lock(); n += 1; lock.unlock() }
}
