import Foundation

/// A constrained, non-clinical draft extracted from a Siri-provided phrase.
/// It is intentionally not a `DoseEvent`: only the validator below may turn a
/// draft into a write command.
struct DoseDraftFields {
    var medication: DoseMedicationCandidate?
    var category: MedicationCategory?
    var route: DoseEvent.Route?
    var compound: Compound?
    var recordOnlyOralMedication: RecordOnlyOralMedication?
    var enteredDoseMG: Double?
    var activeEquivalentDoseMG: Double?
    var concentrationMGmL: Double?
    var volumeML: Double?
    var areaCM2: Double?
    var releaseRateUGPerDay: Double?
    var sublingualTier: SublingualTier?
    var sublingualTheta: Double?
    var recordedAt: Date
    var recordedAtWasExplicit: Bool

    static func empty(recordedAt: Date) -> DoseDraftFields {
        DoseDraftFields(recordedAt: recordedAt, recordedAtWasExplicit: false)
    }
}

struct DoseMedicationCandidate {
    let token: String
    let identifier: String
    let displayName: String
    let category: MedicationCategory
    let route: DoseEvent.Route?
    let compound: Compound?
    let recordOnlyOralMedication: RecordOnlyOralMedication?
}

struct DosePlanCandidate {
    let token: String
    let optionID: String
    let displayName: String
    let summary: String
}

struct DoseInterpretationContext {
    let activePlans: [DosePlanCandidate]
    let medications: [DoseMedicationCandidate]

    static func make(from plans: [MedicationPlan]) -> DoseInterpretationContext {
        let activePlans = plans.filter(\.isEnabled)
        let options = WidgetSnapshotCoordinator.makeDoseOptions(from: activePlans)
        let planCandidates = options.enumerated().map { index, option in
            DosePlanCandidate(
                token: "p\(index)",
                optionID: option.id,
                displayName: option.title,
                summary: option.subtitle
            )
        }

        var candidates: [DoseMedicationCandidate] = []
        for plan in activePlans {
            let template = plan.primaryTemplate
            candidates.append(
                DoseMedicationCandidate(
                    token: "",
                    identifier: "plan:\(plan.id.uuidString)",
                    displayName: plan.displayName,
                    category: template.category,
                    route: template.recordOnlyOralMedication == nil ? template.route : .oral,
                    compound: template.recordOnlyOralMedication == nil ? template.compound : nil,
                    recordOnlyOralMedication: template.recordOnlyOralMedication
                )
            )
        }

        for compound in Compound.allCases {
            let info = CompoundInfo.by(compound: compound)
            candidates.append(
                DoseMedicationCandidate(
                    token: "",
                    identifier: "compound:\(compound.rawValue)",
                    displayName: "\(info.fullName) (\(compound.abbreviation))",
                    category: compound.medicationCategory,
                    route: nil,
                    compound: compound,
                    recordOnlyOralMedication: nil
                )
            )
        }

        for medication in RecordOnlyOralMedication.allCases {
            candidates.append(
                DoseMedicationCandidate(
                    token: "",
                    identifier: "record-only:\(medication.rawValue)",
                    displayName: medication.displayName,
                    category: .antiAndrogen,
                    route: .oral,
                    compound: nil,
                    recordOnlyOralMedication: medication
                )
            )
        }

        let tokenizedMedications = candidates.enumerated().map { index, candidate in
            DoseMedicationCandidate(
                token: "m\(index)",
                identifier: candidate.identifier,
                displayName: candidate.displayName,
                category: candidate.category,
                route: candidate.route,
                compound: candidate.compound,
                recordOnlyOralMedication: candidate.recordOnlyOralMedication
            )
        }
        return DoseInterpretationContext(activePlans: planCandidates, medications: tokenizedMedications)
    }
}

struct ModelDoseDraft {
    var action: String?
    var planToken: String?
    var medicationToken: String?
    var route: String?
    var amount: Double?
    var amountUnit: String?
    var concentrationMGmL: Double?
    var volumeML: Double?
    var areaCM2: Double?
    var releaseRateUGPerDay: Double?
    var activeEquivalentMG: Double?
    var sublingualTier: String?
    var sublingualTheta: Double?
    var recordedAtISO8601: String?

