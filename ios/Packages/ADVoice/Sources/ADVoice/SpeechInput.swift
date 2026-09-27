import Foundation
import ADCore
import ADLocale

/// Speech in, end to end: returns the transcript plus the detected language (always one of
/// {es, en, ht} ∪ {thinkIn}). The live implementation is `SpeechInputRouter`; UI tests use
/// `ScriptedSpeechInput` (`-myadVoiceStub -myadVoiceScript <name>`).
public protocol SpeechInput: Sendable {
    func listen(_ audio: RecordedAudio?, context: ListenContext) async -> RecognitionOutcome
}

/// Routing (Creole report §5 and §7.1):
/// - Creole is never picked from audio. If the prior is ht (explicit setting or ht surface), the
///   audio goes to a server engine for ht, and only with consent, online, and "never send my
///   voice" off. The transcript is always confirmed before acting.
/// - Otherwise on-device engines run the prior first, then the other surfaces and think-in they
///   support, one after another over the same recording; text scoring picks the language.
/// - If the text looks Creole but no Creole engine may be used, the outcome says why (consent,
///   offline, never-send) instead of acting on an es/en transcript of Creole speech.
/// - `needsConfirmation` means recognition doubt only: ht transcripts, French winners and
///   ambiguous/low-confidence picks. An exact on-device es/en command phrase on the Creole path
///   (`command` set) is not flagged. Confirming irreversible commands (call) is the router's job.
public struct SpeechInputRouter: SpeechInput {
    let recognizers: [any SpeechRecognizing]
    let detector: TextLanguageDetector
    /// Voice commands accepted on-device in es/en when the Creole path cannot listen.
    let commands: CommandLexicon?

    public init(recognizers: [any SpeechRecognizing], detector: TextLanguageDetector,
                commands: CommandLexicon? = try? CommandLexicon.bundled()) {
        self.recognizers = recognizers
        self.detector = detector
        self.commands = commands
    }

    public func listen(_ audio: RecordedAudio?, context: ListenContext) async -> RecognitionOutcome {
        guard let audio else { return .unavailable(.nothingHeard) }
        let ht = SurfaceLanguage.ht.language
        let prior = context.prior
        if prior.hasSameLanguageCode(as: ht) {
            let creole = await listenCreole(audio, context: context)
            // No Creole listening (no engine, never-send, offline or no consent yet): the person
            // can still leave Kreyòl or go back by voice. On-device es/en only, commands only;
            // nothing is sent anywhere, so privacy and connectivity don't block it.
            if case .unavailable(let reason) = creole, reason != .nothingHeard,
               let command = await onDeviceCommand(audio) {
                return .heard(command)
            }
            return creole
        }
        let order = [prior] + context.candidates.languages.filter { !$0.hasSameLanguageCode(as: prior) && !$0.hasSameLanguageCode(as: ht) }
        var transcripts: [Transcript] = []
        for language in order {
            guard let engine = await onDeviceEngine(for: language) else { continue }
            if let t = try? await engine.transcribe(audio, language: language) { transcripts.append(t) }
        }
        guard !transcripts.isEmpty else {
            return .unavailable(.noEngine(prior))
        }
        // Creole speech transcribed by an es/en engine: route to the Creole engine if allowed.
        if transcripts.contains(where: { detector.detect($0.text) == .ht }) {
            let creole = await listenCreole(audio, context: context)
            if case .heard = creole { return creole }
            if case .unavailable(let reason) = creole, reason != .noEngine(ht) { return creole }
            // No Creole engine at all: every es/en/fr transcript is a garbled version of Creole
            // speech. Say so (the "no speech in Kreyòl" notice) instead of asking a Creole
            // speaker to confirm a Spanish guess, and never answer in French.
            return .unavailable(.noEngine(ht))
        }
        guard let d = LanguageIdentification.choose(transcripts, detector: detector, candidates: context.candidates, prior: prior) else {
            return .unavailable(.nothingHeard)
        }
        // ht is always a candidate, and a French engine turns Creole speech into French text the
        // detector cannot flag. French stays possible for French think-in speakers, but never
        // without confirmation.
        let frenchWon = d.language.hasSameLanguageCode(as: Locale.Language(identifier: "fr"))
        return .heard(Recognition(transcript: d.transcript.text, language: d.language, confidence: d.transcript.confidence ?? d.score,
                                  engine: d.transcript.engine, needsConfirmation: d.isAmbiguous || frenchWon))
    }

    private func listenCreole(_ audio: RecordedAudio, context: ListenContext) async -> RecognitionOutcome {
        let ht = SurfaceLanguage.ht.language
        var serverEngine: (any SpeechRecognizing)?
        for r in recognizers where await r.supports(ht) {
            if r.location == .onDevice {
                // None exists today (Apple has no ht STT); kept for a future on-device model.
                if let t = try? await r.transcribe(audio, language: ht), !t.text.isEmpty {
                    return .heard(Recognition(transcript: t.text, language: ht, confidence: t.confidence ?? 0, engine: t.engine, needsConfirmation: true))
                }
            } else if serverEngine == nil {
                serverEngine = r
            }
        }
        guard let server = serverEngine else { return .unavailable(.noEngine(ht)) }
        if context.privacy.neverSendVoice { return .unavailable(.neverSendVoice(ht)) }
        if !context.privacy.cloudVoiceConsent { return .unavailable(.consentRequired(ht)) }
        if !context.privacy.isOnline { return .unavailable(.offline(ht)) }
        guard let t = try? await server.transcribe(audio, language: ht), !t.text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .unavailable(.nothingHeard)
        }
        // The reply language still follows the TEXT: a Spanish sentence said with the Creole
        // prior is answered in Spanish. French is impossible (candidates only).
        let textLang = detector.detect(t.text).map(\.language) ?? ht
        let language = context.candidates.candidate(for: textLang) ?? ht
        return .heard(Recognition(transcript: t.text, language: language, confidence: t.confidence ?? 0, engine: t.engine,
                                  needsConfirmation: true))
    }

    /// es then en, on-device engines only (never a server): a transcript that is exactly a
    /// command phrase. Anything else is nil (the Creole outcome stands).
    private func onDeviceCommand(_ audio: RecordedAudio) async -> Recognition? {
        guard let commands else { return nil }
        for surface in [SurfaceLanguage.es, .en] {
            guard let engine = await onDeviceEngine(for: surface.language),
                  let t = try? await engine.transcribe(audio, language: surface.language),
                  let match = commands.match(t.text, in: [surface]).first else { continue }
            // C3: an exact phrase match leaves no recognition doubt. Irreversible commands (call)
            // are confirmed once by the router, not here.
            return Recognition(transcript: t.text, language: surface.language, confidence: t.confidence ?? 0,
                               engine: t.engine, needsConfirmation: false, command: match.command)
        }
        return nil
    }

    /// On the ht surface, whether es/en on-device commands can be heard when Creole listening
    /// can't (drives `ListenUnavailable.messageKey(surface:commandsOnlyAvailable:)`).
    public func commandsOnlyAvailable() async -> Bool {
        guard commands != nil else { return false }
        for surface in [SurfaceLanguage.es, .en] where await onDeviceEngine(for: surface.language) != nil { return true }
        return false
    }

    private func onDeviceEngine(for language: Locale.Language) async -> (any SpeechRecognizing)? {
        for r in recognizers where r.location == .onDevice {
            if await r.supports(language) { return r }
        }
        return nil
    }
}
