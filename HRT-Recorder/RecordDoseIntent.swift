import AppIntents
import Foundation

enum IntentHormoneCategory: String, AppEnum {
    case estradiol
    case testosterone
    case antiAndrogen

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Medication Category"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .estradiol: "Estradiol",
            .testosterone: "Testosterone",
            .antiAndrogen: "Anti-androgen"
        ]
    }

    var category: MedicationCategory {
        switch self {
        case .estradiol: .estradiol
        case .testosterone: .testosterone
        case .antiAndrogen: .antiAndrogen
        }
    }
}

enum IntentHormone: String, AppEnum {
    case estradiol
    case testosterone

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Hormone"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.estradiol: "Estradiol", .testosterone: "Testosterone"]
    }

    var hormone: SimulatedHormone {
        switch self {
        case .estradiol: .estradiol
        case .testosterone: .testosterone
        }
    }
}

enum IntentDoseRoute: String, AppEnum {
    case injection
    case patchApply
    case patchRemove
    case gel
    case oral
    case sublingual

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dosing Route"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .injection: "Injection",
            .patchApply: "Apply patch",
            .patchRemove: "Remove patch",
            .gel: "Gel",
            .oral: "Oral",
            .sublingual: "Sublingual"
        ]
    }

    var route: DoseEvent.Route {
        DoseEvent.Route(rawValue: rawValue)!
    }
}

enum IntentCompound: String, AppEnum {
    case E2
    case EB
    case EV
    case EC
    case EN
    case T
    case TC
    case TE
    case TU

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Compound"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .E2: "Estradiol (E2)",
            .EB: "Estradiol benzoate (EB)",
            .EV: "Estradiol valerate (EV)",
            .EC: "Estradiol cypionate (EC)",
            .EN: "Estradiol enanthate (EN)",
            .T: "Testosterone (T)",
            .TC: "Testosterone cypionate (TC)",
            .TE: "Testosterone enanthate (TE)",
            .TU: "Testosterone undecanoate (TU)"
        ]
    }

    var compound: Compound { Compound(rawValue: rawValue)! }
}

enum IntentSublingualTier: String, AppEnum {
    case quick
    case casual
    case standard
    case strict

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sublingual Hold"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [.quick: "Quick", .casual: "Casual", .standard: "Standard", .strict: "Strict"]
    }

    var tier: SublingualTier { SublingualTier(rawValue: rawValue)! }
}

enum IntentRecordOnlyMedication: String, AppEnum {
    case cyproteroneAcetate
    case spironolactone
    case bicalutamide
    case finasteride
    case dutasteride

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Record-only Medication"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .cyproteroneAcetate: "Cyproterone acetate",
            .spironolactone: "Spironolactone",
            .bicalutamide: "Bicalutamide",
            .finasteride: "Finasteride",
            .dutasteride: "Dutasteride"
        ]
    }

    var medication: RecordOnlyOralMedication { RecordOnlyOralMedication(rawValue: rawValue)! }
}

/// Captures a phrase as a value request so Siri keeps the current App Intent
/// conversation alive. The phrase is interpreted by Foundation Models after it
/// reaches the app; it is not parsed by a keyword dictionary.
struct IntentDosePhraseEntity: AppEntity, Identifiable, Sendable {
    let id: String
    let text: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dose Phrase"
    static var defaultQuery = IntentDosePhraseQuery()

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        id = trimmed
        self.text = trimmed
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(text)")
    }
}

struct IntentDosePhraseQuery: EntityStringQuery {
    func entities(for identifiers: [IntentDosePhraseEntity.ID]) async throws -> [IntentDosePhraseEntity] {
        identifiers
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(IntentDosePhraseEntity.init)
    }

    func suggestedEntities() async throws -> [IntentDosePhraseEntity] { [] }

    func entities(matching string: String) async throws -> [IntentDosePhraseEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : [IntentDosePhraseEntity(text: trimmed)]
    }
}

