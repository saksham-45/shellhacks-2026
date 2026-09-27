import Foundation

/// Handwritten pack policy. Gemini may name the pack and what is visible.
/// It never writes these steps, never names fault, and never names a payout.
enum ScenePack: String, CaseIterable, Sendable {
    case vehicle, home, unreadable, person

    var cannotProve: String {
        switch self {
        case .vehicle:
            "This photo cannot prove who was at fault, a dollar amount, or whether a policy will pay."
        case .home:
            "This photo cannot prove the building is unsafe, that a landlord owes a deposit, or that damage is structural."
        case .unreadable:
            "This frame cannot be read. Take another photo in more light, of the bumper, wall, or leak."
        case .person:
            "A person is in this photo. Point the camera at the car, the wall, or the leak — not a face."
        }
    }

    var cannotProveKey: String {
        switch self {
        case .vehicle: "app.scene.cannot.vehicle"
        case .home: "app.scene.cannot.home"
        case .unreadable: "app.scene.cannot.unreadable"
        case .person: "app.scene.cannot.person"
        }
    }
}

struct SceneReading: Sendable {
    var pack: ScenePack
    var visible: String
    var whereInFrame: String
}

enum SceneGuide {
    static func parse(_ data: Data) -> SceneReading? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = (((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]),
               let raw = (text["parts"] as? [[String: Any]])?.first?["text"] as? String,
               let inner = raw.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] {
                return reading(from: parsed)
            }
            return parseGeminiWrapper(data)
        }
        if obj["pack"] != nil { return reading(from: obj) }
        return parseGeminiWrapper(data)
    }

    private static func parseGeminiWrapper(_ data: Data) -> SceneReading? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = (((obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        guard let inner = s.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else { return nil }
        return reading(from: parsed)
    }

    private static func reading(from obj: [String: Any]) -> SceneReading? {
        guard let packRaw = obj["pack"] as? String, let pack = ScenePack(rawValue: packRaw) else { return nil }
        let visible = (obj["visible"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let whereIn = (obj["where"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return SceneReading(pack: pack, visible: String(visible.prefix(80)), whereInFrame: String(whereIn.prefix(60)))
    }

    static let classifyPrompt = """
    Look at this photo. Return JSON only, no markdown:
    {"pack":"vehicle|home|unreadable|person","visible":"up to 12 words","where":"up to 8 words"}
    pack=vehicle if a car, bumper, plate, lamp, or fender is the subject.
    pack=home if a wall, ceiling, floor, window, or leak is the subject.
    pack=person if a face or body is the main subject.
    pack=unreadable if dark, blurry, or empty.
    Never mention fault, money, insurance payout, diagnosis, or a lawsuit.
    """
}