    nonisolated static let empty = ModelDoseDraft()
}

enum DoseDraftInterpretation {
    case candidate(ModelDoseDraft)
    case unavailable
    case needsReview(String)
}

protocol DoseDraftInterpreting {
    func interpret(
        phrase: String,
        context: DoseInterpretationContext
    ) async -> DoseDraftInterpretation
}

enum DoseDraftInterpreter {
    nonisolated static var canInterpretNaturalLanguage: Bool {
        #if os(iOS) && canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return FoundationModelDoseDraftInterpreter.isAvailable
        }
        #endif
        return false
    }

    static func interpret(
        phrase: String,
        context: DoseInterpretationContext
    ) async -> DoseDraftInterpretation {
        #if os(iOS) && canImport(FoundationModels)
        // Keep the Foundation Models feature boundary intentionally stricter
        // than the framework's SDK availability. The product enables semantic
        // dose interpretation only on iOS 27+, while every older OS continues
        // through the structured App Intent path below.
        if #available(iOS 27.0, *) {
            return await FoundationModelDoseDraftInterpreter().interpret(phrase: phrase, context: context)
        }
        #endif
        return .unavailable
    }
}

enum DoseRecordCommand {
    case planned(
        optionID: String,
        planTitle: String,
        planSummary: String,
        recordedAt: Date,
        mutationID: UUID,
        fingerprint: String
    )
    case custom(request: CustomDoseRecordingRequest, mutationID: UUID, fingerprint: String)

