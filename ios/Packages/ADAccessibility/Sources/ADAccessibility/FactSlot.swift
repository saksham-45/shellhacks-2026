// What the source slot of one fact row says and speaks (docs/accessibility.md A11Y-FACT-01/02).
// Derived only from ADCore's `FactLine`; data, not strings: ADLocale resolves the keys, formats the
// date, and names the desk. The fact row combines value + slot into ONE element (A11Y-VO-04).

import Foundation
import ADCore

public struct FactSlot: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        /// `.shown(fact, status: .verified)`: "Source: <publisher>. Checked <date>."
        case sourced
        /// `.shown(fact, status: .stale)`: "May be out of date." then the sourced line.
        case stale
        /// `.shown(fact, status: .demo)`: "Demo" (plus publisher/date only if the fact has them).
        case demo
        /// `.notApplicable(id, reason:, deferTo:)`: the reason; `deferTo` is a ledger fact in another
        /// region pack (e.g. the City of Miami's trash day), never a desk.
        case notApplicable
        /// `.handedToDesk(id, desk:)`: "No source" and the desk that answers instead.
        case handedToDesk
        /// `.sourceUnavailable(id, desk:)`: "Couldn't check the source right now" and the desk. No value.
        /// ADCore has no key for this wording yet (requested from Household); until it lands the row
        /// shows the desk only and `statusKey` is nil. Never shown as "No source".
        case sourceUnavailable
    }

    public let factID: FactID
    public let kind: Kind
    /// Status word read first (demo, stale, no source). Nil for a verified fact.
    public let statusKey: StringKey?
    /// "Source" lead-in before the publisher. Nil when there is no publisher.
    public let sourceLeadInKey: StringKey?
    /// `Source.publisher`, shown as-is (never translated).
    public let publisher: String?
    /// `Fact.retrievedAt`, spoken and shown as a date by ADLocale ("Checked <date>").
    public let checked: Date?
    /// Why the fact does not apply at this pin (content key).
    public let reason: StringKey?
    /// The ledger fact that answers instead, in another pack. Optional.
    public let deferTo: FactRef?
    /// The desk that answers instead. For `.handedToDesk`; nil only in the defensive case below.
    public let desk: DeskID?

    /// ADCore's key for the "Source" lead-in (`SourceLine.sourced.labelKey`, table "ADCore").
    public static let sourceLeadIn: StringKey = SourceLine.sourced([], lastChecked: .distantPast).labelKey

    public init(_ line: FactLine) {
        switch line {
        case let .shown(fact, status):
            let publisher = fact.source?.publisher
            let lead = publisher == nil ? nil : FactSlot.sourceLeadIn
            let kind: Kind
            let statusKey: StringKey?
            switch status {
            case .verified: kind = .sourced; statusKey = nil
            case .stale: kind = .stale; statusKey = FactStatus.stale.labelKey
            case .demo: kind = .demo; statusKey = FactStatus.demo.labelKey
            case .unsourced:
                // ADCore never builds this (its backstop hands unsourced facts to the desk), but the
                // enum allows it: never show it as sourced. The row uses the card's desk.
                self.init(factID: fact.id, kind: .handedToDesk, statusKey: FactStatus.unsourced.labelKey)
                return
            }
            self.init(factID: fact.id, kind: kind, statusKey: statusKey, sourceLeadInKey: lead,
                      publisher: publisher, checked: fact.retrievedAt)
        case let .notApplicable(id, reason, deferTo):
            self.init(factID: id, kind: .notApplicable, reason: reason, deferTo: deferTo)
        case let .handedToDesk(id, desk):
            self.init(factID: id, kind: .handedToDesk, statusKey: FactStatus.unsourced.labelKey, desk: desk)
        case let .sourceUnavailable(id, desk):
            self.init(factID: id, kind: .sourceUnavailable, desk: desk)
        }
    }

    init(factID: FactID, kind: Kind, statusKey: StringKey? = nil, sourceLeadInKey: StringKey? = nil,
         publisher: String? = nil, checked: Date? = nil, reason: StringKey? = nil,
         deferTo: FactRef? = nil, desk: DeskID? = nil) {
        self.factID = factID
        self.kind = kind
        self.statusKey = statusKey
        self.sourceLeadInKey = sourceLeadInKey
        self.publisher = publisher
        self.checked = checked
        self.reason = reason
        self.deferTo = deferTo
        self.desk = desk
    }

    /// Keys in reading order (status word, then "Source" lead-in, then the reason).
    public var textKeys: [StringKey] { [statusKey, sourceLeadInKey, reason].compactMap { $0 } }

    /// Every ADCore key a seed-scope slot can start with. The UI test checks that each fact element's
    /// label contains one of these, resolved in the surface language. (`.notApplicable` reasons are
    /// content keys and `.sourceUnavailable` has no key yet; both are checked manually, M1. The offline
    /// UI-test seed must not produce `.sourceUnavailable`.)
    public static let seedLeadInKeys: [StringKey] = [
        sourceLeadIn, FactStatus.demo.labelKey, FactStatus.stale.labelKey, FactStatus.unsourced.labelKey,
    ]
}
