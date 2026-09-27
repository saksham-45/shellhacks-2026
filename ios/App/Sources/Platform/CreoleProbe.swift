#if os(iOS)
import AVFoundation
import NaturalLanguage
import Speech
import SwiftUI

/// `-myadProbe creole` (Mac batch only; Language report FM-MYAD-LANG §7.4). Measures, on this
/// simulator/device, what iOS offers for Haitian Creole, then speaks ONE `ht`-tagged sentence with
/// AVSpeechSynthesizer directly (bypassing the app's no-fallback rule on purpose, to observe the
/// fallback) while the screen shows it. Writes Documents/creole_probe.txt and .json; prints each
/// line with the prefix "MYAD-PROBE ".
/// The sentences are Language's UNREVIEWED draft test sentences (report §7.5), used only here.
struct CreoleProbeView: View {
    static let sentence = "Ki jou yo ranmase fatra lakay mwen?"
    static let lidSentences = [
        "Ki jou yo ranmase fatra lakay mwen?", "Èske m ka mete yon matla deyò ak gwo fatra yo?", "E peyaj la?",
        "Konbyen peyaj la koute ak SunPass?", "Ki nimewo pou m rele pou 311?", "Gen yon limyè poto ki kase nan lari mwen.",
        "Ki lè TPS pou Ayiti ap fini?", "Èske m bezwen enskri ankò pou TPS anvan fevriye?",
        "Ki kote ki gen yon klinik toupre m ki pa mande asirans?", "Pitit fi m nan gen lafyèv; èske klinik la louvri samdi?",
    ]

    @State private var probe = CreoleProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: "myAD Creole probe (debug)").font(.headline)
            Text(Self.tagged(Self.sentence)).font(.largeTitle)
                .environment(\.locale, Locale(identifier: "ht"))
                .accessibilityIdentifier("myad.probe.sentence")
            Text(verbatim: probe.status).font(.body).accessibilityIdentifier("myad.probe.status")
            ScrollView { Text(verbatim: probe.report).font(.caption.monospaced()) }
        }
        .padding()
        .task { await probe.run(sentence: Self.sentence, lid: Self.lidSentences) }
    }

    static func tagged(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        a.languageIdentifier = "ht"
        return a
    }
}

@MainActor
@Observable
final class CreoleProbe {
    var status = "running"
    var report = ""
    private var json: [String: Any] = [:]
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let observer = SpeechStartObserver()
    @ObservationIgnored private var started: CheckedContinuation<String, Never>?

    private func line(_ s: String) {
        report += s + "\n"
        print("MYAD-PROBE \(s)")
    }

    func run(sentence: String, lid: [String]) async {
        let voices = AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        line("device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion) model=\(UIDevice.current.model)")
        line("== 1. AVSpeechSynthesisVoice.speechVoices(): \(voices.count)")
        for v in voices { line("voice\t\(v.language)\t\(v.name)\tquality=\(v.quality.rawValue)\t\(v.identifier)") }
        for (tag, match) in [("ht", { (l: String) in l.hasPrefix("ht") }), ("fr-HT", { $0 == "fr-HT" }), ("fr", { $0.hasPrefix("fr") })] {
            let hits = voices.filter { match($0.language) }
            line("match \(tag): \(hits.count) \(hits.map { "\($0.language)/\($0.name)" }.joined(separator: ", "))")
            json["voices_\(tag)"] = hits.map { ["language": $0.language, "name": $0.name, "identifier": $0.identifier] }
        }
        for tag in ["ht", "ht-HT", "fr-HT"] {
            let v = AVSpeechSynthesisVoice(language: tag)
            line("AVSpeechSynthesisVoice(language: \"\(tag)\") = \(v.map { "\($0.language)/\($0.name)" } ?? "nil")")
            json["voice_for_\(tag)"] = v?.identifier ?? NSNull()
        }
        line("AVSpeechSynthesisVoice.currentLanguageCode() = \(AVSpeechSynthesisVoice.currentLanguageCode())")
        json["voice_count"] = voices.count

        line("== 2. SFSpeechRecognizer.supportedLocales()")
        let sf = SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
        let sfHT = sf.filter { $0.lowercased().hasPrefix("ht") }
        line("supported: \(sf.count); ht*: \(sfHT.isEmpty ? "none" : sfHT.joined(separator: ", "))")
        for id in ["es-US", "en-US", "fr-FR"] {
            line("onDevice \(id): \(SFSpeechRecognizer(locale: Locale(identifier: id))?.supportsOnDeviceRecognition.description ?? "no recognizer")")
        }
        json["sf_supported_ht"] = sfHT
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let st = await SpeechTranscriber.supportedLocales.map(\.identifier).sorted()
            let inst = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
            let dt = await DictationTranscriber.supportedLocales.map(\.identifier).sorted()
            line("SpeechTranscriber supported ht*: \(st.filter { $0.hasPrefix("ht") }) of \(st.count); installed ht*: \(inst.filter { $0.hasPrefix("ht") })")
            line("DictationTranscriber supported ht*: \(dt.filter { $0.hasPrefix("ht") }) of \(dt.count)")
            json["speech_transcriber_ht"] = st.filter { $0.hasPrefix("ht") }
        } else {
            line("SpeechTranscriber: needs iOS 26")
        }
        #endif