    var confirmationDialog: String {
        switch self {
        case .planned(_, let planTitle, let planSummary, let recordedAt, _, _):
            return String.localizedStringWithFormat(
                String(localized: "Record %@ (%@) at %@?"),
                planTitle,
                planSummary,
                recordedAt.formatted(date: .omitted, time: .shortened)
            )
        case .custom(let request, _, _):
            var details: [String] = []
            if let medication = request.recordOnlyOralMedication {
                details.append(medication.displayName)
            } else if let releaseRate = request.releaseRateUGPerDay {
                details.append(request.compound?.abbreviation ?? "patch")
                details.append("\(Self.number(releaseRate)) mcg/day")
            } else if request.route == .patchRemove {
                details.append("remove \(request.compound?.abbreviation ?? "the") patch")
            } else {
                details.append(request.compound?.abbreviation ?? "medication")
            }
            if let entered = request.enteredDoseMG {
                details.append("\(Self.number(entered)) mg raw dose")
            }
            if let active = request.activeEquivalentDoseMG {
                details.append("\(Self.number(active)) mg active equivalent")
            }
            if let route = request.route {
                details.append(route.planLabel)
            }
            if let concentration = request.concentrationMGmL {
                if let volume = request.volumeML {
                    details.append("\(Self.number(volume)) mL × \(Self.number(concentration)) mg/mL")
                } else {
                    details.append("\(Self.number(concentration)) mg/mL")
                }
            }
            if let area = request.areaCM2 {
                details.append("\(Self.number(area)) cm²")
            }
            if let tier = request.sublingualTier {
                details.append("sublingual \(tier.rawValue) hold")
            }
            if let theta = request.sublingualTheta {
                details.append("sublingual fraction \(Self.number(theta))")
            }
            return String.localizedStringWithFormat(
                String(localized: "Record %@ at %@?"),
                details.joined(separator: ", "),
                request.recordedAt.formatted(date: .omitted, time: .shortened)
            )
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6g", locale: Locale.current, value)
    }
}

enum DoseDraftValidationResult {
    case success(DoseRecordCommand)
    case failure(String)
}

enum DoseDraftValidator {
    nonisolated static func validate(
        explicit: DoseDraftFields,
        interpreted: DoseDraftInterpretation,
        context: DoseInterpretationContext,
        mutationID: UUID
    ) -> DoseDraftValidationResult {
        let model: ModelDoseDraft
        switch interpreted {
        case .candidate(let value):
            model = value
        case .unavailable:
            // Typed App Intent fields remain usable on older devices. A free
            // phrase alone must be reviewed in the app rather than run through
            // a hidden regex parser.
            if hasExplicitMedicationOrDose(explicit) {
                model = .empty
            } else {
                return .failure(String(localized: "Apple Intelligence is unavailable. Please use the structured dose fields or review the dose in HRT Recorder."))
            }
        case .needsReview(let message):
            return .failure(message)
        }

        let resolvedRecordedAt: Date
        if let modelTimestamp = nonNone(model.recordedAtISO8601) {
            guard let modelDate = parseISO8601Date(modelTimestamp) else {
                return .failure(String(localized: "I could not verify the spoken dose time. Please choose the time explicitly."))
            }
            if explicit.recordedAtWasExplicit,
               abs(explicit.recordedAt.timeIntervalSince(modelDate)) > 60 {
                return .failure(String(localized: "The selected time conflicts with the spoken time. Please review it before recording."))
            }
            resolvedRecordedAt = explicit.recordedAtWasExplicit ? explicit.recordedAt : modelDate
        } else {
            resolvedRecordedAt = explicit.recordedAt
        }
        guard resolvedRecordedAt <= Date().addingTimeInterval(5 * 60) else {
            return .failure(String(localized: "Use the current time or a past time for a dose record."))
        }

        let modelAction = nonNone(model.action)
        if let planToken = nonNone(model.planToken) {
            guard modelAction == "planned" else {
                return .failure(String(localized: "The requested action conflicts with the selected plan. Please choose planned or custom dosing again."))
            }
            guard let plan = context.activePlans.first(where: { $0.token == planToken }) else {
                return .failure(String(localized: "I could not verify that medication plan. Please choose an active plan again."))
            }
            guard !hasCustomValues(explicit), !modelHasCustomValues(model) else {
                return .failure(String(localized: "That phrase mixes a planned dose with custom dose details. Please choose one before recording."))
            }
            return .success(
                .planned(
                    optionID: plan.optionID,
                    planTitle: plan.displayName,
                    planSummary: plan.summary,
                    recordedAt: resolvedRecordedAt,
                    mutationID: mutationID,
                    fingerprint: fingerprint(
                        kind: "planned",
                        values: [plan.optionID, roundedTime(resolvedRecordedAt)]
                    )
                )
            )
        }

        if modelAction == "planned" {
            return .failure(String(localized: "Please specify which active planned dose to record."))
        }

        guard modelAction != "clarify" else {
            return .failure(String(localized: "I need a specific medication, route, and dose before I can record it."))
        }
        if let modelAction, modelAction != "custom" {
            return .failure(String(localized: "I could not verify whether this is a planned or custom dose."))
        }

        let modelMedication = nonNone(model.medicationToken).flatMap { token in
            context.medications.first(where: { $0.token == token })
        }
        if nonNone(model.medicationToken) != nil, modelMedication == nil {
            return .failure(String(localized: "I could not verify that medication. Please choose it again."))
        }
        if let explicitMedication = explicit.medication,
           let modelMedication,
           explicitMedication.identifier != modelMedication.identifier {
            return .failure(String(localized: "The selected medication conflicts with the spoken medication. Please review it before recording."))
        }

        let medication = explicit.medication ?? modelMedication
        if let medication {
            if let selectedCategory = explicit.category, selectedCategory != medication.category {
                return .failure(String(localized: "The selected medication conflicts with the hormone category. Please review it before recording."))
            }
            if let selectedRoute = explicit.route,
               let medicationRoute = medication.route,
               selectedRoute != medicationRoute {
                return .failure(String(localized: "The selected medication conflicts with the dosing route. Please review it before recording."))
            }
            if let selectedCompound = explicit.compound {
                guard medication.recordOnlyOralMedication == nil,
                      medication.compound == nil || medication.compound == selectedCompound else {
                    return .failure(String(localized: "The selected medication conflicts with the compound. Please review it before recording."))
                }
            }
            if let selectedRecordOnly = explicit.recordOnlyOralMedication {
                guard medication.compound == nil,
                      medication.recordOnlyOralMedication == nil || medication.recordOnlyOralMedication == selectedRecordOnly else {
                    return .failure(String(localized: "The selected record-only medication conflicts with the medication. Please review it before recording."))
                }
            }
        }
        var category = explicit.category ?? medication?.category
        var route = explicit.route ?? medication?.route
        var compound = explicit.compound ?? medication?.compound
        let recordOnly = explicit.recordOnlyOralMedication ?? medication?.recordOnlyOralMedication

        if let modelRoute = resolvedRoute(from: model.route) {
            if let route, route != modelRoute {
                return .failure(String(localized: "The selected route conflicts with the spoken route. Please review it before recording."))
            }
            route = modelRoute
        } else if nonNone(model.route) != nil {
            return .failure(String(localized: "I could not verify the dosing route. Please choose it again."))
        }

        if let compound, let category, compound.medicationCategory != category {
            return .failure(String(localized: "The medication category does not match the selected compound."))
        }

        if recordOnly != nil {
            if let category, category != .antiAndrogen {
                return .failure(String(localized: "A record-only medication cannot be combined with that hormone category."))
            }
            if let route, route != .oral {
                return .failure(String(localized: "Record-only medications can only be recorded as oral medications."))
            }
            category = .antiAndrogen
            route = .oral
            compound = nil
        } else {
            guard let resolvedCompound = compound else {
                return .failure(String(localized: "Please specify the exact medication or compound. I will not guess it."))
            }
            compound = resolvedCompound
            category = category ?? resolvedCompound.medicationCategory
        }

        guard let resolvedRoute = route else {
            return .failure(String(localized: "Please specify the dosing route. I will not guess it."))
        }

        if model.amount != nil,
           !["mg", "mcg", "mL"].contains(model.amountUnit ?? "") {
            return .failure(String(localized: "Please say the dose unit explicitly as mg, mcg, or mL."))
        }
        let modelAmountMG = amountMG(from: model)
        let modelVolume: Double?
        if model.amountUnit == "mL" {
            if let statedVolume = model.volumeML,
               let amount = model.amount,
               !approximatelyEqual(statedVolume, amount) {
                return .failure(String(localized: "The spoken volume is inconsistent. Please review it before recording."))
            }
            modelVolume = model.volumeML ?? model.amount
        } else {
            modelVolume = model.volumeML
        }
        if let explicitDose = explicit.enteredDoseMG,
           let modelAmountMG,
           !approximatelyEqual(explicitDose, modelAmountMG) {
            return .failure(String(localized: "The selected dose conflicts with the spoken dose. Please review it before recording."))
        }
        if let explicitConcentration = explicit.concentrationMGmL,
           let modelConcentration = model.concentrationMGmL,
           !approximatelyEqual(explicitConcentration, modelConcentration) {
            return .failure(String(localized: "The selected concentration conflicts with the spoken concentration. Please review it before recording."))
        }
        if conflicting(explicit.activeEquivalentDoseMG, model.activeEquivalentMG) {
            return .failure(String(localized: "The selected equivalent dose conflicts with the spoken equivalent dose. Please review it before recording."))
        }
        if conflicting(explicit.volumeML, modelVolume) {
            return .failure(String(localized: "The selected volume conflicts with the spoken volume. Please review it before recording."))
        }
        if conflicting(explicit.areaCM2, model.areaCM2) {
            return .failure(String(localized: "The selected gel area conflicts with the spoken gel area. Please review it before recording."))
        }
        if conflicting(explicit.releaseRateUGPerDay, model.releaseRateUGPerDay) {
            return .failure(String(localized: "The selected patch release rate conflicts with the spoken release rate. Please review it before recording."))
        }
        if conflicting(explicit.sublingualTheta, model.sublingualTheta) {
            return .failure(String(localized: "The selected sublingual fraction conflicts with the spoken fraction. Please review it before recording."))
        }

        let modelTier = sublingualTier(from: model.sublingualTier)
        if nonNone(model.sublingualTier) != nil, modelTier == nil {
            return .failure(String(localized: "I could not verify the sublingual hold setting. Please choose it again."))
        }
        if let explicitTier = explicit.sublingualTier,
           let modelTier,
           explicitTier != modelTier {
            return .failure(String(localized: "The selected sublingual hold conflicts with the spoken hold. Please review it before recording."))
        }

        let concentration = explicit.concentrationMGmL ?? model.concentrationMGmL
        let volume = explicit.volumeML ?? modelVolume
        var enteredDoseMG = explicit.enteredDoseMG ?? modelAmountMG
        if let concentration, !validPositive(concentration, upperBound: 1_000) {
            return .failure(String(localized: "The concentration is outside a safe recording range."))
        }
        if let volume, !validPositive(volume, upperBound: 100) {
            return .failure(String(localized: "The volume is outside a safe recording range."))
        }
        if volume != nil, concentration == nil {
            return .failure(String(localized: "Please provide the concentration in mg/mL with a volume dose."))
        }
        if let concentration, let volume {
            let calculatedDose = concentration * volume
            if let enteredDoseMG, !approximatelyEqual(enteredDoseMG, calculatedDose) {
                return .failure(String(localized: "The dose does not match the stated concentration and volume. Please review it before recording."))
            }
            enteredDoseMG = calculatedDose
        }

        let activeEquivalent = explicit.activeEquivalentDoseMG ?? model.activeEquivalentMG
        if let enteredDoseMG, !validPositive(enteredDoseMG, upperBound: 10_000) {
            return .failure(String(localized: "The dose amount is outside a safe recording range."))
        }
        if let activeEquivalent, !validPositive(activeEquivalent, upperBound: 10_000) {
            return .failure(String(localized: "The equivalent dose is outside a safe recording range."))
        }
        if recordOnly != nil, activeEquivalent != nil {
            return .failure(String(localized: "A record-only medication does not use an active-equivalent dose."))
        }
        if let enteredDoseMG, let activeEquivalent, let compound {
            let expectedActive = enteredDoseMG * CompoundInfo.by(compound: compound).toActiveFactor
            guard approximatelyEquivalent(activeEquivalent, expectedActive) else {
                return .failure(String(localized: "The raw dose and active-equivalent dose do not describe the same amount."))
            }
        }

        let releaseRate = explicit.releaseRateUGPerDay ?? model.releaseRateUGPerDay
        if let releaseRate, !validPositive(releaseRate, upperBound: 10_000) {
            return .failure(String(localized: "The patch release rate is outside a safe recording range."))
        }

        let tier = explicit.sublingualTier ?? modelTier
        let theta = explicit.sublingualTheta ?? model.sublingualTheta
        if let theta, !theta.isFinite || !(0...1).contains(theta) {
            return .failure(String(localized: "The sublingual absorption fraction must be between 0 and 1."))
        }
        let area = explicit.areaCM2 ?? model.areaCM2
        if let area, !validPositive(area, upperBound: 10_000) {
            return .failure(String(localized: "The gel application area is outside a safe recording range."))
        }

        switch resolvedRoute {
        case .injection:
            guard area == nil, releaseRate == nil, tier == nil, theta == nil else {
                return .failure(String(localized: "Those extra dose details do not apply to an injection."))
            }
            guard enteredDoseMG != nil || activeEquivalent != nil else {
                return .failure(String(localized: "Please provide the dose amount to record."))
            }
        case .gel:
            guard concentration == nil, volume == nil, releaseRate == nil, tier == nil, theta == nil else {
                return .failure(String(localized: "Those extra dose details do not apply to a gel dose."))
            }
            guard enteredDoseMG != nil || activeEquivalent != nil else {
                return .failure(String(localized: "Please provide the dose amount to record."))
            }
        case .oral:
            guard concentration == nil, volume == nil, area == nil, releaseRate == nil, tier == nil, theta == nil else {
                return .failure(String(localized: "Those extra dose details do not apply to an oral dose."))
            }
            guard enteredDoseMG != nil || activeEquivalent != nil else {
                return .failure(String(localized: "Please provide the dose amount to record."))
            }
        case .sublingual:
            guard concentration == nil, volume == nil, area == nil, releaseRate == nil else {
                return .failure(String(localized: "Those extra dose details do not apply to a sublingual dose."))
            }
            guard tier == nil || theta == nil else {
                return .failure(String(localized: "Choose either a sublingual hold setting or a custom fraction, not both."))
            }
            guard enteredDoseMG != nil || activeEquivalent != nil else {
                return .failure(String(localized: "Please provide the dose amount to record."))
            }
        case .patchApply:
            guard releaseRate != nil else {
                return .failure(String(localized: "Please provide the patch release rate in micrograms per day."))
            }
            guard enteredDoseMG == nil, activeEquivalent == nil,
                  concentration == nil, volume == nil, area == nil, tier == nil, theta == nil else {
                return .failure(String(localized: "A patch release rate cannot be combined with other dose details."))
            }
        case .patchRemove:
            guard enteredDoseMG == nil, activeEquivalent == nil, releaseRate == nil,
                  concentration == nil, volume == nil, area == nil, tier == nil, theta == nil else {
                return .failure(String(localized: "Removing a patch should not include dose details."))
            }
        }

        guard let resolvedCategory = category else {
            return .failure(String(localized: "Please specify the exact medication before recording."))
        }
        let finalCompound: Compound?
        if recordOnly == nil {
            guard let compound else {
                return .failure(String(localized: "Please specify the exact medication before recording."))
            }
            guard CompoundSupport.availableCompounds(for: resolvedCategory, route: resolvedRoute).contains(compound) else {
                return .failure(String(localized: "That compound is not supported for the selected route."))
            }
            finalCompound = compound
        } else {
            finalCompound = nil
        }

        let request = CustomDoseRecordingRequest(
            category: resolvedCategory,
            route: resolvedRoute,
            enteredDoseMG: enteredDoseMG,
            activeEquivalentDoseMG: activeEquivalent,
            compound: finalCompound,
            recordOnlyOralMedication: recordOnly,
            concentrationMGmL: concentration,
            volumeML: volume,
            areaCM2: area,
            releaseRateUGPerDay: releaseRate,
            sublingualTier: tier,
            sublingualTheta: theta,
            recordedAt: resolvedRecordedAt
        )
        let fingerprintValues = [
            "custom",
            resolvedCategory.rawValue,
            resolvedRoute.rawValue,
            finalCompound?.rawValue ?? "",
            recordOnly?.rawValue ?? "",
            decimal(enteredDoseMG),
            decimal(activeEquivalent),
            decimal(concentration),
            decimal(volume),
            decimal(area),
            decimal(releaseRate),
            tier?.rawValue ?? "",
            decimal(theta),
            roundedTime(resolvedRecordedAt)
        ]
        return .success(
            .custom(
                request: request,
                mutationID: mutationID,
                fingerprint: fingerprint(kind: "custom", values: fingerprintValues)
            )
        )
    }

