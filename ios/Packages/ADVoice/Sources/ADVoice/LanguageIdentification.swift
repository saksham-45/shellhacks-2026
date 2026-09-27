import Foundation
import ADCore
import ADLocale

/// Scores a transcript's TEXT for es / en / ht. Pure Swift, runs everywhere, never outputs
/// French (the output set is fixed to the three surfaces). Data: `Resources/LanguageID.json`
/// (hand-written function words and diacritics; provenance stated in the file).
public struct TextLanguageDetector: Sendable {
    struct Model: Decodable {
        struct Lang: Decodable { var words: [String]; var marks: String }
        var languages: [String: Lang]
    }

    let words: [SurfaceLanguage: Set<String>]
    let marks: [SurfaceLanguage: Set<Character>]
    let lexicon: CommandLexicon?

    public init(modelData: Data, lexicon: CommandLexicon? = nil) throws {
        let m = try JSONDecoder().decode(Model.self, from: modelData)
        var w: [SurfaceLanguage: Set<String>] = [:]
        var k: [SurfaceLanguage: Set<Character>] = [:]
        for (tag, lang) in m.languages {
            guard let s = SurfaceLanguage(rawValue: tag) else { continue }   // anything else (fr) is ignored
            w[s] = Set(lang.words.map { $0.lowercased() })
            k[s] = Set(lang.marks)
        }
        words = w
        marks = k
        self.lexicon = lexicon
    }

    /// The shipped model, plus the shipped command lexicon (short commands like "wi" or "dale").
    public static func bundled() throws -> TextLanguageDetector {
        guard let url = Bundle.module.url(forResource: "LanguageID", withExtension: "json") else {
            throw VoiceError.notConfigured("text-lid")
        }
        return try TextLanguageDetector(modelData: Data(contentsOf: url), lexicon: try? CommandLexicon.bundled())
    }

    /// Normalized scores (sum 1) over es/en/ht; empty when the text carries no evidence.
    public func scores(_ text: String) -> [SurfaceLanguage: Double] {
        var raw: [SurfaceLanguage: Double] = [:]
        for token in TextNormalizer.wordsKeepingDiacritics(text) {
            let folded = TextNormalizer.normalize(token)
            for (lang, set) in words where set.contains(token) || set.contains(folded) {
                raw[lang, default: 0] += 1
            }
            for (lang, set) in marks where token.contains(where: set.contains) {
                raw[lang, default: 0] += 0.5
            }
        }
        for ch in text where ch == "¿" || ch == "¡" { raw[.es, default: 0] += 0.5 }
        if let lexicon {
            let matched = Set(lexicon.match(text).map(\.language))
            if matched.count == 1, let only = matched.first { raw[only, default: 0] += 2 }
        }
        let total = raw.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return raw.mapValues { $0 / total }
    }

    /// The winning language when it leads by at least `margin`; nil when unclear.
    public func detect(_ text: String, margin: Double = 0.2) -> SurfaceLanguage? {
        let ranked = scores(text).sorted { $0.value > $1.value }
        guard let top = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        return top.value - second >= margin ? top.key : nil
    }
}

/// Picks the language of the sentence from transcripts + text scores, constrained to the
/// candidates, biased toward the prior (explicit setting / last sentence / surface).
public enum LanguageIdentification {
    public struct Decision: Hashable, Sendable {
        public let language: Locale.Language
        public let transcript: Transcript
        /// True when the top two were within the margin (the prior decided): confirm first.
        public let isAmbiguous: Bool
        public let score: Double
    }

    /// - Each transcript is scored by how well its TEXT agrees with the language it was
    ///   transcribed in (0.7) plus engine confidence (0.3); the prior adds 0.1.
    /// - Transcripts in a non-candidate language (fr, fr-HT, ...) are discarded, never mapped.
    /// - Think-in languages outside es/en/ht have no text model; they win only through the
    ///   engine confidence and the prior (the person's explicit setting), never by guessing.
    public static func choose(_ transcripts: [Transcript], detector: TextLanguageDetector,
                              candidates: LanguageCandidates, prior: Locale.Language,
                              margin: Double = 0.15) -> Decision? {
        var scored: [(Transcript, Locale.Language, Double)] = []
        for t in transcripts where !t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let lang = candidates.candidate(for: t.language) else { continue }
            let text = detector.scores(t.text)
            let agreement: Double = if let s = SurfaceLanguage(lang) { text[s] ?? 0 } else { text.isEmpty ? 0.5 : 0 }
            var score = 0.7 * agreement + 0.3 * (t.confidence ?? 0.5)
            if lang.hasSameLanguageCode(as: prior) { score += 0.1 }
            scored.append((t, lang, score))
        }
        scored.sort { $0.2 > $1.2 }
        guard let best = scored.first else { return nil }
        let runnerUp = scored.dropFirst().first { !$0.1.hasSameLanguageCode(as: best.1) }
        let ambiguous = runnerUp.map { best.2 - $0.2 < margin } ?? false
        if ambiguous, let priorPick = scored.first(where: { $0.1.hasSameLanguageCode(as: prior) }) {
            return Decision(language: priorPick.1, transcript: priorPick.0, isAmbiguous: true, score: priorPick.2)
        }
        return Decision(language: best.1, transcript: best.0, isAmbiguous: ambiguous, score: best.2)
    }
}
