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
        case .estradiol:
            return .estradiol
        case .testosterone:
            return .testosterone
        case .antiAndrogen:
            return .antiAndrogen
        }
    }
}

enum IntentHormone: String, AppEnum {
    case estradiol
    case testosterone

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Hormone"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .estradiol: "Estradiol",
            .testosterone: "Testosterone"
        ]
    }

    var hormone: SimulatedHormone {
        switch self {
        case .estradiol:
            return .estradiol
        case .testosterone:
            return .testosterone
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
        switch self {
        case .injection:
            return .injection
        case .patchApply:
            return .patchApply
        case .patchRemove:
            return .patchRemove
        case .gel:
            return .gel
        case .oral:
            return .oral
        case .sublingual:
            return .sublingual
        }
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

    var compound: Compound {
        Compound(rawValue: rawValue)!
    }
}

enum IntentSublingualTier: String, AppEnum {
    case quick
    case casual
    case standard
    case strict

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Sublingual Hold"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
        [
            .quick: "Quick",
            .casual: "Casual",
            .standard: "Standard",
            .strict: "Strict"
        ]
    }

    var tier: SublingualTier {
        switch self {
        case .quick:
            return .quick
        case .casual:
            return .casual
        case .standard:
            return .standard
        case .strict:
            return .strict
        }
    }
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

    var medication: RecordOnlyOralMedication {
        RecordOnlyOralMedication(rawValue: rawValue)!
    }
}

private struct ParsedDosePhrase {
    var category: MedicationCategory?
    var route: DoseEvent.Route?
    var enteredDoseMG: Double?
    var activeEquivalentDoseMG: Double?
    var compound: Compound?
    var recordOnlyOralMedication: RecordOnlyOralMedication?
    var concentrationMGmL: Double?
    var areaCM2: Double?
    var releaseRateUGPerDay: Double?
    var sublingualTier: SublingualTier?
    var sublingualTheta: Double?

    nonisolated init(
        category: MedicationCategory? = nil,
        route: DoseEvent.Route? = nil,
        enteredDoseMG: Double? = nil,
        activeEquivalentDoseMG: Double? = nil,
        compound: Compound? = nil,
        recordOnlyOralMedication: RecordOnlyOralMedication? = nil,
        concentrationMGmL: Double? = nil,
        areaCM2: Double? = nil,
        releaseRateUGPerDay: Double? = nil,
        sublingualTier: SublingualTier? = nil,
        sublingualTheta: Double? = nil
    ) {
        self.category = category
        self.route = route
        self.enteredDoseMG = enteredDoseMG
        self.activeEquivalentDoseMG = activeEquivalentDoseMG
        self.compound = compound
        self.recordOnlyOralMedication = recordOnlyOralMedication
        self.concentrationMGmL = concentrationMGmL
        self.areaCM2 = areaCM2
        self.releaseRateUGPerDay = releaseRateUGPerDay
        self.sublingualTier = sublingualTier
        self.sublingualTheta = sublingualTheta
    }

    nonisolated mutating func merge(_ other: ParsedDosePhrase) {
        category = category ?? other.category
        route = route ?? other.route
        enteredDoseMG = enteredDoseMG ?? other.enteredDoseMG
        activeEquivalentDoseMG = activeEquivalentDoseMG ?? other.activeEquivalentDoseMG
        compound = compound ?? other.compound
        recordOnlyOralMedication = recordOnlyOralMedication ?? other.recordOnlyOralMedication
        concentrationMGmL = concentrationMGmL ?? other.concentrationMGmL
        areaCM2 = areaCM2 ?? other.areaCM2
        releaseRateUGPerDay = releaseRateUGPerDay ?? other.releaseRateUGPerDay
        sublingualTier = sublingualTier ?? other.sublingualTier
        sublingualTheta = sublingualTheta ?? other.sublingualTheta
    }
}

private enum NaturalLanguageDoseParser {
    nonisolated static func parse(_ phrase: String?) -> ParsedDosePhrase {
        guard let phrase, !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ParsedDosePhrase()
        }

        let normalized = normalize(phrase)
        var result = ParsedDosePhrase()

