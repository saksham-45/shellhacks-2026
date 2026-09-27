import Foundation
import ADCore

// Fee Check (wow-factors plan #2, demo beat 0:10-0:30): someone names a price; the phone answers with the official
// fee from the local ledger, its source, and the desk. Rules: no verdict on the private price, no "pay / don't pay",
// every answer names a desk, and every number comes from a verified ledger row (never typed here).

/// What the person was asked to pay for. Each topic reads exactly one ledger fee.
public enum FeeTopic: String, CaseIterable, Hashable, Sendable {
    case license, licenseRenewal = "license-renewal", idCard = "id-card"

    public var feeFactID: String {
        switch self {
        case .license: "us-fl.flhsmv.fee.class-e-original"
        case .licenseRenewal: "us-fl.flhsmv.fee.class-e-renewal"
        case .idCard: "us-fl.flhsmv.fee.id-card-original"
        }
    }

    /// Short chip word ("licencia").
    public var chipKey: String { "regions.fee.topic.\(rawValue)" }
    /// Noun phrase inside the answer sentence ("la primera licencia").
    public var phraseKey: String { "regions.fee.phrase.\(rawValue)" }
}

public enum FeeCheckIDs {
    public static let serviceFee = "us-fl.flhsmv.fee.tax-collector-service-fee"
    /// The office that adds the service fee and issues the credential in Miami-Dade.
    public static let taxCollectorDesk = "us-fl-miamidade.tax-collector"
    /// Where an ask with no ledger fee goes.
    public static let fallbackDesk = "us-fl-miamidade.311"
}

/// The extracted ask. `quotedAmount` is what the person was told, shown on the chip and never judged.
public struct FeeAsk: Hashable, Sendable {
    public var quotedAmount: Decimal?
    public var topic: FeeTopic?
    public init(quotedAmount: Decimal?, topic: FeeTopic?) {
        self.quotedAmount = quotedAmount
        self.topic = topic
    }
}

/// Deterministic keyword extraction for es/en/ht transcripts. It runs on the device with no network, so it is the
/// offline path and the check on any model extraction: it only reads digits and a few topic words.
public enum FeeAskParser {
    public static func parse(_ transcript: String) -> FeeAsk {
        let t = fold(transcript)
        return FeeAsk(quotedAmount: amount(in: t), topic: topic(in: t))
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// "$300", "300 dolares", "300 dollars", "300 dola", "$1,200.50". Only digits count; spelled-out numbers are
    /// left to the chip's manual correction.
    static func amount(in t: String) -> Decimal? {
        let patterns = [
            #"\$\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)"#,
            #"([0-9][0-9,]*(?:\.[0-9]{1,2})?)\s*(?:usd|dolares|dolar|dollars|dollar|dola|bucks)\b"#,
        ]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
                  let r = Range(m.range(at: 1), in: t) else { continue }
            let digits = t[r].replacingOccurrences(of: ",", with: "")
            if let d = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")) { return d }
        }
        return nil
    }

    static func topic(in t: String) -> FeeTopic? {
        func has(_ words: [String]) -> Bool { words.contains { t.range(of: $0) != nil } }
        let license = has(["licencia", "license", "licence", "lisans", "pemi kondi"])
        let renewal = has(["renov", "renew", "renouvl"])
        let idCard = has(["identificacion", "id card", "tarjeta de id", "kat idantite", "kat id", "carte d'identite"])
        if idCard && !license { return .idCard }
        if license { return renewal ? .licenseRenewal : .license }
        return nil
    }
}

/// Formats money for the screen and voice. The app passes ADLocale's formatter; ADCityPack formats nothing itself.
public typealias CheckMoneyFormat = @Sendable (_ amount: Decimal, _ currency: String, _ language: CheckLanguage) -> String

/// "¿Eso es normal? · $300 · licencia": what the phone heard, so a garbled number is visible and correctable.
public struct FeeChip: Hashable, Sendable {
    public let ask: FeeAsk
    public init(_ ask: FeeAsk) { self.ask = ask }

    public func text(_ language: CheckLanguage, strings: some CheckStrings, money: CheckMoneyFormat) -> String {
        var parts = [strings.text("regions.fee.chip.question", language)]
        if let a = ask.quotedAmount { parts.append(money(a, "USD", language)) }
        if let topic = ask.topic { parts.append(strings.text(topic.chipKey, language)) }
        return parts.joined(separator: " · ")
    }
}

