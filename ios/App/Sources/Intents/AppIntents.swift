#if canImport(AppIntents)
import AppIntents
import ADCore
import ADLocale
import ADRouter

// App Intents (Siri, Shortcuts, Action button). Each builds an AppAction and calls the SAME router
// the screens use (source .appIntent), so privacy, tourist rules, and leave-app confirmation apply.
// Siri has no Haitian Creole: phrases exist in English and Spanish only (AppShortcuts.xcstrings);
// Creole speakers reach every intent through the in-app mic and Shortcuts.

@MainActor
private func routerPerform(_ action: AppAction) throws -> ActionOutcome {
    guard let model = AppModelHolder.shared else { throw IntentProblem.notReady }
    return model.router.perform(action, from: .appIntent)
}

enum IntentProblem: Error, CustomLocalizedStringResourceConvertible {
    case notReady, noPerson, noCard
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notReady: "Open myMiami first."
        case .noPerson: "Add a person first."
        case .noCard: "That card is not here."
        }
    }
}

/// "This week": the household's cards.
struct OpenThisWeekIntent: AppIntent {
    static let title: LocalizedStringResource = "Open this week"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        _ = try routerPerform(.home)
        _ = try routerPerform(.navigate(.cards(CardFilter(subject: .household))))
        return .result()
    }
}

/// Reads the first person's next step aloud (or the active person's).
struct ReadNextStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Read my next step"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = AppModelHolder.shared else { throw IntentProblem.notReady }
        if model.router.activePerson == nil {
            guard let first = model.router.household?.people.first else { throw IntentProblem.noPerson }
            _ = try routerPerform(.navigate(.person(first.id)))
        }
        _ = try routerPerform(.readAloud(.step))
        return .result()
    }
}

/// Asks to call the desk of the card on screen (or the county desk). The router asks yes/no first.
struct CallDeskIntent: AppIntent {
    static let title: LocalizedStringResource = "Call the desk"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = AppModelHolder.shared else { throw IntentProblem.notReady }
        let desk = model.router.context.deskID ?? DemoSeed.desk311
        _ = try routerPerform(.callDesk(desk))
        return .result()
    }
}

struct CardEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Card"
    static let defaultQuery = CardQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: title)) }
}

struct CardQuery: EntityQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [CardEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    @MainActor func suggestedEntities() async throws -> [CardEntity] {
        guard let model = AppModelHolder.shared else { return [] }
        return model.router.cards(matching: CardFilter()).map { CardEntity(id: $0.id.rawValue, title: model.text($0.titleKey)) }
    }
}

struct OpenCardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a card"
    static let openAppWhenRun = true
    @Parameter(title: "Card") var card: CardEntity
    @MainActor func perform() async throws -> some IntentResult {
        guard let model = AppModelHolder.shared else { throw IntentProblem.notReady }
        let outcome = try routerPerform(.navigate(.card(CardID(rawValue: card.id), person: model.router.activePerson)))
        if case .refused = outcome { throw IntentProblem.noCard }
        return .result()
    }
}

enum SurfaceLanguageChoice: String, AppEnum {
    case es, en, ht
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Language"
    // Autonyms: identical in every language by design.
    static let caseDisplayRepresentations: [SurfaceLanguageChoice: DisplayRepresentation] = [
        .es: "Español", .en: "English", .ht: "Kreyòl",
    ]
}

struct SwitchLanguageIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch language"
    static let openAppWhenRun = true
    @Parameter(title: "Language") var language: SurfaceLanguageChoice
    @MainActor func perform() async throws -> some IntentResult {
        guard let surface = SurfaceLanguage(rawValue: language.rawValue) else { return .result() }
        _ = try routerPerform(.setSurfaceLanguage(surface))
        return .result()
    }
}

/// English phrases here; Spanish in AppShortcuts.xcstrings. No Creole: Siri does not support it.
struct MyADShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenThisWeekIntent(), phrases: ["Open this week in \(.applicationName)",
                                                            "What's this week in \(.applicationName)"],
                    shortTitle: "This week", systemImageName: "calendar")
        AppShortcut(intent: ReadNextStepIntent(), phrases: ["Read my next step in \(.applicationName)"],
                    shortTitle: "Next step", systemImageName: "speaker.wave.2")
        AppShortcut(intent: CallDeskIntent(), phrases: ["Call the desk with \(.applicationName)"],
                    shortTitle: "Call the desk", systemImageName: "phone")
        AppShortcut(intent: OpenCardIntent(), phrases: ["Open a card in \(.applicationName)"],
                    shortTitle: "Open a card", systemImageName: "rectangle.portrait")
        AppShortcut(intent: SwitchLanguageIntent(), phrases: ["Switch \(.applicationName) language"],
                    shortTitle: "Switch language", systemImageName: "globe")
    }
}
#endif
