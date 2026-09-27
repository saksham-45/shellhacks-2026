import SwiftUI
import ADCore
import ADRouter

struct CardRowButton: View {
    @Environment(AppModel.self) private var model
    let card: Card
    let person: PersonID?
    let id: String?

    var body: some View {
        Button {
            model.router.perform(.navigate(.card(card.id, person: person)), from: .touch)
        } label: {
            HStack {
                Image(systemName: card.heroTopic?.symbolName ?? "rectangle.portrait")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(verbatim: CivicCopy.withoutDemoMark(model.text(card.titleKey))).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .identifier(id)
        .accessibilityInputLabels([Text(verbatim: model.text(card.titleKey))])
        .accessibilityAction(named: Text(verbatim: model.app("app.action.read"))) {
            model.router.perform(.navigate(.card(card.id, person: person)), from: .voiceOver)
            model.router.perform(.readAloud(.card(card.id)), from: .voiceOver)
        }
    }
}

/// The wallet, or one stage's cards, always through ADCore's privacy and tourist rules (router).
struct CardsView: View {
    @Environment(AppModel.self) private var model
    let filter: CardFilter
    let person: PersonID?

    var body: some View {
        let visible = Set(model.router.cards(matching: filter).map(\.id))
        let personID = person ?? model.router.activePerson
        List {
            if let board = HouseholdBoard.matching(filter) {
                boardSections(board, visible: visible, person: personID)
            } else if filter.subject == .household, filter.cardIDs == nil, filter.stage == nil, filter.desk == nil {
                ForEach(HouseholdBoard.allCases) { board in
                    boardSections(board, visible: visible, person: personID)
                }
            } else {
                if let stage = filter.stage { Section { KeyText(stage.labelKey).font(.headline) } }
                ForEach(orderedList) { card in
                    CardRowButton(card: card, person: personID, id: A11yID.Cards.row(card.id.rawValue))
                }
                if orderedList.isEmpty { AppText("app.cards.empty") }
            }
            if model.content.isDemo { HStack { DemoBadge(); AppText("app.demo.explainer") } }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CivicTheme.sand)
        .accessibilityIdentifier(A11yID.Cards.list)
        .screen(screenTitle, large: HouseholdBoard.matching(filter) != nil)
    }

    @ViewBuilder
    private func boardSections(_ board: HouseholdBoard, visible: Set<CardID>, person: PersonID?) -> some View {
        if board == .around {
            Section {
                AppText("app.household.getting_around.lede")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(board.groups) { group in
            let tiles = group.tiles.filter { visible.contains($0.cardID) }
            if !tiles.isEmpty {
                Section {
                    ServiceGrid(items: tiles, columns: 4) { tile in
                        ServiceTile(
                            title: model.app(tile.titleKey),
                            symbol: tile.symbol,
                            tint: tile.tint,
                            id: A11yID.Cards.row(tile.cardID.rawValue)
                        ) {
                            model.router.perform(.navigate(.card(tile.cardID, person: person)), from: .touch)
                        }
                    }
                } header: {
                    AppText(group.titleKey)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }
            }
        }
    }

    private var orderedList: [Card] {
        let cards = model.router.cards(matching: filter)
        guard let board = HouseholdBoard.allCases.first(where: { $0.cardIDs == filter.cardIDs }) else { return cards }
        let rank = Dictionary(uniqueKeysWithValues: board.orderedIDs.enumerated().map { ($0.element, $0.offset) })
        return cards.sorted { (rank[$0.id] ?? 99) < (rank[$1.id] ?? 99) }
    }

    private var screenTitle: String {
        HouseholdBoard.titleKey(for: filter)
            ?? (filter.stage == nil ? "app.screen.cards" : "app.screen.stage")
    }
}

/// One card: title, every fact as ONE element (value + qualifier: status/source or desk), the desk,
/// call and map as separate elements (confirmed by the router first), read aloud / stop.
struct CardDetailView: View {
    @Environment(AppModel.self) private var model
    let cardID: CardID
    let personID: PersonID?

    var body: some View {
        let router = model.router
        if let card = router.catalog.first(where: { $0.id == cardID }) {
            let rows = model.factRows(card)
            let title = CivicCopy.withoutDemoMark(model.text(card.titleKey))
            List {
                Section {
                    Text(verbatim: title)
                        .font(.title2.bold())
                        .foregroundStyle(CivicTheme.midnight)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(A11yID.Card.title)
                    Text(verbatim: model.app(model.content.isDemo ? "app.card.for_pin_demo" : "app.card.for_pin"))
                        .font(.subheadline)
                        .foregroundStyle(CivicTheme.teal)
                    if card.id != "bumper-tap", card.id != "house-damage" {
                        if model.readingCard == card.id, model.isReading {
                            ActionRow(titleKey: "app.card.stop_reading", systemImage: "stop.fill", id: A11yID.Card.stopReading,
                                      action: .stopSpeaking)
                        } else {
                            ActionRow(titleKey: "app.card.read_aloud", systemImage: "speaker.wave.2", id: A11yID.Card.readAloud,
                                      action: .readAloud(.card(card.id)))
                        }
                    }
                }
                TrustSection(card: card)
                if card.id == "bumper-tap" {
                    PhotoGuideView(kind: .vehicle)
                }
                if card.id == "house-damage" {
                    PhotoGuideView(kind: .home)
                }
                Section {
                    ForEach(rows, id: \.id) { row in
                        FactRowView(row: row)
                        if row.place != nil {
                            ActionRow(titleKey: "app.card.open_map", systemImage: "map", id: nil,
                                      action: .openMap(.place(FactRef(regionPackID: packID(of: row.id, card: card), ledgerFactID: row.id))))
                        }
                    }
                } header: { AppText("app.card.facts") }
                Section {
                    Button { router.perform(.navigate(.desk(card.desk)), from: .touch) } label: {
                        Label { Text(verbatim: "\(model.app("app.card.desk_label")): \(card.desk.rawValue)") }
                            icon: { Image(systemName: "building.columns").accessibilityHidden(true) }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier(A11yID.Card.desk)
                    ActionRow(titleKey: "app.card.call", systemImage: "phone", id: A11yID.Card.call, action: .callDesk(card.desk))
                }
                if model.content.isDemo {
                    Section { DemoBadge() }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(CivicTheme.sand)
            .accessibilityIdentifier(A11yID.Card.list)
            .accessibilityAction(named: Text(verbatim: model.app("app.action.read"))) { router.perform(.readAloud(.card(card.id)), from: .voiceOver) }
            .accessibilityAction(named: Text(verbatim: model.app("app.action.stop"))) { router.perform(.stopSpeaking, from: .voiceOver) }
            .accessibilityAction(named: Text(verbatim: model.app("app.action.repeat"))) { router.perform(.repeatLast, from: .voiceOver) }
            .accessibilityAction(named: Text(verbatim: model.app("app.action.next_step"))) { router.perform(.nextStep, from: .voiceOver) }
            .screen("app.screen.card", verbatim: title)
        } else {
            AppText("app.card.missing").screen("app.screen.card")
        }
    }

    /// The fact id's pack: the longest region-pack prefix ("us-fl-miamidade.x.y" -> "us-fl-miamidade").
    private func packID(of id: FactID, card: Card) -> RegionPackID {
        let head = id.rawValue.split(separator: ".").first.map(String.init) ?? card.regionPack.rawValue
        return RegionPackID(rawValue: head)
    }
}

/// Source, date, jurisdiction, demo/verified, desk — the ledger, not a model.
struct TrustSection: View {
    @Environment(AppModel.self) private var model
    let card: Card

    var body: some View {
        let trust = model.trust(for: card)
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    labeled("app.trust.source", trust.publisher ?? model.app("app.trust.no_source"))
                    if let retrieved = trust.retrieved {
                        labeled("app.trust.retrieved", retrieved)
                    }
                    labeled("app.trust.jurisdiction", trust.jurisdiction)
                    labeled("app.trust.evidence", model.app(trust.evidenceKey))
                    labeled("app.trust.desk", model.deskTitle(trust.desk))
                    Text(verbatim: model.app("app.trust.knows")).font(.footnote)
                    Text(verbatim: model.app("app.trust.does_not")).font(.footnote)
                    Text(verbatim: "\(model.app("app.trust.which_desk")) \(model.deskTitle(trust.desk)).")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            } label: {
                AppText("app.trust.why")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
    }

    private func labeled(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            AppText(key).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).font(.body)
        }
    }
}

struct FactRowView: View {
    @Environment(AppModel.self) private var model
    let row: FactRowText

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let value = row.value {
                // Values (codes, names, numbers) are shown as written; tagged with their own language if known.
                Text(tagged(value, row.valueLanguage)).font(.body.weight(.semibold))
            }
            Text(tagged(row.qualifier, model.surface)).font(.footnote)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Card.fact(row.id.rawValue))
    }
}

/// Desk handoff: phone and address only from ledger facts; both leave the app after a yes.
struct DeskView: View {
    @Environment(AppModel.self) private var model
    let desk: DeskID

    var body: some View {
        List {
            Section {
                Text(verbatim: desk.rawValue).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                AppText("app.desk.explainer")
            }
            Section {
                ActionRow(titleKey: "app.card.call", systemImage: "phone", id: A11yID.Desk.call, action: .callDesk(desk))
                ActionRow(titleKey: "app.card.open_map", systemImage: "map", id: A11yID.Desk.map, action: .openMap(.desk(desk)))
            }
        }
        .accessibilityIdentifier(A11yID.Desk.panel)
        .screen("app.screen.desk")
    }
}