        result.route = route(in: normalized)
        result.category = category(in: normalized)
        result.compound = compound(in: normalized)
        result.recordOnlyOralMedication = recordOnlyMedication(in: normalized)
        result.sublingualTier = sublingualTier(in: normalized)
        result.sublingualTheta = value(after: ["theta"], in: normalized)
        result.concentrationMGmL = concentration(in: normalized)
        result.areaCM2 = area(in: normalized)
        result.releaseRateUGPerDay = releaseRate(in: normalized)

        if result.releaseRateUGPerDay != nil {
            result.route = result.route ?? .patchApply
        }

        if let dose = doseAmountMG(in: normalized) {
            if containsAny(["equivalent", "eq", "e2 equivalent", "t equivalent"], in: normalized) {
                result.activeEquivalentDoseMG = dose
            } else {
                result.enteredDoseMG = dose
            }
        }

        if result.recordOnlyOralMedication != nil {
            result.category = .antiAndrogen
            result.route = result.route ?? .oral
        }

        return result
    }

    private nonisolated static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "²", with: "2")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "/", with: " per ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private nonisolated static func route(in text: String) -> DoseEvent.Route? {
        if containsAny(["remove patch", "patch remove", "removed patch", "take off patch", "摘掉贴片", "移除贴片"], in: text) {
            return .patchRemove
        }
        if containsAny(["patch", "apply patch", "贴片"], in: text) {
            return .patchApply
        }
        if containsAny(["injection", "inject", "injected", "shot", "jab", "针", "注射"], in: text) {
            return .injection
        }
        if containsAny(["sublingual", "under tongue", "buccal", "舌下"], in: text) {
            return .sublingual
        }
        if containsAny(["gel", "凝胶"], in: text) {
            return .gel
        }
        if containsAny(["oral", "pill", "tablet", "capsule", "口服"], in: text) {
            return .oral
        }
        return nil
    }

    private nonisolated static func category(in text: String) -> MedicationCategory? {
        if containsAny(["testosterone", "睾酮"], in: text) {
            return .testosterone
        }
        if containsAny(["anti androgen", "antiandrogen", "spiro", "spironolactone", "bica", "bicalutamide", "cpa", "cyproterone", "finasteride", "dutasteride"], in: text) {
            return .antiAndrogen
        }
        if containsAny(["estradiol", "estrogen", "oestrogen", "oestradiol", "e2", "雌二醇", "雌激素"], in: text) {
            return .estradiol
        }
        return nil
    }

    private nonisolated static func compound(in text: String) -> Compound? {
        let matches: [(Compound, [String])] = [
            (.EV, [" estradiol valerate ", " valerate ", " ev "]),
            (.EC, [" estradiol cypionate ", " cypionate ", " ec "]),
            (.EN, [" estradiol enanthate ", " enanthate ", " en "]),
            (.EB, [" estradiol benzoate ", " benzoate ", " eb "]),
            (.E2, [" estradiol ", " estrogen ", " oestradiol ", " e2 "]),
            (.TC, [" testosterone cypionate ", " tc "]),
            (.TE, [" testosterone enanthate ", " te "]),
            (.TU, [" testosterone undecanoate ", " tu "]),
            (.T, [" testosterone ", " t "])
        ]
        let padded = " \(text) "
        return matches.first { _, terms in
            terms.contains { padded.contains($0) }
        }?.0
    }

    private nonisolated static func recordOnlyMedication(in text: String) -> RecordOnlyOralMedication? {
        if containsAny(["cyproterone acetate", "cyproterone", "cpa"], in: text) {
            return .cyproteroneAcetate
        }
        if containsAny(["spironolactone", "spiro"], in: text) {
            return .spironolactone
        }
        if containsAny(["bicalutamide", "bica"], in: text) {
            return .bicalutamide
        }
        if containsAny(["finasteride", "fina"], in: text) {
            return .finasteride
        }
        if containsAny(["dutasteride", "duta"], in: text) {
            return .dutasteride
        }
        return nil
    }

    private nonisolated static func sublingualTier(in text: String) -> SublingualTier? {
        if containsAny(["strict"], in: text) { return .strict }
        if containsAny(["standard"], in: text) { return .standard }
        if containsAny(["casual"], in: text) { return .casual }
        if containsAny(["quick"], in: text) { return .quick }
        return nil
    }

    private nonisolated static func doseAmountMG(in text: String) -> Double? {
        if let mg = firstNumber(
            in: text,
            followedBy: #"mgs?|milligrams?|milligram|毫克"#
        ) {
            return mg
        }
        if let micrograms = firstNumber(
            in: text,
            followedBy: #"ugs?|mcgs?|micrograms?|microgram|微克"#
        ) {
            return micrograms / 1_000.0
        }
        return firstNumber(in: text, followedBy: #"dose|剂量"#)
    }

    private nonisolated static func concentration(in text: String) -> Double? {
        firstCapture(
            in: text,
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:mgs?|milligrams?|milligram)\s*(?:per\s*)?(?:mls?|milliliters?|milliliter)"#
        )
    }

    private nonisolated static func area(in text: String) -> Double? {
        firstNumber(
            in: text,
            followedBy: #"cm2|square centimeters?|square centimeter|平方厘米"#
        )
    }

    private nonisolated static func releaseRate(in text: String) -> Double? {
        firstCapture(
            in: text,
            pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(?:ugs?|mcgs?|micrograms?|microgram)\s*(?:per\s*)?(?:day|d)\b|([0-9]+(?:\.[0-9]+)?)\s*(?:微克每天|微克每日)"#
        )
    }

    private nonisolated static func value(after labels: [String], in text: String) -> Double? {
        labels.lazy.compactMap { label in
            firstNumber(in: text, precededBy: label)
        }.first
    }

    private nonisolated static func firstNumber(in text: String, precededBy label: String) -> Double? {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: label) + #"\s+([0-9]+(?:\.[0-9]+)?)"#
        return firstCapture(in: text, pattern: pattern)
    }

    private nonisolated static func firstNumber(in text: String, followedBy unitPattern: String) -> Double? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(?:"# + unitPattern + #")\b"#
        return firstCapture(in: text, pattern: pattern)
    }

    private nonisolated static func firstCapture(in text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else {
            return nil
        }
        for index in 1..<match.numberOfRanges {
            let nsRange = match.range(at: index)
            guard nsRange.location != NSNotFound,
                  let captureRange = Range(nsRange, in: text) else {
                continue
            }
            return Double(text[captureRange])
        }
        return nil
    }

    private nonisolated static func containsAny(_ needles: [String], in haystack: String) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}