    private nonisolated static func hasExplicitMedicationOrDose(_ fields: DoseDraftFields) -> Bool {
        fields.medication != nil || fields.category != nil || fields.route != nil || fields.compound != nil ||
            fields.recordOnlyOralMedication != nil || fields.enteredDoseMG != nil || fields.activeEquivalentDoseMG != nil ||
            fields.concentrationMGmL != nil || fields.volumeML != nil || fields.releaseRateUGPerDay != nil
    }

    private nonisolated static func hasCustomValues(_ fields: DoseDraftFields) -> Bool {
        hasExplicitMedicationOrDose(fields) || fields.areaCM2 != nil || fields.sublingualTier != nil || fields.sublingualTheta != nil
    }

    private nonisolated static func modelHasCustomValues(_ draft: ModelDoseDraft) -> Bool {
        nonNone(draft.medicationToken) != nil || nonNone(draft.route) != nil || draft.amount != nil ||
            draft.concentrationMGmL != nil || draft.volumeML != nil || draft.areaCM2 != nil ||
            draft.releaseRateUGPerDay != nil || draft.activeEquivalentMG != nil ||
            nonNone(draft.sublingualTier) != nil || draft.sublingualTheta != nil
    }

    private nonisolated static func amountMG(from draft: ModelDoseDraft) -> Double? {
        guard let amount = draft.amount else { return nil }
        switch draft.amountUnit {
        case "mg":
            return amount
        case "mcg":
            return amount / 1_000
        default:
            return nil
        }
    }

