# Siri AI / App Intents

Last updated: 2026-07-11

## Status

Implemented together with the hormone-test OCR work and ready for physical-device revalidation. The dose flow is deliberately conservative for medication logging:

`Siri / App Shortcut → on-device Foundation Models draft → deterministic validation → local authentication → explicit confirmation → idempotent canonical write`

The model can understand a natural-language dose phrase after the custom App Intent is routed. It never writes a dose itself, recommends a regimen, or fills in an omitted medication/compound/route.

## What changed

- Removed the rule/regex-based `NaturalLanguageDoseParser`.
- Added `DoseDraftInterpreter.swift`, which uses `FoundationModels` only on iOS 27+ with a dynamic generation schema.
  - The model may select only short tokens from the current active plan and medication catalog.
  - It receives no persistent conversation history and the stored idempotency fingerprint is a hash of resolved fields, not the spoken phrase.
  - On iOS 16–26, a device without Apple Intelligence, an unsupported locale, or an uncertain result, only explicitly supplied structured fields may proceed; free text is sent to review instead of a hidden keyword fallback.
- Fixed the follow-up failure captured in session `019f0300-35da-7121-80dd-0af6b55d075f`: older Siri/Shortcuts flows now use App Intents `requestValue` prompts for medication, route, and dose, so a reply such as “5 mg” remains inside the active intent conversation.
- Removed prefilled sentinel/default values from required App Intent parameters. A generic hormone-level request now leaves `hormone` unset so Siri asks for estradiol or testosterone instead of silently selecting estradiol. The planned-dose shortcut likewise asks for an active dose instead of receiving a stale placeholder.
- Added deterministic validation for medication identity, route/compound compatibility, dose units, concentration × volume arithmetic, patch handling, sublingual values, conflicts between structured and model values, and broad finite/range checks.
- Added local-device authentication and a confirmation prompt before every dose write and hormone-estimate read.
- Removed the unsafe bare `Record Dose` behavior that recorded the next future planned dose.
- Planned doses now require an active plan and the exact still-existing slot at commit time; paused plans and stale slots are rejected rather than falling back to the primary template.
- Added `DoseStore.swift` as the sole canonical event repository. It uses a versioned document, `NSFileCoordinator`, monotonic revisions, mutation receipts, short retry fingerprints, and App Group storage. The UI, Siri, and Watch now merge mutations rather than independently overwrite `dose_events.json`.
- Migrated medication-plan persistence to the same App Group (with a one-time legacy Application Support fallback), so a background App Intent reads the same active plans as the foreground app.
- Updated Watch sync to send individual upsert/delete mutations. A legacy full snapshot is merge-only on the phone, so it cannot erase a Siri event.
- Filtered paused plans from Siri/Shortcuts/widget record options and remove stale Spotlight indexed entities during refresh.

## Lab report OCR and Apple Intelligence

- Merged the hormone-test OCR flow into the same iOS 27 availability boundary used by Siri.
- On an eligible iOS 27 device, the universal Foundation Models schema receives the raw OCR evidence for every non-empty report. It performs semantic extraction of rows and metadata; the deterministic parser is retained as a grounding and fallback layer, not as the gate that decides whether the LLM may understand the document.
- A real iOS 27 beta device reproduced an uncatchable `EXC_BAD_ACCESS` inside `FoundationModels.Attachment(cgImage, orientation:)`. The production import path no longer constructs a Foundation Models image attachment. It now uses `Vision OCR → universal structured Foundation Model → evidence verifier`, preserving LLM understanding while removing the crashing beta image bridge. Direct multimodal attachment can be reconsidered after Apple ships a runtime that passes physical-device regression tests.
- Model output is accepted only when its source line, numeric value, date, institution/location, specimen, and method can be grounded in visible OCR evidence. Reference ranges and table row numbers are excluded from result-value matching.
- Specimen output must now be grounded in the OCR text itself; the presence of a specimen label alone is insufficient. Corrupted text such as `血消` is rejected instead of allowing the model to substitute an ungrounded plausible material. Debug diagnostics show both raw and accepted values, so a safely rejected model guess is reported as a passing boundary rather than an app failure.
- On iOS 16–26, unsupported hardware, unavailable Apple Intelligence, or an unsupported locale, the app remains on Vision OCR plus deterministic review and never instantiates a Foundation Models session.
- Imported images are downsampled and limited to four at a time for older-device memory safety. Persisted OCR source text is scrubbed of common patient identity, identifier, contact, provider, and diagnosis lines.
- Apple AI diagnostic UI and diagnostic runners are compiled only in Debug builds. Their user-facing strings are absent from the Release string catalog and Release app artifact.

## Platform boundary

The public iOS 27 SDK does **not** expose a Health/Medication App Schema for third-party dose logging. HealthKit medication APIs are read/query surfaces; `HKMedicationDoseEvent` has no public writable initializer. Do not pretend a Notes/Reminders schema is a medication action.