struct IntentDosePhraseEntity: AppEntity, Identifiable, Sendable {
    let id: String
    let text: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dose Phrase"
    static var defaultQuery = IntentDosePhraseQuery()

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = trimmed
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

    func suggestedEntities() async throws -> [IntentDosePhraseEntity] {
        []
    }

    func entities(matching string: String) async throws -> [IntentDosePhraseEntity] {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [IntentDosePhraseEntity(text: trimmed)]
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
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)"
        )
    }

    var searchTerms: [String] {
        Array(Set([
            title,
            subtitle,
            "planned dose",
            "scheduled dose",
            "dose",
            "dosing",
            "medication",
            "计划用药",
            "记录用药"
        ].map(Self.normalized).filter { !$0.isEmpty })).sorted()
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }
        let searchableText = Self.normalized(([title, subtitle] + searchTerms).joined(separator: " "))

        if searchableText.contains(normalizedQuery) {
            return true
        }

        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { searchableText.contains($0) }
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
        let options = try await MainActor.run {
            try DoseRecordingService.loadDoseOptions()
        }
        let byID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })

        return identifiers.map { identifier in
            if let option = byID[identifier] {
                return DoseOptionEntity(option: option)
            }
            return DoseOptionEntity(
                id: identifier,
                title: String(localized: "Needs reconfiguration"),
                subtitle: String(localized: "Choose an available medication plan"),
                isStale: true
            )
        }
    }

    func suggestedEntities() async throws -> [DoseOptionEntity] {
        try await MainActor.run {
            try DoseRecordingService.loadDoseOptions().map(DoseOptionEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [DoseOptionEntity] {
        try await MainActor.run {
            try DoseRecordingService
                .loadDoseOptions()
                .map(DoseOptionEntity.init)
        }
            .filter { $0.matches(string) }
    }

    func defaultResult() async -> DoseOptionEntity? {
        do {
            return try await MainActor.run {
                try DoseRecordingService.defaultDoseOption().map(DoseOptionEntity.init)
            }
        } catch {
            return nil
        }
    }
}

struct RecordDoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Dose"
    static var description = IntentDescription("Record a dosing event from structured parameters extracted by Siri.")
    static var openAppWhenRun = false

    @Parameter(
        title: "Medication",
        description: "The medication or plan to record, such as estradiol valerate, EV, testosterone cypionate, spironolactone, or a configured medication plan."
    )
    var medication: IntentMedicationEntity?

    @Parameter(
        title: "Category",
        description: "Estradiol, testosterone, or an anti-androgen. Siri can infer this from the compound or medication name."
    )
    var category: IntentHormoneCategory?

    @Parameter(
        title: "Route",
        description: "The dosing route, such as injection, oral, sublingual, gel, patch apply, or patch remove."
    )
    var route: IntentDoseRoute?

    @Parameter(
        title: "Compound",
        description: "The hormone compound or ester, such as EV, EC, TC, TE, E2, or T."
    )
    var compound: IntentCompound?

    @Parameter(
        title: "Dose",
        description: "The dose amount spoken by the user, in milligrams. For esters such as EV or TC, use the raw compound dose from the phrase."
    )
    var enteredDoseMG: Double?

    @Parameter(
        title: "Dose Phrase",
        description: "A natural-language dose phrase, such as 5 mg, 5 mg EV injection, 100 micrograms per day patch, or spironolactone 100 mg.",
        requestValueDialog: "What dose should I record? You can say something like 5 mg EV injection."
    )
    var dosePhrase: IntentDosePhraseEntity?

    @Parameter(
        title: "Active Equivalent Dose",
        description: "Optional estradiol-equivalent or testosterone-equivalent dose in milligrams when the user explicitly gives an equivalent dose."
    )
    var activeEquivalentDoseMG: Double?

    @Parameter(
        title: "Record-only Medication",
        description: "Non-PK oral medications such as cyproterone acetate, spironolactone, bicalutamide, finasteride, or dutasteride."
    )
    var recordOnlyMedication: IntentRecordOnlyMedication?

    @Parameter(
        title: "Concentration",
        description: "Optional injection concentration in mg/mL if the user says it."
    )
    var concentrationMGmL: Double?

    @Parameter(
        title: "Gel Area",
        description: "Optional gel application area in square centimeters."
    )
    var areaCM2: Double?

    @Parameter(
        title: "Patch Release Rate",
        description: "Optional patch release rate in micrograms per day. If present, the route is treated as applying a patch."
    )
    var releaseRateUGPerDay: Double?

    @Parameter(
        title: "Sublingual Hold",
        description: "Sublingual hold quality when the user says quick, casual, standard, or strict."
    )
    var sublingualTier: IntentSublingualTier?

    @Parameter(
        title: "Sublingual Theta",
        description: "Optional custom sublingual absorption fraction between 0 and 1."
    )
    var sublingualTheta: Double?

    @Parameter(
        title: "Time",
        description: "When the dosing happened. Defaults to now."
    )
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
        areaCM2 = nil
        releaseRateUGPerDay = nil
        sublingualTier = nil
        sublingualTheta = nil
        recordedAt = nil
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        if shouldRecordDefaultPlannedDose {
            do {
                if let dialog = try await MainActor.run(body: { try recordDefaultPlannedDose() }) {
                    return .result(dialog: "\(dialog)")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "I could not record the planned dose.")
                return .result(dialog: "\(message)")
            }
        }

        var request = makeCustomDoseRequest(parsedDosePhrase: NaturalLanguageDoseParser.parse(dosePhrase?.text))

        for _ in 0..<4 {
            do {
                let currentRequest = request
                let dialog = try await MainActor.run {
                    try DoseRecordingService.recordDose(currentRequest).dialogText
                }
                return .result(dialog: "\(dialog)")
            } catch DoseRecordingError.missingDoseAmount {
                let phrase = try await $dosePhrase.requestValue(
                    "What dose should I record? You can say 5 mg, 5 milligrams, or 100 micrograms per day."
                )
                request.merge(NaturalLanguageDoseParser.parse(phrase.text))
            } catch DoseRecordingError.missingRoute {
                let requestedRoute = try await $route.requestValue(
                    "Which route should I record: injection, oral, sublingual, gel, or patch?"
                )
                request.route = requestedRoute.route
            } catch DoseRecordingError.missingRecordOnlyMedication {
                let requestedMedication = try await $recordOnlyMedication.requestValue(
                    "Which medication should I record?"
                )
                request.recordOnlyOralMedication = requestedMedication.medication
                request.category = .antiAndrogen
                request.route = .oral
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? String(localized: "I could not record the dose.")
                return .result(dialog: "\(message)")
            }
        }

        return .result(dialog: "I still need a medication, route, and dose amount to record this.")
    }

    private var shouldRecordDefaultPlannedDose: Bool {
        medication == nil
            && category == nil
            && route == nil
            && compound == nil
            && enteredDoseMG == nil
            && dosePhrase == nil
            && activeEquivalentDoseMG == nil
            && recordOnlyMedication == nil
            && concentrationMGmL == nil
            && areaCM2 == nil
            && releaseRateUGPerDay == nil
            && sublingualTier == nil
            && sublingualTheta == nil
    }

    private func recordDefaultPlannedDose() throws -> String? {
        guard let option = try DoseRecordingService.defaultDoseOption(at: recordedAt ?? Date()) else {
            return nil
        }
        return try DoseRecordingService.recordDose(
            optionID: option.id,
            at: recordedAt ?? Date()
        ).dialogText
    }

    private func makeCustomDoseRequest(parsedDosePhrase: ParsedDosePhrase) -> CustomDoseRecordingRequest {
        CustomDoseRecordingRequest(
            category: category?.category ?? medication?.category ?? parsedDosePhrase.category,
            route: route?.route ?? medication?.route ?? parsedDosePhrase.route,
            enteredDoseMG: enteredDoseMG ?? parsedDosePhrase.enteredDoseMG,
            activeEquivalentDoseMG: activeEquivalentDoseMG ?? parsedDosePhrase.activeEquivalentDoseMG,
            compound: compound?.compound ?? medication?.compound ?? parsedDosePhrase.compound,
            recordOnlyOralMedication: recordOnlyMedication?.medication
                ?? medication?.recordOnlyOralMedication
                ?? parsedDosePhrase.recordOnlyOralMedication,
            concentrationMGmL: concentrationMGmL ?? parsedDosePhrase.concentrationMGmL,
            areaCM2: areaCM2 ?? parsedDosePhrase.areaCM2,
            releaseRateUGPerDay: releaseRateUGPerDay ?? parsedDosePhrase.releaseRateUGPerDay,
            sublingualTier: sublingualTier?.tier ?? parsedDosePhrase.sublingualTier,
            sublingualTheta: sublingualTheta ?? parsedDosePhrase.sublingualTheta,
            recordedAt: recordedAt ?? Date()
        )
    }
}

