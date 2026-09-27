import Foundation
import ADCore

/// Text keys the router speaks and shows (table "ADRouter", Resources/ADRouter.xcstrings).
/// Every outcome has one, so every step can be read aloud.
public enum RouterText {
    public static let table = "ADRouter"
    /// Table for proper nouns shown as-is (person names, street addresses). Its "key" IS the text:
    /// resolvers return it unchanged, and it is never translated.
    public static let verbatimTable = "Verbatim"

    static func key(_ k: String) -> StringKey { StringKey(key: k, table: table) }
    public static func verbatim(_ text: String) -> StringKey { StringKey(key: text, table: verbatimTable) }

    public static let opened = key("router.ok.opened")
    public static let wentBack = key("router.ok.back")
    public static let wentHome = key("router.ok.home")
    public static let reading = key("router.ok.reading")
    public static let stopped = key("router.ok.stopped")
    public static let languageChanged = key("router.ok.language")
    public static let thinkInChanged = key("router.ok.think_in")
    public static let onboardingNext = key("router.ok.onboarding_next")
    public static let onboardingDone = key("router.ok.onboarding_done")
    public static let pinChanged = key("router.ok.pin")
    public static let modeTourist = key("router.ok.mode_tourist")
    public static let modeResident = key("router.ok.mode_resident")
    public static let cancelled = key("router.ok.cancelled")
    public static let leavingToCall = key("router.ok.leaving_call")
    public static let leavingToMap = key("router.ok.leaving_map")

    public static let askCallDesk = key("router.ask.call_desk")
    public static let askOpenMap = key("router.ask.open_map")
    public static let clarifyWhichCard = key("router.clarify.which_card")

    public static let refusedPrivacy = key("router.refused.privacy")
    public static let refusedTourist = key("router.refused.tourist")
    public static let refusedUnknown = key("router.refused.unknown")
    public static let refusedNotAPlace = key("router.refused.not_a_place")
    public static let refusedNothingToConfirm = key("router.refused.nothing_to_confirm")
    public static let refusedNothingToRepeat = key("router.refused.nothing_to_repeat")
    public static let refusedNoPerson = key("router.refused.no_person")
    public static let refusedNoSteps = key("router.refused.no_steps")
    public static let refusedNotOnboarding = key("router.refused.not_onboarding")
    public static let refusedUngrounded = key("router.refused.ungrounded")
    public static let refusedNoChoice = key("router.refused.no_choice")
    public static let refusedAlreadyHome = key("router.refused.already_home")
    public static let dontHaveThis = key("router.no_answer")
    public static let offline = key("router.offline")
    public static let saved = key("router.ok.saved")
    public static let deleted = key("router.ok.deleted")
    public static let restored = key("router.ok.restored")
    public static let refusedNothingToUndo = key("router.refused.nothing_to_undo")
    public static let refusedInvalidPerson = key("router.refused.invalid_person")

    public static func surfaceName(_ code: String) -> StringKey { key("router.language.\(code)") }

    /// Every key above (tests check the catalog has each in es, en, ht).
    public static let all: [StringKey] = [
        opened, wentBack, wentHome, reading, stopped, languageChanged, thinkInChanged, onboardingNext,
        onboardingDone, pinChanged, modeTourist, modeResident, cancelled, leavingToCall, leavingToMap,
        askCallDesk, askOpenMap, clarifyWhichCard,
        refusedPrivacy, refusedTourist, refusedUnknown, refusedNotAPlace, refusedNothingToConfirm,
        refusedNothingToRepeat, refusedNoPerson, refusedNoSteps, refusedNotOnboarding, refusedUngrounded,
        refusedNoChoice, refusedAlreadyHome, dontHaveThis, offline,
        saved, deleted, restored, refusedNothingToUndo, refusedInvalidPerson,
        surfaceName("es"), surfaceName("en"), surfaceName("ht"),
    ]
}

/// ADRouter's resource bundle, for the app to resolve table "ADRouter".
public enum ADRouterStrings {
    public static var bundle: Bundle { .module }
}
