import Foundation

/// Display text that always carries its language, run by run, so VoiceOver and speech never
/// guess. A run with `language == nil` inherits the sentence language (proper names, digits).
public struct ResolvedText: Hashable, Sendable, CustomStringConvertible {
    public struct Run: Hashable, Sendable {
        public let text: String
        public let language: Locale.Language?
        /// Read character by character (phone digits).
        public let spellsOut: Bool
        /// English standing in for a missing es/ht string (speech refuses it without opt-in).
        public let isFallback: Bool
        /// The visible `⟦table:key⟧` marker of a missing key (never spoken).
        public let isMissing: Bool

        public init(_ text: String, language: Locale.Language? = nil, spellsOut: Bool = false,
                    isFallback: Bool = false, isMissing: Bool = false) {
            self.text = text
            self.language = language
            self.spellsOut = spellsOut
            self.isFallback = isFallback
            self.isMissing = isMissing
        }
    }

    public let runs: [Run]
    /// Base language of the sentence.
    public let language: Locale.Language
    /// True when the requested language had no string and another language filled in (the
    /// tag is then that other language, never the requested one).
    public let isFallback: Bool
    /// True when the key or table is missing and the text is (or, inside a sentence, contains)
    /// the visible `⟦table:key⟧` marker.
    public let isMissing: Bool

    public init(runs: [Run], language: Locale.Language, isFallback: Bool = false, isMissing: Bool = false) {
        self.runs = ResolvedText.merge(runs, base: language)
        self.language = language
        self.isFallback = isFallback
        self.isMissing = isMissing
    }

    public init(_ text: String, language: Locale.Language) {
        self.init(runs: [Run(text)], language: language)
    }

    public var plain: String { runs.map(\.text).joined() }
    public var description: String { plain }

    /// Language actually in effect for a run.
    public func effectiveLanguage(of run: Run) -> Locale.Language { run.language ?? language }

    /// Runs whose language differs from the base. Used by tests and the VoiceOver bridge.
    public var foreignRuns: [Run] {
        runs.filter { $0.language != nil }
    }

    /// Attributed form for SwiftUI `Text`: every run carries `languageIdentifier` (base language
    /// on untagged runs), and phone runs spell out on Apple platforms.
    public var attributed: AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            piece.languageIdentifier = effectiveLanguage(of: run).minimalIdentifier
            #if canImport(Darwin)
            if run.spellsOut { piece.accessibilitySpeechSpellsOutCharacters = true }
            #endif
            out.append(piece)
        }
        return out
    }

    /// Spoken form: one segment per language (and per fallback/missing state), so a voice never
    /// gets mixed-language input and speech can refuse only the fallback or missing pieces.
    public var spoken: SpokenText {
        var segments: [SpokenText.Segment] = []
        // Runs carry their own fallback flag; a whole-text flag with no run flags (a value built
        // by hand) marks every run.
        let wholeFallback = isFallback && !runs.contains(where: \.isFallback)
        for run in runs {
            let lang = effectiveLanguage(of: run)
            let fb = wholeFallback || run.isFallback, ms = run.isMissing
            if let last = segments.last, last.language.minimalIdentifier == lang.minimalIdentifier,
               last.isFallback == fb, last.isMissing == ms {
                segments[segments.count - 1] = SpokenText.Segment(last.text + run.text, language: lang, isFallback: fb, isMissing: ms)
            } else {
                segments.append(SpokenText.Segment(run.text, language: lang, isFallback: fb, isMissing: ms))
            }
        }
        // A segment of only spaces or punctuation (a lone ".") is never read.
        return SpokenText(segments: segments.filter { $0.text.contains { $0.isLetter || $0.isNumber } })
    }

    /// Joins adjacent runs with the same language and spelling. A run tagged with the base
    /// language is stored untagged so equality does not depend on how a value was built.
    static func merge(_ runs: [Run], base: Locale.Language) -> [Run] {
        var out: [Run] = []
        for r in runs where !r.text.isEmpty {
            let lang = (r.language?.minimalIdentifier == base.minimalIdentifier) ? nil : r.language
            let run = Run(r.text, language: lang, spellsOut: r.spellsOut, isFallback: r.isFallback, isMissing: r.isMissing)
            if let last = out.last, last.language == run.language, last.spellsOut == run.spellsOut,
               last.isFallback == run.isFallback, last.isMissing == run.isMissing {
                out[out.count - 1] = Run(last.text + run.text, language: last.language, spellsOut: last.spellsOut,
                                         isFallback: last.isFallback, isMissing: last.isMissing)
            } else {
                out.append(run)
            }
        }
        return out
    }
}

