import Foundation
import ADCore
import ADRouter

/// Which A11yID identifiers the views show for the current state. The views set exactly these; the
/// voice-script stub waits on them (it cannot query the accessibility tree from inside the app).
extension AppModel {
    public var presentIdentifiers: Set<String> {
        var ids: Set<String> = [A11yID.Voice.mic]
        switch router.current {
        case nil, .household?:
            ids.formUnion([A11yID.Household.list, A11yID.Household.addPerson, A11yID.Household.settings,
                           A11yID.Household.pin, A11yID.Household.cards])
            ids.formUnion((router.household?.people ?? []).map { A11yID.Household.row($0.id.rawValue.uuidString) })
        case .onboarding(let step)?:
            ids.formUnion([A11yID.Onboarding.form, A11yID.Onboarding.question, A11yID.Onboarding.step(step)])
            // No a11y.onboarding.back: ADCore's draft only moves forward (gap reported).
            if step == .people || step == .originAndLanguage { ids.insert(A11yID.Onboarding.next) }
            if step == .originAndLanguage { ids.insert(A11yID.Onboarding.skip) }
        case .addPerson?, .editPerson?:
            ids.formUnion([A11yID.AddPerson.form, A11yID.AddPerson.name, A11yID.AddPerson.stage, A11yID.AddPerson.origin,
                           A11yID.AddPerson.language, A11yID.AddPerson.thinkIn, A11yID.AddPerson.mode,
                           A11yID.AddPerson.save, A11yID.AddPerson.cancel])
        case .person?:
            ids.formUnion([A11yID.PersonDetail.list, A11yID.PersonDetail.name, A11yID.PersonDetail.stage,
                           A11yID.PersonDetail.nextSteps, A11yID.PersonDetail.edit, A11yID.PersonDetail.delete])
            if !router.nextSteps.isEmpty { ids.insert(A11yID.PersonDetail.hero) }
        case .stage(let id, let stage)?:
            ids.insert(A11yID.Cards.list)
            ids.formUnion(router.cards(matching: CardFilter(subject: .person, stage: stage)).map { A11yID.Cards.row($0.id.rawValue) })
            _ = id
        case .cards(let filter)?:
            ids.insert(A11yID.Cards.list)
            ids.formUnion(router.cards(matching: filter).map { A11yID.Cards.row($0.id.rawValue) })
        case .card(let id, _)?:
            ids.formUnion([A11yID.Card.list, A11yID.Card.title, A11yID.Card.readAloud, A11yID.Card.desk, A11yID.Card.call])
            if readingCard == id, isReading { ids.insert(A11yID.Card.stopReading) }
            if let card = router.catalog.first(where: { $0.id == id }) {
                ids.formUnion(card.facts.map { A11yID.Card.fact($0.rawValue) })
            }
        case .desk?:
            ids.formUnion([A11yID.Desk.panel, A11yID.Desk.call, A11yID.Desk.map])
        case .pin?:
            ids.formUnion([A11yID.Pin.list, A11yID.Pin.kendall, A11yID.Pin.downtown, A11yID.Pin.current])
        case .settings?, .language?:
            ids.formUnion([A11yID.Settings.form, A11yID.Settings.languageES, A11yID.Settings.languageEN,
                           A11yID.Settings.languageHT, A11yID.Settings.thinkIn, A11yID.Settings.done])
            if router.activePerson != nil { ids.insert(A11yID.Settings.mode) }
        case .voice?:
            ids.formUnion([A11yID.Voice.panel, A11yID.Voice.transcript, A11yID.Voice.answer, A11yID.Voice.typeInstead])
            if isReading || listening { ids.insert(A11yID.Voice.stop) }
        }
        if let c = router.pendingClarification {
            ids.insert(A11yID.Router.clarify)
            ids.formUnion((1...c.options.count).map(A11yID.Router.clarifyOption))
        }
        if router.pendingConfirmation != nil {
            ids.formUnion([A11yID.Router.confirm, A11yID.Router.confirmYes, A11yID.Router.confirmNo])
        }
        if handoff != nil { ids.insert(A11yID.Router.handoff) }
        if notice?.isSpeechNotice == true { ids.insert(A11yID.Voice.unavailableNotice) }
        if voiceScriptStatus != nil { ids.insert(A11yID.Voice.stub) }
        if router.lastDeleted != nil, router.current == nil || router.current == .household { ids.insert(A11yID.PersonDetail.undo) }
        return ids
    }
}