private extension CustomDoseRecordingRequest {
    nonisolated mutating func merge(_ parsedDosePhrase: ParsedDosePhrase) {
        category = category ?? parsedDosePhrase.category
        route = route ?? parsedDosePhrase.route
        enteredDoseMG = enteredDoseMG ?? parsedDosePhrase.enteredDoseMG
        activeEquivalentDoseMG = activeEquivalentDoseMG ?? parsedDosePhrase.activeEquivalentDoseMG
        compound = compound ?? parsedDosePhrase.compound
        recordOnlyOralMedication = recordOnlyOralMedication ?? parsedDosePhrase.recordOnlyOralMedication
        concentrationMGmL = concentrationMGmL ?? parsedDosePhrase.concentrationMGmL
        areaCM2 = areaCM2 ?? parsedDosePhrase.areaCM2
        releaseRateUGPerDay = releaseRateUGPerDay ?? parsedDosePhrase.releaseRateUGPerDay
        sublingualTier = sublingualTier ?? parsedDosePhrase.sublingualTier
        sublingualTheta = sublingualTheta ?? parsedDosePhrase.sublingualTheta
    }
}

struct RecordPlannedDoseIntent: AppIntent {
    static var title: LocalizedStringResource = "Record Planned Dose"
    static var description = IntentDescription("Record a dose from an existing medication plan.")
    static var openAppWhenRun = false