    private nonisolated static func resolvedRoute(from rawValue: String?) -> DoseEvent.Route? {
        guard let rawValue, rawValue != "unspecified" else { return nil }
        return DoseEvent.Route(rawValue: rawValue)
    }

    private nonisolated static func sublingualTier(from rawValue: String?) -> SublingualTier? {
        guard let rawValue else { return nil }
        return SublingualTier(rawValue: rawValue)
    }

    private nonisolated static func nonNone(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "__none__", value != "unspecified" else { return nil }
        return value
    }

    private nonisolated static func validPositive(_ value: Double, upperBound: Double) -> Bool {
        value.isFinite && value > 0 && value <= upperBound
    }

    private nonisolated static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(0.001, max(abs(lhs), abs(rhs)) * 0.001)
    }

    private nonisolated static func approximatelyEquivalent(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(0.01, max(abs(lhs), abs(rhs)) * 0.02)
    }

    private nonisolated static func conflicting(_ explicit: Double?, _ interpreted: Double?) -> Bool {
        guard let explicit, let interpreted else { return false }
        return !approximatelyEqual(explicit, interpreted)
    }

    private nonisolated static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private nonisolated static func roundedTime(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970 / 30))
    }

    private nonisolated static func decimal(_ value: Double?) -> String {
        value.map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? ""
    }

    private nonisolated static func fingerprint(kind: String, values: [String]) -> String {
        DoseStore.fingerprint(for: [kind] + values)
    }
}

