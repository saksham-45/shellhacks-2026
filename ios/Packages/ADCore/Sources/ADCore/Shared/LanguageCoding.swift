import Foundation

// Every language in an ADCore Codable payload is a plain BCP-47 string
// (`Locale.Language.minimalIdentifier`, e.g. "es", "ht", "hi", "es-419"), never the nested
// `Locale.Language` JSON (ARCHITECTURE.md §12).

extension Locale.Language {
    /// The wire form: `minimalIdentifier`.
    public var bcp47: String { minimalIdentifier }

    /// Normalized so equality survives an encode/decode round trip.
    static func normalized(_ language: Locale.Language) -> Locale.Language {
        Locale.Language(identifier: language.minimalIdentifier)
    }
}

extension KeyedEncodingContainer {
    mutating func encodeLanguage(_ language: Locale.Language, forKey key: Key) throws {
        try encode(language.minimalIdentifier, forKey: key)
    }

    mutating func encodeLanguageIfPresent(_ language: Locale.Language?, forKey key: Key) throws {
        try encodeIfPresent(language?.minimalIdentifier, forKey: key)
    }
}

extension KeyedDecodingContainer {
    func decodeLanguage(forKey key: Key) throws -> Locale.Language {
        let tag = try decode(String.self, forKey: key)
        guard !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "empty BCP-47 tag")
        }
        return Locale.Language(identifier: tag)
    }

    func decodeLanguageIfPresent(forKey key: Key) throws -> Locale.Language? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try decodeLanguage(forKey: key)
    }
}
