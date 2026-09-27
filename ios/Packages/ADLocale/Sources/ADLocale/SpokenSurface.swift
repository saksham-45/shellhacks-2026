import Foundation

/// Maps a spoken utterance onto a UI surface. Used so the screen can follow the sentence
/// when the person talks in a different language, and stay put when they already match.
public enum SpokenSurface {
    /// BCP-47 tag from STT or a voice script (`"es-US"` → `.es`). Nil when it is not a surface
    /// (Hindi, Japanese, empty).
    public static func fromTag(_ tag: String) -> SurfaceLanguage? {
        SurfaceLanguage(languageTag: tag)
    }

    /// Strong script signal: Arabic, Han, or Cyrillic letters. Needs a few letters so a
    /// mixed name does not flip the screen.
    public static func fromScript(_ text: String) -> SurfaceLanguage? {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2 else { return nil }
        let total = Double(letters.count)
        func share(_ pred: (Unicode.Scalar) -> Bool) -> Double {
            Double(letters.filter(pred).count) / total
        }
        if share(isArabic) >= 0.4 { return .ar }
        if share(isHan) >= 0.4 { return .zh }
        if share(isCyrillic) >= 0.4 { return .ru }
        return nil
    }

    private static func isArabic(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x0600 && s.value <= 0x06FF) || (s.value >= 0x0750 && s.value <= 0x077F)
            || (s.value >= 0x08A0 && s.value <= 0x08FF) || (s.value >= 0xFB50 && s.value <= 0xFDFF)
    }

    private static func isHan(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x4E00 && s.value <= 0x9FFF) || (s.value >= 0x3400 && s.value <= 0x4DBF)
            || (s.value >= 0x3040 && s.value <= 0x30FF)
    }

    private static func isCyrillic(_ s: Unicode.Scalar) -> Bool {
        (s.value >= 0x0400 && s.value <= 0x04FF) || (s.value >= 0x0500 && s.value <= 0x052F)
    }

    /// Language the UI should use for this utterance.
    /// Script first, then the STT/script tag when it is a surface, else `current`.
    public static func resolve(text: String, tagged: String?, current: SurfaceLanguage) -> SurfaceLanguage {
        if let script = fromScript(text) { return script }
        if let tagged, let surface = fromTag(tagged) { return surface }
        return current
    }
}