struct DoseOptionEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isStale: Bool

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Planned Dose"
    static var defaultQuery = DoseOptionQuery()

    init(option: WidgetDoseOption) {
        id = option.id
        title = option.title
        subtitle = option.subtitle
        isStale = false
    }

    init(id: String, title: String, subtitle: String, isStale: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isStale = isStale
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    var searchTerms: [String] {
        Array(Set([title, subtitle, "planned dose", "计划用药"].map(Self.normalized).filter { !$0.isEmpty })).sorted()
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = Self.normalized(([title, subtitle] + searchTerms).joined(separator: " "))
        return searchableText.contains(normalizedQuery)
            || normalizedQuery.split(separator: " ").allSatisfy { searchableText.contains($0) }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct DoseOptionQuery: EntityStringQuery {
    func entities(for identifiers: [DoseOptionEntity.ID]) async throws -> [DoseOptionEntity] {
        let options = try await MainActor.run { try DoseRecordingService.loadDoseOptions() }
        let byID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })
        return identifiers.map { identifier in
            guard let option = byID[identifier] else {
                return DoseOptionEntity(
                    id: identifier,
                    title: String(localized: "Needs reconfiguration"),
                    subtitle: String(localized: "Choose an available medication plan"),
                    isStale: true
                )
            }
            return DoseOptionEntity(option: option)
        }
    }

    func suggestedEntities() async throws -> [DoseOptionEntity] {
        try await MainActor.run { try DoseRecordingService.loadDoseOptions().map(DoseOptionEntity.init) }
    }

    func entities(matching string: String) async throws -> [DoseOptionEntity] {
        try await suggestedEntities().filter { $0.matches(string) }
    }

    func defaultResult() async -> DoseOptionEntity? {
        // A default here would let a bare Siri request select a future dose.
        // Planned doses must always be selected explicitly.
        nil
    }
}