#if os(iOS) && canImport(FoundationModels)
import FoundationModels

@available(iOS 27.0, *)
private struct FoundationModelDoseDraftInterpreter: DoseDraftInterpreting {
    nonisolated static var isAvailable: Bool {
        let model = SystemLanguageModel.default
        return model.isAvailable && model.supportsLocale(.current)
    }

    func interpret(
        phrase: String,
        context: DoseInterpretationContext
    ) async -> DoseDraftInterpretation {
        let model = SystemLanguageModel.default
        guard Self.isAvailable else { return .unavailable }

        do {
            let none = "__none__"
            let planTokens = [none] + context.activePlans.map(\.token)
            let medicationTokens = [none] + context.medications.map(\.token)
            let root = DynamicGenerationSchema(
                name: "DoseDraft",
                description: "A dose-recording draft. It is not medical advice and never records anything.",
                properties: [
                    .init(name: "action", schema: .init(name: "Action", anyOf: ["planned", "custom", "clarify"])),
                    .init(name: "planToken", schema: .init(name: "Plan", anyOf: planTokens), isOptional: true),
                    .init(name: "medicationToken", schema: .init(name: "Medication", anyOf: medicationTokens), isOptional: true),
                    .init(name: "route", schema: .init(name: "Route", anyOf: ["unspecified", "injection", "patchApply", "patchRemove", "gel", "oral", "sublingual"]), isOptional: true),
                    .init(name: "amount", schema: .init(type: Double.self, guides: [.range(0...10_000)]), isOptional: true),
                    .init(name: "amountUnit", schema: .init(name: "Unit", anyOf: ["unspecified", "mg", "mcg", "mL"]), isOptional: true),
                    .init(name: "concentrationMGmL", schema: .init(type: Double.self, guides: [.range(0...1_000)]), isOptional: true),
                    .init(name: "volumeML", schema: .init(type: Double.self, guides: [.range(0...100)]), isOptional: true),
                    .init(name: "areaCM2", schema: .init(type: Double.self, guides: [.range(0...10_000)]), isOptional: true),
                    .init(name: "releaseRateUGPerDay", schema: .init(type: Double.self, guides: [.range(0...10_000)]), isOptional: true),
                    .init(name: "activeEquivalentMG", schema: .init(type: Double.self, guides: [.range(0...10_000)]), isOptional: true),
                    .init(name: "sublingualTier", schema: .init(name: "SublingualTier", anyOf: ["quick", "casual", "standard", "strict"]), isOptional: true),
                    .init(name: "sublingualTheta", schema: .init(type: Double.self, guides: [.range(0...1)]), isOptional: true),
                    .init(name: "recordedAtISO8601", schema: .init(type: String.self), isOptional: true)
                ]
            )
            let schema = try GenerationSchema(root: root, dependencies: [])
            let session = LanguageModelSession(model: model, instructions: instructions(context: context))
            let response = try await session.respond(
                to: phrase,
                schema: schema,
                options: generationOptions
            )
            let content = response.content
            return .candidate(
                ModelDoseDraft(
                    action: try content.value(String?.self, forProperty: "action"),
                    planToken: try content.value(String?.self, forProperty: "planToken"),
                    medicationToken: try content.value(String?.self, forProperty: "medicationToken"),
                    route: try content.value(String?.self, forProperty: "route"),
                    amount: try content.value(Double?.self, forProperty: "amount"),
                    amountUnit: try content.value(String?.self, forProperty: "amountUnit"),
                    concentrationMGmL: try content.value(Double?.self, forProperty: "concentrationMGmL"),
                    volumeML: try content.value(Double?.self, forProperty: "volumeML"),
                    areaCM2: try content.value(Double?.self, forProperty: "areaCM2"),
                    releaseRateUGPerDay: try content.value(Double?.self, forProperty: "releaseRateUGPerDay"),
                    activeEquivalentMG: try content.value(Double?.self, forProperty: "activeEquivalentMG"),
                    sublingualTier: try content.value(String?.self, forProperty: "sublingualTier"),
                    sublingualTheta: try content.value(Double?.self, forProperty: "sublingualTheta"),
                    recordedAtISO8601: try content.value(String?.self, forProperty: "recordedAtISO8601")
                )
            )
        } catch {
            return .needsReview(String(localized: "I could not confidently understand that dose. Please review it in HRT Recorder."))
        }
    }

