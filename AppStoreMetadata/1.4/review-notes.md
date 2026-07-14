# App Review Notes — HRT Recorder 1.4 (build 5)

HRT Recorder is a personal medication record and informational pharmacokinetic-estimation tool. It does not diagnose conditions, recommend treatment, calculate a prescribed dose, or provide treatment decisions. Users should consult a qualified healthcare professional before making medical decisions. It is not for emergencies.

Suggested review path:

1. On first launch, choose an Estradiol (E2) or Testosterone (T) HRT profile.
2. Tap Add Dose and create a sample event. No account is required.
3. Open Settings → Hormone Lab Results to import or scan a report. OCR and deterministic fallback run on device; the user reviews extracted values before saving or using an eligible result for calibration.
4. Open Settings → About to view the medical notice, privacy policy, and PK methodology.
5. Siri/App Shortcuts may record a dose only after resolving required details and presenting confirmation. Siri is optional; all core recording controls remain available in the app.

HealthKit access is optional and limited to the usage descriptions shown by iOS: supported medication events and body weight may be read with permission, and body weight is written only after the user chooses to do so. The app has no sign-in, advertising, third-party analytics, or developer-operated data server.

The release build does not include the internal Apple AI Diagnostics interface. Private Cloud Compute entitlement is not enabled. On unsupported systems and devices, the app uses structured controls, App Intents/Shortcuts, and Vision OCR fallbacks.

PK charts are informational estimates based on the open methodology linked in Settings → About and must not be used to change a prescribed regimen.