/// The stacked hero: the surface line and, under it, the companion language (decision D3).
/// Two separate tagged lines, never one combined string.
public struct StackedLine: Hashable, Sendable {
    public let primary: ResolvedText
    public let companion: ResolvedText?

    /// What `StackedLineView` exposes, in reading order: each line's speech language, and the
    /// primary line as the header. Kept platform-neutral so Linux tests can check it.
    public struct AccessibilityLine: Hashable, Sendable {
        public let text: ResolvedText
        public let speechLanguage: Locale.Language
        public let isHeader: Bool
    }
    public var accessibilityLines: [AccessibilityLine] {
        [AccessibilityLine(text: primary, speechLanguage: primary.language, isHeader: true)]
            + (companion.map { [AccessibilityLine(text: $0, speechLanguage: $0.language, isHeader: false)] } ?? [])
    }

    public init(primary: ResolvedText, companion: ResolvedText?) {
        self.primary = primary
        self.companion = companion
    }
}

/// What a voice reads: segments, each in exactly one language.
public struct SpokenText: Hashable, Sendable, CustomStringConvertible {
    public struct Segment: Hashable, Sendable {
        public let text: String
        public let language: Locale.Language
        /// Fallback English for a missing es/ht string: not read unless the listener opts in.
        public let isFallback: Bool
        /// A missing-key marker: never read aloud.
        public let isMissing: Bool
        public init(_ text: String, language: Locale.Language, isFallback: Bool = false, isMissing: Bool = false) {
            self.text = text
            self.language = language
            self.isFallback = isFallback
            self.isMissing = isMissing
        }
        func with(fallback: Bool) -> Segment { Segment(text, language: language, isFallback: fallback, isMissing: isMissing) }
    }

    public let segments: [Segment]
    /// `containsFallback: true` marks every segment as fallback (whole-text fallback).
    public init(segments: [Segment], containsFallback: Bool = false) {
        self.segments = containsFallback ? segments.map { $0.with(fallback: true) } : segments
    }
    public init(_ text: String, language: Locale.Language, containsFallback: Bool = false) {
        self.segments = [Segment(text, language: language, isFallback: containsFallback)]
    }

    /// True when some segment is fallback English standing in for a missing es/ht string.
    public var containsFallback: Bool { segments.contains(where: \.isFallback) }
    /// True when some segment is a missing-key marker.
    public var containsMissing: Bool { segments.contains(where: \.isMissing) }

    public var plain: String { segments.map(\.text).joined() }
    public var description: String { plain }
    /// The language most of the text is in (by characters); nil when empty.
    public var dominantLanguage: Locale.Language? {
        var counts: [String: Int] = [:]
        for s in segments { counts[s.language.minimalIdentifier, default: 0] += s.text.count }
        return counts.max { $0.value < $1.value }.map { Locale.Language(identifier: $0.key) }
    }

    public static func + (a: SpokenText, b: SpokenText) -> SpokenText {
        var segs = a.segments
        for s in b.segments {
            if let last = segs.last, last.language.minimalIdentifier == s.language.minimalIdentifier,
               last.isFallback == s.isFallback, last.isMissing == s.isMissing {
                segs[segs.count - 1] = Segment(last.text + s.text, language: last.language, isFallback: last.isFallback, isMissing: last.isMissing)
            } else {
                segs.append(s)
            }
        }
        return SpokenText(segments: segs)
    }
}