struct RecordDoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Dose"
    static var description = IntentDescription("Create a reviewed, confirmed dosing record. Natural-language understanding is available on supported iOS 27 devices; structured fields work on older devices.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(title: "Medication", description: "The exact medication or a configured medication plan.")
    var medication: IntentMedicationEntity?

    @Parameter(title: "Category", description: "Estradiol, testosterone, or an anti-androgen.")
    var category: IntentHormoneCategory?

    @Parameter(title: "Route", description: "Injection, oral, sublingual, gel, apply patch, or remove patch.")
    var route: IntentDoseRoute?

    @Parameter(title: "Compound", description: "The exact hormone compound or ester, such as EV, EC, TC, TE, E2, or T.")
    var compound: IntentCompound?

    @Parameter(title: "Dose", description: "Dose amount in milligrams. For esters, provide the raw compound amount.")
    var enteredDoseMG: Double?

    @Parameter(
        title: "Dose Phrase",
        description: "A natural-language dose phrase, interpreted on device and always reviewed before saving.",
        requestValueDialog: "What dose should I record? For example, say 5 milligrams EV by injection."
    )
    var dosePhrase: IntentDosePhraseEntity?

    @Parameter(title: "Active Equivalent Dose", description: "An explicitly stated active-equivalent dose in milligrams.")
    var activeEquivalentDoseMG: Double?

    @Parameter(title: "Record-only Medication", description: "A non-PK oral medication to record.")
    var recordOnlyMedication: IntentRecordOnlyMedication?

    @Parameter(title: "Concentration", description: "Injection concentration in mg/mL when explicitly stated.")
    var concentrationMGmL: Double?

    @Parameter(title: "Volume", description: "Injection volume in mL when explicitly stated.")
    var volumeML: Double?

    @Parameter(title: "Gel Area", description: "Gel application area in square centimeters when explicitly stated.")
    var areaCM2: Double?

    @Parameter(title: "Patch Release Rate", description: "Patch release rate in micrograms per day.")
    var releaseRateUGPerDay: Double?

    @Parameter(title: "Sublingual Hold", description: "Sublingual hold quality.")
    var sublingualTier: IntentSublingualTier?

    @Parameter(title: "Sublingual Theta", description: "Custom sublingual absorption fraction between 0 and 1.")
    var sublingualTheta: Double?

    @Parameter(title: "Time", description: "When the dosing happened. Defaults to now.")
    var recordedAt: Date?

    init() {
        medication = nil
        category = nil
        route = nil
        compound = nil
        enteredDoseMG = nil
        dosePhrase = nil
        activeEquivalentDoseMG = nil
        recordOnlyMedication = nil
        concentrationMGmL = nil
        volumeML = nil
        areaCM2 = nil
        releaseRateUGPerDay = nil
        sublingualTier = nil
        sublingualTheta = nil
        recordedAt = nil
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let mutationID = UUID()
        let occurredAt = recordedAt ?? Date()
        var explicit = makeExplicitFields(recordedAt: occurredAt)
        let plans: [MedicationPlan]
        do {
            plans = try await MainActor.run { try DoseRecordingService.loadMedicationPlans() }
        } catch {
            return .result(dialog: "\(localizedErrorMessage(error, fallback: "I could not read your medication plans."))")
        }
        let context = await MainActor.run { DoseInterpretationContext.make(from: plans) }

        let naturalLanguageAvailable = DoseDraftInterpreter.canInterpretNaturalLanguage
        var phrase = naturalLanguageAvailable
            ? dosePhrase?.text.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        if !naturalLanguageAvailable {
            explicit = try await requestStructuredFallback(starting: explicit)
        }

        for attempt in 0..<2 {
            var interpretation: DoseDraftInterpretation
            if let phrase, !phrase.isEmpty {
                interpretation = await DoseDraftInterpreter.interpret(phrase: phrase, context: context)
            } else {
                interpretation = .candidate(.empty)
            }

            if case .unavailable = interpretation {
                explicit = try await requestStructuredFallback(starting: explicit)
                phrase = nil
                interpretation = .candidate(.empty)
            }

            switch DoseDraftValidator.validate(
                explicit: explicit,
                interpreted: interpretation,
                context: context,
                mutationID: mutationID
            ) {
            case .success(let command):
                try await confirm(command)
                do {
                    let dialog = try await execute(command).dialogText
                    return .result(dialog: "\(dialog)")
                } catch {
                    return .result(dialog: "\(localizedErrorMessage(error, fallback: "I could not record the dose."))")
                }

            case .failure(let message):
                guard attempt == 0, phrase == nil, !hasStructuredValues(explicit) else {
                    return .result(dialog: "\(message)")
                }
                let captured = try await $dosePhrase.requestValue(
                    "What dose should I record? Include the medication, route, and amount—for example, 5 milligrams EV by injection."
                )
                phrase = captured.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return .result(dialog: "I need the medication, route, and dose amount before I can record it.")
    }

    private func requestStructuredFallback(starting initial: DoseDraftFields) async throws -> DoseDraftFields {
        var fields = initial

        if fields.medication == nil,
           fields.compound == nil,
           fields.recordOnlyOralMedication == nil {
            let selected = try await $medication.requestValue(
                "Which exact medication should I record?"
            )
            fields.medication = medicationCandidate(from: selected)
        }

        let medicationRoute: DoseEvent.Route? = fields.recordOnlyOralMedication != nil
            ? .oral
            : fields.medication?.route
        if fields.route == nil, medicationRoute == nil {
            let selected = try await $route.requestValue(
                "How did you take it—by injection, oral, sublingual, gel, applying a patch, or removing a patch?"
            )
            fields.route = selected.route
        }

        switch fields.route ?? medicationRoute {
        case .patchApply:
            if fields.releaseRateUGPerDay == nil {
                fields.releaseRateUGPerDay = try await $releaseRateUGPerDay.requestValue(
                    "What is the patch release rate in micrograms per day?"
                )
            }
        case .patchRemove:
            break
        case .injection:
            if fields.volumeML != nil, fields.concentrationMGmL == nil {
                fields.concentrationMGmL = try await $concentrationMGmL.requestValue(
                    "What is the injection concentration in milligrams per milliliter?"
                )
            }
            if fields.enteredDoseMG == nil,
               fields.activeEquivalentDoseMG == nil,
               !(fields.concentrationMGmL != nil && fields.volumeML != nil) {
                fields.enteredDoseMG = try await $enteredDoseMG.requestValue(
                    "What is the dose amount in milligrams?"
                )
            }
        case .gel, .oral, .sublingual, .none:
            if fields.enteredDoseMG == nil,
               fields.activeEquivalentDoseMG == nil,
               !(fields.concentrationMGmL != nil && fields.volumeML != nil) {
                fields.enteredDoseMG = try await $enteredDoseMG.requestValue(
                    "What is the dose amount in milligrams?"
                )
            }
        }
        return fields
    }

    private func makeExplicitFields(recordedAt: Date) -> DoseDraftFields {
        let medicationCandidate = medication.map(medicationCandidate(from:))
        return DoseDraftFields(
            medication: medicationCandidate,
            category: category?.category,
            route: route?.route,
            compound: compound?.compound,
            recordOnlyOralMedication: recordOnlyMedication?.medication,
            enteredDoseMG: enteredDoseMG,
            activeEquivalentDoseMG: activeEquivalentDoseMG,
            concentrationMGmL: concentrationMGmL,
            volumeML: volumeML,
            areaCM2: areaCM2,
            releaseRateUGPerDay: releaseRateUGPerDay,
            sublingualTier: sublingualTier?.tier,
            sublingualTheta: sublingualTheta,
            recordedAt: recordedAt,
            recordedAtWasExplicit: self.recordedAt != nil
        )
    }

    private func medicationCandidate(from entity: IntentMedicationEntity) -> DoseMedicationCandidate {
        DoseMedicationCandidate(
            token: "explicit",
            identifier: entity.id,
            displayName: entity.title,
            category: entity.category,
            route: entity.route,
            compound: entity.compound,
            recordOnlyOralMedication: entity.recordOnlyOralMedication
        )
    }

    private func hasStructuredValues(_ fields: DoseDraftFields) -> Bool {
        fields.medication != nil || fields.category != nil || fields.route != nil || fields.compound != nil ||
            fields.recordOnlyOralMedication != nil || fields.enteredDoseMG != nil || fields.activeEquivalentDoseMG != nil ||
            fields.concentrationMGmL != nil || fields.volumeML != nil || fields.areaCM2 != nil || fields.releaseRateUGPerDay != nil ||
            fields.sublingualTier != nil || fields.sublingualTheta != nil
    }

    private func confirm(_ command: DoseRecordCommand) async throws {
        if #available(iOS 18.0, *) {
            try await requestConfirmation(
                conditions: [],
                actionName: .log,
                dialog: IntentDialog(stringLiteral: command.confirmationDialog)
            )
        } else {
            try await requestConfirmation()
        }
    }

    private func execute(_ command: DoseRecordCommand) async throws -> RecordedDoseSummary {
        switch command {
        case .planned(let optionID, _, _, let recordedAt, let mutationID, let fingerprint):
            return try await DoseRecordingService.recordDose(
                optionID: optionID,
                at: recordedAt,
                mutationID: mutationID,
                fingerprint: fingerprint
            )
        case .custom(let request, let mutationID, let fingerprint):
            return try await DoseRecordingService.recordDose(
                request,
                mutationID: mutationID,
                fingerprint: fingerprint
            )
        }
    }
}

struct RecordPlannedDoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Planned Dose"
    static var description = IntentDescription("Record a selected dose from an active medication plan.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(
        title: "Planned Dose",
        requestValueDialog: "Please specify which active planned dose to record."
    )
    var doseOption: DoseOptionEntity

    @Parameter(title: "Time")
    var recordedAt: Date?

    init() {
        recordedAt = nil
    }

    init(doseOption: DoseOptionEntity, recordedAt: Date? = nil) {
        self.doseOption = doseOption
        self.recordedAt = recordedAt
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !doseOption.id.isEmpty, !doseOption.isStale else {
            return .result(dialog: "Choose an active planned dose first.")
        }

        let occurredAt = recordedAt ?? Date()
        let mutationID = UUID()
        let fingerprint = DoseStore.fingerprint(for: [
            "planned", doseOption.id, String(Int(occurredAt.timeIntervalSince1970 / 30))
        ])
        if #available(iOS 18.0, *) {
            let confirmation = String.localizedStringWithFormat(
                String(localized: "Record %@ (%@) at %@?"),
                doseOption.title,
                doseOption.subtitle,
                occurredAt.formatted(date: .omitted, time: .shortened)
            )
            try await requestConfirmation(
                conditions: [],
                actionName: .log,
                dialog: IntentDialog(stringLiteral: confirmation)
            )
        } else {
            try await requestConfirmation()
        }

        do {
            let dialog = try await DoseRecordingService.recordDose(
                optionID: doseOption.id,
                at: occurredAt,
                mutationID: mutationID,
                fingerprint: fingerprint
            ).dialogText
            return .result(dialog: "\(dialog)")
        } catch {
            return .result(dialog: "\(localizedErrorMessage(error, fallback: "I could not record the planned dose."))")
        }
    }
}

