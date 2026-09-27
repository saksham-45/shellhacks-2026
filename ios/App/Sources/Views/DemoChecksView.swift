import SwiftUI
import ADCityPack

/// Plain list of the three demo beats. No new visual system: a section per beat, the shipped lines as text.
struct DemoChecksView: View {
    @State private var beats: [DemoBeat] = []
    @State private var failed = false

    var body: some View {
        List {
            if failed {
                Text(verbatim: "Couldn't load the demo checks.")
            }
            ForEach(beats, id: \.id) { beat in
                Section(beat.id) {
                    ForEach(Array(beat.lines.enumerated()), id: \.offset) { _, line in
                        Text(verbatim: line)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                }
            }
        }
        .navigationTitle("Demo checks")
        .accessibilityIdentifier("demo.checks")
        .task { load() }
    }

    private func load() {
        do {
            beats = try DemoChecks.scripted(language: .en, strings: BundleCheckStrings())
        } catch {
            failed = true
        }
    }
}
