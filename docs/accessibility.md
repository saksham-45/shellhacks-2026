# myAmericanDream: accessibility foundation

Status: draft v0.7 (2026-09-25, LANG-03 part 3 and M12 synced with ADVoice's focus grace window and exact-command contract; v0.6 added the playback-stop, screen-reader-gate and Creole command-only device checks, M11–M12; v0.5 synced with myAD Language's ADVoice/ADLocale fixes: Creole notice order, Kreyòl playback notices, per-segment speech refusal, mic input labels; v0.4 retired `a11y.card.playInKreyol` for ADVoice's `kreyol.play`), myAD Access. Paths are relative to the project root.
Ownership: myAD Access owns this standard and the code of `ios/Packages/ADAccessibility` (handed over by
Lead on 2026-09-25); myAD Lead reviews every change to it. The package links to the app target
`MyAmericanDream` and the UI test target `MyAmericanDreamUITests`. `tools/` (including the CI string-parity
check) stays Lead's.
Scope: the basic test UI now, and every UI that replaces it later. Visual design comes later; these rules
cover the parts that are hard to retrofit: semantics, language tagging, layout that grows, speech, input
paths, and the identifier contract.

**Who we build for.** People in their first years in the US. Many read little or no English, some read
little at all, some are blind or low-vision, many are elderly, some are in crisis (just arrived, no bed,
an eviction notice). Surfaces: Español, English, Kreyòl (equal), plus a "language I think in" for spoken
explanations. Voice in and out follow the sentence spoken.

**Bar.** WCAG 2.2 AA and the Apple HIG are the floor (MUST). Where AAA is cheap to build in now, it is a
SHOULD: 7:1 body contrast, no time limits, plain-language reading level, 44x44 pt targets (AAA 2.5.5
level; HIG default). Assistive Access, elderly, and crisis users are named requirements.

**Rule format.** `ID · MUST|SHOULD · rule` / Why / Verify / Pattern. "Auto" names a test in
`ios/Tests/Accessibility/` (`AccessibilityAuditTests.swift`, `VoiceFirstFlowTests.swift`; Xcode-only), in
`ios/Packages/ADAccessibility` (runs on Linux), or Lead's `tools/check_string_parity.py` in `tools/ci.sh`.
"Manual" is a check listed in §11.

**Shared types used in patterns.** Real names from ADCore's `Sources/ADCore/Shared/` (the contract,
ARCHITECTURE §12) and ADRouter (ARCHITECTURE §13):
- `Fact`: `id: FactID`, `displayValue: FactValue?` (nil for an unsourced fact; the stored `value` is internal
  by design, so views and speech use `displayValue` only), `source: Source?` (`publisher`, `url`),
  `quote: String?`, `quoteLanguage: Locale.Language?` (optional), `retrievedAt: Date?`, `status: FactStatus`.
- `FactValue`: `.text(String, language:)`, `.code(String)`, `.codes([String])` (read as-is), `.phone(digits:)`,
  `.date(Date)`, `.money(amount: Decimal, currency:)`, `.quantity(Decimal, unit:)`, `.weekdays(Set<Weekday>)`,
  `.place(Place)`, `.flag(Bool)` (`displayKey` gives the yes/no key).
- `FactStatus`: `.verified`, `.stale`, `.unsourced`, `.demo`; `labelKey` ("Demo", "May be out of date", "No source").
- `FactLine` (one row on a card, from `card.factLines(using:asOf:)`): `.shown(Fact, status:)`,
  `.notApplicable(FactID, reason: StringKey, deferTo: FactRef?)`, `.handedToDesk(FactID, desk: DeskID)`,
  `.sourceUnavailable(FactID, desk: DeskID)`. `FactRef` is a ledger fact in another region pack, not a desk.
- `SourceLine` (bottom of the card, `card.sourceLine(using:asOf:)`): `.sourced([Source], lastChecked:)` or
  `.noSource(desk:)`. `SpeakableParts` (`card.speakableParts(using:asOf:)`): `titleKey`, `keyFact: FactLine?`,
  `verbatimCodes`, `sourcePublisher`, `retrievedAt`, `desk`.
- `StringKey { key, table }`, resolved by ADLocale: `key.resolve(in: bundle, surface: surface)`. Below,
  `loc.string(key)` is shorthand for that call; `loc.display(_:)` / `loc.spoken(_:)` stand in for ADLocale's
  value formatting (names pending myAD Language). Keys such as `.card_readAloud` are illustrative constants.
- Router (ADRouter, owner Lead): `router.perform(_ action: AppAction, from: ActionSource)`; `Destination`,
  `AppAction` (`.readAloud(.card(id))`, `.callDesk(desk)`, `.openMap(desk)`, `.setSurfaceLanguage(_)`,
  `.choose(optionID)`, `.confirm(Bool)`, …), `Router.pendingClarification` / `pendingConfirmation`,
  `IntentResolution` (≥ 0.75 performs; 0.40–0.75 asks one clarifying question with 2–3 options; < 0.40
  offers the closest desk).
- `FactSlot` (ADAccessibility): what a fact row's source slot says, derived from `FactLine` (A11Y-FACT-02).

---

## 1. VoiceOver: labels, hints, traits, order

**A11Y-VO-01 · MUST · Every meaningful element is reachable by VoiceOver; decoration is hidden.**
Why: blind users only get what the accessibility tree exposes. Verify: Auto, audit `.elementDetection`,
`.sufficientElementDescription` in `test_audit_*`; Manual M1.
```swift
Image(systemName: hero.symbolName).accessibilityHidden(true)   // the adjacent word carries meaning
```

**A11Y-VO-02 · MUST · Every interactive element has a non-empty, localized label that is not its
identifier and not a raw key (dotted or snake_case).**
Why: "a11y.card.readAloud, button" or "card_title" is noise, and a leaked key means a missing translation.
Verify: Auto, `A11yCustomChecks.run` in every `test_audit_*` (uses `A11yLabelLint`, unit-tested on Linux).
```swift
Button { router.perform(.readAloud(.card(card.id)), from: .touch) } label: {
    Label(loc.string(.card_readAloud), systemImage: "speaker.wave.2")
}
    .accessibilityIdentifier(A11yID.Card.readAloud)   // identifier: test-only, never shown or spoken
```

**A11Y-VO-03 · MUST · Labels name the thing, hints say the result, both short; traits carry the role.**
Never put "button" or "tap" in a label. A hint is only there when the result isn't obvious.
Why: VoiceOver adds the role; doubled words slow everyone down. Verify: audit `.trait`; Manual M1.
```swift
.accessibilityHint(loc.string(.card_call_hint))   // e.g. "Calls the school office"
.accessibilityAddTraits(.isHeader)                 // section titles
```

**A11Y-VO-04 · MUST · One fact is one element: value + unit + qualifier + source slot are read together.**
Why: "$0.66" then "with sticker" as two swipes loses meaning. The row is combined, so there is no separate
source element; the source slot (A11Y-FACT-02) is part of the combined label. Actions (call, map) are
separate elements next to the row, never inside it (a combined row would swallow them).
Verify: Auto, `test_cardDetailContract` (each `a11y.card.fact.<id>` label/value contains its slot text);
Manual M1.
```swift
ForEach(card.factLines(using: resolver, asOf: now), id: \.self) { line in
    let slot = FactSlot(line)
    FactRow(line: line, slot: slot)          // value (if shown) + unit + qualifier + slot text
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(A11yID.Card.fact(slot.factID.rawValue))
    if case .shown(let fact, _) = line, case .phone? = fact.displayValue {
        CallButton(fact: fact)               // A11Y-LIT-04: its own element, a11y.card.call
    }
}
```

**A11Y-VO-05 · MUST · Reading order matches meaning: hero, key fact, action, then details. Headings
mark each section; lists have one row per item.**
Why: WCAG 1.3.2, 2.4.3; people jump by heading with the rotor. Verify: Manual M1 (swipe the whole screen).
Use layout order first. Use `accessibilitySortPriority` (higher is read first, default 0, iOS 14+) only when
layout and reading order must differ (e.g. a stacked bilingual hero).
```swift
VStack { heroLabel; heroFact.accessibilitySortPriority(1); otherLanguageLine }
    .accessibilityElement(children: .contain)
```

