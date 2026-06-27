# Siri AI / App Intents Progress

Last updated: 2026-06-27

## Status

Paused. Keep the current App Intents implementation as a prepared baseline, and resume when Siri AI / Apple Intelligence routing for third-party App Intents is more stable and testable on device.

The current work improves HRT Recorder's Shortcuts and Siri integration, but the system behavior still looks closer to App Shortcuts phrase routing than fully semantic, app-name-free Siri AI routing.

## Goal

Let a user say a natural sentence to Siri, such as:

- "Record 5 mg EV injection in HRT Recorder."
- "Log spironolactone 100 mg in HRT Recorder."
- "What's my estrogen level in HRT Recorder?"

Longer-term goal:

- Allow less rigid language.
- Let Siri extract dosing parameters from a complex utterance.
- Let Siri read hormone concentration.
- Let Siri write a dosing event through HRT Recorder without opening the app.

## Current Implementation

Main file:

- `HRT-Recorder/RecordDoseIntent.swift`

Supporting files already present in the worktree:

- `HRT-Recorder/DoseRecordingService.swift`
- `HRT-Recorder/MedicationIntentEntities.swift`
- `HRT-Recorder-Info.plist`
- `HRT-Recorder.xcodeproj/project.pbxproj`

Implemented:

- `RecordDoseIntent` for recording dosing events.
- `RecordPlannedDoseIntent` for recording an existing planned dose.
- `GetHormoneConcentrationIntent` for returning estimated hormone concentration.
- `IntentDosePhraseEntity` plus `EntityStringQuery` so Siri / Shortcuts can pass a free-form dose phrase into the app.
- Deterministic parser for dosing phrases such as:
  - `5 mg`
  - `5 mg EV injection`
  - `100 micrograms per day patch`
  - `spironolactone 100 mg`
  - Chinese route/category hints like injection, patch, oral, and estrogen terms.
- Real App Intent parameter follow-up using `requestValue(...)`.

Important fix:

- The old behavior returned a plain dialog like "Tell me the dose amount to record."
- That ended the App Intent interaction, so a follow-up like "5 mg" lost context and Siri answered "Sorry, I don't understand."
- The new implementation asks for missing values through App Intent parameter resolution, preserving context inside the same intent run.

## App Shortcut Phrases

Current shortcut phrases include:

- `Record a dose in HRT Recorder`
- `Log my dose in HRT Recorder`
- `Record my dosing in HRT Recorder`
- `Log dosing in HRT Recorder`
- `Record ${dosePhrase} in HRT Recorder`
- `Log ${dosePhrase} in HRT Recorder`
- `Record ${medication} dose in HRT Recorder`
- `Log ${medication} in HRT Recorder`
- `What's my estrogen level in HRT Recorder`
- `What is my estrogen level in HRT Recorder`
- `What's my estradiol level in HRT Recorder`
- `What's my ${hormone} level in HRT Recorder`

Known limitation:

- App Shortcut phrase templates still need the app name in practice.
- A phrase with multiple dynamic parameters is restricted by the App Intents metadata processor, so free-form `dosePhrase` is used as the broad capture field.
- `Siri, what's my estrogen level` without `in HRT Recorder` is not expected to reliably route to the app unless Apple exposes a suitable Assistant Schema or semantic routing behavior for this domain.

## Verification Completed

Simulator:

- Built with Xcode 27 beta against iOS 27 simulator.
- AppIntents metadata extraction succeeded.
- SSU / NLU training generated `root.ssu.yaml`.
- App bundle contains:
  - `Metadata.appintents/extract.actionsdata`
  - `Metadata.appintents/root.ssu.yaml`
  - `en.lproj/nlu.appintents/nlu.lzfse`
  - `zh-Hans.lproj/nlu.appintents/nlu.lzfse`
  - `zh-Hant.lproj/nlu.appintents/nlu.lzfse`
- Installed and launched on the iOS 27 simulator.
- Shortcuts app opened on simulator.

Device:

