import SwiftUI
import ADCore
import ADRouter

/// The voice panel (Destination.voice): what was heard, the answer, stop, and "type instead".
struct VoicePanelView: View {
    @Environment(AppModel.self) private var model
    @State private var typed = ""
    @FocusState private var typing: Bool

    var body: some View {
        let speechNotice = model.notice?.isSpeechNotice == true
        List {
            if speechNotice, let notice = model.notice {
                Section {
                    ContentUnavailableView {
                        Label {
                            AppText(notice.key)
                        } icon: {
                            Image(systemName: "mic.slash")
                        }
                    } description: {
                        AppText("app.voice.footer")
                    }
                    .identifier(A11yID.Voice.unavailableNotice)
                }
            } else {
                Section {
                    HStack {
                        Image(systemName: model.listening ? "waveform" : "mic").accessibilityHidden(true)
                        AppText(model.listening ? "app.voice.listening" : "app.voice.not_listening")
                    }
                }
            }
            Section {
                Text(verbatim: model.transcript.isEmpty ? model.app("app.voice.nothing_yet") : model.transcript)
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
                    .accessibilityIdentifier(A11yID.Voice.transcript)
            } header: { AppText("app.voice.heard") }
            Section {
                Text(tagged(model.answer.isEmpty ? model.app("app.voice.nothing_yet") : model.answer, model.surface))
                    .foregroundStyle(model.answer.isEmpty ? .secondary : .primary)
                    .accessibilityIdentifier(A11yID.Voice.answer)
            } header: { AppText("app.voice.answer") }
            if model.isReading || model.listening {
                Section {
                    Button {
                        if model.isReading { model.router.perform(.stopSpeaking, from: .touch) }
                        if model.listening { model.toggleListening() }
                    } label: {
                        Label { AppText("app.voice.stop") } icon: { Image(systemName: "stop.fill").accessibilityHidden(true) }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier(A11yID.Voice.stop)
                }
            }
            if SecretEnv.gemini != nil || SecretEnv.elevenLabs != nil {
                Section {
                    if SecretEnv.gemini != nil { AppText("app.voice.gemini_share") }
                    if SecretEnv.elevenLabs != nil { AppText("app.voice.elevenlabs") }
                } header: { AppText("app.voice.how") }
            }
            Section {
                TextField(text: $typed) { AppText("app.voice.type_instead") }
                    .focused($typing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier(A11yID.Voice.typeInstead)
                Button(action: send) {
                    Label { AppText("app.voice.send") } icon: { Image(systemName: "paperplane").accessibilityHidden(true) }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            } footer: { AppText("app.voice.footer") }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier(A11yID.Voice.panel)
        .screen("app.screen.voice")
    }

    private func send() {
        let text = typed
        typed = ""
        Task { await model.hear(text, language: nil, from: .voice) }
    }
}

/// Clarifying question (2-3 options) and leave-app confirmation, over any screen. Spoken by the model,
/// VoiceOver focus moves to the question, answerable by voice (yes/no/ordinals) or 44 pt buttons.
/// No timeout: it stays until answered.
struct PromptOverlay: View {
    @Environment(AppModel.self) private var model
    @AccessibilityFocusState private var focus: Focus?
    enum Focus: Hashable { case clarify, confirm }

    var body: some View {
        let router = model.router
        List {
            if let c = router.pendingClarification {
                Section {
                    KeyText(c.question)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(A11yID.Router.clarify)
                        .accessibilityFocused($focus, equals: .clarify)
                    ForEach(Array(c.options.enumerated()), id: \.element.id) { index, option in
                        Button { router.perform(.choose(option.id), from: .touch) } label: {
                            HStack {
                                Text(verbatim: "\(index + 1).").accessibilityHidden(true)
                                KeyText(option.label)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier(A11yID.Router.clarifyOption(index + 1))
                    }
                }
            }
            if let pending = router.pendingConfirmation {
                Section {
                    if let summary = model.handoffSummary(for: pending) {
                        Text(verbatim: summary.headline)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(A11yID.Router.confirm)
                            .accessibilityFocused($focus, equals: .confirm)
                        if let phone = summary.phone {
                            Text(verbatim: phone)
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                        if let languages = summary.languages {
                            Text(verbatim: languages).font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        KeyText(prompt(for: pending))
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(A11yID.Router.confirm)
                            .accessibilityFocused($focus, equals: .confirm)
                    }
                    Button { router.perform(.confirm(true), from: .touch) } label: {
                        AppText(yesKey(pending)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier(A11yID.Router.confirmYes)
                    .accessibilityInputLabels([Text(verbatim: model.app(yesKey(pending)))])
                    Button(role: .cancel) { router.perform(.confirm(false), from: .touch) } label: {
                        AppText(noKey(pending)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .accessibilityIdentifier(A11yID.Router.confirmNo)
                    .accessibilityInputLabels([Text(verbatim: model.app(noKey(pending)))])
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: router.pendingClarification) { _, new in if new != nil { focus = .clarify } }
        .onChange(of: router.pendingConfirmation) { _, new in if new != nil { focus = .confirm } }
    }

    private func prompt(for action: AppAction) -> StringKey {
        if case .openMap = action { return RouterText.askOpenMap }
        return RouterText.askCallDesk
    }

    private func yesKey(_ action: AppAction) -> String {
        if case .openMap = action { return "app.handoff.confirm.map" }
        return "app.handoff.confirm.call"
    }

    private func noKey(_ action: AppAction) -> String {
        "app.handoff.confirm.cancel"
    }
}
