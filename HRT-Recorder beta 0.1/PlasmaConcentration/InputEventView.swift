//
//  InputEventView.swift
//  HRT‑Recorder
//
//    Created by mihari-zhong on 2025‑08‑01.
//
//  SwiftUI sheet for adding a DoseEvent.  The form adapts fields
//  to the selected route (injection, patch apply/remove, gel, oral, sublingual).
//
import Foundation
import SwiftUI
import Combine
/// Input mode when adding a transdermal patch
private enum PatchInputMode: String, CaseIterable, Identifiable {
    case totalDose           // mg in reservoir
    case releaseRate         // µg per day
    var id: Self { self }
    var label: LocalizedStringKey {
        switch self {
        case .totalDose:   "patch.mode.totalDose"
        case .releaseRate: "patch.mode.releaseRate"
        }
    }
}

private enum FocusedDoseField: Hashable {
    case raw
    case e2
    case patchTotal
    case patchRelease
    case customTheta
}

// MARK: - Draft model (for UI binding)
private struct DraftDoseEvent {
    var id: UUID? // For editing existing events
    var date = Date()
    var route: DoseEvent.Route = .injection
    var ester: Ester = .EV
    
    // **NEW**: Separate state for raw ester dose and E2 equivalent dose
    var rawEsterDoseText: String = ""
    var e2EquivalentDoseText: String = ""
    
    // for patch apply
    var patchMode: PatchInputMode = .totalDose
    var releaseRateText: String = ""
    
    // Sublingual behavior (θ) UI
    var slTierIndex: Int = 2        // 0: quick, 1: casual, 2: standard, 3: strict
    var useCustomTheta: Bool = false
    var customThetaText: String = ""
}