    private var generationOptions: GenerationOptions {
        #if FOUNDATION_MODELS_IOS27
        return GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 260)
        #else
        return GenerationOptions(sampling: .greedy, maximumResponseTokens: 260)
        #endif
    }

    private func instructions(context: DoseInterpretationContext) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        let referenceTime = formatter.string(from: Date())
        let planLines = context.activePlans.map {
            "\($0.token) | \($0.displayName) | \($0.summary)"
        }.joined(separator: "\n")
        let medicationLines = context.medications.map {
            "\($0.token) | \($0.displayName) | category=\($0.category.rawValue) | route=\($0.route?.rawValue ?? "unspecified")"
        }.joined(separator: "\n")
        return """
        Extract facts from the user's dose-recording phrase only. This is not medical advice and you must never recommend, calculate a regimen, or invent a value.
        Return `clarify` whenever medication, route, amount, unit, concentration, or action is ambiguous. Preserve the user's numbers and units. Never assume mg when a unit is missing. Select a plan token only when the user explicitly refers to that listed active plan; never choose a next, default, or future plan. Select medication and plan tokens only from the supplied catalog. Do not infer a compound from a category. Put an explicitly stated active-equivalent value in `activeEquivalentMG`; otherwise put the dose in `amount`. Put a spoken volume in `volumeML`, not in the mass dose. A volume needs an explicit mg/mL concentration. A patch removal carries no dose. A patch application uses a micrograms-per-day release rate.
        The current local reference time is \(referenceTime). Set `recordedAtISO8601` only when the user explicitly states or clearly implies a past/current occurrence time (including relative phrases such as yesterday evening). Resolve it to an ISO 8601 timestamp with time-zone offset. Leave it absent when no occurrence time is expressed; never invent or move a dose into the future.

        Active planned doses:
        \(planLines)

        Medication catalog:
        \(medicationLines)
        """
    }
}
#endif
