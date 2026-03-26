import Foundation
import HealthKit

@MainActor
final class HealthMedicationImportService {
    private let store = HKHealthStore()
    private let queryTimeout: Duration = .seconds(12)

    var isSupported: Bool {
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    var availabilityDescription: String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return String(localized: "Health data isn't available on this device.")
        }

        if #available(iOS 26.0, *) {
            return String(localized: "Import plans from Apple Health.")
        }

        return String(localized: "Medication import needs iOS 26 or later.")
    }

    func loadSuggestions() async throws -> [MedicationImportSuggestion] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthMedicationImportError.healthDataUnavailable
        }
        guard #available(iOS 26.0, *) else {
            throw HealthMedicationImportError.unsupportedOS
        }

        try await HealthKitService.shared.requestMedicationAuthorizationIfNeeded()

        let medications = try await fetchActiveMedications()
        guard !medications.isEmpty else { return [] }

        return medications
            .map(makeSuggestion(from:))
            .sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
    }

    @available(iOS 26.0, *)
    private func fetchActiveMedications() async throws -> [HKUserAnnotatedMedication] {
        try await executeQuery(timeout: queryTimeout) { finish in
            var collected: [HKUserAnnotatedMedication] = []
            let predicate = HKQuery.predicateForUserAnnotatedMedications(isArchived: false)

            return HKUserAnnotatedMedicationQuery(predicate: predicate, limit: HKObjectQueryNoLimit) { _, medication, done, error in
                if let error {
                    finish(.failure(error))
                    return
                }

                if let medication {
                    collected.append(medication)
                }

                if done {
                    finish(.success(collected))
                }
            }
        }
    }

    @available(iOS 26.0, *)
    private func makeSuggestion(
        from medication: HKUserAnnotatedMedication
    ) -> MedicationImportSuggestion {
        let concept = medication.medication
        let snapshot = makeSnapshot(from: medication)
        let alignmentRule = MedicationImportCatalog.match(snapshot: snapshot)
        let route = alignmentRule?.route ?? inferRoute(generalForm: concept.generalForm, text: snapshot.combinedNormalizedText)
        let recurrence = defaultRecurrence(for: route, date: Date())
        let suggestedTemplate = alignmentRule.flatMap { makeTemplate(from: snapshot, rule: $0) }
        let alignmentStatus = alignmentStatus(for: alignmentRule, template: suggestedTemplate)
        let note = makeNote(
            for: medication,
            rule: alignmentRule,
            alignmentStatus: alignmentStatus
        )

        return MedicationImportSuggestion(
            id: UUID(),
            sourceName: concept.displayText,
            nickname: medication.nickname,
            generalFormText: snapshot.generalFormText,
            latestDoseDescription: nil,
            suggestedTemplate: suggestedTemplate,
            suggestedRecurrence: recurrence,
            note: note,
            sourceMedicationName: concept.displayText,
            alignmentStatus: alignmentStatus,
            alignmentRuleName: alignmentRule?.name
        )
    }

    @available(iOS 26.0, *)
    private func inferRoute(generalForm: HKMedicationGeneralForm, text: String) -> DoseEvent.Route {
        if generalForm == .injection || text.contains("inject") || text.contains("intramuscular") {
            return .injection
        }
        if generalForm == .patch || text.contains("patch") {
            return .patchApply
        }
        if generalForm == .gel
            || generalForm == .cream
            || generalForm == .lotion
            || generalForm == .ointment
            || generalForm == .topical
            || text.contains("gel")
            || text.contains("topical") {
            return .gel
        }
        return .oral
    }

    @available(iOS 26.0, *)
    private func makeSnapshot(from medication: HKUserAnnotatedMedication) -> HealthMedicationSnapshot {
        let generalFormText = formattedGeneralForm(medication.medication.generalForm)

        return HealthMedicationSnapshot(
            displayName: medication.medication.displayText,
            nickname: medication.nickname,
            generalFormText: generalFormText,
            normalizedDisplayName: MedicationImportNameNormalizer.normalize(medication.medication.displayText),
            normalizedNickname: MedicationImportNameNormalizer.normalize(medication.nickname),
            normalizedGeneralFormText: MedicationImportNameNormalizer.normalize(generalFormText)
        )
    }

    @available(iOS 26.0, *)
    private func makeTemplate(
        from snapshot: HealthMedicationSnapshot,
        rule: MedicationAlignmentRule
    ) -> MedicationDoseTemplate? {
        let rawDoseMG: Double?
        switch rule.doseParsingMode {
        case .strengthInName:
            rawDoseMG = MedicationStrengthParser.parseRawDoseMG(from: snapshot.displayName)
        }
        guard let rawDoseMG else { return nil }

        let convertedDoseMG = rawDoseMG * EsterInfo.by(ester: rule.ester).toE2Factor
        return MedicationDoseTemplate(
            route: rule.route,
            doseMG: convertedDoseMG,
            ester: rule.ester,
            extras: [:]
        )
    }

    @available(iOS 26.0, *)
    private func alignmentStatus(
        for rule: MedicationAlignmentRule?,
        template: MedicationDoseTemplate?
    ) -> MedicationImportAlignmentStatus {
        guard rule != nil else {
            return .needsRule
        }

        return template == nil ? .needsDoseConfirmation : .aligned
    }

    @available(iOS 26.0, *)
    private func makeNote(
        for medication: HKUserAnnotatedMedication,
        rule: MedicationAlignmentRule?,
        alignmentStatus: MedicationImportAlignmentStatus
    ) -> String {
        var noteParts: [String] = []

        if let ruleName = rule?.name, !ruleName.isEmpty {
            noteParts.append("Health mapping: \(ruleName).")
        }

        if let ruleNote = rule?.note, !ruleNote.isEmpty {
            noteParts.append(ruleNote)
        }

        switch alignmentStatus {
        case .aligned:
            noteParts.append("Dose uses the strength written in the Health medication name. If you take multiple tablets or capsules at once, adjust the dose before saving.")
        case .needsDoseConfirmation:
            noteParts.append("This medication matched a rule, but the app couldn't read a single strength from the Health medication name. Confirm the dose manually before saving.")
        case .needsRule:
            noteParts.append("No alignment rule yet for this Health medication.")
        }

        if medication.hasSchedule {
            noteParts.append("Health marks this medication as scheduled, but exact reminder timing isn't available to the app. Confirm the schedule before saving.")
        } else {
            noteParts.append("Health marks this medication as taken as needed. Add or adjust reminders manually if needed.")
        }

        if rule?.route == .sublingual {
            noteParts.append("Sublingual dosing isn't auto-detected. Confirm whether this should stay oral or become sublingual.")
        }

        return noteParts.joined(separator: " ")
    }

    private func defaultRecurrence(for route: DoseEvent.Route, date: Date) -> MedicationPlanRecurrence {
        switch route {
        case .oral, .gel, .sublingual:
            return .daily(times: [clockTime(from: date)])
        case .injection, .patchApply, .patchRemove:
            return .everyNDays(intervalDays: 7, startDate: date, time: clockTime(from: date))
        }
    }

    private func formattedGeneralForm(_ generalForm: HKMedicationGeneralForm) -> String {
        generalForm
            .rawValue
            .replacingOccurrences(of: "_", with: " ")
            .localizedCapitalized
    }

    private func clockTime(from date: Date) -> ReminderClockTime {
        let calendar = Calendar.autoupdatingCurrent
        return ReminderClockTime(
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date)
        )
    }

    private func executeQuery<Value>(
        timeout: Duration,
        makeQuery: @escaping (@escaping @Sendable (Result<Value, Error>) -> Void) -> HKQuery
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let state = QueryExecutionState<Value>(continuation: continuation)
            let query = makeQuery { result in
                switch result {
                case .success(let value):
                    state.resume(returning: value)
                case .failure(let error):
                    state.resume(throwing: error)
                }
            }

            state.setQuery(query)
            store.execute(query)

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self,
                      let queryToStop = state.resumeIfNeeded(throwing: HealthMedicationImportError.queryTimedOut) else {
                    return
                }
                self.store.stop(queryToStop)
            }
        }
    }
}

