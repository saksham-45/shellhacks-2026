import SwiftUI
import ADCore
import ADLocale
import ADRouter

/// Live language switch (es/en/ht, autonyms), think-in language (separate), and mode for the active person.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let router = model.router
        Form {
            Section {
                ForEach(SurfaceLanguage.allCases, id: \.self) { lang in
                    Button { router.perform(.setSurfaceLanguage(lang), from: .touch) } label: {
                        HStack {
                            // Autonyms, tagged with their own language.
                            Text(tagged(lang.autonym, lang.rawValue))
                            Spacer()
                            if router.surface == lang { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(id(for: lang))
                    .accessibilityAddTraits(router.surface == lang ? .isSelected : [])
                    .accessibilityInputLabels([Text(verbatim: lang.autonym)])
                }
            } header: { AppText("app.settings.surface") }
            Section {
                Picker(selection: Binding(get: { router.thinkIn.bcp47 },
                                          set: { router.perform(.setThinkIn(SpokenLanguage(bcp47: $0)), from: .touch) })) {
                    ForEach(Languages.all(in: model.surface, including: router.thinkIn.bcp47), id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                } label: { AppText("app.settings.think_in") }
                    .accessibilityIdentifier(A11yID.Settings.thinkIn)
            } footer: { AppText("app.settings.think_in_footer") }
            if let id = router.activePerson, let person = router.household?.person(id) {
                Section {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Button { router.perform(.setMode(mode), from: .touch) } label: {
                            HStack { KeyText(mode.labelKey); Spacer(); if person.mode == mode { Image(systemName: "checkmark").accessibilityHidden(true) } }
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                    }
                } header: { AppText("app.settings.mode") }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(A11yID.Settings.mode)
            }
            Section {
                ActionRow(titleKey: "app.settings.done", systemImage: "checkmark", id: A11yID.Settings.done, action: .back)
            }
        }
        .accessibilityIdentifier(A11yID.Settings.form)
        .screen("app.screen.settings")
    }

    private func id(for lang: SurfaceLanguage) -> String {
        A11yID.Settings.language(lang.rawValue)
    }
}

/// The two demo pins (addresses from Regions' fixtures).
struct PinView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let router = model.router
        List {
            Section {
                HStack {
                    AppText("app.pin.current")
                    Text(verbatim: router.household?.pin?.address ?? "—")
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(A11yID.Pin.current)
            }
            Section {
                ForEach(router.pins) { pin in
                    Button { router.perform(.setPin(pin.id), from: .touch) } label: {
                        HStack {
                            Image(systemName: "mappin").accessibilityHidden(true)
                            KeyText(pin.label)
                            Spacer()
                            if router.pinID == pin.id || router.household?.pin == pin.pin { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .identifier(pin.id == DemoSeed.kendall ? A11yID.Pin.kendall : pin.id == DemoSeed.downtown ? A11yID.Pin.downtown : nil)
                }
            } footer: { HStack { DemoBadge(); AppText("app.pin.demo_footer") } }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier(A11yID.Pin.list)
        .screen("app.screen.pin")
    }
}