- Built Debug iPhoneOS package with Xcode 27 beta.
- AppIntents metadata extraction succeeded.
- SSU assets archived for `en`, `zh-Hans`, and `zh-Hant`.
- Installed successfully on physical device `みはり`.
- Remote launch failed only because the phone was locked. Manual launch should refresh the system App Intents / Shortcuts index.

Useful build command:

```sh
/Applications/Xcode-27-beta.app/Contents/Developer/usr/bin/xcodebuild \
  -project HRT-Recorder.xcodeproj \
  -scheme HRT-Recorder \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/HRTRecorder-AppIntents-DerivedData \
  build
```

Useful install command:

```sh
DEVELOPER_DIR='/Applications/Xcode-27-beta.app/Contents/Developer' \
/usr/bin/xcrun devicectl device install app \
  --device B10EABC3-EBB5-5B29-9B74-1376F68F006D \
  /tmp/HRTRecorder-AppIntents-DerivedData/Build/Products/Debug-iphoneos/HRT-Recorder.app
```

## Why This Is Paused

The current Apple platform behavior is not yet the desired full Siri AI experience.

Observed behavior:

- App Shortcuts are visible to the system through generated metadata.
- Exact or near-exact phrases with `HRT Recorder` are the reliable path.
- App-name-free requests are not reliably routed to the app.
- Siri still behaves as if App Shortcut phrase matching is the first gate.

This means further app-side changes may produce diminishing returns until Apple's Siri AI routing, App Schemas, and testing tools stabilize.

## Resume Criteria

Resume this feature when one or more of these become true:

- Siri AI / Apple Intelligence reliably routes third-party App Intents from natural language without explicit app names.
- Apple exposes or documents a suitable health / medication / logging Assistant Schema for third-party dose recording.
- `AssistantIntent(schema:)` has a public schema that matches medication or health event logging.
- `AppIntentsTesting` can run utterance-level tests locally or in CI for this app.
- Xcode beta NLU tooling can run inference reliably against archived App Shortcuts.
- Real-device Siri testing shows improvement beyond phrase-template behavior.

## Next Plan

1. Add AppIntentsTesting coverage.
   - Test that `RecordDoseIntent` resolves missing dose and route through parameter prompts.
   - Test that free-form dose phrases produce the expected `CustomDoseRecordingRequest`.
   - Test `GetHormoneConcentrationIntent` returns a value and dialog.

2. Add an iOS 27-only Foundation Models parser layer.
   - Keep the deterministic parser as fallback.
   - Use `FoundationModels` only behind availability checks.
   - Return a typed dosing parse result rather than free text.
   - Never let model output write directly to storage without validation.

3. Improve app entity indexing.
   - Ensure medication plans are `IndexedEntity` where appropriate.
   - Add useful synonyms for estradiol, estrogen, E2, EV, testosterone, T, anti-androgens, and Chinese terms.
   - Recheck what Siri can discover from entities after reinstall and index refresh.

4. Revisit Assistant Schemas.
   - Search the iOS SDK for public medication / health schemas.
   - Prefer an Apple-provided schema if one matches dose logging.
   - Keep custom App Shortcuts only as fallback if a schema becomes available.

5. Re-run device test matrix.
   - Shortcuts app action search: `HRT Recorder`, `Record Dose`, `Hormone Level`.
   - Siri phrase with app name: `Record 5 mg EV injection in HRT Recorder`.
   - Siri phrase with follow-up: `Record a dose in HRT Recorder`, then `5 mg EV injection`.
   - Siri hormone query with app name: `What's my estrogen level in HRT Recorder`.
   - Siri hormone query without app name: `What's my estrogen level`.
   - Chinese phrases: `用 HRT Recorder 记录 5 mg EV 注射`, `用 HRT Recorder 查看激素浓度`.

## References

- App Intents: https://developer.apple.com/documentation/appintents
- App Shortcuts: https://developer.apple.com/documentation/appintents/app-shortcuts
- Assistant schemas: https://developer.apple.com/documentation/appintents/assistantintent%28schema%3A%29
- Foundation Models: https://developer.apple.com/documentation/foundationmodels
- AppIntentsTesting WWDC26: https://developer.apple.com/videos/play/wwdc2026/295/

