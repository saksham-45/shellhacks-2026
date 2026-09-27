import Foundation
import ADCore
import ADRouter

/// `-uiTestScreen <name>`: drives the router (source .uiTest) to one screen for screenshots.
/// Names: household, onboarding (with -myadSeed none), addPerson, person, stage, cards, card, desk, pin,
/// settings, voice, clarify, confirm, notice.
public enum ScreenshotRoute {
    public static let all = ["household", "onboarding", "addPerson", "person", "stage", "cards", "card", "desk",
                             "pin", "settings", "voice", "clarify", "confirm", "notice"]

    @MainActor
    public static func apply(_ screen: String, to model: AppModel) {
        let r = model.router
        let first = r.household?.people.first?.id
        func go(_ a: AppAction) { r.perform(a, from: .uiTest) }
        switch screen {
        case "addPerson": go(.navigate(.addPerson))
        case "person": if let first { go(.navigate(.person(first))) }
        case "stage": if let p = first.flatMap({ r.household?.person($0) }) { go(.navigate(.person(p.id))); go(.navigate(.stage(p.id, p.stage))) }
        case "cards": go(.navigate(.cards(CardFilter())))
        case "around": go(.navigate(.cards(HouseholdBoard.around.filter)))
        case "city": go(.navigate(.cards(HouseholdBoard.city.filter)))
        case "street": go(.navigate(.card("street-week", person: nil)))
        case "taxi": go(.navigate(.card("taxi", person: nil)))
        case "license": go(.navigate(.card("license", person: nil)))
        case "bumper": go(.navigate(.card("bumper-tap", person: nil)))
        case "house": go(.navigate(.card("house-damage", person: nil)))
        case "handoff":
            go(.navigate(.card("house-damage", person: nil)))
            go(.callDesk(DemoSeed.desk311))
        case "card": go(.navigate(.card(DemoSeed.officesCard, person: nil)))
        case "desk": go(.navigate(.desk(DemoSeed.desk311)))
        case "pin": go(.navigate(.pin))
        case "settings": go(.navigate(.settings))
        case "voice": go(.navigate(.voice))
        case "confirm":
            go(.navigate(.card(DemoSeed.officesCard, person: nil)))
            go(.callDesk(DemoSeed.desk311))
        case "clarify":
            let cards = r.cards(matching: CardFilter(subject: .household)).prefix(3)
            let options = cards.map { ClarifyOption(id: ClarifyOptionID(rawValue: "card.\($0.id.rawValue)"), label: $0.titleKey,
                                                    action: .navigate(.card($0.id, person: nil))) }
            if let c = try? Clarification(question: RouterText.clarifyWhichCard, options: Array(options)) {
                r.handle(IntentResolution(confidence: 0.5, clarification: c, replyLanguage: model.surface), from: .uiTest)
            }
        case "notice":
            go(.navigate(.card(DemoSeed.officesCard, person: nil)))
            go(.setSurfaceLanguage(.ht))
            go(.readAloud(.card(DemoSeed.officesCard)))
        default: break  // household, onboarding: the launch state
        }
    }
}