private enum HealthMedicationImportError: LocalizedError {
    case healthDataUnavailable
    case unsupportedOS
    case queryTimedOut

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return String(localized: "Health data isn't available on this device.")
        case .unsupportedOS:
            return String(localized: "Medication import needs iOS 26 or later.")
        case .queryTimedOut:
            return String(localized: "Apple Health took too long to answer. Close the sheet and try again.")
        }
    }
}

private final class QueryExecutionState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var continuation: CheckedContinuation<Value, Error>?
    nonisolated(unsafe) private var query: HKQuery?

    nonisolated
    init(continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @_optimize(none)
    deinit {}

    nonisolated
    func setQuery(_ query: HKQuery) {
        lock.lock()
        self.query = query
        lock.unlock()
    }

    nonisolated
    func resume(returning value: Value) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(returning: value)
    }

    nonisolated
    func resume(throwing error: Error) {
        guard let continuation = takeContinuation() else { return }
        continuation.resume(throwing: error)
    }

    nonisolated
    func resumeIfNeeded(throwing error: Error) -> HKQuery? {
        lock.lock()
        let continuation = continuation
        let query = query
        self.continuation = nil
        lock.unlock()

        continuation?.resume(throwing: error)
        return continuation == nil ? nil : query
    }

    nonisolated
    private func takeContinuation() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        return continuation
    }
}
