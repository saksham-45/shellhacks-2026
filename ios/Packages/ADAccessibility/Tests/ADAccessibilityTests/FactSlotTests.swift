import Foundation
import Testing
import ADCore
@testable import ADAccessibility

/// A11Y-FACT-01/02: what the source slot says for each ADCore `FactLine` case.
/// Fixture values are obviously fake test data, not sources.
@Suite("Fact slot")
struct FactSlotTests {
    let source = Source(id: "test.source", url: URL(string: "https://example.invalid/test")!, publisher: "Test Publisher")
    let checked = Date(timeIntervalSince1970: 1_790_000_000)

    func fact(_ status: FactStatus, source: Source?) throws -> Fact {
        try Fact(id: "us-test.desk.phone", value: .phone(digits: "5550100"), source: source,
                 quote: source == nil ? nil : "test quote", quoteLanguage: nil,
                 retrievedAt: source == nil ? nil : checked, status: status)
    }

    @Test func verifiedSaysSourceAndCheckedDate() throws {
        let slot = FactSlot(.shown(try fact(.verified, source: source), status: .verified))
        #expect(slot.kind == .sourced)
        #expect(slot.statusKey == nil)
        #expect(slot.sourceLeadInKey == StringKey(key: "source_line.sourced", table: "ADCore"))
        #expect(slot.publisher == "Test Publisher")
        #expect(slot.checked == checked)
    }

    @Test func staleSaysStaleThenSource() throws {
        let slot = FactSlot(.shown(try fact(.verified, source: source), status: .stale))
        #expect(slot.kind == .stale)
        #expect(slot.statusKey == FactStatus.stale.labelKey)
        #expect(slot.textKeys == [FactStatus.stale.labelKey, FactSlot.sourceLeadIn])
        #expect(slot.publisher == "Test Publisher")
    }

    @Test func demoSaysDemoAndInventsNoSource() throws {
        let slot = FactSlot(.shown(try fact(.demo, source: nil), status: .demo))
        #expect(slot.kind == .demo)
        #expect(slot.statusKey == FactStatus.demo.labelKey)
        #expect(slot.sourceLeadInKey == nil && slot.publisher == nil && slot.checked == nil)
    }

    @Test func notApplicableCarriesReasonAndOptionalLedgerFact() {
        let reason = StringKey(key: "trash.not_applicable.city", table: "Cards")
        let ref = FactRef(regionPackID: "us-fl-miami", ledgerFactID: "us-fl-miami.trash.day")
        let slot = FactSlot(.notApplicable("us-fl-miamidade.trash.day", reason: reason, deferTo: ref))
        #expect(slot.kind == .notApplicable)
        #expect(slot.reason == reason && slot.deferTo == ref)
        #expect(slot.desk == nil)                  // deferTo is a ledger fact, not a desk
        let noRef = FactSlot(.notApplicable("x.y.z", reason: reason, deferTo: nil))
        #expect(noRef.deferTo == nil && noRef.textKeys == [reason])
    }

    @Test func handedToDeskSaysNoSourceAndNamesDesk() {
        let slot = FactSlot(.handedToDesk("us-fl-miamidade.311.hours", desk: "us-fl-miamidade.311"))
        #expect(slot.kind == .handedToDesk)
        #expect(slot.statusKey == FactStatus.unsourced.labelKey)
        #expect(slot.desk == "us-fl-miamidade.311")
        #expect(slot.publisher == nil)
    }

    @Test func sourceUnavailableNamesDeskAndIsNotNoSource() {
        let slot = FactSlot(.sourceUnavailable("us-fl-miamidade.311.hours", desk: "us-fl-miamidade.311"))
        #expect(slot.kind == .sourceUnavailable)
        #expect(slot.desk == "us-fl-miamidade.311")
        #expect(slot.statusKey != FactStatus.unsourced.labelKey)
        #expect(slot.publisher == nil && slot.checked == nil)
    }

    @Test func seedLeadInsCoverEverySeedSlot() throws {
        let slots = [
            FactSlot(.shown(try fact(.verified, source: source), status: .verified)),
            FactSlot(.shown(try fact(.verified, source: source), status: .stale)),
            FactSlot(.shown(try fact(.demo, source: nil), status: .demo)),
            FactSlot(.handedToDesk("a.b.c", desk: "a.desk")),
        ]
        for slot in slots {
            #expect(slot.textKeys.contains { FactSlot.seedLeadInKeys.contains($0) }, "\(slot.kind)")
        }
    }
}
