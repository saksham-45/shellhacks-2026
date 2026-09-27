import SwiftUI
import ADCore
import ADLocale
import ADRouter

struct HouseholdView: View {
    @Environment(AppModel.self) private var model

    private let weekIDs: Set<CardID> = ["trash-week"]

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let router = model.router
        let cards = router.cards(matching: CardFilter(subject: .household))
        let week = cards.first { weekIDs.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brandedHeader
                if let step = model.householdNextStep() { nextStepHero(step, router: router) }
                if let week { thisWeek(week, router: router) }
                explore(router: router)
                peopleBlock(router: router)
                toolsBlock(router: router)
                if model.content.isDemo {
                    DemoBadge()
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
        }
        .background(CivicTheme.canvas(scheme).ignoresSafeArea())
        .accessibilityIdentifier(A11yID.Household.list)
        .screen("app.screen.household", hideTitle: true)
    }

    private var greetingKey: String {
        if model.options.deterministic { return "app.greeting.morning" }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour < 12 { return "app.greeting.morning" }
        if hour < 18 { return "app.greeting.afternoon" }
        return "app.greeting.evening"
    }

    private var placeLine: String {
        let pin = model.router.household?.pin
        let id = model.router.pins.first { $0.pin.address == pin?.address }?.id
        let area: String
        if id == DemoSeed.kendall { area = model.app("app.place.kendall") }
        else if id == DemoSeed.downtown { area = model.app("app.place.downtown") }
        else { area = "" }
        return [model.app("app.place.county"), area].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var brandedHeader: some View {
        Button {
            model.router.perform(.navigate(.pin), from: .touch)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(CivicTheme.teal)
                        .accessibilityHidden(true)
                    Text(verbatim: placeLine)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(CivicTheme.teal)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(CivicTheme.teal.opacity(0.7))
                        .accessibilityHidden(true)
                }
                AppText(greetingKey)
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(CivicTheme.ink(scheme))
                Text(verbatim: model.router.household?.pin?.address ?? "—")
                    .font(.subheadline)
                    .foregroundStyle(CivicTheme.ink(scheme).opacity(0.65))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Household.pin)
        .accessibilityValue(Text(verbatim: model.router.household?.pin?.address ?? ""))
    }

