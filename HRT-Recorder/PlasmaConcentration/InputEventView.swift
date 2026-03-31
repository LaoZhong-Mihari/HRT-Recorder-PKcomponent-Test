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
    case activeEquivalent
    case recordOnlyDose
    case patchTotal
    case patchRelease
    case customTheta
}

private enum DraftMedicationCategory: String, CaseIterable, Identifiable {
    case estradiol
    case testosterone
    case antiAndrogen

    var id: Self { self }

    var category: MedicationCategory {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        case .antiAndrogen: return .antiAndrogen
        }
    }

    init(category: MedicationCategory) {
        switch category {
        case .estradiol: self = .estradiol
        case .testosterone: self = .testosterone
        case .antiAndrogen: self = .antiAndrogen
        }
    }
}

// MARK: - Draft model (for UI binding)
private struct DraftDoseEvent {
    var id: UUID? // For editing existing events
    var date = Date()
    var medicationCategory: DraftMedicationCategory = .estradiol
    var route: DoseEvent.Route = .injection
    var ester: Ester = .EV
    var recordOnlyOralMedication: RecordOnlyOralMedication = .cyproteroneAcetate
    var recordOnlyDoseText: String = ""
    
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

    var isRecordOnlyOralMedication: Bool {
        medicationCategory == .antiAndrogen
    }
}