**A11Y-VO-06 · MUST · State is spoken: selected language, current pin, stage, toggles, "demo data".**
Why: WCAG 4.1.2. Verify: Manual M1.
```swift
.accessibilityAddTraits(isCurrent ? .isSelected : [])
.accessibilityValue(loc.string(stage.labelKey))
```

**A11Y-VO-07 · SHOULD · Long screens offer rotors (facts, desks/phones) instead of 40 swipes.**
Why: fast navigation on card detail. Verify: Manual M1. API: `accessibilityRotor(_:entries:)` (iOS 16+).
```swift
.accessibilityRotor(Text(loc.string(.rotor_phones))) {
    ForEach(phoneFacts) { f in                    // shown facts whose displayValue is .phone
        if let v = f.displayValue { AccessibilityRotorEntry(Text(verbatim: loc.spoken(v)), id: f.id) }
    }
}
```

**A11Y-VO-08 · MUST · Swipe or long-press actions also exist as visible buttons and as
`accessibilityAction(named:)`.** Why: HIG (swipe to delete also needs a button); Switch Control and
Voice Control. Verify: Manual M1, M4. (Router actions without a visible control: A11Y-VC-07.)

## 2. Language: per-string tagging and localized a11y strings

**A11Y-LANG-01 · MUST · Every string VoiceOver or TTS reads is tagged with its language when it differs
from the surface language: fact quotes, official names, the second line of the bilingual hero.**
Why: WCAG 3.1.2; a Spanish voice reading an English quote is unintelligible to both audiences.
Verify: Manual M2 (VoiceOver in each surface language over a mixed card).
Findings, 2026-09-25: SwiftUI has no `.speechLanguage` view modifier. Foundation's
`AttributeScopes.AccessibilityAttributes` has no speech-language member either (it has pitch, SSML,
IPA notation, spell-out, heading level, announcement priority). What is documented: the Foundation
`languageIdentifier` attribute on `AttributedString` (iOS 15+), UIKit's
`NSAttributedString.Key.accessibilitySpeechLanguage` (a BCP 47 code), and `.environment(\.locale, …)`
on a container. One report says the attribute alone did not change VoiceOver in `Text` and
`environment(\.locale)` plus `Text(verbatim:)` did (useyourloaf). So: do both, and check on a device.
```swift
// ADLocale or ADAccessibility (Apple-only): one helper, used everywhere quotes are shown.
func tagged(_ text: String, _ lang: Locale.Language) -> AttributedString {
    var s = AttributedString(text)
    s.languageIdentifier = lang.minimalIdentifier            // "es", "en", "ht"
    return s
}
if let quote = fact.quote {
    // quoteLanguage is optional: when the ledger has none, don't guess; show it untagged (surface language).
    if let lang = fact.quoteLanguage {
        Text(tagged(quote, lang))                           // attributed, NOT a localization key
            .environment(\.locale, Locale(identifier: lang.minimalIdentifier))
    } else {
        Text(verbatim: quote)
    }
}
```

**A11Y-LANG-02 · MUST · Proper names, numbers, phones, and school names are shown as-is; the sentence
around them is localized.** Why: plan ("Claude Pepper does not get translated"). Verify: Manual M2.

**A11Y-LANG-03 · MUST · Creole is never read with a Spanish or English voice by the app.** Scoping below was
**confirmed by the captain via Firstmate on 2026-09-25**: the rule governs the app's own read-aloud, not the
person's own screen reader.
Facts: Apple's iOS/iPadOS 27 feature-availability page (fetched 2026-09-25) lists Haitian Creole only under
"QuickType Keyboard: Language Support". It is absent from "Accessibility: VoiceOver, Live Speech, Read &
Speak", from "Accessibility: Voice Control", and from "Dictation". Spanish (several regions) and English are
listed for VoiceOver; Spanish (United States) is listed for Voice Control. What a device does with
`ht`-tagged text is **unverified** (M3 records `AVSpeechSynthesisVoice.speechVoices()` on device).
Rule, in two scopes:
1. **Speech the app produces** (read-aloud, spoken explanations, spoken confirmations and questions, voice
   replies): MUST NEVER use a non-Creole voice for ht text. Until myAD Language's chosen Creole voice path
   ships (cloud TTS, a bundled model, or recorded audio), ADVoice returns `.unavailable` for ht
   (ARCHITECTURE §13.3) and the app shows the Creole text with a visible, announced Creole notice that audio
   isn't available yet (A11Y-VC-09). No silent fallback, and no fallback "with a warning" either.