struct GetHormoneConcentrationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Hormone Concentration"
    static var description = IntentDescription("Read an estimated hormone concentration from HRT Recorder.")
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    @Parameter(
        title: "Hormone",
        requestValueDialog: "Which hormone should I check—estradiol or testosterone?"
    )
    var hormone: IntentHormone?

    @Parameter(title: "Time")
    var measuredAt: Date?

    init() {
        hormone = nil
        measuredAt = nil
    }

    init(hormone: IntentHormone, measuredAt: Date? = nil) {
        self.hormone = hormone
        self.measuredAt = measuredAt
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let resolvedHormone = hormone?.hormone ?? HRTProfilePreferences().confirmedHormone else {
            let message = String(localized: "Choose your HRT type in HRT Recorder before asking for a hormone level.")
            return .result(value: message, dialog: "\(message)")
        }

        do {
            let measuredAt = measuredAt ?? Date()
            let dialog = try await MainActor.run {
                try DoseRecordingService.hormoneConcentration(for: resolvedHormone, at: measuredAt).dialogText
            }
            return .result(value: dialog, dialog: "\(dialog)")
        } catch {
            let message = localizedErrorMessage(error, fallback: "I could not read the hormone concentration.")
            return .result(value: message, dialog: "\(message)")
        }
    }
}

