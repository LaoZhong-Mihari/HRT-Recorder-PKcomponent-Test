# UI Review Notes

Date: 2026-03-28

## Confirmed Findings

1. Settings rows bypass localization and create a mixed-language UI.
   - `HRT-Recorder/PlasmaConcentration/TimelineScreen.swift:295-320`
   - `HRT-Recorder/PlasmaConcentration/DoseTimelineVM.swift:228-242`

2. Dose-entry sheets nest `NavigationStack` around `InputEventView`, which already owns one.
   - `HRT-Recorder/PlasmaConcentration/TimelineScreen.swift:123-149`
   - `HRT-Recorder/Medication/MedicationPlansView.swift:931-949`
   - `HRT-Recorder/Medication/MedicationPlansView.swift:1373-1391`
   - `HRT-Recorder/PlasmaConcentration/InputEventView.swift:207-208`
   - In runtime this also shows up as a clear background/color mismatch: the extra outer container stays plain white while the inner `Form` keeps grouped styling, leaving obvious white gutters around the dose sheet.

3. Switching recurrence to daily ignores the selected weekly time.
   - `HRT-Recorder/Medication/MedicationPlansView.swift:1113-1128`

4. Fresh install immediately triggers the Health permission flow before the user can reach the main UI.
   - Reproduced on iOS Simulator on 2026-03-28.
   - `HRT-Recorder/HRT_RecorderApp.swift:108-117`

5. Populated timeline layout breaks under accessibility-extra-extra-extra-large Dynamic Type.
   - Reproduced on iOS Simulator on 2026-03-28 with populated sample events, dark appearance, and `accessibility-extra-extra-extra-large`.
   - The date header, dose card, chart title, and chart axes overlap or clip, leaving the timeline hard to read.
   - Likely contributors:
     - `HRT-Recorder/PlasmaConcentration/TimelineScreen.swift:57-91`
     - `HRT-Recorder/PlasmaConcentration/TimelineScreen.swift:560-584`
     - `HRT-Recorder/PlasmaConcentration/ResultChartView.swift:336-363`

6. Medication plan overview screen becomes cramped and partially truncated under accessibility-extra-extra-extra-large Dynamic Type.
   - Reproduced on iOS Simulator on 2026-03-28 after navigating from Settings to Medication & Reminders with `accessibility-extra-extra-extra-large`.
   - The navigation title truncates, and the overview card copy wraps into very tall blocks that crowd out the rest of the screen.
   - Likely contributors:
     - `HRT-Recorder/Medication/MedicationPlansView.swift:10-90`
     - `HRT-Recorder/Medication/MedicationPlansView.swift:134-215`

7. Opening Add Dose auto-focuses an off-screen field and surfaces a stray keyboard accessory button.
   - Reproduced on iOS Simulator on 2026-03-28 with default content size.
   - The add sheet opens at the top, but focus jumps to the dose field below the fold, leaving a floating `Done` button visible even though the focused text field is not on screen.
   - Likely contributors:
     - `HRT-Recorder/PlasmaConcentration/InputEventView.swift:427-440`

8. Add Dose has no validation gate, so a blank form can save a 0 mg event.
   - Confirmed by code inspection on 2026-03-28.
   - The confirmation button is always available, and `save()` falls back to `0` when the dose fields are empty or unparsable.
   - Likely contributors:
     - `HRT-Recorder/PlasmaConcentration/InputEventView.swift:408-415`
     - `HRT-Recorder/PlasmaConcentration/InputEventView.swift:512-548`

## Next Step

Continue runtime UI inspection in iOS and watchOS separately to keep memory usage down.
