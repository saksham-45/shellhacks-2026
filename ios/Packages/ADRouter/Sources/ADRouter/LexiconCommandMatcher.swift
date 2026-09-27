import Foundation
import ADCore

/// The on-device matcher (ARCHITECTURE.md §13.2 step 1). Deterministic, no network. Every match
/// returns confidence 1.0; anything it does not recognize returns nil and goes to `/v1/ask`.
///
/// Order: yes/no while a confirmation waits; command keys; the labels of the choices on offer;
/// the onboarding question being asked; card utterances (2-3 matching cards become one clarifying
/// question, never a guess).
public struct LexiconCommandMatcher: CommandMatcher {
    public let lexicon: any CommandLexiconProviding
    public let cards: [CardUtterances]
    public let labels: (any LabelTextResolving)?

    public init(lexicon: any CommandLexiconProviding, cards: [CardUtterances] = [],
                labels: (any LabelTextResolving)? = nil) {
        self.lexicon = lexicon
        self.cards = cards
        self.labels = labels
    }

    /// Clarifying question for "which card did you mean" (table "ADRouter").
    public static let whichCardQuestion = RouterText.clarifyWhichCard

    public func match(_ u: Utterance) -> IntentResolution? { match(u, choices: []) }

    public func match(_ u: Utterance, choices: [ClarifyOption]) -> IntentResolution? {
        let text = Normalized(u.text)
        guard !text.isEmpty else { return nil }
        func resolved(_ action: AppAction, grounding: Grounding? = nil) -> IntentResolution {
            IntentResolution(action: action, grounding: grounding, confidence: 1.0, replyLanguage: u.language)
        }

        if u.context.awaitingConfirmation, let key = bestCommand(in: text, language: u.language, among: [.yes, .no]),
           let action = key.action(in: u.context) {
            return resolved(action)
        }
        if let key = bestCommand(in: text, language: u.language, among: CommandKey.allCases),
           let action = key.action(in: u.context) {
            return resolved(action)
        }
        if let id = choice(in: text, language: u.language, choices: choices) {
            return resolved(.choose(id))
        }
        if case .onboarding(let step)? = u.context.destination, let answer = onboardingAnswer(step, u, text) {
            return resolved(.answerOnboarding(answer))
        }
        return cardMatch(text, u)
    }

    // MARK: Commands

    /// The command whose phrase matches, preferring the longest phrase; the utterance's own
    /// language first, then the lexicon's other languages.
    func bestCommand(in text: Normalized, language: String, among keys: [CommandKey]) -> CommandKey? {
        let languages = [language] + lexicon.languages.filter { InMemoryCommandLexicon.base($0) != InMemoryCommandLexicon.base(language) }
        for lang in languages {
            var best: (key: CommandKey, length: Int)?
            for key in keys {
                for phrase in lexicon.phrases(for: key, language: lang) {
                    let p = Normalized(phrase)
                    guard !p.isEmpty, text.contains(words: p) else { continue }
                    if p.value.count > (best?.length ?? 0) { best = (key, p.value.count) }
                }
            }
            if let best { return best.key }
        }
        return nil
    }

    // MARK: Choices

    func choice(in text: Normalized, language: String, choices: [ClarifyOption]) -> ClarifyOptionID? {
        guard let labels, !choices.isEmpty else { return nil }
        let hits = choices.filter { option in
            guard let label = labels.text(for: option.label, language: language).map(Normalized.init), !label.isEmpty else { return false }
            return text.contains(words: label) || (text.value.count >= 3 && label.contains(words: text))
        }
        return hits.count == 1 ? hits[0].id : nil
    }

    // MARK: Onboarding (ADCore's four questions, answerable by voice)

    func onboardingAnswer(_ step: OnboardingStep, _ u: Utterance, _ text: Normalized) -> OnboardingAnswer? {
        switch step {
        case .pin:
            return nil  // a choice between the pins: ordinals or the pin's label
        case .people:
            let people = Self.people(from: u.text)
            return people.isEmpty ? nil : .people(people)
        case .originAndLanguage:
            let origin = Self.region(in: text, language: u.language).map(Origin.init(countryCode:))
            let thinkIn = Self.languageCode(in: text, language: u.language) ?? InMemoryCommandLexicon.base(u.language)
            return .originAndLanguage(origin: origin, thinkIn: thinkIn)
        case .goal:
            guard let labels else { return nil }
            let hits = Goal.allCases.filter { goal in
                guard let label = labels.text(for: goal.labelKey, language: u.language).map(Normalized.init), !label.isEmpty else { return false }
                return text.contains(words: label) || label.contains(words: text)
            }
            return hits.count == 1 ? .goal(hits[0]) : nil
        }
    }

