import ADCore

/// Keys ADLocale owns, all in `Resources/ADLocale.xcstrings` (table "ADLocale").
/// A test asserts every one exists in es, en and ht.
public enum ADLocaleKey {
    public static let table = "ADLocale"
    static func k(_ key: String) -> StringKey { StringKey(key: key, table: table) }

    public static func weekday(_ day: Weekday) -> StringKey { k("weekday.\(day.rawValue)") }
    /// 1...12. Used for Creole dates only (Foundation's ht data is French).
    public static func month(_ month: Int) -> StringKey { k("month.\(month)") }
    /// Unit word for `FactValue.quantity(_, unit:)`: "unit.<unit>". Added when a ledger unit needs one.
    public static func unit(_ unit: String) -> StringKey { k("unit.\(unit)") }

    public static let listPair = k("list.pair")            // "%1$@ y %2$@"
    public static let listMiddle = k("list.middle")        // "%1$@, %2$@"
    public static let listEnd = k("list.end")              // "%1$@ y %2$@"
    public static let everyDay = k("weekdays.every_day")   // "todos los días"
    public static let mondayToFriday = k("weekdays.mon_to_fri")  // "de lunes a viernes"
    public static let dateLong = k("date.long")            // ht: "%1$@ %2$@ %3$@" (day, month word, year)
    public static let moneyDollars = k("money.dollars")    // plural, %lld
    public static let moneyCents = k("money.cents")        // plural, %lld
    public static let moneyDollarsAndCents = k("money.dollars_and_cents")
    public static let quantity = k("quantity")             // "%1$@ %2$@" (number, unit word)
    public static let placeWithAddress = k("place.with_address")
    public static let factLabeled = k("fact.labeled")               // value · label (demo/stale)
    public static let factLabeledSpoken = k("fact.labeled.spoken")  // label first when spoken
    public static let handedToDesk = k("fact.handed_to_desk")       // "... Ask: <desk>"
    public static let sourceUnavailable = k("fact.source_unavailable") // "couldn't check right now. Ask: <desk>"
    public static let sourceLine = k("source.line")                 // "<Source>: <publishers> · <checked>"
    public static let lastChecked = k("source.last_checked")        // "revisado el %@"
    public static let noSource = k("source.no_source")              // "<no source label>: <desk>"
    public static let speechSource = k("speech.card.source")        // "Fuente: %@."
    public static let speechChecked = k("speech.card.checked")      // "Revisado el %@."
    /// Leave-the-app confirmations (router `openMap` / `callDesk`), spoken and shown.
    public static let confirmOpenMap = k("confirm.leave_app.map")   // "... ir a <place or desk name>?"
    public static let confirmCall = k("confirm.leave_app.call")     // "... llamar a <desk name>?"
    /// Shown next to fallback English (a string not yet translated into es/ht).
    public static let fallbackEnglishBadge = k("fallback.englishBadge")  // "(en inglés)"
    public static let fallbackEnglishHint = k("fallback.englishHint")    // "Este texto aún no está traducido."

    /// Every fixed key (weekdays, months and the list above). Units are open-ended and excluded.
    public static var all: [StringKey] {
        Weekday.allCases.map(weekday) + (1...12).map(month) + [
            listPair, listMiddle, listEnd, everyDay, mondayToFriday, dateLong,
            moneyDollars, moneyCents, moneyDollarsAndCents, quantity, placeWithAddress,
            factLabeled, factLabeledSpoken, handedToDesk, sourceUnavailable, sourceLine, lastChecked, noSource,
            speechSource, speechChecked, confirmOpenMap, confirmCall, fallbackEnglishBadge, fallbackEnglishHint,
        ] + SurfaceLanguage.allCases.map(\.autonymKey)
    }
}

/// Desk names (decision D5): key "desk.<DeskID>" in the catalog of the pack that declares the
/// desk. The table defaults to "ADCityPack"; change it in one place if packs get their own tables.
public struct DeskNaming: Sendable, Hashable {
    public var table: String
    public init(table: String = "ADCityPack") { self.table = table }
    public func key(for desk: DeskID) -> StringKey { StringKey(key: "desk.\(desk.rawValue)", table: table) }
}

extension Weekday {
    /// "weekday.<raw>" in ADLocale's own table (lowercase in Spanish, as written mid-sentence).
    public var stringKey: StringKey { ADLocaleKey.weekday(self) }
}
