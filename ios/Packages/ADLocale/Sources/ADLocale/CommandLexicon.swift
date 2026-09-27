import Foundation

/// Text normalization shared by command matching and language scoring:
/// lowercase, diacritics folded (kreyòl = kreyol, sí = si), punctuation removed (¿?¡!.,),
/// apostrophes and hyphens split words (m'ap -> m ap), whitespace collapsed.
public enum TextNormalizer {
    public static func normalize(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out: [String] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Lowercased words with diacritics KEPT (for language scoring, where è/ñ are evidence).
    public static func wordsKeepingDiacritics(_ text: String) -> [String] {
        let lower = text.lowercased()
        var out: [String] = []
        var current = ""
        for ch in lower {
            if ch.isLetter || ch.isNumber { current.append(ch) } else if !current.isEmpty { out.append(current); current = "" }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// The on-device voice command lexicon (ARCHITECTURE.md §13.3), read by ADRouter's matcher.
/// Returns command KEYS; the router maps keys to `AppAction`s. Keys equal
/// `contracts/intent/command_keys.json` exactly (Lead's file; a new key goes there first).
///
/// Resource format, `Commands/<lang>.json` (lang = es | en | ht):
/// ```json
/// {
///   "language": "ht",
///   "version": 1,
///   "review": { "state": "needs_review", "note": "who drafted it and why it is unreviewed" },
///   "fillers": ["tanpri"],                       // politeness words stripped at either end
///   "spelling_variants": { "mwen": "m" },        // optional; token -> canonical token (both sides)
///   "commands": {
///     "back": ["tounen", { "phrase": "retounen", "state": "needs_review", "note": "why" }]
///   }
/// }
/// ```
/// Review marker: every phrase inherits the file's `review.state`; an object entry overrides it
/// for one phrase. States follow String Catalogs: `translated` or `needs_review`. All ht files
/// are `needs_review` until a native-speaker pass (decision D9). ci-hook.sh checks key parity
/// with the contract, non-empty lists, no phrase mapped to two commands in one language, and
/// prints the needs_review counts.
public struct CommandLexicon: Sendable {
    public struct Phrase: Hashable, Sendable {
        public let text: String
        public let normalized: String
        public let needsReview: Bool
        public let note: String?
    }

    public struct Match: Hashable, Sendable {
        public let command: String
        public let language: SurfaceLanguage
        public let phrase: Phrase
        public var needsReview: Bool { phrase.needsReview }
    }

    public struct LanguageTable: Sendable {
        public let language: SurfaceLanguage
        public let fileNeedsReview: Bool
        public let commands: [String: [Phrase]]
        let fillers: [[String]]
        let variants: [String: String]
        let index: [String: String]   // normalized phrase -> command
        /// Normalized phrases that map to more than one command (must be empty; ci-hook enforces).
        public let conflicts: [String: Set<String>]
    }

    public enum LoadError: Error, Equatable {
        case missingFile(String)
        case malformed(String)
    }

    public let tables: [SurfaceLanguage: LanguageTable]

    /// The shipped lexicon in ADLocale's bundle.
    public static func bundled() throws -> CommandLexicon {
        var files: [SurfaceLanguage: Data] = [:]
        for lang in SurfaceLanguage.allCases {
            guard let url = Bundle.module.url(forResource: lang.rawValue, withExtension: "json", subdirectory: "Commands")
                    ?? Bundle.module.url(forResource: lang.rawValue, withExtension: "json") else {
                throw LoadError.missingFile("Commands/\(lang.rawValue).json")
            }
            files[lang] = try Data(contentsOf: url)
        }
        return try CommandLexicon(files: files)
    }

    public init(files: [SurfaceLanguage: Data]) throws {
        var t: [SurfaceLanguage: LanguageTable] = [:]
        for (lang, data) in files { t[lang] = try CommandLexicon.parse(data, lang) }
        tables = t
    }

    /// All command keys, per language.
    public func commandKeys(_ language: SurfaceLanguage) -> Set<String> { Set(tables[language]?.commands.keys ?? [:].keys) }

    /// Whole-utterance match after normalization (then again with fillers stripped at either end).
    /// Searches `languages` (default all three: "Kreyòl" or "en español" work from any surface)
    /// and returns every language that matched, in the order given.
    public func match(_ utterance: String, in languages: [SurfaceLanguage] = SurfaceLanguage.allCases) -> [Match] {
        var out: [Match] = []
        let tokens = TextNormalizer.tokens(utterance)
        guard !tokens.isEmpty else { return [] }
        for lang in languages {
            guard let table = tables[lang] else { continue }
            if let m = table.lookup(tokens) { out.append(m) }
        }
        return out
    }

    /// The best match for a transcript already known to be in `language`, falling back to the
    /// other languages (switch-language names are said in any language).
    public func command(for utterance: String, language: SurfaceLanguage) -> Match? {
        let order = [language] + SurfaceLanguage.allCases.filter { $0 != language }
        return match(utterance, in: order).first
    }

    /// Phrase counts awaiting review, per language.
    public var needsReviewCounts: [SurfaceLanguage: Int] {
        tables.mapValues { $0.commands.values.joined().filter(\.needsReview).count }
    }

    // MARK: Parsing

    private struct RawFile: Decodable {
        var language: String
        var review: RawReview?
        var fillers: [String]?
        var spelling_variants: [String: String]?
        var commands: [String: [RawPhrase]]
    }
    private struct RawReview: Decodable { var state: String; var note: String? }
    private enum RawPhrase: Decodable {
        case plain(String)
        case marked(phrase: String, state: String?, note: String?)
        private enum K: String, CodingKey { case phrase, state, note }
        init(from decoder: any Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { self = .plain(s); return }
            let c = try decoder.container(keyedBy: K.self)
            self = .marked(phrase: try c.decode(String.self, forKey: .phrase),
                           state: try c.decodeIfPresent(String.self, forKey: .state),
                           note: try c.decodeIfPresent(String.self, forKey: .note))
        }
    }

    static func parse(_ data: Data, _ lang: SurfaceLanguage) throws -> LanguageTable {
        let raw: RawFile
        do { raw = try JSONDecoder().decode(RawFile.self, from: data) } catch { throw LoadError.malformed("\(lang.rawValue): \(error)") }
        guard raw.language == lang.rawValue else { throw LoadError.malformed("\(lang.rawValue).json says language \(raw.language)") }
        let fileReview = raw.review?.state == "needs_review"
        let variants = Dictionary(uniqueKeysWithValues: (raw.spelling_variants ?? [:]).map {
            (TextNormalizer.normalize($0.key), TextNormalizer.normalize($0.value))
        })
        func canon(_ tokens: [String]) -> String { tokens.map { variants[$0] ?? $0 }.joined(separator: " ") }
        var commands: [String: [Phrase]] = [:]
        var owners: [String: Set<String>] = [:]
        for (key, list) in raw.commands {
            commands[key] = list.map { entry in
                let (text, state, note): (String, String?, String?) = switch entry {
                case .plain(let s): (s, nil, nil)
                case let .marked(p, s, n): (p, s, n)
                }
                let normalized = canon(TextNormalizer.tokens(text))
                owners[normalized, default: []].insert(key)
                return Phrase(text: text, normalized: normalized, needsReview: state.map { $0 == "needs_review" } ?? fileReview, note: note)
            }
        }
        var index: [String: String] = [:]
        for (phrase, keys) in owners where keys.count == 1 { index[phrase] = keys.first! }
        let conflicts = owners.filter { $0.value.count > 1 }
        return LanguageTable(language: lang, fileNeedsReview: fileReview, commands: commands,
                             fillers: (raw.fillers ?? []).map { TextNormalizer.tokens($0).map { variants[$0] ?? $0 } },
                             variants: variants, index: index, conflicts: conflicts)
    }
}

extension CommandLexicon.LanguageTable {
    func lookup(_ rawTokens: [String]) -> CommandLexicon.Match? {
        var tokens = rawTokens.map { variants[$0] ?? $0 }
        if let m = find(tokens) { return m }
        // Strip fillers at either end ("go back please", "tanpri tounen"), then retry.
        var changed = true
        while changed, !tokens.isEmpty {
            changed = false
            for f in fillers where !f.isEmpty {
                if tokens.count > f.count, Array(tokens.prefix(f.count)) == f { tokens.removeFirst(f.count); changed = true }
                if tokens.count > f.count, Array(tokens.suffix(f.count)) == f { tokens.removeLast(f.count); changed = true }
            }
            if changed, let m = find(tokens) { return m }
        }
        return nil
    }

    private func find(_ tokens: [String]) -> CommandLexicon.Match? {
        let key = tokens.joined(separator: " ")
        guard let command = index[key], let phrase = commands[command]?.first(where: { $0.normalized == key }) else { return nil }
        return CommandLexicon.Match(command: command, language: language, phrase: phrase)
    }
}