Consequently, the supported surface remains custom App Intents plus App Shortcuts. In current system behavior, including the app name is still the reliable way to route a phrase such as:

- `Record 5 mg EV injection in HRT Recorder`
- `用 HRT Recorder 记录 5 毫克 EV 注射`
- `What's my estrogen level in HRT Recorder?`

An app-name-free request such as `What's my estrogen level?` is a Siri routing limitation, not something the app can reliably repair until Apple ships a public medication schema or broader semantic routing.

## Verification

The merged app builds in Debug and Release with Xcode 27 beta, including App Intents metadata extraction and the iOS 27 Foundation Models structured-text path:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
xcodebuild -project HRT-Recorder.xcodeproj -scheme HRT-Recorder \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath /tmp/HRTRecorder-MergedAI-20260710 \
  CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME= build
```

The same source also builds with the stable Xcode 26 SDK. iOS 16–26 retains Siri/App Shortcuts and Vision OCR fallbacks without loading iOS 27-only model APIs.

The Xcode 27-built app was also installed and launched on both iOS 26.1 and iOS 27.0 simulators. Release builds succeeded for both the iOS Simulator and arm64 `iphoneos`. Both artifacts have a 16.0 minimum OS version, weak-link `FoundationModels.framework`, and contain no Foundation Models `Attachment` symbol, so loading the app on iOS 26 does not require or instantiate that framework.

The Debug-only OCR fallback suite was enabled explicitly and run on both iOS 26.1 and iOS 27 simulators. All 12 checks passed on each OS, covering Chinese upload/scan OCR, leading-flag artifacts, sparse and split tables, specimen-field grounding, English and patient-portal layouts, international date/number formats, generic non-hormone rows, column-order variants, and administrative-field noise. The synthetic image pipeline also passed with seven analytes on both OS versions. On iOS 27, a simulator model guardrail error cleanly fell back to verified OCR instead of crashing or retrying an equivalent metadata request.

The generated App Intents metadata marks `hormone` and `doseOption` as required, contains no preconfigured estradiol or stale dose value for the generic shortcuts, and generated SSU/NLU assets for English, Simplified Chinese, and Traditional Chinese.

The temporary AppIcon override only avoids a pre-existing Watch asset-catalog issue in simulator CI; it is not part of the Siri implementation.

The resulting app was installed and launched on an iOS 27 iPhone 17 Pro simulator. App Intents SSU/NLU assets were generated for English, Simplified Chinese, and Traditional Chinese, and the system indexed the app entities successfully. The simulator cannot validate an actual on-device Foundation Models response or Siri authorization flow.

## Device test matrix

Run these on Apple-Intelligence-capable hardware with the app unlocked at least once after install:

1. `Record a dose in HRT Recorder`, then `5 mg EV by injection`.
2. `Record 0.5 mL EV at 20 mg/mL in HRT Recorder` and verify the confirmation says 10 mg-equivalent raw dose, not 20 mg.
3. `Record 1,000 mcg E2 orally in HRT Recorder` and verify it is 1 mg.
4. `Record 5 mg injection in HRT Recorder` and verify it asks for the exact medication rather than choosing EB/EV.
5. Try a paused plan and a plan whose dose slot was deleted after selection; both must refuse to write.
6. Confirm a dose, retry the same request, and verify only one event appears.
7. Record on Siri while the phone UI is open, then edit an unrelated UI event; verify both records remain.
8. Add, edit, and delete on Watch while a Siri event exists; verify Watch changes do not erase the Siri event.
9. Check `Check my hormone level in HRT Recorder`; Siri must ask estradiol or testosterone. Then try `Check testosterone level in HRT Recorder`; it should run without the extra question. The response is an estimate from local recorded data, not a clinical measurement.
10. Import a hormone report on an Apple-Intelligence-capable iOS 27 device and verify semantic extraction is shown for review before saving; try mixed Chinese/English labels and a report with fewer than seven rows.
11. Import the same report on iOS 26 or an Apple-Intelligence-ineligible device and verify Vision OCR review works without a crash or Foundation Models availability error.
12. Verify a Release archive has no Apple AI Diagnostics entry or diagnostic report UI.
13. On iOS 27, import the same image repeatedly after a fresh launch and after an interrupted import. Verify there is no `FoundationModels.Attachment` frame, crash, or persistent retry loop.

## References

- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [What’s new in the Foundation Models framework (WWDC26)](https://developer.apple.com/videos/play/wwdc2026/241/)
- [App Intents](https://developer.apple.com/documentation/appintents)
- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [App Schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [Confirmation API](https://developer.apple.com/documentation/appintents/appintent/requestconfirmation%28conditions%3Aactionname%3Adialog%3A%29)
