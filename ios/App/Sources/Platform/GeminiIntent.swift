import Foundation
import ADCore
import ADRouter

/// Gemini classifies a spoken sentence onto one catalog card id. It never writes the
/// answer the person sees (Microsoft: no chat window; Assurant: papers stay off the wire).
struct GeminiCardHint: Sendable {
    let id: CardID
    let title: String
}

enum GeminiCardParse {
    /// Pull a card id out of a generateContent JSON body.
    static func choice(from data: Data, allowed: Set<String>) -> String? {
        let raw: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let text = (((obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
            raw = text
        } else {
            raw = String(data: data, encoding: .utf8)
        }
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
            s = String(s.dropFirst().dropLast())
        }
        if s == "none" { return nil }
        return allowed.contains(s) ? s : nil
    }

    static func prompt(utterance: String, cards: [GeminiCardHint]) -> String {
        let lines = cards.map { "- \($0.id.rawValue): \($0.title)" }.joined(separator: "\n")
        return """
        Select the one household card id that best matches this spoken request.
        Return only the id, or none. Never explain. Never invent a card.
        Utterance: \(utterance)
        Cards:
        \(lines)
        """
    }
}

struct GeminiCardIntent: IntentResolving {
    let apiKey: String
    let cards: [GeminiCardHint]
    var model: String = "gemini-2.5-flash"

    func resolve(_ u: Utterance) async throws -> IntentResolution {
        let allowed = Set(cards.map(\.id.rawValue))
        guard !allowed.isEmpty else { throw GeminiIntentError.emptyCatalog }
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["parts": [["text": GeminiCardParse.prompt(utterance: u.text, cards: cards)]]]],
            "generationConfig": [
                "temperature": 0,
                "responseMimeType": "application/json",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeminiIntentError.http
        }
        guard let raw = GeminiCardParse.choice(from: data, allowed: allowed),
              let hint = cards.first(where: { $0.id.rawValue == raw }) else {
            throw GeminiIntentError.noMatch
        }
        return IntentResolution(
            action: .navigate(.card(hint.id, person: nil)),
            grounding: .card(hint.id, facts: []),
            confidence: 0.86,
            replyLanguage: u.language
        )
    }
}

enum GeminiIntentError: Error { case emptyCatalog, http, noMatch }
