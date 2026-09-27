import SwiftUI
import ADCore
import ADLocale
import ADRouter

/// ADCore's four questions (pin, people, origin and language, goal). Never a status question.
/// Each answer is an `AppAction.answerOnboarding` (or `setPin`) through the router; the same
/// questions can be answered by voice from the mic.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let step: OnboardingStep
    @AccessibilityFocusState private var questionFocused: Bool
    @State private var people: [PersonEntry] = [PersonEntry()]
    @State private var origin = ""
    @State private var thinkIn = ""

    struct PersonEntry: Identifiable { let id = UUID(); var name = ""; var age = "" }

    var body: some View {
        let router = model.router
        Form {
            Section {
                KeyText(step.prompt)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(A11yID.Onboarding.question)
                    .accessibilityFocused($questionFocused)
            }
            Section { content(router) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(A11yID.Onboarding.step(step))
            if case .refused(let reason)? = router.lastOutcome {
                Section { KeyText(reason).foregroundStyle(.red) }
            }
        }
        .accessibilityIdentifier(A11yID.Onboarding.form)
        .screen("app.screen.onboarding")
        .onAppear { questionFocused = true }
        .onChange(of: step) { questionFocused = true }
    }

    @ViewBuilder
    private func content(_ router: Router) -> some View {
        switch step {
        case .pin:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SurfaceLanguage.allCases, id: \.self) { lang in
                        Button {
                            router.perform(.setSurfaceLanguage(lang), from: .touch)
                        } label: {
                            Text(verbatim: lang.autonym)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(router.surface == lang ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                            in: Capsule())
                        }
                        .accessibilityIdentifier(A11yID.Settings.language(lang.rawValue))
                    }
                }
            }
            ForEach(router.pins) { pin in
                Button { router.perform(.setPin(pin.id), from: .touch) } label: {
                    Label { KeyText(pin.label) } icon: { Image(systemName: "mappin").accessibilityHidden(true) }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .identifier(pin.id == DemoSeed.kendall ? A11yID.Pin.kendall : pin.id == DemoSeed.downtown ? A11yID.Pin.downtown : nil)
            }
        case .people:
            ForEach($people) { $entry in
                HStack {
                    TextField(text: $entry.name) { AppText("app.form.name") }.textContentType(.name)
                    TextField(text: $entry.age) { AppText("app.form.age") }.keyboardType(.numberPad).frame(maxWidth: 90)
                }
            }
            Button { people.append(PersonEntry()) } label: {
                Label { AppText("app.onboarding.add_another") } icon: { Image(systemName: "plus").accessibilityHidden(true) }
                    .frame(minHeight: 44)
            }
            nextButton {
                .answerOnboarding(.people(people.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
                    .map { OnboardingPerson(displayName: $0.name, age: Int($0.age.trimmingCharacters(in: .whitespaces))) }))
            }
        case .originAndLanguage:
            Picker(selection: $origin) {
                AppText("app.form.origin_none").tag("")
                ForEach(Regions.all(in: model.surface), id: \.code) { Text(verbatim: $0.name).tag($0.code) }
            } label: { AppText("app.form.origin") }
            Picker(selection: Binding(get: { thinkIn.isEmpty ? model.surface : thinkIn }, set: { thinkIn = $0 })) {
                ForEach(Languages.all(in: model.surface, including: model.surface), id: \.code) { Text(verbatim: $0.name).tag($0.code) }
            } label: { AppText("app.form.think_in") }
            nextButton { .answerOnboarding(.originAndLanguage(origin: origin.isEmpty ? nil : Origin(countryCode: origin),
                                                              thinkIn: thinkIn.isEmpty ? model.surface : thinkIn)) }
            Button {
                router.perform(.answerOnboarding(.originAndLanguage(origin: nil, thinkIn: thinkIn.isEmpty ? model.surface : thinkIn)), from: .touch)
            } label: { AppText("app.onboarding.skip_origin").frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityIdentifier(A11yID.Onboarding.skip)
        case .goal:
            ForEach(Goal.allCases, id: \.self) { goal in
                Button { router.perform(.answerOnboarding(.goal(goal)), from: .touch) } label: {
                    KeyText(goal.labelKey).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private func nextButton(_ action: @escaping () -> AppAction) -> some View {
        Button { model.router.perform(action(), from: .touch) } label: {
            Label { AppText("app.onboarding.next") } icon: { Image(systemName: "arrow.right").accessibilityHidden(true) }
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier(A11yID.Onboarding.next)
    }
}
