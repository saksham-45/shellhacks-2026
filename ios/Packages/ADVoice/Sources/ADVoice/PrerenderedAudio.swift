import Foundation
import ADCore
import ADLocale

/// A bundled recording of one catalog string in one language. Offline and private: no network,
/// no user data. Plays only while `contentHash` equals the SHA-256 of the CURRENT text, so an
/// edited string never plays stale audio.
public struct PrerenderedClip: Hashable, Sendable {
    public let key: StringKey?
    public let language: Locale.Language
    /// Lowercase hex SHA-256 of the UTF-8 text the clip speaks.
    public let contentHash: String
    public let fileURL: URL
    /// A native speaker reviewed both the text and the audio. `BundledPrerenderedAudio` never
    /// returns an unreviewed clip; `KreyolAudio` checks again so no library can bypass it.
    public let reviewed: Bool

    public init(key: StringKey?, language: Locale.Language, contentHash: String, fileURL: URL, reviewed: Bool = false) {
        self.key = key
        self.language = language
        self.contentHash = contentHash
        self.fileURL = fileURL
        self.reviewed = reviewed
    }
}

extension PrerenderedClip {
    /// The one playability check for recorded clips, shared by `KreyolAudio` and `VoicePolicy`:
    /// reviewed by a native speaker, same language code, and hashed against the EXACT text.
    /// Returns nil for anything else, whatever the library claims.
    public static func verified(_ clip: PrerenderedClip?, language: Locale.Language, text: String) -> PrerenderedClip? {
        guard let clip, clip.reviewed, clip.language.hasSameLanguageCode(as: language),
              clip.contentHash.lowercased() == SHA256.hex(Data(text.utf8)) else { return nil }
        return clip
    }
}

public protocol PrerenderedAudioLibrary: Sendable {
    func clip(for key: StringKey, language: Locale.Language, text: String) -> PrerenderedClip?
}

/// Reads `PrerenderedAudio.json` from a bundle:
/// ```json
/// { "clips": [ { "table": "Cards", "key": "card.x.title", "language": "ht",
///                "sha256": "<hex of the exact text>", "file": "card.x.title.ht.m4a",
///                "reviewed": true } ] }
/// ```
/// `reviewed` defaults to false when absent; unreviewed entries are dropped at load.
/// Shipped empty: Creole clips are generated through our server (Gemini TTS, Creole report
/// §7.1) and added only after a native speaker has reviewed both text and audio.
public struct BundledPrerenderedAudio: PrerenderedAudioLibrary {
    struct Manifest: Decodable {
        struct Entry: Decodable {
            var table: String; var key: String; var language: String; var sha256: String; var file: String
            /// Missing means false (not reviewed by a native speaker).
            var reviewed: Bool?
            var isReviewed: Bool { reviewed ?? false }
        }
        var clips: [Entry]
    }
    struct ID: Hashable { var table: String; var key: String; var language: String }

    let entries: [ID: (hash: String, url: URL)]

    public init(manifest data: Data, audioDirectory: URL) throws {
        let m = try JSONDecoder().decode(Manifest.self, from: data)
        var map: [ID: (String, URL)] = [:]
        for e in m.clips where e.isReviewed {
            let lang = Locale.Language(identifier: e.language).minimalIdentifier
            map[ID(table: e.table, key: e.key, language: lang)] = (e.sha256.lowercased(), audioDirectory.appendingPathComponent(e.file))
        }
        entries = map
    }

    /// ADVoice's own manifest (empty today).
    public static func bundled() throws -> BundledPrerenderedAudio {
        guard let url = Bundle.module.url(forResource: "PrerenderedAudio", withExtension: "json") else { throw VoiceError.notConfigured("prerendered") }
        return try BundledPrerenderedAudio(manifest: Data(contentsOf: url), audioDirectory: url.deletingLastPathComponent())
    }

    /// Reviewed clips only.
    public var count: Int { entries.count }

    public func clip(for key: StringKey, language: Locale.Language, text: String) -> PrerenderedClip? {
        guard let e = entries[ID(table: key.table, key: key.key, language: language.minimalIdentifier)] else { return nil }
        let hash = SHA256.hex(Data(text.utf8))
        guard hash == e.hash else { return nil }
        return PrerenderedClip(key: key, language: language, contentHash: hash, fileURL: e.url, reviewed: true)
    }
}

/// Minimal SHA-256 (FIPS 180-4), so content hashes match the generating pipeline's
/// `hashlib.sha256` on every platform without a dependency.
enum SHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hex(_ data: Data) -> String {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = [UInt8](data)
        let bitLength = UInt64(msg.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLength >> (UInt64(i) * 8)) & 0xff)) }
        var w = [UInt32](repeating: 0, count: 64)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return h.map { word in
            let s = String(word, radix: 16)
            return String(repeating: "0", count: 8 - s.count) + s
        }.joined()
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}