    /// "Priya 20, Rosa 58" -> two people. Free text: each comma-separated part is one person; the
    /// first number in a part is the age, the rest is the name as said.
    static func people(from text: String) -> [OnboardingPerson] {
        text.split(separator: ",").compactMap { part in
            var name: [Substring] = []
            var age: Int?
            for word in part.split(separator: " ") {
                if age == nil, let n = Int(word) { age = n } else { name.append(word) }
            }
            let display = name.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            return display.isEmpty ? nil : OnboardingPerson(displayName: display, age: age)
        }
    }

    /// A country named in the sentence, by the system's own region names in that language (no
    /// country list of ours). Longest name wins, so "Dominican Republic" beats a shorter overlap.
    static func region(in text: Normalized, language: String) -> String? {
        let locale = Locale(identifier: language)
        var best: (code: String, length: Int)?
        for region in Locale.Region.isoRegions where region.subRegions.isEmpty {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter),
                  let name = locale.localizedString(forRegionCode: code).map(Normalized.init), name.value.count >= 3,
                  text.contains(words: name) else { continue }
            if name.value.count > (best?.length ?? 0) { best = (code, name.value.count) }
        }
        return best?.code
    }

    /// A language named in the sentence ("hindi", "creole"), by the system's own language names.
    static func languageCode(in text: Normalized, language: String) -> String? {
        let locale = Locale(identifier: language)
        var best: (code: String, length: Int)?
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) where code.count == 2 {
            guard let name = locale.localizedString(forLanguageCode: code).map(Normalized.init), name.value.count >= 3,
                  text.contains(words: name) else { continue }
            if name.value.count > (best?.length ?? 0) { best = (code, name.value.count) }
        }
        return best?.code
    }

    // MARK: Cards

    func cardMatch(_ text: Normalized, _ u: Utterance) -> IntentResolution? {
        var hits: [(card: CardID, length: Int)] = []
        let base = InMemoryCommandLexicon.base(u.language)
        for entry in cards {
            let phrases = entry.phrases.filter { InMemoryCommandLexicon.base($0.key) == base }.flatMap(\.value)
            let longest = phrases.map(Normalized.init).filter { !$0.isEmpty && text.contains(words: $0) }.map(\.value.count).max()
            if let longest { hits.append((entry.cardID, longest)) }
        }
        hits.sort { ($0.length, $1.card.rawValue) > ($1.length, $0.card.rawValue) }
        let person = u.context.personID
        if hits.count == 1 {
            let card = hits[0].card
            return IntentResolution(action: .navigate(.card(card, person: person)), grounding: .card(card, facts: []),
                                    confidence: 1.0, replyLanguage: u.language)
        }
        guard hits.count >= 2 else { return nil }
        let options = hits.prefix(3).map { hit in
            ClarifyOption(id: ClarifyOptionID(rawValue: "card.\(hit.card.rawValue)"),
                          label: Card.defaultTitleKey(for: hit.card),
                          action: .navigate(.card(hit.card, person: person)))
        }
        guard let clarification = try? Clarification(question: Self.whichCardQuestion, options: Array(options)) else { return nil }
        return IntentResolution(action: nil, grounding: nil, confidence: 0.5, clarification: clarification,
                                replyLanguage: u.language)
    }
}

/// Lowercased, diacritics folded, punctuation dropped, single spaces. Both sides of every
/// comparison go through this, so "dezyèm" and "dezyem" match.
struct Normalized: Hashable {
    let value: String
    let words: [Substring]

    init(_ raw: String) {
        let folded = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
        let cleaned = String(folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " })
        words = cleaned.split(separator: " ")
        value = words.joined(separator: " ")
    }

    var isEmpty: Bool { words.isEmpty }

    /// True when `other`'s words appear in order, as whole words.
    func contains(words other: Normalized) -> Bool {
        guard !other.words.isEmpty, other.words.count <= words.count else { return false }
        for start in 0...(words.count - other.words.count) where Array(words[start..<(start + other.words.count)]) == other.words {
            return true
        }
        return false
    }
}