        line("== 3. NLLanguageRecognizer")
        let ht = NLLanguage(rawValue: "ht")
        var htCount = 0, frCount = 0
        for s in lid {
            let r = NLLanguageRecognizer()
            r.processString(s)
            let top = r.languageHypotheses(withMaximum: 5).sorted { $0.value > $1.value }
                .map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))" }.joined(separator: " ")
            let dom = r.dominantLanguage?.rawValue ?? "nil"
            if dom == "ht" { htCount += 1 }
            if dom == "fr" { frCount += 1 }
            let c = NLLanguageRecognizer()
            c.languageConstraints = [.spanish, .english]
            c.processString(s)
            line("lid dominant=\(dom) [\(top)] constrained(es,en)=\(c.dominantLanguage?.rawValue ?? "nil") :: \(s)")
        }
        let only = NLLanguageRecognizer()
        only.languageConstraints = [ht]
        only.processString(sentence)
        let offersHT = only.dominantLanguage == ht
        line("offers ht (constrained to [ht] returns ht): \(offersHT); dominant ht \(htCount)/\(lid.count), fr \(frCount)/\(lid.count)")
        json["nl_offers_ht"] = offersHT
        json["nl_dominant_ht"] = htCount
        json["nl_dominant_fr"] = frCount

        line("== 4. Speak one ht-tagged utterance (voice = AVSpeechSynthesisVoice(language: \"ht\"))")
        synthesizer.delegate = observer
        observer.onStart = { [weak self] id in
            Task { @MainActor in self?.resume(id) }
        }
        let u = AVSpeechUtterance(string: sentence)
        u.voice = AVSpeechSynthesisVoice(language: "ht")
        let requested = u.voice?.identifier ?? "nil (system default voice)"
        let used = await withCheckedContinuation { (k: CheckedContinuation<String, Never>) in
            started = k
            synthesizer.speak(u)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                self?.resume("no didStart within 5 s")
            }
        }
        line("requested voice: \(requested); voice at didStart: \(used); system default language: \(AVSpeechSynthesisVoice.currentLanguageCode())")
        line("interpretation: nil voice means iOS reads the text with the default voice for \(AVSpeechSynthesisVoice.currentLanguageCode()); listen to the device for French-vs-English phonetics (simctl recordings have no audio).")
        json["tts_requested_voice"] = requested
        json["tts_voice_at_start"] = used
        json["tts_system_default_language"] = AVSpeechSynthesisVoice.currentLanguageCode()
        // VoiceOver-style: the same string as a language-tagged announcement (heard only with VoiceOver on).
        UIAccessibility.post(notification: .announcement,
                             argument: NSAttributedString(string: sentence, attributes: [.accessibilitySpeechLanguage: "ht"]))
        try? await Task.sleep(for: .seconds(4))
        write()
        status = "done"
        line("done")
    }

    private func write() {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? report.write(to: docs.appendingPathComponent("creole_probe.txt"), atomically: true, encoding: .utf8)
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent("creole_probe.json"))
        }
    }

    private func resume(_ id: String) {
        started?.resume(returning: id)
        started = nil
    }
}

/// Reports the voice on the utterance when speech actually starts.
final class SpeechStartObserver: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    var onStart: (@Sendable (String) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        onStart?(utterance.voice.map { "\($0.language)/\($0.name)/\($0.identifier)" } ?? "nil")
    }
}
#endif