/// The ledger's answer to an ask. Built only from verified facts; anything else becomes `.unsourced` with a desk.
public struct FeeAnswer: Sendable {
    public enum Body: Sendable {
        /// The state fee, and the Tax Collector service fee when the ledger has it verified.
        case official(topic: FeeTopic, fee: Fact, serviceFee: Fact?)
        /// No verified fee for this ask: the answer names the desk and no number.
        case unsourced(topic: FeeTopic?)
    }

    public let body: Body
    public let desk: CheckLedger.DeskEntry
    /// The desk's phone, when the ledger has it verified.
    public let deskPhone: Fact?

    /// Every source behind the numbers, in order (for the source chip and "as of" date).
    public var facts: [Fact] {
        guard case let .official(_, fee, service) = body else { return [] }
        return [fee] + (service.map { [$0] } ?? [])
    }

    /// The answer sentence(s) to show and speak, in one language.
    public func lines(_ language: CheckLanguage, strings: some CheckStrings, money: CheckMoneyFormat) -> [String] {
        let deskName = desk.names[language.rawValue] ?? desk.names["en"] ?? desk.desk.id.rawValue
        var out: [String] = []
        switch body {
        case let .official(topic, fee, service):
            guard case let .money(amount, currency)? = fee.displayValue, let src = fee.source else { return [] }
            let sourceLabel = strings.template("regions.fee.source.\(src.id.rawValue)", language) ?? src.publisher
            let phrase = strings.text(topic.phraseKey, language)
            if let service, case let .money(extra, extraCurrency)? = service.displayValue {
                out.append(strings.text("regions.fee.answer.with-service-fee", language,
                                        [money(amount, currency, language), phrase, money(extra, extraCurrency, language), sourceLabel]))
            } else {
                out.append(strings.text("regions.fee.answer.state-fee", language,
                                        [money(amount, currency, language), phrase, sourceLabel]))
            }
        case .unsourced:
            out.append(strings.text("regions.fee.answer.unsourced", language, [deskName]))
            return out
        }
        if case let .phone(digits)? = deskPhone?.displayValue {
            out.append(strings.text("regions.fee.desk-line", language, [deskName, CheckPhone.spaced(digits)]))
        } else {
            out.append(strings.text("regions.fee.desk-only", language, [deskName]))
        }
        return out
    }
}

public enum FeeCheck {
    /// Pure and offline: the same ask and ledger always give the same answer.
    public static func answer(_ ask: FeeAsk, ledger: CheckLedger) -> FeeAnswer? {
        func phone(_ entry: CheckLedger.DeskEntry) -> Fact? {
            entry.desk.contactFacts.first { $0.rawValue.hasSuffix(".phone") }.flatMap { ledger.facts[$0] }
                .flatMap { $0.displayValue == nil ? nil : $0 }
        }
        guard let taxCollector = ledger.desk(FeeCheckIDs.taxCollectorDesk),
              let fallback = ledger.desk(FeeCheckIDs.fallbackDesk) else { return nil }
        guard let topic = ask.topic, let fee = ledger.fact(topic.feeFactID), fee.status == .verified,
              case .money? = fee.displayValue else {
            return FeeAnswer(body: .unsourced(topic: ask.topic), desk: ask.topic == nil ? fallback : taxCollector,
                             deskPhone: phone(ask.topic == nil ? fallback : taxCollector))
        }
        let service = ledger.fact(FeeCheckIDs.serviceFee).flatMap { $0.status == .verified ? $0 : nil }
        return FeeAnswer(body: .official(topic: topic, fee: fee, serviceFee: service), desk: taxCollector,
                         deskPhone: phone(taxCollector))
    }
}

public enum CheckPhone {
    /// "3053755448" -> "305-375-5448"; other lengths are returned unchanged.
    public static func spaced(_ digits: String) -> String {
        let d = digits.filter(\.isNumber)
        guard d.count == 10 else { return digits }
        let a = d.prefix(3), b = d.dropFirst(3).prefix(3), c = d.suffix(4)
        return "\(a)-\(b)-\(c)"
    }
}
