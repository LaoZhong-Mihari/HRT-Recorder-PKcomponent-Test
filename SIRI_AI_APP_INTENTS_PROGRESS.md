# Siri AI / App Intents

Last updated: 2026-07-10

## Status

Implemented and ready for device validation. The flow is deliberately conservative for medication logging:

`Siri / App Shortcut → on-device Foundation Models draft → deterministic validation → local authentication → explicit confirmation → idempotent canonical write`

The model can understand a natural-language dose phrase after the custom App Intent is routed. It never writes a dose itself, recommends a regimen, or fills in an omitted medication/compound/route.

## What changed

- Removed the rule/regex-based `NaturalLanguageDoseParser`.
- Added `DoseDraftInterpreter.swift`, which uses `FoundationModels` only on iOS 27+ with a dynamic generation schema.
  - The model may select only short tokens from the current active plan and medication catalog.
  - It receives no persistent conversation history and the stored idempotency fingerprint is a hash of resolved fields, not the spoken phrase.
  - On iOS 16–26, a device without Apple Intelligence, an unsupported locale, or an uncertain result, only explicitly supplied structured fields may proceed; free text is sent to review instead of a hidden keyword fallback.
- Added deterministic validation for medication identity, route/compound compatibility, dose units, concentration × volume arithmetic, patch handling, sublingual values, conflicts between structured and model values, and broad finite/range checks.
- Added local-device authentication and a confirmation prompt before every dose write and hormone-estimate read.
- Removed the unsafe bare `Record Dose` behavior that recorded the next future planned dose.
- Planned doses now require an active plan and the exact still-existing slot at commit time; paused plans and stale slots are rejected rather than falling back to the primary template.
- Added `DoseStore.swift` as the sole canonical event repository. It uses a versioned document, `NSFileCoordinator`, monotonic revisions, mutation receipts, short retry fingerprints, and App Group storage. The UI, Siri, and Watch now merge mutations rather than independently overwrite `dose_events.json`.
- Migrated medication-plan persistence to the same App Group (with a one-time legacy Application Support fallback), so a background App Intent reads the same active plans as the foreground app.
- Updated Watch sync to send individual upsert/delete mutations. A legacy full snapshot is merge-only on the phone, so it cannot erase a Siri event.
- Filtered paused plans from Siri/Shortcuts/widget record options and remove stale Spotlight indexed entities during refresh.

## Platform boundary

The public iOS 27 SDK does **not** expose a Health/Medication App Schema for third-party dose logging. HealthKit medication APIs are read/query surfaces; `HKMedicationDoseEvent` has no public writable initializer. Do not pretend a Notes/Reminders schema is a medication action.

Consequently, the supported surface remains custom App Intents plus App Shortcuts. In current system behavior, including the app name is still the reliable way to route a phrase such as:

- `Record 5 mg EV injection in HRT Recorder`
- `用 HRT Recorder 记录 5 毫克 EV 注射`
- `What's my estrogen level in HRT Recorder?`

An app-name-free request such as `What's my estrogen level?` is a Siri routing limitation, not something the app can reliably repair until Apple ships a public medication schema or broader semantic routing.

## Verification

The Debug simulator build succeeds with Xcode 27 beta and App Intents metadata extraction:

```sh
DEVELOPER_DIR=/Applications/Xcode-27-beta.app/Contents/Developer \
xcodebuild -project HRT-Recorder.xcodeproj -scheme HRT-Recorder \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<simulator-udid>' \
  -derivedDataPath /tmp/HRTRecorder-SiriAI-20260710 \
  CODE_SIGNING_ALLOWED=NO ASSETCATALOG_COMPILER_APPICON_NAME= build
```

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
9. Check `What's my estrogen level in HRT Recorder?`; the response is an estimate from local recorded data, not a clinical measurement.

## References

- [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
- [App Intents](https://developer.apple.com/documentation/appintents)
- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [App Schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [Confirmation API](https://developer.apple.com/documentation/appintents/appintent/requestconfirmation%28conditions%3Aactionname%3Adialog%3A%29)