    private func nextStepHero(_ step: HouseholdNextStep, router: Router) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: model.app("app.next.title").uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(CivicTheme.mustard)
            Text(verbatim: step.personName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CivicTheme.cream.opacity(0.8))
            Text(verbatim: model.app(step.lineKey))
                .font(.title2.weight(.bold))
                .foregroundStyle(CivicTheme.cream)
                .fixedSize(horizontal: false, vertical: true)
            CivicPrimaryButton(title: model.app("app.next.start")) {
                router.perform(.navigate(.card(step.card.id, person: nil)), from: .touch)
            }
            HStack(spacing: 16) {
                Button {
                    model.speakPlain(model.spokenNextStep(step), language: model.surface)
                } label: {
                    Label { AppText("app.next.read") } icon: {
                        Image(systemName: "speaker.wave.2").accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CivicTheme.cream.opacity(0.9))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                Button {
                    router.perform(.callDesk(step.card.desk), from: .touch)
                } label: {
                    Label { AppText("app.next.call") } icon: {
                        Image(systemName: "phone").accessibilityHidden(true)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(CivicTheme.cream.opacity(0.9))
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CivicTheme.midnight, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func thisWeek(_ card: Card, router: Router) -> some View {
        Button {
            router.perform(.navigate(.card(card.id, person: nil)), from: .touch)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AppText("app.household.this_week")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(CivicTheme.teal)
                Text(verbatim: CivicCopy.withoutDemoMark(model.text(card.titleKey)))
                    .font(.headline)
                    .foregroundStyle(CivicTheme.ink(scheme))
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(16)
            .background(CivicTheme.paper(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(A11yID.Cards.row(card.id.rawValue))
    }

    private func explore(router: Router) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AppText("app.household.life")
                .font(.headline)
                .foregroundStyle(CivicTheme.ink(scheme))
            ServiceGrid(items: Array(HouseholdBoard.allCases), columns: 3) { board in
                ServiceTile(
                    title: model.app(board.titleKey),
                    symbol: board.symbol,
                    tint: board.tint,
                    id: board.rowID
                ) {
                    router.perform(.navigate(.cards(board.filter)), from: .touch)
                }
            }
            .listRowInsets(EdgeInsets())
        }
        .padding(16)
        .background(CivicTheme.paper(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func peopleBlock(router: Router) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AppText("app.household.people")
                .font(.headline)
                .foregroundStyle(CivicTheme.ink(scheme))
                .padding(.bottom, 4)
            ForEach(router.household?.people ?? []) { person in
                Button {
                    router.perform(.navigate(.person(person.id)), from: .touch)
                } label: {
                    HStack {
                        PersonRow(person: person)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(CivicTheme.teal)
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(A11yID.Household.row(person.id.rawValue.uuidString))
                .accessibilityInputLabels([Text(verbatim: person.displayName)])
            }
            ActionRow(titleKey: "app.household.add_person", systemImage: "person.badge.plus", id: A11yID.Household.addPerson,
                      action: .navigate(.addPerson))
        }
    }

    private func toolsBlock(router: Router) -> some View {
        VStack(spacing: 0) {
            NavigationLink {
                DemoChecksView()
            } label: {
                Label {
                    AppText("app.checks.title")
                } icon: { Image(systemName: "checklist").accessibilityHidden(true) }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .foregroundStyle(CivicTheme.ink(scheme))
            }
            .accessibilityIdentifier("demo.checks.entry")
            ActionRow(titleKey: "app.household.cards", systemImage: "rectangle.stack", id: A11yID.Household.cards,
                      action: .navigate(.cards(CardFilter(subject: .household))))
            ActionRow(titleKey: "app.household.settings", systemImage: "globe", id: A11yID.Household.settings,
                      action: .navigate(.settings))
            if router.lastDeleted != nil {
                ActionRow(titleKey: "app.person.undo", systemImage: "arrow.uturn.backward", id: A11yID.PersonDetail.undo,
                          action: .undo)
            }
        }
    }
}

/// One life-domain on home. Related cards sit in titled groups one push in.
struct HouseholdTile: Identifiable, Equatable {
    var id: CardID { cardID }
    let cardID: CardID
    let titleKey: String
    let symbol: String
    let tint: ServiceTint
}

struct HouseholdGroup: Identifiable, Equatable {
    let id: String
    let titleKey: String
    let tiles: [HouseholdTile]
    var cardIDs: [CardID] { tiles.map(\.cardID) }
    var cardIDSet: Set<CardID> { Set(cardIDs) }
    var filter: CardFilter { CardFilter(subject: .household, cardIDs: cardIDSet) }
}

enum HouseholdBoard: String, CaseIterable, Identifiable {
    case city, around, school, money, papers, help
    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .city: "app.household.city"
        case .around: "app.household.getting_around"
        case .school: "app.household.school"
        case .money: "app.household.money"
        case .papers: "app.household.papers"
        case .help: "app.household.help"
        }
    }

    var symbol: String {
        switch self {
        case .city: "building.columns"
        case .around: "figure.walk"
        case .school: "graduationcap"
        case .money: "dollarsign.circle"
        case .papers: "doc.text"
        case .help: "heart"
        }
    }

    var tint: ServiceTint {
        switch self {
        case .city: .orange
        case .around: .green
        case .school: .pink
        case .money: .cyan
        case .papers: .brown
        case .help: .red
        }
    }

    var groups: [HouseholdGroup] {
        switch self {
        case .city:
            [
                HouseholdGroup(id: "place", titleKey: "app.group.place", tiles: [
                    .init(cardID: "offices", titleKey: "app.tile.offices", symbol: "building.columns", tint: .blue),
                    .init(cardID: "building", titleKey: "app.tile.building", symbol: "building.2", tint: .indigo),
                    .init(cardID: "library-park", titleKey: "app.tile.library-park", symbol: "books.vertical", tint: .green),
                ]),
                HouseholdGroup(id: "house", titleKey: "app.group.house", tiles: [
                    .init(cardID: "water", titleKey: "app.tile.water", symbol: "drop", tint: .cyan),
                    .init(cardID: "flood", titleKey: "app.tile.flood", symbol: "water.waves", tint: .teal),
                    .init(cardID: "house-damage", titleKey: "app.tile.house-damage", symbol: "house", tint: .orange),
                ]),
            ]
        case .around:
            [
                HouseholdGroup(id: "walk", titleKey: "app.group.walk", tiles: [
                    .init(cardID: "street-week", titleKey: "app.tile.street-week", symbol: "figure.walk", tint: .blue),
                    .init(cardID: "night-walk", titleKey: "app.tile.night-walk", symbol: "moon.stars", tint: .indigo),
                    .init(cardID: "theft-map", titleKey: "app.tile.theft-map", symbol: "map", tint: .orange),
                    .init(cardID: "lights-311", titleKey: "app.tile.lights-311", symbol: "lightbulb", tint: .brown),
                ]),
                HouseholdGroup(id: "ride", titleKey: "app.group.ride", tiles: [
                    .init(cardID: "transit", titleKey: "app.tile.transit", symbol: "bus", tint: .blue),
                    .init(cardID: "parking", titleKey: "app.tile.parking", symbol: "parkingsign", tint: .teal),
                ]),
                HouseholdGroup(id: "airport", titleKey: "app.group.airport", tiles: [
                    .init(cardID: "taxi", titleKey: "app.tile.taxi", symbol: "car", tint: .orange),
                    .init(cardID: "rideshare", titleKey: "app.tile.rideshare", symbol: "car.side", tint: .green),
                ]),
                HouseholdGroup(id: "crash", titleKey: "app.group.crash", tiles: [
                    .init(cardID: "bumper-tap", titleKey: "app.tile.bumper-tap", symbol: "car.rear", tint: .red),
                    .init(cardID: "storm-walk", titleKey: "app.tile.storm-walk", symbol: "cloud.heavyrain", tint: .cyan),
                ]),
            ]
        case .school:
            [
                HouseholdGroup(id: "school", titleKey: "app.group.school", tiles: [
                    .init(cardID: "school-zone", titleKey: "app.tile.school-zone", symbol: "graduationcap", tint: .indigo),
                    .init(cardID: "school-access", titleKey: "app.tile.school-access", symbol: "studentdesk", tint: .blue),
                ]),
            ]
        case .money:
            [
                HouseholdGroup(id: "drive", titleKey: "app.group.drive", tiles: [
                    .init(cardID: "license", titleKey: "app.tile.license", symbol: "car", tint: .orange),
                ]),
                HouseholdGroup(id: "costs", titleKey: "app.group.costs", tiles: [
                    .init(cardID: "rent", titleKey: "app.tile.rent", symbol: "house", tint: .blue),
                    .init(cardID: "power-help", titleKey: "app.tile.power-help", symbol: "bolt", tint: .orange),
                ]),
            ]
        case .papers:
            [
                HouseholdGroup(id: "civic", titleKey: "app.group.civic", tiles: [
                    .init(cardID: "vote", titleKey: "app.tile.vote", symbol: "checkmark.seal", tint: .blue),
                    .init(cardID: "scam", titleKey: "app.tile.scam", symbol: "exclamationmark.triangle", tint: .orange),
                    .init(cardID: "uscis", titleKey: "app.tile.uscis", symbol: "doc.text", tint: .indigo),
                ]),
                HouseholdGroup(id: "renting", titleKey: "app.group.renting", tiles: [
                    .init(cardID: "landlord", titleKey: "app.tile.landlord", symbol: "key", tint: .brown),
                ]),
            ]
        case .help:
            [
                HouseholdGroup(id: "everyday", titleKey: "app.group.everyday", tiles: [
                    .init(cardID: "benefits", titleKey: "app.tile.benefits", symbol: "fork.knife", tint: .green),
                    .init(cardID: "health-help", titleKey: "app.tile.health-help", symbol: "cross.case", tint: .red),
                    .init(cardID: "shelter-help", titleKey: "app.tile.shelter-help", symbol: "bed.double", tint: .purple),
                ]),
                HouseholdGroup(id: "lawyer", titleKey: "app.group.lawyer", tiles: [
                    .init(cardID: "legal-help", titleKey: "app.tile.legal-help", symbol: "briefcase", tint: .indigo),
                    .init(cardID: "immigration-lawyer", titleKey: "app.tile.immigration-lawyer", symbol: "person.text.rectangle", tint: .teal),
                ]),
            ]
        }
    }

    var orderedIDs: [CardID] { groups.flatMap(\.cardIDs) }
    var cardIDs: Set<CardID> { Set(orderedIDs) }
    var filter: CardFilter { CardFilter(subject: .household, cardIDs: cardIDs) }
    var rowID: String { "household.board.\(titleKey)" }

    static func titleKey(for filter: CardFilter) -> String? {
        allCases.first { $0.cardIDs == filter.cardIDs }?.titleKey
    }

    static func matching(_ filter: CardFilter) -> HouseholdBoard? {
        allCases.first { $0.cardIDs == filter.cardIDs }
    }

    static func group(matching filter: CardFilter) -> HouseholdGroup? {
        allCases.flatMap(\.groups).first { $0.cardIDSet == filter.cardIDs }
    }
}

struct PersonRow: View {
    @Environment(AppModel.self) private var model
    let person: Person
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Names are never translated; tagged with no language change.
            Text(verbatim: person.displayName).font(.headline)
            HStack(spacing: 6) {
                KeyText(person.stage.labelKey)
                Text(verbatim: "·").accessibilityHidden(true)
                KeyText(person.mode.labelKey)
            }
            .font(.subheadline)
        }
    }
}

struct PersonDetailView: View {
    @Environment(AppModel.self) private var model
    let personID: PersonID

    var body: some View {
        let router = model.router
        if let person = router.household?.person(personID) {
            let steps = router.nextSteps
            List {
                Section {
                    Text(verbatim: person.displayName).font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(A11yID.PersonDetail.name)
                    Button {
                        router.perform(.navigate(.stage(person.id, person.stage)), from: .touch)
                    } label: {
                        Label { KeyText(person.stage.labelKey) } icon: { Image(systemName: "stairs").accessibilityHidden(true) }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier(A11yID.PersonDetail.stage)
                }
                if let hero = steps.first {
                    Section {
                        CardRowButton(card: hero, person: person.id, id: A11yID.PersonDetail.hero)
                    } header: { AppText("app.person.hero") }
                }
                Section {
                    if steps.count > 1 {
                        ForEach(Array(steps.dropFirst()), id: \.id) { card in CardRowButton(card: card, person: person.id, id: nil) }
                    } else {
                        AppText("app.person.no_more_steps")
                    }
                } header: { AppText("app.person.next_steps") }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(A11yID.PersonDetail.nextSteps)
                Section {
                    ActionRow(titleKey: "app.person.read_step", systemImage: "speaker.wave.2", id: nil,
                              action: .readAloud(.step))
                    ActionRow(titleKey: "app.person.edit", systemImage: "pencil", id: A11yID.PersonDetail.edit,
                              action: .navigate(.editPerson(person.id)))
                    ActionRow(titleKey: "app.person.delete", systemImage: "trash", id: A11yID.PersonDetail.delete, role: .destructive,
                              action: .deletePerson(person.id))
                }
            }
            .accessibilityIdentifier(A11yID.PersonDetail.list)
            .accessibilityAction(named: Text(verbatim: model.app("app.action.next_step"))) { router.perform(.nextStep, from: .voiceOver) }
            .accessibilityAction(named: Text(verbatim: model.app("app.action.previous_step"))) { router.perform(.previousStep, from: .voiceOver) }
            .screen("app.screen.person")
        } else {
            AppText("app.person.gone").screen("app.screen.person")
        }
    }
}

/// Add person / edit person. Only a name and a think-in language are needed; status is optional
/// and never asked for by the app.
struct PersonFormView: View {
    @Environment(AppModel.self) private var model
    let personID: PersonID?
    @State private var draft = PersonDraft(displayName: "", thinkIn: "es", goal: .arrive)
    @State private var ageText = ""
    @State private var loaded = false

    var body: some View {
        let router = model.router
        Form {
            Section {
                TextField(text: $draft.displayName) { AppText("app.form.name") }
                    .textContentType(.name)
                    .accessibilityIdentifier(A11yID.AddPerson.name)
                TextField(text: $ageText) { AppText("app.form.age") }
                    .keyboardType(.numberPad)
                Picker(selection: $draft.goal) {
                    ForEach(Goal.allCases, id: \.self) { KeyText($0.labelKey).tag($0) }
                } label: { AppText("app.form.goal") }
                Picker(selection: $draft.stage) {
                    AppText("app.form.stage_keep").tag(Stage?.none)
                    ForEach(Stage.allCases, id: \.self) { KeyText($0.labelKey).tag(Stage?.some($0)) }
                } label: { AppText("app.form.stage") }
                    .accessibilityIdentifier(A11yID.AddPerson.stage)
                Picker(selection: $draft.mode) {
                    AppText("app.form.mode_from_goal").tag(Mode?.none)
                    ForEach(Mode.allCases, id: \.self) { KeyText($0.labelKey).tag(Mode?.some($0)) }
                } label: { AppText("app.form.mode") }
                    .accessibilityIdentifier(A11yID.AddPerson.mode)
            }
            Section {
                Picker(selection: Binding(get: { draft.origin?.countryCode ?? "" },
                                          set: { draft.origin = $0.isEmpty ? nil : Origin(countryCode: $0) })) {
                    AppText("app.form.origin_none").tag("")
                    ForEach(Regions.all(in: model.surface), id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                } label: { AppText("app.form.origin") }
                    .accessibilityIdentifier(A11yID.AddPerson.origin)
                Picker(selection: Binding(get: { draft.surfaceLanguage ?? "" }, set: { draft.surfaceLanguage = $0.isEmpty ? nil : $0 })) {
                    AppText("app.form.language_follow").tag("")
                    ForEach(SurfaceLanguage.allCases, id: \.self) { Text(verbatim: $0.autonym).tag($0.rawValue) }
                } label: { AppText("app.form.language") }
                    .accessibilityIdentifier(A11yID.AddPerson.language)
                Picker(selection: $draft.thinkIn) {
                    ForEach(Languages.all(in: model.surface, including: draft.thinkIn), id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                } label: { AppText("app.form.think_in") }
                    .accessibilityIdentifier(A11yID.AddPerson.thinkIn)
                TextField(text: Binding(get: { draft.statusWord ?? "" }, set: { draft.statusWord = $0.isEmpty ? nil : $0 })) {
                    AppText("app.form.status_optional")
                }
            }
            if case .refused(let reason)? = router.lastOutcome {
                Section { KeyText(reason).foregroundStyle(.red).accessibilityIdentifier(A11yID.AddPerson.error) }
            }
            Section {
                Button {
                    draft.age = Int(ageText.trimmingCharacters(in: .whitespaces))
                    router.perform(.savePerson(draft), from: .touch)
                } label: { AppText("app.form.save").frame(maxWidth: .infinity, minHeight: 44) }
                    .accessibilityIdentifier(A11yID.AddPerson.save)
                ActionRow(titleKey: "app.form.cancel", systemImage: "xmark", id: A11yID.AddPerson.cancel, action: .back)
            }
        }
        .accessibilityIdentifier(A11yID.AddPerson.form)
        .screen(personID == nil ? "app.screen.add_person" : "app.screen.edit_person")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let id = personID, let p = router.household?.person(id) {
                draft = PersonDraft(p)
                ageText = p.age.map(String.init) ?? ""
            } else {
                draft.thinkIn = router.thinkIn.bcp47
            }
        }
    }
}

/// Country names from the system, in the surface language (no country list of ours).
enum Regions {
    struct Entry { let code: String; let name: String }
    static func all(in language: String) -> [Entry] {
        let locale = Locale(identifier: language)
        return Locale.Region.isoRegions
            .filter { $0.subRegions.isEmpty && $0.identifier.count == 2 && $0.identifier.allSatisfy(\.isLetter) }
            .compactMap { r in locale.localizedString(forRegionCode: r.identifier).map { Entry(code: r.identifier, name: $0) } }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

/// Languages a person may think in: any the system can name, shown by name in the surface language.
enum Languages {
    struct Entry { let code: String; let name: String }
    static func all(in language: String, including current: String) -> [Entry] {
        let locale = Locale(identifier: language)
        var codes = Set(Locale.LanguageCode.isoLanguageCodes.map(\.identifier).filter { $0.count == 2 })
        codes.insert(current)
        return codes.compactMap { c in locale.localizedString(forLanguageCode: c).map { Entry(code: c, name: $0) } }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