// MARK: - View
struct InputEventView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DraftDoseEvent
    @FocusState private var focusedField: FocusedDoseField?

    private let showsDatePicker: Bool
    private let navigationTitleOverride: String?
    private let autoFocusOnAppear: Bool
    private let onSave: (DoseEvent) -> Void
    private let onCancel: (() -> Void)?
    
    // **NEW**: Initializer for both creating a new event and editing an existing one.
    init(
        eventToEdit: DoseEvent? = nil,
        seed: DoseEntrySeed? = nil,
        preferredCategory: MedicationCategory = .estradiol,
        showsDatePicker: Bool = true,
        navigationTitleOverride: String? = nil,
        autoFocusOnAppear: Bool = false,
        onSave: @escaping (DoseEvent) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.showsDatePicker = showsDatePicker
        self.navigationTitleOverride = navigationTitleOverride
        self.autoFocusOnAppear = autoFocusOnAppear
        self.onSave = onSave
        self.onCancel = onCancel
        if let event = eventToEdit {
            let recordOnlyOralMedication = event.recordOnlyOralMedication
            let compoundInfo = CompoundInfo.by(compound: event.compound)
            let rawDose = event.doseMG / compoundInfo.toActiveFactor

            var initialDraft = DraftDoseEvent(
                id: event.id,
                date: event.date,
                medicationCategory: DraftMedicationCategory(category: event.category),
                route: event.route,
                ester: event.compound,
                recordOnlyOralMedication: recordOnlyOralMedication ?? .cyproteroneAcetate,
                recordOnlyDoseText: recordOnlyOralMedication == nil ? "" : String(format: "%.2f", locale: Locale.current, event.doseMG),
                rawEsterDoseText: recordOnlyOralMedication == nil && event.compound != .E2 && event.compound != .T ? String(format: "%.2f", locale: Locale.current, rawDose) : "",
                e2EquivalentDoseText: recordOnlyOralMedication == nil ? String(format: "%.2f", locale: Locale.current, event.doseMG) : ""
            )

            if recordOnlyOralMedication == nil && event.route == .patchApply {
                if let rate = event.extras[.releaseRateUGPerDay] {
                    initialDraft.patchMode = .releaseRate
                    initialDraft.releaseRateText = String(format: "%.0f", locale: Locale.current, rate)
                    initialDraft.e2EquivalentDoseText = ""
                } else {
                    initialDraft.patchMode = .totalDose
                }
            }

            if recordOnlyOralMedication == nil && event.route == .sublingual {
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
            let recordOnlyOralMedication = seed.template.recordOnlyOralMedication
            var initialDraft = DraftDoseEvent(
                id: nil,
                date: seed.date,
                medicationCategory: DraftMedicationCategory(category: seed.template.category),
                route: seed.template.route,
                ester: seed.template.compound,
                recordOnlyOralMedication: recordOnlyOralMedication ?? .cyproteroneAcetate,
                recordOnlyDoseText: recordOnlyOralMedication == nil ? "" : String(
                    format: "%.2f",
                    locale: Locale.current,
                    seed.template.doseMG
                ),
                rawEsterDoseText: recordOnlyOralMedication == nil && seed.template.compound != .E2 && seed.template.compound != .T ? String(
                    format: "%.2f",
                    locale: Locale.current,
                    seed.template.doseMG / CompoundInfo.by(compound: seed.template.compound).toActiveFactor
                ) : "",
                e2EquivalentDoseText: recordOnlyOralMedication == nil && seed.template.doseMG > 0
                    ? String(format: "%.2f", locale: Locale.current, seed.template.doseMG)
                    : ""
            )

            if recordOnlyOralMedication == nil && seed.template.route == .patchApply {
                if let rate = seed.template.extras[.releaseRateUGPerDay] {
                    initialDraft.patchMode = .releaseRate
                    initialDraft.releaseRateText = String(format: "%.0f", locale: Locale.current, rate)
                    initialDraft.e2EquivalentDoseText = ""
                }
            }

            if recordOnlyOralMedication == nil && seed.template.route == .sublingual {
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
            let initialCategory = DraftMedicationCategory(category: preferredCategory)
            var initialDraft = DraftDoseEvent(medicationCategory: initialCategory)
            let routes = Self.routes(for: initialCategory)
            initialDraft.route = routes.first ?? .oral
            initialDraft.ester = CompoundSupport.availableCompounds(for: preferredCategory, route: initialDraft.route).first ?? .EV
            _draft = State(initialValue: initialDraft)
        }
    }
    
    private static func routes(for category: DraftMedicationCategory) -> [DoseEvent.Route] {
        switch category {
        case .estradiol:
            return [.injection, .patchApply, .patchRemove, .gel, .oral, .sublingual]
        case .testosterone:
            return [.injection, .patchApply, .patchRemove, .gel, .oral]
        case .antiAndrogen:
            return [.oral]
        }
    }

    private var availableRoutes: [DoseEvent.Route] {
        Self.routes(for: draft.medicationCategory)
    }

    private var availableEsters: [Ester] {
        CompoundSupport.availableCompounds(for: draft.medicationCategory.category, route: draft.route)
    }

    // MARK: - Localization helpers for ester names (with English fallback)
    private func esterDefaultName(_ e: Ester) -> String {
        CompoundInfo.by(compound: e).fullName
    }
    private func esterNameText(_ e: Ester) -> Text {
        // Dynamic key: "ester.<abbr>.name", e.g. "ester.EV.name"
        let key = "ester.\(e.abbreviation).name"
        // Use Foundation to resolve localization with a **default value** so English shows even when the key is missing for the current locale.
        let resolved = NSLocalizedString(key, tableName: nil, bundle: .main, value: esterDefaultName(e), comment: "Localized ester name")
        return Text(resolved)
    }

    private var navigationTitleText: String {
        if let navigationTitleOverride, !navigationTitleOverride.isEmpty {
            return navigationTitleOverride
        }

        return draft.id == nil ? String(localized: "input.title.add") : String(localized: "input.title.edit")
    }

    private var resolvedDoseMG: Double? {
        if draft.isRecordOnlyOralMedication {
            return parsedDouble(draft.recordOnlyDoseText)
        }

        if let e2Dose = parsedDouble(draft.e2EquivalentDoseText) {
            return e2Dose
        }

        guard showsRawCompoundDose,
              let rawDose = parsedDouble(draft.rawEsterDoseText) else {
            return nil
        }

        let factor = CompoundInfo.by(compound: draft.ester).toActiveFactor
        return rawDose * factor
    }

    private var activeEquivalentDosePlaceholder: String {
        switch draft.medicationCategory {
        case .estradiol:
            return "Estradiol-equivalent dose (mg)"
        case .testosterone:
            return "Testosterone-equivalent dose (mg)"
        case .antiAndrogen:
            return "Dose (mg)"
        }
    }

    private var showsRawCompoundDose: Bool {
        switch draft.ester {
        case .E2, .T:
            return false
        default:
            return true
        }
    }

    private var canSaveEvent: Bool {
        if draft.route == .patchRemove {
            return true
        }

        if draft.route == .sublingual && draft.useCustomTheta {
            guard let theta = parsedDouble(draft.customThetaText), (0...1).contains(theta) else {
                return false
            }
        }

        if !draft.isRecordOnlyOralMedication && draft.route == .patchApply && draft.patchMode == .releaseRate {
            guard let releaseRate = parsedDouble(draft.releaseRateText) else {
                return false
            }
            return releaseRate > 0
        }

        guard let dose = resolvedDoseMG else {
            return false
        }

        return dose > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                // ... (DatePicker and Route Picker remain the same)
                Section {
                    if showsDatePicker {
                        DatePicker("input.time", selection: $draft.date, displayedComponents: [.date, .hourAndMinute])
                    }
                    Picker("input.medication_type.title", selection: $draft.medicationCategory) {
                        Text("Estradiol").tag(DraftMedicationCategory.estradiol)
                        Text("Testosterone").tag(DraftMedicationCategory.testosterone)
                        Text("Anti-androgen").tag(DraftMedicationCategory.antiAndrogen)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.medicationCategory) { _ in
                        applyMedicationCategoryChange()
                    }

                    if !draft.isRecordOnlyOralMedication {
                        Picker("input.route", selection: $draft.route) {
                            ForEach(availableRoutes, id: \.self) { route in
                                Text(routeLabel(route)).tag(route)
                            }
                        }
                        .onChange(of: draft.route) { _ in
                            if let firstValidEster = availableEsters.first {
                                draft.ester = firstValidEster
                            }
                            draft.rawEsterDoseText = ""
                            draft.e2EquivalentDoseText = ""
                            draft.patchMode = .totalDose
                            draft.releaseRateText = ""
                            draft.slTierIndex = 2
                            draft.useCustomTheta = false
                            draft.customThetaText = ""
                        }
                    } else {
                        Text("input.record_only.help")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !draft.isRecordOnlyOralMedication && draft.route == .patchApply {
                    Section("input.patchMode") {
                        ViewThatFits(in: .horizontal) {
                            Picker("input.patchMode.label", selection: $draft.patchMode) {
                                ForEach(PatchInputMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Picker("input.patchMode.label", selection: $draft.patchMode) {
                                ForEach(PatchInputMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                        }
                        .onChange(of: draft.patchMode) { newValue in
                            focusedField = newValue == .totalDose ? .patchTotal : .patchRelease
                        }
                    }
                }
                
                if draft.route != .patchRemove {
                    Section(draft.isRecordOnlyOralMedication ? "input.record_only.section" : "input.drugDetails") {
                        if draft.isRecordOnlyOralMedication {
                            Picker("input.record_only.medication", selection: $draft.recordOnlyOralMedication) {
                                ForEach(RecordOnlyOralMedication.allCases) { medication in
                                    Text(medication.displayName).tag(medication)
                                }
                            }

                            TextField("input.record_only.dose_mg", text: $draft.recordOnlyDoseText)
                                .keyboardType(.decimalPad)
                                .submitLabel(.done)
                                .focused($focusedField, equals: .recordOnlyDose)
                                .onSubmit { handleSubmit(for: .recordOnlyDose) }
                        } else {
                            if availableEsters.count > 1 {
                                Picker("input.drugEster", selection: $draft.ester) {
                                    ForEach(availableEsters) { e in
                                        esterNameText(e).tag(e)
                                    }
                                }
                                .onChange(of: draft.ester) { _ in
                                    syncDoseTextsAfterEsterChange()
                                }
                            }

                            if draft.route == .patchApply {
                                if draft.patchMode == .totalDose {
                                    TextField(activeEquivalentDosePlaceholder, text: $draft.e2EquivalentDoseText)
                                        .keyboardType(.decimalPad)
                                        .submitLabel(.done)
                                        .focused($focusedField, equals: .patchTotal)
                                        .onSubmit { handleSubmit(for: .patchTotal) }
                                } else {
                                    TextField("input.patchMode.releaseRate", text: $draft.releaseRateText)
                                        .keyboardType(.decimalPad)
                                        .submitLabel(.done)
                                        .focused($focusedField, equals: .patchRelease)
                                        .onSubmit { handleSubmit(for: .patchRelease) }
                                }
                            } else {
                                if showsRawCompoundDose {
                                    TextField(
                                        String(
                                            format: NSLocalizedString("input.dose.raw", comment: "Dose input placeholder"),
                                            locale: Locale.current,
                                            draft.ester.abbreviation
                                        ),
                                        text: $draft.rawEsterDoseText
                                    )
                                    .keyboardType(.decimalPad)
                                    .submitLabel(.done)
                                    .focused($focusedField, equals: .raw)
                                    .onSubmit { handleSubmit(for: .raw) }
                                }
                                TextField(activeEquivalentDosePlaceholder, text: $draft.e2EquivalentDoseText)
                                    .keyboardType(.decimalPad)
                                    .submitLabel(.done)
                                    .focused($focusedField, equals: .activeEquivalent)
                                    .onSubmit { handleSubmit(for: .activeEquivalent) }
                            }
                        }
                    }
                }

                // MARK: Sublingual behavior (θ)
                if !draft.isRecordOnlyOralMedication && draft.medicationCategory == .estradiol && draft.route == .sublingual {
                    Section("input.sublingual") {
                        let tier = [SublingualTier.quick, .casual, .standard, .strict][min(max(draft.slTierIndex, 0), 3)]
                        let hold = SublingualTheta.holdMinutes[tier] ?? 0
                        let theta = SublingualTheta.recommended[tier] ?? 0.11

                        Picker("input.sublingual.hold", selection: $draft.slTierIndex) {
                            Text("input.sublingual.quick").tag(0)
                            Text("input.sublingual.casual").tag(1)
                            Text("input.sublingual.standard").tag(2)
                            Text("input.sublingual.strict").tag(3)
                        }

                        Text(String(format: NSLocalizedString("input.sublingual.suggestion", comment: "Sublingual suggestion"), locale: Locale.current, hold, theta))
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("input.sublingual.instructions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)

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
            .navigationTitle(Text(navigationTitleText))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onCancel?()
                        dismiss()
                    } label: {
                        Text("common.cancel")
                            .fontWeight(.medium)
                            .foregroundStyle(.pink)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Text("common.save")
                            .fontWeight(.semibold)
                            .foregroundStyle(canSaveEvent ? .pink : .secondary)
                    }
                        .disabled(!canSaveEvent)
                }
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
            guard draft.id == nil, autoFocusOnAppear else { return }
            DispatchQueue.main.async {
                if draft.isRecordOnlyOralMedication {
                    focusedField = .recordOnlyDose
                } else if draft.route == .patchApply {
                    focusedField = (draft.patchMode == .totalDose) ? .patchTotal : .patchRelease
                } else if showsRawCompoundDose {
                    // Prefer focusing raw ester input when it's available
                    focusedField = .raw
                } else {
                    focusedField = .activeEquivalent
                }
            }
        }
    }

    // MARK: - Conversion Logic
    private func handleSubmit(for field: FocusedDoseField?) {
        switch field {
        case .raw:
            convertToE2Equivalent()
        case .activeEquivalent, .patchTotal:
            convertToRawEster()
        case .recordOnlyDose:
            break
        case .customTheta, .patchRelease, .none:
            break
        }
    }

    private func convertToE2Equivalent() {
        guard !draft.isRecordOnlyOralMedication else { return }
        guard let rawDose = parsedDouble(draft.rawEsterDoseText) else { return }
        let factor = CompoundInfo.by(compound: draft.ester).toActiveFactor
        draft.e2EquivalentDoseText = String(format: "%.2f", locale: Locale.current, rawDose * factor)
    }

    private func convertToRawEster() {
        guard !draft.isRecordOnlyOralMedication else { return }
        guard showsRawCompoundDose, let e2Dose = parsedDouble(draft.e2EquivalentDoseText) else { return }
        let factor = CompoundInfo.by(compound: draft.ester).toActiveFactor
        draft.rawEsterDoseText = String(format: "%.2f", locale: Locale.current, e2Dose / factor)
    }

    private func syncDoseTextsAfterEsterChange() {
        guard !draft.isRecordOnlyOralMedication else { return }
        if !showsRawCompoundDose {
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

    private func applyMedicationCategoryChange() {
        switch draft.medicationCategory {
        case .estradiol, .testosterone:
            draft.recordOnlyDoseText = ""
            draft.route = availableRoutes.first ?? .oral
            if let firstValidEster = availableEsters.first {
                draft.ester = firstValidEster
            }
        case .antiAndrogen:
            draft.route = .oral
            draft.ester = .E2
            draft.rawEsterDoseText = ""
            draft.e2EquivalentDoseText = ""
            draft.patchMode = .totalDose
            draft.releaseRateText = ""
            draft.slTierIndex = 2
            draft.useCustomTheta = false
            draft.customThetaText = ""
        }
    }

    private func save() {
        guard canSaveEvent else { return }

        var dose = draft.isRecordOnlyOralMedication
            ? (parsedDouble(draft.recordOnlyDoseText) ?? 0)
            : (resolvedDoseMG ?? 0)
        var extras: [DoseEvent.ExtraKey: Double] = [:]

        // zero‑order patch: rate stored separately
        if !draft.isRecordOnlyOralMedication && draft.route == .patchApply && draft.patchMode == .releaseRate {
            dose = 0
            if let rateUG = parsedDouble(draft.releaseRateText) {
                extras[.releaseRateUGPerDay] = rateUG
            }
        }

        // sublingual behavior: either tier code or explicit theta
        if !draft.isRecordOnlyOralMedication && draft.route == .sublingual {
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
            category: draft.medicationCategory.category,
            route: draft.isRecordOnlyOralMedication ? .oral : draft.route,
            // store absolute UTC hours (since 1970) – avoids 2001/01/01 offset
            timeH: draft.date.timeIntervalSince1970 / 3600.0,
            doseMG: dose,
            compound: draft.isRecordOnlyOralMedication ? .E2 : draft.ester,
            extras: extras,
            recordOnlyOralMedication: draft.isRecordOnlyOralMedication ? draft.recordOnlyOralMedication : nil
        )
        onSave(event)
        dismiss()
    }

    private func routeLabel(_ route: DoseEvent.Route) -> String {
        switch route {
        case .injection: return "Injection"
        case .patchApply: return "Patch apply"
        case .patchRemove: return "Patch remove"
        case .gel: return "Gel"
        case .oral: return "Oral"
        case .sublingual: return "Sublingual"
        }
    }
}