struct HRTRecorderAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordDoseIntent(),
            phrases: [
                "Record a dose in \(.applicationName)",
                "Log my dose in \(.applicationName)",
                "Record my dosing in \(.applicationName)",
                "Log dosing in \(.applicationName)",
                "Record \(\.$dosePhrase) in \(.applicationName)",
                "Log \(\.$dosePhrase) in \(.applicationName)",
                "在 \(.applicationName) 记录用药",
                "在 \(.applicationName) 记录 \(\.$dosePhrase)"
            ],
            shortTitle: "Record Dose",
            systemImageName: "pills.fill"
        )

        AppShortcut(
            intent: RecordPlannedDoseIntent(),
            phrases: [
                "Record a planned dose in \(.applicationName)",
                "Log my planned dose in \(.applicationName)",
                "在 \(.applicationName) 记录计划用药"
            ],
            shortTitle: "Record Planned Dose",
            systemImageName: "calendar.badge.plus"
        )

        AppShortcut(
            intent: GetHormoneConcentrationIntent(),
            phrases: [
                "Check my hormone level in \(.applicationName)",
                "Get my hormone concentration in \(.applicationName)",
                "What's my \(\.$hormone) level in \(.applicationName)",
                "Check \(\.$hormone) level in \(.applicationName)",
                "用 \(.applicationName) 查看激素浓度"
            ],
            shortTitle: "Hormone Level",
            systemImageName: "waveform.path.ecg"
        )
    }
}

private nonisolated func localizedErrorMessage(_ error: Error, fallback: String) -> String {
    (error as? LocalizedError)?.errorDescription ?? fallback
}