    @Parameter(title: "Planned Dose")
    var doseOption: DoseOptionEntity

    @Parameter(title: "Time")
    var recordedAt: Date?

    init() {
        doseOption = DoseOptionEntity(
            id: "",
            title: String(localized: "Dose"),
            subtitle: "",
            isStale: true
        )
        recordedAt = nil
    }

    init(doseOption: DoseOptionEntity, recordedAt: Date? = nil) {
        self.doseOption = doseOption
        self.recordedAt = recordedAt
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !doseOption.id.isEmpty, !doseOption.isStale else {
            return .result(dialog: "Choose an available medication plan first.")
        }

        do {
            let recordedAt = recordedAt ?? Date()
            let optionID = doseOption.id
            let dialog = try await MainActor.run {
                try DoseRecordingService.recordDose(
                    optionID: optionID,
                    at: recordedAt
                ).dialogText
            }
            return .result(dialog: "\(dialog)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "I could not record the planned dose.")
            return .result(dialog: "\(message)")
        }
    }
}

struct GetHormoneConcentrationIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Hormone Concentration"
    static var description = IntentDescription("Read the estimated hormone concentration from HRT Recorder.")
    static var openAppWhenRun = false

    @Parameter(title: "Hormone")
    var hormone: IntentHormone

    @Parameter(title: "Time")
    var measuredAt: Date?