// MARK: - View
struct InputEventView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DraftDoseEvent
    @FocusState private var focusedField: FocusedDoseField?

    var onSave: (DoseEvent) -> Void
    var onCancel: (() -> Void)?
    
    // **NEW**: Initializer for both creating a new event and editing an existing one.
    init(
        eventToEdit: DoseEvent? = nil,
        seed: DoseEntrySeed? = nil,
        onSave: @escaping (DoseEvent) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.onSave = onSave
        self.onCancel = onCancel
        if let event = eventToEdit {
            let esterInfo = EsterInfo.by(ester: event.ester)
            let rawDose = event.doseMG / esterInfo.toE2Factor

            var initialDraft = DraftDoseEvent(
                id: event.id,
                date: event.date,
                route: event.route,
                ester: event.ester,
                rawEsterDoseText: event.ester == .E2 ? "" : String(format: "%.2f", locale: Locale.current, rawDose),
                e2EquivalentDoseText: String(format: "%.2f", locale: Locale.current, event.doseMG)
            )

            if event.route == .patchApply {
                if let rate = event.extras[.releaseRateUGPerDay] {
                    initialDraft.patchMode = .releaseRate
                    initialDraft.releaseRateText = String(format: "%.0f", locale: Locale.current, rate)
                    initialDraft.e2EquivalentDoseText = ""
                } else {
                    initialDraft.patchMode = .totalDose
                }
            }

            if event.route == .sublingual {
                if let theta = event.extras[.sublingualTheta] {
                    initialDraft.useCustomTheta = true
                    initialDraft.customThetaText = String(format: "%.2f", locale: Locale.current, theta)
                }
                if let tierCode = event.extras[.sublingualTier] {
                    let clampedIndex = min(max(Int(tierCode.rounded()), 0), 3)
                    initialDraft.slTierIndex = clampedIndex
                }
            }

            _draft = State(initialValue: initialDraft)
        } else if let seed {
            var initialDraft = DraftDoseEvent(
                id: nil,
                date: seed.date,
                route: seed.template.route,
                ester: seed.template.ester,
                rawEsterDoseText: seed.template.ester == .E2 ? "" : String(
                    format: "%.2f",
                    locale: Locale.current,
                    seed.template.doseMG / EsterInfo.by(ester: seed.template.ester).toE2Factor
                ),
                e2EquivalentDoseText: seed.template.doseMG > 0 ? String(format: "%.2f", locale: Locale.current, seed.template.doseMG) : ""
            )

            if seed.template.route == .patchApply {
                if let rate = seed.template.extras[.releaseRateUGPerDay] {
                    initialDraft.patchMode = .releaseRate
                    initialDraft.releaseRateText = String(format: "%.0f", locale: Locale.current, rate)
                    initialDraft.e2EquivalentDoseText = ""
                }
            }

            if seed.template.route == .sublingual {
                if let theta = seed.template.extras[.sublingualTheta] {
                    initialDraft.useCustomTheta = true
                    initialDraft.customThetaText = String(format: "%.2f", locale: Locale.current, theta)
                }
                if let tierCode = seed.template.extras[.sublingualTier] {
                    initialDraft.slTierIndex = min(max(Int(tierCode.rounded()), 0), 3)
                }
            }

            _draft = State(initialValue: initialDraft)
        } else {
            _draft = State(initialValue: DraftDoseEvent())
        }
    }
    
    // ... (availableEsters logic updated for sublingual)
    private var availableEsters: [Ester] {
        switch draft.route {
        case .injection: return [.EB, .EV, .EC, .EN]
        case .patchApply, .patchRemove, .gel: return [.E2]
        case .oral: return [.E2, .EV]
        case .sublingual: return [.E2, .EV]
        }
    }

    // MARK: - Localization helpers for ester names (with English fallback)
    private func esterDefaultName(_ e: Ester) -> String {
        switch e {
        case .E2: return "Estradiol"
        case .EV: return "Estradiol valerate"
        case .EB: return "Estradiol benzoate"
        case .EC: return "Estradiol cypionate"
        case .EN: return "Estradiol enanthate"
        @unknown default: return "Estradiol"
        }
    }
    private func esterNameText(_ e: Ester) -> Text {
        // Dynamic key: "ester.<abbr>.name", e.g. "ester.EV.name"
        let key = "ester.\(e.abbreviation).name"
        // Use Foundation to resolve localization with a **default value** so English shows even when the key is missing for the current locale.
        let resolved = NSLocalizedString(key, tableName: nil, bundle: .main, value: esterDefaultName(e), comment: "Localized ester name")
        return Text(resolved)
    }

    var body: some View {
        NavigationStack {
            Form {
                // ... (DatePicker and Route Picker remain the same)
                Section {
                    DatePicker("input.time", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
                    Picker("input.route", selection: $draft.route) {
                        Text("route.injection").tag(DoseEvent.Route.injection)
                        Text("route.patchApply").tag(DoseEvent.Route.patchApply)
                        Text("route.patchRemove").tag(DoseEvent.Route.patchRemove)
                        Text("route.gel").tag(DoseEvent.Route.gel)
                        Text("route.oral").tag(DoseEvent.Route.oral)
                        Text("route.sublingual").tag(DoseEvent.Route.sublingual)
                    }
                    #if swift(>=5.9)
                    .onChange(of: draft.route) { oldValue, newValue in
                        if let firstValidEster = availableEsters.first {
                            draft.ester = firstValidEster
                        }
                        // Clear doses on route change
                        draft.rawEsterDoseText = ""
                        draft.e2EquivalentDoseText = ""
                        draft.patchMode = .totalDose
                        draft.releaseRateText = ""
                        // reset sublingual UI
                        draft.slTierIndex = 2
                        draft.useCustomTheta = false
                        draft.customThetaText = ""
                    }
                    #else
                    .onChange(of: draft.route) { _ in
                        if let firstValidEster = availableEsters.first {
                            draft.ester = firstValidEster
                        }
                        // Clear doses on route change
                        draft.rawEsterDoseText = ""
                        draft.e2EquivalentDoseText = ""
                        draft.patchMode = .totalDose
                        draft.releaseRateText = ""
                        // reset sublingual UI
                        draft.slTierIndex = 2
                        draft.useCustomTheta = false
                        draft.customThetaText = ""
                    }
                    #endif
                }
                
                if draft.route != .patchRemove {
                    Section("input.drugDetails") {
                        if availableEsters.count > 1 {
                            Picker("input.drugEster", selection: $draft.ester) {
                                ForEach(availableEsters) { e in
                                    esterNameText(e).tag(e)
                                }
                            }
#if swift(>=5.9)
                            .onChange(of: draft.ester) { _, _ in
                                // Recalculate when ester changes
                                syncDoseTextsAfterEsterChange()
                            }
#else
                            .onChange(of: draft.ester) { _ in
                                // Recalculate when ester changes
                                syncDoseTextsAfterEsterChange()
                            }
#endif
                        }

                        // **NEW**: Two-way binding text fields for dose conversion.
                        if draft.ester != .E2 {
                             TextField(String(format: NSLocalizedString("input.dose.raw", comment: "Dose input placeholder"), locale: Locale.current, draft.ester.abbreviation), text: $draft.rawEsterDoseText)
                                .keyboardType(.decimalPad)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .raw)
                                .onSubmit { handleSubmit(for: .raw) }
                        }

                        TextField("input.dose.e2", text: $draft.e2EquivalentDoseText)
                            .keyboardType(.decimalPad)
                            .submitLabel(.done)
                            .focused($focusedField, equals: draft.route == .patchApply ? .patchTotal : .e2)
                            .onSubmit { handleSubmit(for: draft.route == .patchApply ? .patchTotal : .e2) }
                    }
                }

                // MARK: Patch‑specific input
                if draft.route == .patchApply {
                    Section("input.patchMode") {
                        Picker("input.patchMode.label", selection: $draft.patchMode) {
                            ForEach(PatchInputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if draft.patchMode == .totalDose {
                            TextField("input.patchMode.totalDose", text: $draft.e2EquivalentDoseText)
                                .keyboardType(.decimalPad)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .patchTotal)
                        } else {
                            TextField("input.patchMode.releaseRate", text: $draft.releaseRateText)
                                .keyboardType(.decimalPad)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .patchRelease)
                        }
                    }
                }

                // MARK: Sublingual behavior (θ)
                if draft.route == .sublingual {
                    Section("input.sublingual") {
                        // Tier picker (segmented)
                        Picker("input.sublingual.hold", selection: $draft.slTierIndex) {
                            Text("input.sublingual.quick").tag(0)
                            Text("input.sublingual.casual").tag(1)
                            Text("input.sublingual.standard").tag(2)
                            Text("input.sublingual.strict").tag(3)
                        }
                        .pickerStyle(.segmented)

                        // Show suggested hold time and θ for current tier
                        let tier = [SublingualTier.quick, .casual, .standard, .strict][min(max(draft.slTierIndex, 0), 3)]
                        let hold = SublingualTheta.holdMinutes[tier] ?? 0
                        let theta = SublingualTheta.recommended[tier] ?? 0.11
                        Text(String(format: NSLocalizedString("input.sublingual.suggestion", comment: "Sublingual suggestion"), locale: Locale.current, hold, theta))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("input.sublingual.instructions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)

                        // Optional: custom theta override
                        Toggle("input.sublingual.customTheta", isOn: $draft.useCustomTheta)
                        if draft.useCustomTheta {
                            TextField("input.sublingual.customThetaPlaceholder", text: $draft.customThetaText)
                                .keyboardType(.decimalPad)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .customTheta)
                                .onSubmit { handleSubmit(for: .customTheta) }
                        }
                    }
                }
            }
            .navigationTitle(draft.id == nil ? Text("input.title.add") : Text("input.title.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        onCancel?()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("common.save") { save() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("common.done") {
                        let field = focusedField
                        handleSubmit(for: field)
                        focusedField = nil
                    }
                }
            }
        }
        // When the sheet/view appears, set focus to the most relevant field so the keyboard shows automatically.
        .onAppear {
            // Only auto-focus when creating a new event (draft.id == nil). When editing, avoid forcing focus.
            guard draft.id == nil else { return }
            DispatchQueue.main.async {
                if draft.route == .patchApply {
                    focusedField = (draft.patchMode == .totalDose) ? .patchTotal : .patchRelease
                } else if draft.ester != .E2 {
                    // Prefer focusing raw ester input when it's available
                    focusedField = .raw
                } else {
                    focusedField = .e2
                }
            }
        }
    }

    // MARK: - Conversion Logic
    private func handleSubmit(for field: FocusedDoseField?) {
        switch field {
        case .raw:
            convertToE2Equivalent()
        case .e2, .patchTotal:
            convertToRawEster()
        case .customTheta, .patchRelease, .none:
            break
        }
    }

    private func convertToE2Equivalent() {
        guard let rawDose = parsedDouble(draft.rawEsterDoseText) else { return }
        let factor = EsterInfo.by(ester: draft.ester).toE2Factor
        draft.e2EquivalentDoseText = String(format: "%.2f", locale: Locale.current, rawDose * factor)
    }

    private func convertToRawEster() {
        guard draft.ester != .E2, let e2Dose = parsedDouble(draft.e2EquivalentDoseText) else { return }
        let factor = EsterInfo.by(ester: draft.ester).toE2Factor
        draft.rawEsterDoseText = String(format: "%.2f", locale: Locale.current, e2Dose / factor)
    }

    private func syncDoseTextsAfterEsterChange() {
        if draft.ester == .E2 {
            draft.rawEsterDoseText = ""
            return
        }

        if let _ = parsedDouble(draft.e2EquivalentDoseText), !draft.e2EquivalentDoseText.isEmpty {
            convertToRawEster()
        } else if let _ = parsedDouble(draft.rawEsterDoseText), !draft.rawEsterDoseText.isEmpty {
            convertToE2Equivalent()
        }
    }

    private func parsedDouble(_ text: String) -> Double? {
        let sanitized = text.replacingOccurrences(of: ",", with: ".")
        return Double(sanitized)
    }

    private func save() {
        var dose = parsedDouble(draft.e2EquivalentDoseText) ?? 0
        var extras: [DoseEvent.ExtraKey: Double] = [:]

        // zero‑order patch: rate stored separately
        if draft.route == .patchApply && draft.patchMode == .releaseRate {
            dose = 0
            if let rateUG = parsedDouble(draft.releaseRateText) {
                extras[.releaseRateUGPerDay] = rateUG
            }
        }

        // sublingual behavior: either tier code or explicit theta
        if draft.route == .sublingual {
            if draft.useCustomTheta, let th = parsedDouble(draft.customThetaText) {
                let clamped = max(0.0, min(1.0, th))
                extras[.sublingualTheta] = clamped
            } else {
                let code = Double(min(max(draft.slTierIndex, 0), 3))
                extras[.sublingualTier] = code
            }
        }
        
        let event = DoseEvent(
            id: draft.id ?? UUID(), // Use existing ID or create a new one
            route: draft.route,
            // store absolute UTC hours (since 1970) – avoids 2001/01/01 offset
            timeH: draft.date.timeIntervalSince1970 / 3600.0,
            doseMG: dose,
            ester: draft.ester,
            extras: extras
        )
        onSave(event)
        dismiss()
    }
}