2. **VoiceOver** is the person's own system screen reader; the app can't choose its voice. The app MUST tag
   every ht string with its language so VoiceOver can do its best: SwiftUI `AttributedString.languageIdentifier
   = "ht"` plus `.environment(\.locale, Locale(identifier: "ht"))` (A11Y-LANG-01); UIKit `accessibilityLanguage
   = "ht"`; `NSAttributedString.Key.accessibilitySpeechLanguage` = "ht" where attributed strings are used.
   (SwiftUI has no `.speechLanguage` modifier; these are the documented equivalents.) The app MUST state this
   limit plainly, in this document and in the app's Creole notice. **The Creole notice** includes ADVoice's
   `voice.creole.voiceOverLimit` (en "VoiceOver may read Kreyòl with another language's voice. This app's voice
   never does that."). Keys and order come from `VoiceKey.creoleNotice(for:)`: first what is missing, which is
   `voice.unavailable.creole` (`.noVoice`: read-aloud has no Creole voice) **or** `kreyol.noRecording`
   (`.noRecording`: Play in Kreyòl has no reviewed recording for this card), then `voice.creole.voiceOverLimit`.
   One visible notice, one announcement, all in the surface language (es/en/ht values in ADVoice.xcstrings; ht
   `needs_review`). The app MUST NEVER
   hide Creole text from VoiceOver (no `accessibilityHidden`, no empty label, no swapping in another language)
   to avoid that voice.
3. **Play in Kreyòl.** Every card shown in Kreyòl MUST offer a VoiceOver custom action labelled "Jwe an
   Kreyòl" (English surface: "Play in Kreyòl"; Spanish surface: "Escuchar en Kreyòl") that plays myAD
   Language's reviewed, pre-recorded Creole audio for that card, so VoiceOver users can hear real Creole.
   Magic Tap does the same while VoiceOver focus is on that card (A11Y-VC-04 explains how the two share the
   gesture). Rules: only reviewed clips play (never live synthesis in another voice); the action and label
   are always present on a ht card, and when no clip exists for it the action says so out loud and on screen
   with the Creole notice instead of failing silently; playback ducks VoiceOver and stops on the next
   gesture, Magic Tap, or screen change; it respects the think-in language only for explanations
   (A11Y-LANG-04). Hook: ADVoice owns playback (shipped): `KreyolAudio.playKreyol(parts:) async ->
   KreyolPlayback` plays only reviewed, hash-matched clips and returns `.played`, `.partial(played:missing:)`,
   `.noClip(notice:)`, `.stopped`, or `.failed(played:missing:)`; `stop()` ends it. Stops: `PlaybackStopper`
   (ADVoice) stops `KreyolAudio` and `VoiceSpeaker` on a VoiceOver focus change (`VoiceOverFocusStopObserver`),
   the screen disappearing, and the scene leaving the foreground (`.stopsPlaybackOnScreenChange(_:)`, on the
   screen's root view, never on a row inside a lazy list); Magic Tap is the app's call (on the card that is
   playing, it stops). The focus stop MUST NOT fire for Switch Control focus or for the focus change caused by
   the activation itself: call `stopper.playbackWillStart(origin:)` when Play or Read is tapped and register the
   stopper with `setStartListener(_:)` on `KreyolAudio` and `VoiceSpeaker`; VoiceOver focus is then ignored until
   0.5 s after the first clip or segment starts, and on the originating element (device check M11 (a), (d)).
   `KreyolAudio(gate: VoiceOverGate())` waits for VoiceOver to finish (at most 1.5 s) before the first clip. Every result except `.played`
   and `.stopped` has a `notice` that the app MUST show and announce: `.partial` gives `kreyol.restOnScreen`,
   `.noClip` its own notice (`kreyol.noRecording`, as part of the Creole notice), `.failed` gives
   `kreyol.couldNotPlay`. The action is a router `AppAction` (to add, Lead) so voice
   ("jwe l", "play it") reaches the same path. **Action label key: ADVoice `kreyol.play`** (`VoiceKey.kreyolPlay`,
   table "ADVoice"; en "Play in Kreyòl", es "Escuchar en Kreyòl", ht "Jwe an Kreyòl"), the single key agreed with
   myAD Language on 2026-09-25. ADAccessibility's `a11y.card.playInKreyol` is **retired** (removed from
   ADAccessibility.xcstrings and `A11yStrings`). The Magic Tap hint stays in ADAccessibility
   (`a11y.card.playInKreyol.hint`, `A11yStrings.playInKreyolHint`) because ADVoice has no equivalent key.
   Owners: myAD Language (clips, ADVoice and the `kreyol.play` wording), myAD Lead (router action), myAD Access
   (hint, test ids, audits).
```swift
// On each ht card (SwiftUI). Label: ADVoice `kreyol.play`; hint: ADAccessibility `a11y.card.playInKreyol.hint`
// (register ADAccessibility's table with the app's CatalogRegistry to resolve it in the surface language:
// `CatalogRegistration(table: A11yStrings.table, bundle: A11yStrings.bundle)`). es/ht wording pending myAD Language review.
.accessibilityAction(named: Text(loc.string(VoiceKey.kreyolPlay))) { router.perform(.playCreoleAudio(card.id)) }
.accessibilityHint(Text(loc.string(StringKey(key: A11yStrings.playInKreyolHint, table: A11yStrings.table))))
.accessibilityAction(.magicTap) { router.perform(.playCreoleAudio(card.id)) }
```
Verify: Manual M3 (app speech in ht never uses es/en voices; notice shown and announced), M2 (VoiceOver
over ht-tagged text: record what happens; Creole text is never hidden), M11 (Play in Kreyòl on every ht
card); Auto (partial), `test_creoleCardsOfferPlayInKreyol`: the ADVoice `kreyol.play` name in es/en/ht (read from
ADVoice.xcstrings when the runner sees the source tree, else a mirrored table; the two must agree), and every ht
card row plus one card detail exposed in Creole. XCUITest can't list or perform custom actions (§11), so the
test then skips and attaches the M11 checklist; the action's presence, playback, and notice are M11.

**A11Y-LANG-04 · MUST · Speech follows the sentence: output language = language of the last spoken input
(or the card's surface language); explanations may use the think-in language; controls and labels stay in
the surface language.** Why: plan. Verify: Manual M3.

**A11Y-L10N-01 · MUST · Accessibility labels, hints, values, Voice Control input labels, and
announcements are strings like any other: StringKeys with es/en/ht in the package catalogs.**
Verify: Auto, Lead's `tools/check_string_parity.py` in `tools/ci.sh` (every `.xcstrings` key has es, en, ht).
`tools/` is Lead's. myAD Language is drafting stronger rules for it (placeholders, empty values,
`needs_review`) as a proposal to Lead; Access has asked that they also cover a11y labels, hints, and Voice
Control phrases, and fail when a key is used as the English text (a semantic key such as
`card.readAloud` with no English value ships the key itself). This doc does
not duplicate that check. (`xcstrings-parity` in ADAccessibility is a reference checker only, NOTES.md.)

**A11Y-L10N-02 · MUST · No raw keys and no silent fallback to another language on screen or in speech.**
Verify: Auto, `test_surfaceLanguageChangesVisibleLabels`, plus label lint in `test_audit_*`.
**English fallback rule.** The only fallback is English, and it is never silent. When a key has no es or ht value,
ADLocale shows the English value **tagged `en`, never the surface language** (`ResolvedText.isFallback`), and it
carries ADLocale's `fallback.englishBadge` (visible, in the surface language: "(en inglés)", "(an angle)") plus
`fallback.englishHint` ("This text is not translated yet.") as its VoiceOver hint (`LocalizedTextView`). Speech:
ADVoice's `SpokenText.containsFallback` marks it, and `VoiceSpeaker` refuses to read the fallback segments aloud
(each comes back `.unavailable`, reason `.untranslatedFallback`, notice `fallback.englishHint`) and reads the rest
of the text, unless the person chooses Listen in English (`voice.listen_in.en`, then `allowEnglishFallback: true`).
A missing key (`⟦table:key⟧`, `SpokenText.containsMissing`) is never read aloud, not even after Listen in English:
that segment comes back `.unavailable`, reason `.missingText`, notice `voice.unavailable.missing_text`. Always pass
the surface as `language:` to `speak`. Show and announce the notice in the surface language. Verify: ADLocale and ADVoice unit
tests (Language); Manual M2, M3.

**A11Y-L10N-03 · MUST · Placeholders match across languages (count, type, and position).**
Verify: Auto **pending the shared `check_string_parity` rules (Language proposal to Lead)**. Meanwhile:
Manual, review every changed key with a placeholder in es/en/ht (the `xcstrings-parity` reference checker,
`StringCatalogParity`, Linux-tested, can be run by hand to help).

## 3. Dynamic Type through AX5, no truncation

**A11Y-DT-01 · MUST · All text uses text styles (`.body`, `.headline`, …) or `@ScaledMetric`; nothing is
a fixed point size.** Verify: Auto, audit `.dynamicType` at default and AX5.

**A11Y-DT-02 · MUST · No truncation or clipping at any size: no `lineLimit(1…n)` caps on content, no
fixed heights on text containers, no `minimumScaleFactor` on content, wrap instead.**
Why: HIG asks for text enlargement of at least 200%; truncated facts are wrong facts.
Verify: Auto, audit `.textClipped` in `test_audit_*_AX5` (every screen, paged by scrolling).
```swift
Text(value).fixedSize(horizontal: false, vertical: true)  // grow vertically; never .frame(height: 44)
    .frame(minHeight: 44)                                  // minimums are fine, fixed heights are not
```

**A11Y-DT-03 · MUST · At accessibility sizes, horizontal rows become vertical stacks; icons sit above or
beside text without squeezing it.** Verify: `test_audit_*_AX5` plus Manual M5 (screenshots in report).
```swift
@Environment(\.dynamicTypeSize) private var size
var body: some View {
    let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading))
                                          : AnyLayout(HStackLayout())
    layout { icon; label; Spacer(minLength: 0); value }
}
```

**A11Y-DT-04 · MUST · Every screen scrolls vertically; nothing needs two-direction scrolling.**
Why: WCAG 1.4.10. Verify: Manual M5.

**A11Y-DT-05 · SHOULD · Bars and toolbars that can't grow support the Large Content Viewer.**
`accessibilityShowsLargeContentViewer()` (iOS 15+). Verify: Manual M5.

## 4. Display settings and motion

| ID | Level | Rule | Pattern | Verify |
|---|---|---|---|---|
| A11Y-DISP-01 | MUST | Bold Text: use system fonts/text styles so weight follows the setting; custom fonts check `legibilityWeight`. | `@Environment(\.legibilityWeight)` | M6 |
| A11Y-DISP-02 | MUST | Reduce Motion: no parallax, zoom, spin, or slide; use fades or instant changes. The future outline-draw splash and rising card get a static version. | `@Environment(\.accessibilityReduceMotion)`; `withAnimation(reduce ? nil : .default)` | M6 |
| A11Y-DISP-03 | MUST | Reduce Transparency: every material or blur behind text becomes opaque. | `@Environment(\.accessibilityReduceTransparency)` | M6 |
| A11Y-DISP-04 | MUST | Increase Contrast: custom colors ship a high-contrast variant (asset catalog "High Contrast" appearance). | `@Environment(\.colorSchemeContrast)` | M6 |
| A11Y-DISP-05 | MUST | Differentiate Without Color: state is never color alone (stale fact, demo data, error, selected pin). Pair with an icon and a word. | `@Environment(\.accessibilityDifferentiateWithoutColor)` | M6 + audit |
| A11Y-DISP-06 | MUST | Smart Invert: photos, maps, and outline art don't invert. | `.accessibilityIgnoresInvertColors()` | M6 |
| A11Y-DISP-07 | MUST | Nothing flashes more than 3 times per second; no autoplaying motion over 5 s without pause. | (WCAG 2.3.1, 2.2.2) | M6 |
| A11Y-DISP-08 | MUST | Light and dark both pass §5 contrast. | asset catalog variants | audit `.contrast`, M6 |

## 5. Contrast, color, and targets

**A11Y-CON-01 · MUST · Text contrast ≥ 4.5:1, or ≥ 3:1 for WCAG large text, in light, dark, and
Increase Contrast.** WCAG large text is ≥ 18 pt regular or ≥ 14 pt bold, in CSS points (1 pt = 4/3 px);
with 1 iOS pt ≈ 1 CSS px that is **≈ 24 iOS pt regular or ≈ 18.67 iOS pt bold** (bold or heavier; semibold
is not bold). We follow WCAG, not the HIG's looser table (18 pt, or any bold): 17 pt semibold Headline and
20 pt Title 3 are body text here. Why: WCAG 1.4.3. Verify: audit `.contrast`; palette check with
`WCAGContrast.meetsAA(_:on:points:isBold:)` / `WCAGContrast.TextSize(points:isBold:)` (Linux-tested).
**A11Y-CON-02 · SHOULD · Body text ≥ 7:1, large text (as in CON-01) ≥ 4.5:1 (WCAG 1.4.6 AAA).** Cheap now because the
palette doesn't exist yet. Verify: `WCAGContrast.meetsAAA` over every palette pair once design lands.
**A11Y-CON-03 · MUST · Icons, control borders, focus rings ≥ 3:1 against neighbors (1.4.11).**
Verify: `WCAGContrast.meetsNonText`; Manual M6.
**A11Y-CON-04 · MUST · Measure translucent text after compositing over its real background.**
`SRGBColor.composited(alpha:over:)`.
```swift
// palette test (Linux): every text/background pair from the design tokens
#expect(WCAGContrast.meetsAAA(SRGBColor(hex: token.text)!, on: SRGBColor(hex: token.surface)!))
```

**A11Y-TGT-01 · MUST · Every tappable target is ≥ 44x44 pt** (HIG default; HIG minimum 28x28 and WCAG
2.5.8 24x24 are not our bar). Verify: Auto, `A11yCustomChecks.run` (frame ≥ 44x44 for every visible
enabled control, except switches, steppers, segmented-control segments, and text fields, whose frames are
not their hit areas) plus audit `.hitRegion` (covers those too).
```swift
Button(action: call) { Label(title, systemImage: "phone") }
    .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
```
**A11Y-TGT-02 · MUST · Adjacent targets have ≥ 8 pt between hit areas; destructive actions are never next
to the primary action.** Verify: Manual M4.
**A11Y-TGT-03 · MUST · No function needs a drag, multi-finger, or path gesture (WCAG 2.5.1, 2.5.7).**
Verify: Manual M4.

## 6. Speech for every card, and facts

**A11Y-SPK-01 · MUST · Every card has a visible "Read this card" button (icon + word) near the top that
reads a transcript of the card: title, key fact, then each fact line with its source slot, then the source
line and the desk.** Why: low-literacy and blind users, and the plan ("the card talks and shows the same
facts"). The transcript is built by ADVoice (myAD Language) from `card.speakableParts(using:asOf:)`
(`titleKey`, `keyFact`, `verbatimCodes`, `sourcePublisher`, `retrievedAt`, `desk`) plus
`card.factLines(using:asOf:)` and `card.sourceLine(using:asOf:)`, with the same resolver and the same
`asOf` date as the screen, so it covers the same facts. Values are spoken by ADLocale; `.code`/`.codes`
are read as-is. Verify: Auto, `test_cardDetailContract` (button exists, labeled) and
`test_voiceOnly_heroCard` (reading starts by voice); Manual M3 (listen in es/en/ht).
```swift
// The view only triggers it; the router hands the card to ADVoice.
Button { router.perform(.readAloud(.card(card.id)), from: .touch) } label: {
    Label(loc.string(.card_readAloud), systemImage: "speaker.wave.2.fill")
}
.accessibilityIdentifier(A11yID.Card.readAloud)
// Transcript shape (es, demo data): "<title>. <key fact value>. Demo. … Fuente: <publisher>.
// Revisado el <date spoken by ADLocale>. Oficina: <desk>."
```
**A11Y-SPK-02 · MUST · The transcript is the same facts as the screen: no extra, no fewer, no
paraphrased numbers.** Verify: ADVoice unit test (Language): the transcript's fact ids equal the ids of
`card.factLines(using:asOf:)` for the same resolver and date, and every slot (FACT-02) is spoken; Manual M3.
**A11Y-SPK-03 · MUST · Reading can be stopped and restarted by button, and it pauses when VoiceOver is
speaking.** No autoplay on open. Verify: Manual M3.
Pattern: check `@Environment(\.accessibilityVoiceOverEnabled)`; when VoiceOver is on, prefer
`AccessibilityNotification.Announcement` (iOS 17+) or let VoiceOver read the combined elements rather
than talking over it.

**A11Y-FACT-01 · MUST · Every fact element shows and speaks its source slot: for a shown fact, the
publisher and the last-checked date; otherwise what happened and who answers.** The slot is part of the
one combined fact element (A11Y-VO-04). Verify: Auto, `test_cardDetailContract` (each
`a11y.card.fact.<id>` label/value contains its slot lead-in in the surface language); Manual M1.
**A11Y-FACT-02 · MUST · Every `FactLine` case is labeled and spoken clearly, not only `.shown`.**
`FactSlot(line)` (ADAccessibility, Linux-tested) gives the parts; ADLocale renders them:

| `FactLine` | Value | Source slot says (keys from ADCore's table) |
|---|---|---|
| `.shown(f, status: .verified)` | `f.displayValue` | "Source: <publisher>. Checked <date>." (`source_line.sourced`, `f.source?.publisher`, `f.retrievedAt`) |
| `.shown(f, status: .stale)` | `f.displayValue` | "May be out of date." (`fact.status.stale`) then the verified line |
| `.shown(f, status: .demo)` | `f.displayValue` | "Demo" (`fact.status.demo`); publisher/date only if the fact has them, never invented |
| `.notApplicable(id, reason:, deferTo:)` | none | the reason (content key). `deferTo` is an optional ledger fact in another pack (e.g. the City of Miami's trash day): offer to show it; it is not a desk |
| `.handedToDesk(id, desk:)` | none | "No source" (`fact.status.unsourced`) and the desk, with its call action |
| `.sourceUnavailable(id, desk:)` | none | "Couldn't check the source right now" (key requested from Household; not "No source") and the desk |

"Checked <date>" needs a key with a date placeholder; none exists yet (requested from Household, ADCore
table). `.shown` never carries `.unsourced` (ADCore hands those to the desk); `FactSlot` treats it as a
handoff if it ever does.
```swift
switch line {
case let .shown(fact, status):
    if let value = fact.displayValue { ValueText(value) }        // never fact.value (internal)
    SlotText(FactSlot(line))                                      // status word, "Source: X. Checked <date>"
case let .notApplicable(_, reason, deferTo):
    Label(loc.string(reason), systemImage: "info.circle")        // "The city collects trash here"
    if let deferTo { DeferredFactLink(deferTo) }                  // opens that pack's ledger fact
case let .handedToDesk(_, desk):
    Label(loc.string(FactStatus.unsourced.labelKey), systemImage: "questionmark.circle")
    DeskButton(desk)                                              // the desk, with a call action
case let .sourceUnavailable(_, desk):
    Label(loc.string(sourceUnavailableKey), systemImage: "exclamationmark.icloud")  // key pending Household
    DeskButton(desk)
}
```
Why: "no source" or "does not apply" must be as clear to a listener as a value; silence reads like "no".
Verify: Auto for the seed scope (above); Manual M1, M3 on a card with each case (`.notApplicable` and
`.sourceUnavailable` need a Regions fixture).
**A11Y-FACT-03 · MUST · Demo data is labeled in text and in speech ("Demo basket", "Neighbor reports,
not this meter").** Verify: Manual M1.
**A11Y-FACT-04 · MUST · Values are spoken naturally by ADLocale: phones digit by digit, money as money
("1 dólar 32"), quantities with their unit, dates as dates, weekdays as words ("martes y viernes"), places
by name, flags as yes/no, codes as-is.** The view sets the label from ADLocale's spoken form; the visible
text stays as-is. Only `displayValue` is used (nil for unsourced: show the slot, not a value).
```swift
if let value = fact.displayValue {
    Text(verbatim: loc.display(value)).accessibilityLabel(Text(verbatim: loc.spoken(value)))
}
```
Verify: ADLocale unit tests (owned by Language); Manual M2.

## 7. Voice-only use, Voice Control, Switch Control, Full Keyboard Access

**A11Y-VC-01 · MUST · Every control's visible word is its spoken name (WCAG 2.5.3 Label in Name); icon
controls add input labels in the surface language.** Voice Control users say what they see.
Why: Voice Control uses the label. API: `accessibilityInputLabels(_:isEnabled:)` (iOS 18 overload;
original iOS 14), most important first. Verify: Manual M4 (Voice Control "Show names").
```swift
Button { … } label: { Label(loc.string(.household_addPerson), systemImage: "person.badge.plus") }
    .accessibilityInputLabels([Text(loc.string(.household_addPerson)),
                               Text(loc.string(.household_addPerson_alt1))])  // "Add family member"
```
**A11Y-VC-02 · MUST · Input-label phrases exist in es, en, and ht** (L10N-01; Lead's `tools/check_string_parity.py` covers them).
Known limit: Apple lists no Voice Control recognition for Haitian Creole or Dictation in Creole, so a Creole
reader with Voice Control speaks Spanish, English, or French (the device's Voice Control language). ht
phrases still ship for parity and future support. Verify: `tools/check_string_parity.py`; Manual M4.
**A11Y-VC-03 · MUST · The whole app works by voice alone (captain's voice-first order, ARCHITECTURE §13):
every screen, card, and action is an `AppAction` through `router.perform(_:from:)`, reachable by the in-app
mic in es/en/ht (ht recognition follows myAD Language's chosen path) and by Voice Control; nothing is
touch-only.** A "Type instead" button always sits next to
the mic (speech disabilities, noisy places). Verify: Auto, four no-touch flows in `VoiceFirstFlowTests`
(voice script replayed by the app's voice stub, §9; after launch no taps, typing, or swipes): onboarding
(`onboarding_es`: the four questions, never a status question), hero card (`hero_card_en`: open it and
hear it read), desk handoff (`desk_handoff_es`: leaving needs a yes, "no" cancels), language switch
(`switch_language_ht`: "Kreyòl", then "en español"). A missing stub or script fails; each skips with a clear
message only while the test plan sets `MYAD_VOICE_STUB_PENDING=1`. Real Voice Control stays Manual M4; the
other voice rules are Manual M10.

**A11Y-VC-04 · MUST · VoiceOver Magic Tap (two-finger double-tap) starts and stops listening on every
screen, except while VoiceOver focus is on a Kreyòl card, where it plays that card's Creole audio
(A11Y-LANG-03 part 3).** iOS sends Magic Tap to the focused element first, then up to the screen, so the
card's handler wins only while the card is focused; move focus off it (or use the mic button, A11Y-VC-05)
to listen. The card's announced hint (ADAccessibility `a11y.card.playInKreyol.hint`) says "Two-finger double-tap
to play in Kreyòl" so the difference is never a surprise. The custom action's label key is ADVoice `kreyol.play`;
`a11y.card.playInKreyol` is retired. Why: blind users need the mic without hunting for it. Verify: Manual M10, M11 (XCUITest
can't synthesize Magic Tap, §11). Put the screen handler on a root that also covers the toolbar mic and the
router prompts, not only the screen's `List`/`Form`.
```swift
// Root container of every screen (SwiftUI). UIKit equivalent: accessibilityPerformMagicTap().
.accessibilityAction(.magicTap) { voice.isListening ? voice.stopListening() : voice.startListening() }
```
**A11Y-VC-05 · MUST · The mic button is on every screen with the same identifier (`a11y.voice.mic`), a
localized label, and `accessibilityInputLabels` in es/en/ht.** Input labels come from ADVoice:
`VoiceKey.micInputLabels(surface:)` while idle and `VoiceKey.micStopInputLabels(surface:)` while listening. Each
returns `InputLabel{key, language}`, one phrase per key, and each must be resolved in its own `language`. On the
ht surface, es and en names follow the ht ones (A11Y-VC-02 known limit). The first label matches the visible
label (`mic.label` / `mic.stopLabel`). Verify: Auto, `test_audit_*` (mic present,
label lint-clean, on every screen), `test_surfaceLanguageChangesVisibleLabels` (label differs per surface);
parity check (L10N-01); Manual M4, M10.
```swift
let labels = voice.isListening ? VoiceKey.micStopInputLabels(surface: surface) : VoiceKey.micInputLabels(surface: surface)
Button { voice.toggleListening() } label: {
    Label(loc.string(voice.isListening ? VoiceKey.micStopLabel : VoiceKey.micLabel), systemImage: "mic.fill")
}
    .accessibilityInputLabels(labels.map { Text(localizer.text($0.key, in: $0.language).plain) })  // ADLocale Localizer
    .accessibilityIdentifier(A11yID.Voice.mic)
```
**A11Y-VC-06 · MUST · Router clarifications (`Clarification`, 2 or 3 options) and leave-app confirmations
(`callDesk`, `openMap`: `Router.pendingConfirmation`) are spoken, move VoiceOver focus to the question, can
be answered by voice (yes/no, "the second one", or the option's label) or by buttons ≥ 44x44 pt, and never
time out.** Leaving the app always needs a yes, whatever the source. Verify: Auto,
`test_voiceOnly_deskHandoff` (confirmation before handoff; "no" cancels; yes/no buttons ≥ 44 pt; still
open after 10 s); Manual M10 (focus lands on the question).
```swift
@AccessibilityFocusState private var questionFocused: Bool
Text(loc.string(clarification.question)).accessibilityAddTraits(.isHeader)
    .accessibilityFocused($questionFocused)
    .accessibilityIdentifier(A11yID.Router.clarify)
    .onAppear { questionFocused = true }                 // no timer, no auto-dismiss
ForEach(Array(clarification.options.enumerated()), id: \.element.id) { i, option in
    Button(loc.string(option.label)) { router.perform(.choose(option.id), from: .touch) }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityIdentifier(A11yID.Router.clarifyOption(i + 1))
}
```
**A11Y-VC-07 · MUST · Every router `AppAction` a screen supports is also a VoiceOver custom action where it
isn't already a visible control** (e.g. repeat last, next/previous step, read this screen).
Verify: Manual M10 (rotor "Actions" on each screen lists them).
```swift
.accessibilityAction(named: Text(loc.string(.action_repeatLast))) { router.perform(.repeatLast, from: .voiceOver) }
```
**A11Y-VC-08 · MUST · Navigation by voice announces the new screen in the surface language.** Post a
screen-changed notification with the screen's title after the router changes `path`, so VoiceOver users
know where they are. Verify: Manual M10.
```swift
AccessibilityNotification.ScreenChanged(loc.string(destinationTitleKey)).post()
```
**A11Y-VC-09 · MUST · When speech is unavailable (e.g. no Creole voice: ADVoice returns `.unavailable`),
the text stays on screen with a visible and announced notice (`a11y.voice.unavailableNotice`) in the
surface language.** For ht that notice is the Creole notice of A11Y-LANG-03 part 2. Never read it with another
language's voice (A11Y-LANG-03). Verify: Manual M3, M10;
`test_voiceOnly_heroCard` asserts the notice does not appear for English.

**A11Y-KB-01 · MUST · Full Keyboard Access and Switch Control reach every control in reading order, with
no traps; custom controls are Buttons, not tap gestures on shapes.** Why: HIG mobility guidance;
WCAG 2.1.1, 2.1.2. Verify: Manual M4 (hardware keyboard + Switch Control item-scan).
```swift
Button(action: open) { CardRow(card) }   // not: CardRow(card).onTapGesture(open)
    .buttonStyle(.plain)
```
**A11Y-KB-02 · MUST · Focus is never hidden behind sticky bars, sheets, or the keyboard (WCAG 2.4.11).**
Verify: Auto, the navigator fails when a target exists but isn't hittable; Manual M4.
**A11Y-KB-03 · SHOULD · Keep scan groups short for Switch Control: group each row's parts.**
`.accessibilityElement(children: .combine)`; check `@Environment(\.accessibilitySwitchControlEnabled)`
only to simplify, never to hide features.

## 8. Low literacy, cognitive load, crisis, errors, privacy

**A11Y-LIT-01 · MUST · One action per row; icon plus word; never an icon-only control.** The word is in
the surface language; the icon is decoration (hidden) or reinforcement. Verify: Auto (label lint catches
empty labels); Manual M7.
**A11Y-LIT-02 · MUST · Plain language: short sentences, common words, one idea per line, the action verb
first. SHOULD: lower-secondary reading level (WCAG 3.1.5 AAA) in all three languages; jargon (I-94, SEVIS,
ITIN, folio) is defined on first use.** Verify: Content review (myAD Content); Manual M7.
**A11Y-LIT-03 · MUST · Numbers are digits, not words, on screen; dates are words ("miércoles 30 de
septiembre"), never "9/30".** Verify: Manual M7.
**A11Y-LIT-04 · MUST · Every phone number is a call action (button with a phone icon and the word
"Call" plus the number) that goes through the router (`.callDesk`, confirmed first, A11Y-VC-06) and opens
`tel:` digits; the number is spoken digit by digit.** Verify: Auto, `test_cardDetailContract`
(`a11y.card.call` exists on the seeded phone card and is a button or link); Manual M7.
No interpolated `LocalizedStringKey`: resolve a StringKey with a placeholder, then use verbatim text.
```swift
if case .phone? = fact.displayValue, let value = fact.displayValue {
    // Catalog key "action.call %@": en "Call %@"; es/ht from myAD Language (placeholder parity, L10N-03).
    let template = loc.string(StringKey(key: "action.call %@", table: "ADAccessibility"))
    let shown = String(format: template, locale: surface.locale, loc.display(value))
    let spoken = String(format: template, locale: surface.locale, loc.spoken(value))
    Button { router.perform(.callDesk(card.desk), from: .touch) } label: {
        Label { Text(verbatim: shown) } icon: { Image(systemName: "phone.fill") }
    }
    .accessibilityLabel(Text(verbatim: spoken))
    .accessibilityIdentifier(A11yID.Card.call)
}
```
**A11Y-LIT-05 · MUST · Stage heroes use their SF Symbol plus label key together; the symbol is never the
only cue.** `Label(loc.string(hero.labelKey), systemImage: hero.symbolName)`.

**A11Y-COG-01 · MUST · No time limits, no auto-dismissing toasts with actions, no session timeouts, no
auto-advancing screens.** (WCAG 2.2.1 Level A; AAA 2.2.3 as our default.) Verify: Manual M7; review
(grep for `Timer`, `asyncAfter`, `.task { try await Task.sleep` driving UI dismissal).
**A11Y-COG-02 · MUST · One primary thing per screen; the hero is one fact and one next step.**
**A11Y-COG-03 · MUST · Destructive actions (remove person, clear data, change pin) ask for confirmation
in plain words and can be undone right after.** (WCAG 3.3.4.) Verify: Manual M7.
```swift
.confirmationDialog(loc.string(.person_remove_confirm_title), isPresented: $confirm) {
    Button(loc.string(.person_remove_confirm), role: .destructive) { remove(); showUndo = true }
}
```
**A11Y-COG-04 · MUST · Never ask for the same thing twice in one flow (WCAG 3.3.7); prefill from the
household.** **A11Y-COG-05 · MUST · No login, password, or puzzle (3.3.8); there is no account.**
**A11Y-COG-06 · MUST · Help sits in the same place on every screen (WCAG 3.2.6): 911, 211, and the desk
button have fixed positions.**
**A11Y-COG-07 · SHOULD · Crisis path: from any screen, one tap reaches "Help this week" (911 for
emergencies, 211, the card's desk) with no detours, no stage questions, and nothing to fill in.**
**A11Y-ASA-01 · SHOULD · Assistive Access: set `UISupportsAssistiveAccess` and add an `AssistiveAccess`
scene (iOS 26+) showing hero, read-aloud, and call-the-desk only; on iOS 18 respect
`@Environment(\.accessibilityAssistiveAccessEnabled)` (iOS 18+) to hide secondary rows.** Without the key,
the system shows the app in a reduced frame. Verify: Manual M8. Decision for Lead (NOTES.md): scene vs
`UISupportsFullScreenInAssistiveAccess`.

**A11Y-ERR-01 · MUST · Errors name the field and the fix in text, next to the field, and are announced.**
(WCAG 3.3.1, 3.3.3, 4.1.3.) Verify: Manual M7; `a11y.addPerson.error` exists after an empty save.
```swift
.onChange(of: error) { _, e in
    if let e { AccessibilityNotification.Announcement(loc.string(e.messageKey)).post() }
}
```
**A11Y-ERR-02 · MUST · Status changes (pin moved, language switched, card refreshed, reading started)
are announced once, briefly, in the new surface language.**

**A11Y-PRIV-01 · MUST · Labels, hints, transcripts, and announcements for one person never include
another person's papers, status word, or documents.** A child's card may speak the shared address, not a
parent's immigration file. Why: product rule; speech is overheard. Verify: ADCore privacy-scope test
feeds the transcript builder; Manual M9 (read each person's cards with VoiceOver).
**A11Y-PRIV-02 · MUST · Status words and document names aren't announced unprompted (no automatic
announcements of papers); they're read only when the user focuses or asks for that card.**
**A11Y-PRIV-03 · MUST · Tourist mode speaks no immigration content.** Verify: Manual M9.

---

## 9. accessibilityIdentifier contract (test UI)

Source of truth: `ios/Packages/ADAccessibility/Sources/ADAccessibility/A11yID.swift` (the app and UI
tests both import it). Format `a11y.<screen>.<element>`, stable across languages, every segment starts with
a letter. Dynamic rows append a stable model id, never a name or index. Identifiers are never labels
(A11Y-VO-02). **Anchor** = the element the navigator waits for and pages by scrolling (put it on the
screen's `List`/`Form`/`ScrollView`). `ADAccessibility.identifier(forCard:)` returns
`A11yID.Cards.row(id.rawValue)`: one scheme.

| Screen | Anchor | Elements |
|---|---|---|
| Every screen | (none) | `a11y.voice.mic` (the mic, A11Y-VC-05) |
| Household (root) | `a11y.household.list` | `a11y.household.addPerson`, `.settings`, `.pin`, `.cards`, rows `a11y.household.row.<personID>` |
| Onboarding | `a11y.onboarding.form` | `.question`, `.next`, `.back`, `.skip`; current step container `a11y.onboarding.step.pin`, `.step.people`, `.step.originAndLanguage`, `.step.goal` (ADCore `OnboardingStep`; no other step id may exist, none is about status) |
| Add person | `a11y.addPerson.form` | `.name`, `.stage`, `.origin`, `.language`, `.thinkIn`, `.mode`, `.save`, `.cancel`, `.error` |
| Person detail | `a11y.personDetail.list` | `.name`, `.stage`, `.hero`, `.nextSteps`, `.edit`, `.delete`, `.undo` |
| Settings / language | `a11y.settings.form` | `a11y.settings.language.es`, `.language.en`, `.language.ht`, `.thinkIn`, `.mode`, `.done` |
| Pin switch | `a11y.pin.list` | `a11y.pin.option.kendall`, `a11y.pin.option.downtown`, `a11y.pin.current` |
| Card list | `a11y.cards.list` | rows `a11y.cards.row.<cardID>` |
| Card detail | `a11y.card.list` | `.title`, `.readAloud`, `.stopReading` (exists only while reading), `.desk`, `.call` (separate element, not inside a fact row), facts `a11y.card.fact.<factID>` (one combined element each; its label/value includes the source slot, A11Y-VO-04/FACT-01; there is no `.source` identifier) |
| Desk (`Destination.desk`) | `a11y.desk.panel` | `.call`, `.map` |
| Router prompts (any screen) | (none) | `a11y.router.clarify` (question), `a11y.router.clarify.option1`…`option3`, `a11y.router.confirm` (question), `.confirm.yes`, `.confirm.no`, `a11y.router.handoff` (UI-test mode only) |
| Voice (`Destination.voice`) | `a11y.voice.panel` | `.transcript`, `.answer`, `.stop`, `.typeInstead`, `.unavailableNotice`, `a11y.voice.stub` (UI-test only) |

Navigation the tests assume (change only `A11yNavigator.go(to:)` if Lead's differs): root is household;
add person, settings, pin, cards are one tap from root; the mic opens the voice panel; person detail is the
first household row; card detail is the first card row, or a named row (`goToCard`). The clarify overlay
has no identifier path (it needs an ambiguous request): the audit opens it with `-uiTestScreen clarify`.

**Launch arguments** (UserDefaults argument domain): `-AppleLanguages (xx)`, `-AppleLocale xx_US`,
`-UIPreferredContentSizeCategoryName <category>`, `-myadUITest YES` (in-memory store, no network,
deterministic; leave-app actions are recorded, not opened: after a confirmed `callDesk`/`openMap` the app
shows `a11y.router.handoff` with value `callDesk`/`openMap`), `-myadSeed demoHousehold|none`,
`-myadSurfaceLanguage es|en|ht`, `-myadVoiceStub YES` (no mic/speech permission prompts), and
`-myadVoiceScript <name>` (below). Lead's test-only `-uiTestScreen <name>` (ScreenshotRoute) opens one screen;
the tests use it only for `clarify`.

**Demo seed** (`-myadSeed`, owner Lead; test scope follows it, no invented sources):
- `demoHousehold`: 2 people (student + parent), Kendall pin, all cards. Card **`offices`** (row
  `a11y.cards.row.offices`; id confirmed by Lead as `DemoSeed.officesCard`, set in `A11ySeed.phoneCardID`) must
  have a desk phone fact, so `a11y.card.call` exists on it. Its fact lines come from the offline ledger/fixtures
  only: `.shown` (verified, stale, or `demo`-status, labeled demo) or `.handedToDesk`. The offline seed
  must not produce `.sourceUnavailable`. `test_cardDetailContract` checks each fact element's label/value
  contains one of the ADCore lead-ins (`source_line.sourced`, `fact.status.demo`, `fact.status.stale`,
  `fact.status.unsourced`) in the surface language; `.notApplicable` needs a Regions fixture (Manual M1).
- `none`: fresh install; the app opens on onboarding.

**VoiceScript** (as shipped in the test UI, 2026-09-25). `-myadVoiceStub YES -myadVoiceScript <name>` makes
the app's stub (Lead, `AppModel.runVoiceScript`, started at launch with no tap) replay the named script through
the router instead of the mic. File `ios/App/UITestFixtures/voicescript.<name>.json` (Debug only):
`{"name", "lines": [{"text", "language", "expect"}]}`, one line per utterance with its BCP-47 language and the
identifier that must appear next (e.g. `a11y.router.confirm`). The stub waits up to 10 s for it, pauses about
1 s so observers can see it, then plays the next line. **Pending (v0.4):** myAD Language's
`ios/Packages/ADVoice/Sources/ADVoice/VoiceScript.swift` (files named `<name>.voicescript.json`: `name`, `steps`
with `say`, `language`, optional `confidence`, and `expect` {`command`, `reply_language`, `speech`, `confirm`}) is
the canonical format. The app's placeholder above is expected to switch to it, and the `VoiceFirstFlowTests`
fixtures will move to that shape; until then the tests keep asserting the placeholder format, unchanged. Scripts the tests
use, with the line numbers they assert: `onboarding_es` (6 lines: pin, people "Ana 20, Rosa 58", then origin
and goal for each person, ending on the household), `hero_card_en` (5: person, next step opens the hero
card, "read this", "stop", "go back"), `desk_handoff_es` (7: person, hero card, ask to call → confirmation;
line 4 "no" → nothing leaves; ask again → line 6 "sí" → handoff recorded; line 7 asks a third time and ends
with the confirmation open), `switch_language_ht` (2: "Kreyòl" on the Spanish surface shows the Creole
notice, then "en español"). While a script is requested, the app shows `a11y.voice.stub` whose
value is `loading`, `running <n>/<total>`, `passed`, `failed <n>: <reason>`, or `scriptNotFound`. No
`a11y.voice.stub` ("no stub hook") or `scriptNotFound` ("script not bundled") → the tests fail, or skip while
the test plan sets `MYAD_VOICE_STUB_PENDING=1`. Likewise `test_audit_*`, `test_surfaceLanguageChangesVisibleLabels`, `test_cardDetailContract` and `test_creoleCardsOfferPlayInKreyol` skip when `a11y.household.list` is
missing after launch only while `MYAD_APP_IDS_PENDING=1`; otherwise they fail. Both prerequisites shipped on
2026-09-25 and `ios/Accessibility.xctestplan` sets neither variable: keep them unset.

## 10. Change review checklist (every UI change)

- [ ] New/changed controls: localized label (no "button"), hint only when needed, correct trait, identifier from `A11yID` if the tests use it.
- [ ] Icon + word; no icon-only controls; decorative images `accessibilityHidden(true)`.
- [ ] Each fact is one combined element with its value (`displayValue`, never `value`) and its `FactSlot` text; every `FactLine` case reads clearly; call/map actions are separate elements.
- [ ] Mixed-language text tagged (`tagged(_:_:)` + locale); ht strings tagged "ht"; names and numbers untranslated.
- [ ] App speech never reads ht text with an es/en voice; `.unavailable` shows the Creole notice (visible and announced).
- [ ] English fallback text is tagged `en`, shows `fallback.englishBadge` with `fallback.englishHint`, and is read aloud only after Listen in English.
- [ ] Phones are call actions through the router, confirmed first; strings with values use a placeholder key and verbatim text (no interpolated `LocalizedStringKey`); values spoken via ADLocale.
- [ ] No `lineLimit` caps, fixed text heights, or `minimumScaleFactor` on content; AX layout switch where rows are horizontal.
- [ ] 44x44 targets; no drag-only or gesture-only function; swipe actions duplicated as buttons.
- [ ] Mic (`a11y.voice.mic`) on the screen with label + input labels; Magic Tap toggles listening.
- [ ] Every `AppAction` the screen supports is a visible control or a VoiceOver custom action; nothing bypasses `router.perform`.
- [ ] Clarifications and leave-app confirmations: spoken, focused, answerable by voice and ≥ 44 pt buttons, no timeout.
- [ ] Voice navigation posts a screen-changed announcement in the surface language.
- [ ] Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color, Smart Invert handled for anything custom.
- [ ] Text contrast measured with WCAG large-text sizes (≈ 24 pt regular / ≈ 18.67 pt bold), not the HIG table.
- [ ] No timers that dismiss or advance UI; destructive actions confirm and undo.
- [ ] New strings (including a11y labels, hints, input labels, announcements) have es/en/ht; `tools/check_string_parity.py` passes; placeholders checked by hand until the shared rules land (L10N-03).
- [ ] No other person's papers in labels, transcripts, or announcements.
- [ ] `tools/ci.sh` green (Linux parts); UI audit and voice-flow batch queued for the next Mac run if UI changed.

## 11. Known limits, manual checks, exemptions

**Automation limits.** `performAccessibilityAudit` only sees on-screen elements (WWDC23 10035), so the
tests page each screen by slowly swiping its anchor (up to 12 pages; a screen still changing after that
fails). It can't hear VoiceOver, judge label quality, check language tagging, check order, or toggle
Reduce Motion, Bold Text, Increase Contrast, and so on through launch arguments. The voice-flow tests drive
the router through the app's voice stub, not real speech recognition or Voice Control. XCUITest can't
perform Magic Tap or list or perform VoiceOver custom actions (`XCUIElement` has no such API; Xcode 27's
`XCUIVoiceOverService`, iOS 27+, only turns VoiceOver on and off, moves focus, and returns speech), so Play in
Kreyòl and Magic Tap stay manual (M10, M11). Contrast audits of
translucent or gradient backgrounds can be false positives: exempt only after measuring
(`A11yExemptions.all`, empty today; each entry has a reason, an owner, and an identifier scoped to at least
`a11y.<screen>.`, enforced by `test_exemptionsAreWellFormed`; list them here).

**Manual checks** (on the captain's Mac simulator plus one physical iPhone where noted; record
results in a run log):
- **M1 VoiceOver walk:** every screen in es/en/ht, swipe start to end; order, labels, headings, states, facts read as one element with their source slot; every `FactLine` case.
- **M2 Language:** mixed card (Spanish surface, English quote, Creole quote): each segment switches voice or behaves as documented; record what VoiceOver does with ht-tagged text; names and numbers intact. Hero card on the ht surface (ADLocale `StackedLineView`): each line is read in its own language (`.speechLanguage`), and only the first line is a heading in the rotor (`.isHeader`). *Physical device.*
- **M3 Speech:** "Read this card" in es/en/ht; stop/restart; same facts as screen; ht: the app's own speech never uses an es/en voice and the Creole notice appears and is announced; list `AVSpeechSynthesisVoice.speechVoices()` languages and record whether any `ht` voice exists. *Physical device.*
- **M4 Input:** real Voice Control (show names/numbers, run each flow in es and en), Switch Control item scan, Full Keyboard Access (Tab/arrow, no traps, focus visible, never obscured). The stub-driven voice tests do not replace this.
- **M5 Size:** AX1–AX5 screenshots of every screen in ht (usually longest; the AX5 sweep keeps its screenshots); no truncation; single-direction scroll; Large Content Viewer on bars.
- **M6 Display:** Bold Text, Reduce Motion, Reduce Transparency, Increase Contrast, Differentiate Without Color, Smart Invert, light/dark, Button Shapes.
- **M7 Literacy/cognition:** a non-English reader completes add person, switch language, move pin, open a card, call a desk with no help; no timeouts; confirm + undo.
- **M8 Assistive Access:** app in Assistive Access on device; core path works.
- **M9 Privacy:** two-person household; each person's cards read aloud never mention the other's papers; tourist mode has no immigration speech.
- **M10 Voice-first with VoiceOver:** on every screen, Magic Tap starts and stops listening; the mic's label and input labels in es/en/ht; a clarification (2–3 options) and a leave-app confirmation are spoken, take VoiceOver focus, accept yes/no/ordinal speech and buttons, and never time out; the rotor's Actions list every router action without a visible control; voice navigation announces the new screen; with no Creole voice, the text stays with a visible, announced notice. *Physical device for speech.*
- **M11 Play in Kreyòl:** with VoiceOver on and the Kreyòl surface, every ht card lists "Jwe an Kreyòl" in the rotor's Actions; it plays the reviewed Creole clip; Magic Tap on a focused ht card plays it and Magic Tap elsewhere toggles listening; with no clip the action announces and shows the Creole notice; VoiceOver speech is ducked while a clip plays and comes back after; playback stops on the next gesture or screen change; Creole text is never hidden from VoiceOver. Also record:
  (a) activating "Jwe an Kreyòl" (custom action and Magic Tap) and "Read this card" does not fire a VoiceOver focus change that stops the clip or read it just started; also try it right after the app posts an announcement or while the card's label changes;
  (b) the 1.5 s VoiceOver gate feels right: VoiceOver is not cut off, and there is no long silence before the clip (time it with and without a notice announcement);
  (c) the screen-change stop fires on navigation (push, back, tab change) and when the app goes to the background or Control Center opens, and does not fire when a sheet or an overlay appears over the card (note what a full-screen cover does);
  (d) with Switch Control auto-scanning, a playing clip is not stopped by the scan cursor moving;
  (e) Stop while a clip is still loading (tap Play, then stop at once, several times): nothing plays afterwards (`AVClipPlayer` stop-during-load, not compiled on Linux). *Physical device.*
- **M12 Creole voice fallback (commands only):** ht surface, with no Creole speech engine (today) and again with "Never send my voice or card text to our server" on: saying "en español", "in English", and "atrás" / "back" is heard on the device and acts without a "did you say" step (an exact on-device command is not re-confirmed); "llamar" / "call" still asks the one leave-app confirmation (A11Y-VC-06); any other sentence is not acted on and shows and announces `voice.creole.commandsOnly`, which names the phrases, each read in its own language; nothing goes to the server (proxy log or network monitor). Repeat offline and with consent not given yet: commands still work, and the notice is the offline or consent one. *Physical device.*

## 12. Sources (fetched 2026-09-25)

- Apple HIG, Accessibility (44x44 pt default, 28x28 minimum; contrast table; Reduce Motion; Voice Control; Switch Control; Full Keyboard Access; Assistive Access): https://developer.apple.com/design/human-interface-guidelines/accessibility
- Apple iOS/iPadOS feature availability (VoiceOver, Voice Control, Dictation, and keyboard language lists; Haitian Creole only under QuickType Keyboard): https://www.apple.com/ios/feature-availability/
- WCAG 2.2 (1.4.3, 1.4.6, 1.4.11, 2.2.x, 2.4.11, 2.5.5, 2.5.8, 3.1.2, 3.1.5, 3.2.6, 3.3.7, 3.3.8, 4.1.3; contrast ratio and relative luminance with the 0.04045 threshold): https://www.w3.org/TR/WCAG22/
- WWDC23 "Perform accessibility audits for your app" (audit types, issue handler returns true to ignore, on-screen-only): https://developer.apple.com/videos/play/wwdc2023/10035/
- XCUIAccessibilityAuditType (contrast, dynamicType, elementDetection, hitRegion, sufficientElementDescription, textClipped, trait; action/parentChild are macOS): https://developer.apple.com/documentation/xcuiautomation/xcuiaccessibilityaudittype
- `performAccessibilityAudit(for:_:)` (iOS 17+): https://developer.apple.com/documentation/xcuiautomation/xcuiapplication/performaccessibilityaudit(for:_:)
- NSAttributedString.Key.accessibilitySpeechLanguage (BCP 47): https://developer.apple.com/documentation/foundation/nsattributedstring/key/accessibilityspeechlanguage
- AttributedString `languageIdentifier` attribute (iOS 15+): https://developer.apple.com/documentation/foundation/attributescopes/foundationattributes/languageidentifierattribute
- AccessibilityAttributes scope (no speech-language member): https://developer.apple.com/documentation/foundation/attributescopes/accessibilityattributes
- SwiftUI language for VoiceOver (attribute alone didn't work; locale environment + verbatim did): https://useyourloaf.com/blog/swiftui-accessibility-language/
- CVS Health SwiftUI techniques, language of parts: https://github.com/cvs-health/ios-swiftui-accessibility-techniques/blob/main/iOSswiftUIa11yTechniques/iOSswiftUIa11yTechniques/LanguageView.swift
- `accessibilityInputLabels(_:isEnabled:)` (iOS 18): https://developer.apple.com/documentation/swiftui/view/accessibilityinputlabels(_:isenabled:)
- `accessibilityRotor(_:entries:)` (iOS 16): https://developer.apple.com/documentation/swiftui/view/accessibilityrotor(_:entries:)
- WCAG 2.2 "large scale" text (18 pt / 14 pt bold, CSS pt): https://www.w3.org/TR/WCAG22/#dfn-large-scale
- Magic Tap: SwiftUI `AccessibilityActionKind.magicTap` https://developer.apple.com/documentation/swiftui/accessibilityactionkind/magictap ; UIKit `accessibilityPerformMagicTap()` https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilityperformmagictap()
- `AccessibilityNotification.ScreenChanged` (iOS 17): https://developer.apple.com/documentation/accessibility/accessibilitynotification/screenchanged
- `AccessibilityFocusState` (iOS 15): https://developer.apple.com/documentation/swiftui/accessibilityfocusstate
- UIKit `accessibilityLanguage`: https://developer.apple.com/documentation/objectivec/nsobject-swift.class/accessibilitylanguage
- `swipeUp(velocity:)` / `XCUIGestureVelocity`: https://developer.apple.com/documentation/xcuiautomation/xcuielement/swipeup(velocity:)
- `accessibilitySortPriority(_:)` (iOS 14): https://developer.apple.com/documentation/swiftui/view/accessibilitysortpriority(_:)
- `accessibilitySwitchControlEnabled` (iOS 15): https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityswitchcontrolenabled
- `AccessibilityNotification.Announcement` (iOS 17): https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement
- Assistive Access: WWDC25 "Customize your app for Assistive Access" https://developer.apple.com/videos/play/wwdc2025/238/ ; `AssistiveAccess` scene (iOS 26) https://developer.apple.com/documentation/swiftui/assistiveaccess ; `accessibilityAssistiveAccessEnabled` (iOS 18) https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityassistiveaccessenabled ; `UISupportsAssistiveAccess` https://developer.apple.com/documentation/bundleresources/information-property-list/uisupportsassistiveaccess
- AVSpeechSynthesisVoice / `speechVoices()`: https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice
- `XCUIVoiceOverService` (Xcode 27, iOS 27+; `XCUIDevice.voiceOverService`: enable, disable, currentSpeech, moveForward/Backward/In/Out): https://developer.apple.com/documentation/xcuiautomation/xcuivoiceoverservice
