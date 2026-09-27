import Foundation

/// The three hackathon beats, in demo order, from the shipped check functions and the bundled fixtures.
/// Fee Check, then Listing Check, then Who handles my address (both saved pins).
public struct DemoBeat: Equatable, Sendable {
    public let id: String
    public let lines: [String]
    public init(id: String, lines: [String]) {
        self.id = id
        self.lines = lines
    }
}

public enum DemoChecks {
    public static let beatOrder = ["fee_check", "listing_check", "address_check"]

    /// Dollars as `$48.00`. The app can pass ADLocale later; this does not look up a rate.
    public static let plainMoney: CheckMoneyFormat = { amount, _, _ in
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        let text = NSDecimalNumber(decimal: rounded).stringValue
        let parts = text.split(separator: ".")
        let cents = parts.count > 1 ? String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0) : "00"
        return "$\(parts[0]).\(cents)"
    }

    public static func scripted(language: CheckLanguage, strings: some CheckStrings, money: CheckMoneyFormat = plainMoney) throws -> [DemoBeat] {
        let ledger = try CheckLedger.bundled()
        let rules = try AddressRules.bundled()
        guard let fee = FeeCheckRun.replay(try FeeReplay.bundled(), ledger: ledger, because: .chosen) else {
            throw BundledRegionData.LoadError.missing("fee replay")
        }
        let feeLines = fee.answer.lines(language, strings: strings, money: money)
            + [strings.text("regions.fee.replay.label", language)]

        let building = try ListingCheck.CachedParcel.bundled()
        let claim = ListingClaim(address: "111 NW 1st St, Miami, FL 33128", claimedName: "Carlos Pérez")
        let listing = building.replay(claim, because: .chosen)
        let listingLines = listing.lines(language, strings: strings, ledger: ledger)
            + [strings.text("regions.listing.replay.label", language, [AddressFormat.day(listing.retrievedAt)])]

        var addressLines: [String] = []
        for pin in try AddressCached.bundled() {
            let answer = AddressCheck.replay(pin, rules: rules, ledger: ledger)
            addressLines.append(contentsOf: answer.lines(language, strings: strings, ledger: ledger, rules: rules))
        }
        return [
            DemoBeat(id: "fee_check", lines: feeLines),
            DemoBeat(id: "listing_check", lines: listingLines),
            DemoBeat(id: "address_check", lines: addressLines),
        ]
    }
}
