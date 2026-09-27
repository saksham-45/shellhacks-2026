# Mac batch (`tools/mac_batch.sh`)

Owner: myAD Lead. One approved run on the captain's Mac builds and tests the whole iOS app.
The Linux box never runs Xcode; everything Xcode-only is batched here.

## What it runs (in order, continuing past failures)

1. **prerequisites**: `xcodegen`, `xcodebuild`, `xcrun simctl`, `swift`, `python3`, an iOS 18+ simulator
   runtime and an available iPhone simulator. If anything is missing it prints how to install it
   (`brew install xcodegen`, Xcode 16+, `xcodebuild -downloadPlatform iOS`, `xcode-select --install`) and
   exits 2. It also checks that the scheme/target names it uses still exist in `ios/project.yml`.
2. **xcodegen generate** in `ios/`.
3. **xcodebuild build** of scheme `MyAmericanDream` on one simulator: the newest available iPhone on the
   newest iOS ≥ 18 (from `xcrun simctl list devices available -j`), or `DEVICE="<name or UDID>"`.
4. **swift test** for every package in `ios/Packages` (ADCore, ADLocale, ADVoice, ADCityPack, ADRouter,
   ADAgentsClient, ADAccessibility, ADBeat, plus any new folder, which is tested and noted).
5. **App unit tests**: `MyAmericanDreamTests`, through test plan `Accessibility`, English configuration only.
6. **Accessibility test plan**: `ios/Accessibility.xctestplan`, all three configurations (Español, English,
   Kreyòl), which runs `MyAmericanDreamUITests` (audits, voice-first flows) and the unit tests. If the plan
   file is missing it says so and runs the `MyAmericanDreamUITests` target instead.
7. **Creole voice probe**: installs the built app and launches it with `-myadProbe creole`
   (`ios/App/Sources/Platform/CreoleProbe.swift`, Language report FM-MYAD-LANG §7.4 items 1-3 and 5), once per
   device language in `PROBE_LANGS` (default `en fr`). The `MYAD-PROBE …` console lines are captured with
   `simctl launch --console-pty`, and the app's `Documents/creole_probe.{txt,json}` are copied out. PASS means the
   probe finished and wrote its JSON. It does **not** judge the result; read the files.

## How to run

```sh
cd <tree root>                      # the folder that holds ios/ and tools/
tools/mac_batch.sh                  # or: DEVICE="iPhone 17 Pro" PROBE_LANGS="en" tools/mac_batch.sh
```

No secrets, no network keys, no version control. Optional env: `DEVICE`, `PROBE_LANGS`, `PROBE_TIMEOUT`
(seconds, default 90), `DERIVED_DATA` (default `build/mac-batch/DerivedData`, shared so reruns are
incremental). Exit code: 0 all PASS, 1 any step FAILED, 2 prerequisites missing.

## Where the output goes

`build/mac-batch/<YYYYmmdd-HHMMSS>/` (ignored by `.gitignore`'s `build/`):
- `summary.txt`: one `PASS|FAIL|SKIP  <step>  (log …)` line per step, the device, and `RESULT: PASS|FAIL`;
- `<step>.log` for every step (`xcodegen_generate.log`, `swift_test_ADCore.log`, …);
- `build.xcresult`, `unit-tests.xcresult`, `accessibility.xcresult` (+ `*.summary.json` from `xcresulttool`
  when available); the AX5 audit screenshots live inside `accessibility.xcresult`;
- `creole-probe-<lang>.console.log`, `.lines.txt`, `.txt`, `.json`;
- `simctl-runtimes.json`, `simctl-devices.json`, `prerequisites.log`.

Send the whole folder (or at least `summary.txt`, the failing logs, and the probe files) back to Lead.

## What it cannot automate (docs/accessibility.md §11, record in a run log)

XCUITest can't hear VoiceOver, perform Magic Tap, list or run VoiceOver custom actions, or toggle display
settings, and the simulator records no audio. These stay manual; *device* = physical iPhone:
- **M1 VoiceOver walk**: every screen in es/en/ht; order, labels, headings, states, one element per fact
  with its source slot, every `FactLine` case.
- **M2 Language** *(device)*: mixed-language card; what VoiceOver does with `ht`-tagged text; stacked hero
  lines each in its own language, only the first is a heading.
- **M3 Speech** *(device)*: "Read this card" in es/en/ht, stop/restart, same facts as the screen; the app
  never reads ht with an es/en voice; Creole notice shown and announced; list `speechVoices()`. The probe's
  "voice at didStart" must be **listened to** on a device (French or English phonetics).
- **M4 Input**: real Voice Control, Switch Control item scan, Full Keyboard Access.
- **M5 Size**: AX1-AX5 screenshots in ht, no truncation, single-direction scroll, Large Content Viewer.
- **M6 Display**: Bold Text, Reduce Motion/Transparency, Increase Contrast, Differentiate Without Color,
  Smart Invert, light/dark, Button Shapes.
- **M7 Literacy/cognition**: a non-English reader completes the core tasks unaided; no timeouts; confirm + undo.
- **M8 Assistive Access** *(device)*.
- **M9 Privacy**: two-person household; no one else's papers read aloud; tourist mode speaks no immigration.
- **M10 Voice-first with VoiceOver** *(device)*: Magic Tap toggles listening; clarifications and leave-app
  confirmations are spoken, focused, answerable by voice and buttons, never time out; screen-change announcements.
- **M11 Play in Kreyòl** *(device)*: "Jwe an Kreyòl" on every ht card, clip playback, ducking, stops, and
  checks (a)-(e).
- **M12 Creole voice fallback (commands only)** *(device)*: the few command phrases work with no Creole
  engine and with "never send my voice" on; nothing goes to the server.
- Report §7.4 items 4 and 6-7 (VoiceOver with `ht` tags under French and English device languages, cloud
  latency, WhisperKit sanity check) also need a physical device.