    init() {
        hormone = .estradiol
        measuredAt = nil
    }

    init(hormone: IntentHormone, measuredAt: Date? = nil) {
        self.hormone = hormone
        self.measuredAt = measuredAt
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let hormone = hormone.hormone
            let measuredAt = measuredAt ?? Date()
            let dialog = try await MainActor.run {
                try DoseRecordingService.hormoneConcentration(
                    for: hormone,
                    at: measuredAt
                ).dialogText
            }
            return .result(value: dialog, dialog: "\(dialog)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? String(localized: "I could not read the hormone concentration.")
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
                "Record \(\.$medication) dose in \(.applicationName)",
                "Log \(\.$medication) in \(.applicationName)",
                "Record my medication in \(.applicationName)",
                "Record my medication dose in \(.applicationName)",
                "用 \(.applicationName) 记录用药",
                "用 \(.applicationName) 记录 \(\.$dosePhrase)",
                "在 \(.applicationName) 记录 dosing",
                "在 \(.applicationName) 记录 \(\.$dosePhrase)",
                "在 \(.applicationName) 记录 \(\.$medication)"
            ],
            shortTitle: "Record Dose",
            systemImageName: "pills.fill"
        )

        AppShortcut(
            intent: RecordPlannedDoseIntent(),
            phrases: [
                "Record a planned dose in \(.applicationName)",
                "Log my planned dose in \(.applicationName)",
                "Record scheduled medication in \(.applicationName)",
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
                "What's my estrogen level in \(.applicationName)",
                "What is my estrogen level in \(.applicationName)",
                "What's my estradiol level in \(.applicationName)",
                "What is my estradiol level in \(.applicationName)",
                "Check \(\.$hormone) level in \(.applicationName)",
                "Get \(\.$hormone) concentration in \(.applicationName)",
                "What's my \(\.$hormone) level in \(.applicationName)",
                "用 \(.applicationName) 查看激素浓度"
            ],
            shortTitle: "Hormone Level",
            systemImageName: "waveform.path.ecg"
        )
    }
}
