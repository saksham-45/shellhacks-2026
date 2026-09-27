import SwiftUI
import ADCore
import ADRouter

/// The navigation stack is bound to `router.path`; the only write back is the system back gesture,
/// which goes through `router.systemPopped(to:)` (pop only). No view pushes directly.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var finishedStartup = false

    private var playStartup: Bool {
        !model.options.deterministic && model.options.screen == nil && !finishedStartup
    }

    var body: some View {
        let router = model.router
        ZStack {
            Group {
                if router.household == nil {
                    NavigationStack {
                        OnboardingView(step: onboardingStep)
                    }
                } else {
                    NavigationStack(path: Binding(get: { router.path }, set: { router.systemPopped(to: $0) })) {
                        HouseholdView()
                            .navigationDestination(for: Destination.self) { DestinationView(destination: $0) }
                    }
                }
            }
            if playStartup {
                StartupFilmView {
                    withAnimation(.easeOut(duration: 0.45)) { finishedStartup = true }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .tint(CivicTheme.crayola)
        .environment(\.locale, router.surface.locale)
        .alert(noticeTitle, isPresented: noticeAlertPresented) {
            Button(model.app("app.notice.dismiss"), role: .cancel) { model.dismissNotice() }
        } message: {
            if case .noPhoneNumber(let desk) = model.notice {
                Text(verbatim: "\(model.app("app.card.desk_label")): \(desk.rawValue)")
            }
        }
        .sheet(isPresented: promptPresented) {
            NavigationStack { PromptOverlay() }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { TestStatusBar() }
        .transaction { if model.options.deterministic { $0.disablesAnimations = true } }
    }

    private var onboardingStep: OnboardingStep {
        if case .onboarding(let step)? = model.router.current { return step }
        return .pin
    }

    private var noticeTitle: String {
        model.notice.map { model.app($0.key) } ?? ""
    }

    /// System alert for notices that are not already the Voice empty state (Apple Maps / Phone).
    private var noticeAlertPresented: Binding<Bool> {
        Binding(
            get: {
                guard let notice = model.notice else { return false }
                if notice.isSpeechNotice, model.router.current == .voice { return false }
                return true
            },
            set: { if !$0 { model.dismissNotice() } }
        )
    }

    private var promptPresented: Binding<Bool> {
        Binding(
            get: { model.router.pendingClarification != nil || model.router.pendingConfirmation != nil },
            set: { if !$0, model.router.pendingConfirmation != nil { model.router.perform(.confirm(false), from: .touch) } }
        )
    }
}

struct DestinationView: View {
    let destination: Destination
    var body: some View {
        switch destination {
        case .household: HouseholdView()
        case .person(let id): PersonDetailView(personID: id)
        case .addPerson: PersonFormView(personID: nil)
        case .editPerson(let id): PersonFormView(personID: id)
        case .onboarding(let step): OnboardingView(step: step)
        case let .stage(id, stage): CardsView(filter: CardFilter(subject: .person, stage: stage), person: id)
        case let .card(id, person): CardDetailView(cardID: id, personID: person)
        case .cards(let filter): CardsView(filter: filter, person: nil)
        case .desk(let desk): DeskView(desk: desk)
        case .pin: PinView()
        case .settings, .language: SettingsView()
        case .voice: VoicePanelView()
        }
    }
}

/// UI-test markers only. Never a banner over the navigation bar.
struct TestStatusBar: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.handoff != nil || model.voiceScriptStatus != nil {
            VStack(spacing: 2) {
                if let handoff = model.handoff {
                    Text(verbatim: "handoff: \(handoff)").font(.caption2)
                        .accessibilityIdentifier(A11yID.Router.handoff)
                        .accessibilityValue(Text(verbatim: handoff))
                }
                if let status = model.voiceScriptStatus {
                    Text(verbatim: "voice script: \(status)").font(.caption2)
                        .accessibilityIdentifier(A11yID.Voice.stub)
                        .accessibilityValue(Text(verbatim: status))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
