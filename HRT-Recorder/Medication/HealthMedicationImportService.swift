import Foundation
import HealthKit

@MainActor
protocol MedicationImportServicing {
    var isSupported: Bool { get }
    var availabilityDescription: String { get }

    func loadSuggestions() async throws -> [MedicationImportSuggestion]
}

struct UnsupportedMedicationImportService: MedicationImportServicing {
    var isSupported: Bool { false }

    var availabilityDescription: String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return String(localized: "medimport.availability.health_data_unavailable")
        }

        return String(localized: "medimport.availability.unsupported_os")
    }

    func loadSuggestions() async throws -> [MedicationImportSuggestion] {
        throw HealthMedicationImportError.unsupportedOS
    }
}

@MainActor
@available(iOS 26.0, *)
final class HealthMedicationImportService: MedicationImportServicing {
    private let store = HKHealthStore()
    private let queryTimeout: Duration = .seconds(12)

    var isSupported: Bool { true }

    var availabilityDescription: String {
        guard HKHealthStore.isHealthDataAvailable() else {
            return String(localized: "medimport.availability.health_data_unavailable")
        }

        return String(localized: "medimport.availability.import_plans")
    }

    func loadSuggestions() async throws -> [MedicationImportSuggestion] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthMedicationImportError.healthDataUnavailable
        }

        try await HealthKitService.shared.requestMedicationAuthorizationIfNeeded()

        let medications = try await fetchActiveMedications()
        guard !medications.isEmpty else { return [] }

        let identifiers = Set(medications.map { $0.medication.identifier })
        let doseEvents = (try? await fetchDoseEvents(for: identifiers)) ?? []
        let groupedDoseEvents = Dictionary(grouping: doseEvents, by: \.medicationConceptIdentifier)

        return medications
            .map { medication in
                makeSuggestion(
                    from: medication,
                    doseEvents: groupedDoseEvents[medication.medication.identifier] ?? []
                )
            }
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
    private func fetchDoseEvents(for identifiers: Set<HKHealthConceptIdentifier>) async throws -> [HKMedicationDoseEvent] {
        guard !identifiers.isEmpty else { return [] }

        return try await executeQuery(timeout: queryTimeout) { finish in
            let type = HKObjectType.medicationDoseEventType()
            let predicate = HKQuery.predicateForMedicationDoseEvent(medicationConceptIdentifiers: identifiers)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

            return HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    finish(.failure(error))
                    return
                }

                let events = (samples as? [HKMedicationDoseEvent]) ?? []
                finish(.success(events))
            }
        }
    }

    @available(iOS 26.0, *)
    private func makeSuggestion(
        from medication: HKUserAnnotatedMedication,
        doseEvents: [HKMedicationDoseEvent]
    ) -> MedicationImportSuggestion {
        let concept = medication.medication
        let snapshot = makeSnapshot(from: medication)
        let alignmentRule = MedicationImportCatalog.match(snapshot: snapshot)
        let route = alignmentRule?.route ?? inferRoute(
            generalFormRawValue: concept.generalForm.rawValue,
            text: snapshot.combinedNormalizedText
        )
        let scheduledDoseEvents = scheduleDoseEvents(from: doseEvents)
        let recurrence = inferRecurrence(
            hasSchedule: medication.hasSchedule,
            route: route,
            scheduleDoseEvents: scheduledDoseEvents
        )
        let suggestedTemplate = alignmentRule.flatMap {
            makeTemplate(from: snapshot, rule: $0, scheduleDoseEvents: scheduledDoseEvents)
        }
        let alignmentStatus = alignmentStatus(for: alignmentRule, template: suggestedTemplate)
        let healthPlanSummary = makeHealthPlanSummary(
            hasSchedule: medication.hasSchedule,
            recurrence: recurrence,
            scheduleDoseEvents: scheduledDoseEvents
        )
        let note = makeNote(
            for: medication,
            rule: alignmentRule,
            alignmentStatus: alignmentStatus,
            usedScheduleSeed: !scheduledDoseEvents.isEmpty
        )

        return MedicationImportSuggestion(
            id: UUID(),
            sourceName: concept.displayText,
            nickname: medication.nickname,
            generalFormText: snapshot.generalFormText,
            latestDoseDescription: nil,
            suggestedTemplate: suggestedTemplate,
            suggestedRecurrence: recurrence,
            healthPlanSummary: healthPlanSummary,
            note: note,
            sourceMedicationName: concept.displayText,
            alignmentStatus: alignmentStatus,
            alignmentRuleName: alignmentRule?.name
        )
    }

    @available(iOS 26.0, *)
    private func inferRoute(generalFormRawValue: String, text: String) -> DoseEvent.Route {
        let normalizedGeneralForm = generalFormRawValue
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()

        if normalizedGeneralForm.contains("inject") || text.contains("inject") || text.contains("intramuscular") {
            return .injection
        }
        if normalizedGeneralForm.contains("patch") || text.contains("patch") {
            return .patchApply
        }
        if normalizedGeneralForm.contains("gel")
            || normalizedGeneralForm.contains("cream")
            || normalizedGeneralForm.contains("lotion")
            || normalizedGeneralForm.contains("ointment")
            || normalizedGeneralForm.contains("topical")
            || text.contains("gel")
            || text.contains("topical") {
            return .gel
        }
        return .oral
    }

    @available(iOS 26.0, *)
    private func makeSnapshot(from medication: HKUserAnnotatedMedication) -> HealthMedicationSnapshot {
        let generalFormText = formattedGeneralForm(medication.medication.generalForm.rawValue)

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
        rule: MedicationAlignmentRule,
        scheduleDoseEvents: [HKMedicationDoseEvent]
    ) -> MedicationDoseTemplate? {
        let rawDoseMG = rawDoseMG(
            from: scheduleSeedEvent(from: scheduleDoseEvents),
            snapshot: snapshot,
            rule: rule
        ) ?? fallbackRawDoseMG(from: snapshot, rule: rule)

        if let recordOnlyOralMedication = rule.recordOnlyOralMedication {
            return MedicationDoseTemplate(
                route: rule.route,
                doseMG: rawDoseMG ?? 0,
                ester: .E2,
                extras: [:],
                recordOnlyOralMedication: recordOnlyOralMedication
            )
        }

        guard let ester = rule.ester else { return nil }
        let convertedDoseMG = (rawDoseMG ?? 0) * EsterInfo.by(ester: ester).toE2Factor
        return MedicationDoseTemplate(
            route: rule.route,
            doseMG: convertedDoseMG,
            ester: ester,
            extras: [:],
            recordOnlyOralMedication: nil
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

        guard let template else {
            return .needsDoseConfirmation
        }

        return template.hasConfiguredDose ? .aligned : .needsDoseConfirmation
    }

    @available(iOS 26.0, *)
    private func makeNote(
        for medication: HKUserAnnotatedMedication,
        rule: MedicationAlignmentRule?,
        alignmentStatus: MedicationImportAlignmentStatus,
        usedScheduleSeed: Bool
    ) -> String {
        var noteParts: [String] = []

        switch alignmentStatus {
        case .aligned:
            if usedScheduleSeed {
                noteParts.append(String(localized: "medimport.note.aligned_with_schedule"))
            } else {
                noteParts.append(String(localized: "medimport.note.aligned_partial_schedule"))
            }
        case .needsDoseConfirmation:
            if usedScheduleSeed {
                noteParts.append(String(localized: "medimport.note.needs_dose_with_schedule"))
            } else {
                noteParts.append(String(localized: "medimport.note.needs_dose_without_schedule"))
            }
        case .needsRule:
            noteParts.append(String(localized: "medimport.note.needs_rule"))
        }

        if !medication.hasSchedule {
            noteParts.append(String(localized: "medimport.note.as_needed"))
        }

        if let ruleName = rule?.name, !ruleName.isEmpty {
            noteParts.append(
                String.localizedStringWithFormat(
                    String(localized: "medimport.note.mapping_format"),
                    ruleName
                )
            )
        }

        if let recordOnlyOralMedication = rule?.recordOnlyOralMedication {
            noteParts.append(
                String.localizedStringWithFormat(
                    String(localized: "medimport.note.record_only_format"),
                    recordOnlyOralMedication.displayName
                )
            )
        }

        if rule?.route == .sublingual {
            noteParts.append(String(localized: "medimport.note.sublingual_confirmation"))
        }

        return noteParts.joined(separator: " ")
    }

    @available(iOS 26.0, *)
    private func scheduleDoseEvents(from doseEvents: [HKMedicationDoseEvent]) -> [HKMedicationDoseEvent] {
        doseEvents
            .filter { $0.scheduleType == .schedule && $0.scheduledDate != nil }
            .sorted { ($0.scheduledDate ?? .distantPast) < ($1.scheduledDate ?? .distantPast) }
    }

    @available(iOS 26.0, *)
    private func scheduleSeedEvent(from scheduleDoseEvents: [HKMedicationDoseEvent]) -> HKMedicationDoseEvent? {
        let now = Date()
        if let upcoming = scheduleDoseEvents.first(where: { ($0.scheduledDate ?? .distantPast) >= now }) {
            return upcoming
        }
        return scheduleDoseEvents.last
    }

    @available(iOS 26.0, *)
    private func rawDoseMG(
        from scheduleSeedEvent: HKMedicationDoseEvent?,
        snapshot: HealthMedicationSnapshot,
        rule: MedicationAlignmentRule
    ) -> Double? {
        guard let scheduleSeedEvent,
              let scheduledQuantity = scheduleSeedEvent.scheduledDoseQuantity else {
            return nil
        }

        let unit = scheduleSeedEvent.unit.unitString.lowercased()
        switch unit {
        case "mg", "milligram", "milligrams":
            return scheduledQuantity
        case "g", "gram", "grams":
            return scheduledQuantity * 1000
        case "mcg", "ug", "μg", "µg":
            return scheduledQuantity / 1000
        case "tablet", "tablets", "capsule", "capsules", "caplet", "caplets":
            guard let singleUnitStrength = fallbackRawDoseMG(from: snapshot, rule: rule) else {
                return nil
            }
            return scheduledQuantity * singleUnitStrength
        default:
            return nil
        }
    }

    private func fallbackRawDoseMG(from snapshot: HealthMedicationSnapshot, rule: MedicationAlignmentRule) -> Double? {
        switch rule.doseParsingMode {
        case .strengthInName:
            if let parsedFromName = MedicationStrengthParser.parseRawDoseMG(from: snapshot.displayName) {
                return parsedFromName
            }

            if let parsedFromNickname = MedicationStrengthParser.parseRawDoseMG(from: snapshot.nickname ?? "") {
                return parsedFromNickname
            }

            return rule.defaultUnitStrengthMG
        }
    }

    @available(iOS 26.0, *)
    private func inferRecurrence(
        hasSchedule: Bool,
        route: DoseEvent.Route,
        scheduleDoseEvents: [HKMedicationDoseEvent]
    ) -> MedicationPlanRecurrence {
        let scheduledDates = scheduleDoseEvents.compactMap(\.scheduledDate)

        guard hasSchedule, !scheduledDates.isEmpty else {
            return defaultRecurrence(for: route, date: Date())
        }

        let times = uniqueTimes(from: scheduledDates)
        let primaryTime = times.first ?? .defaultMorning

        switch route {
        case .oral, .gel, .sublingual:
            return .daily(times: times.isEmpty ? [primaryTime] : times)
        case .injection, .patchApply, .patchRemove:
            let interval = inferredIntervalDays(from: scheduledDates)
            let roundedInterval = max(1, interval ?? 7)
            return .everyNDays(
                intervalDays: roundedInterval,
                startDate: scheduledDates.last ?? Date(),
                time: primaryTime
            )
        }
    }

    @available(iOS 26.0, *)
    private func makeHealthPlanSummary(
        hasSchedule: Bool,
        recurrence: MedicationPlanRecurrence,
        scheduleDoseEvents: [HKMedicationDoseEvent]
    ) -> String {
        guard hasSchedule else {
            return String(localized: "medimport.summary.as_needed")
        }

        guard !scheduleDoseEvents.isEmpty else {
            return String(localized: "medimport.summary.schedule_unavailable")
        }

        return recurrenceSummary(recurrence)
    }

    private func defaultRecurrence(for route: DoseEvent.Route, date: Date) -> MedicationPlanRecurrence {
        switch route {
        case .oral, .gel, .sublingual:
            return .daily(times: [clockTime(from: date)])
        case .injection, .patchApply, .patchRemove:
            return .everyNDays(intervalDays: 7, startDate: date, time: clockTime(from: date))
        }
    }

    private func uniqueTimes(from dates: [Date]) -> [ReminderClockTime] {
        var seen = Set<String>()
        var unique: [ReminderClockTime] = []

        for date in dates {
            let time = clockTime(from: date)
            let key = "\(time.hour):\(time.minute)"
            guard seen.insert(key).inserted else { continue }
            unique.append(time)
        }

        return unique.sorted {
            if $0.hour == $1.hour {
                return $0.minute < $1.minute
            }
            return $0.hour < $1.hour
        }
    }

    private func inferredIntervalDays(from dates: [Date]) -> Int? {
        let calendar = Calendar.autoupdatingCurrent
        let intervals = zip(dates, dates.dropFirst()).compactMap { lhs, rhs in
            calendar.dateComponents([.day], from: lhs, to: rhs).day
        }

        guard !intervals.isEmpty else { return nil }
        return Int((Double(intervals.reduce(0, +)) / Double(intervals.count)).rounded())
    }

    private func recurrenceSummary(_ recurrence: MedicationPlanRecurrence) -> String {
        switch recurrence.kind {
        case .daily:
            let times = recurrence.times.map(\.formattedText).joined(separator: ", ")
            if times.isEmpty {
                return String(localized: "medimport.summary.daily")
            }
            return String.localizedStringWithFormat(
                String(localized: "medimport.summary.daily_times"),
                times
            )
        case .weekly:
            let weekdaySymbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
            let weekdays = recurrence.weekdays
                .compactMap { weekday -> String? in
                    guard (1...7).contains(weekday) else { return nil }
                    return weekdaySymbols[weekday - 1]
                }
                .joined(separator: ", ")
            return String.localizedStringWithFormat(
                String(localized: "medimport.summary.weekly"),
                weekdays,
                recurrence.primaryTime.formattedText
            )
        case .everyNDays:
            return String.localizedStringWithFormat(
                String(localized: "medimport.summary.every_n_days"),
                recurrence.intervalDays,
                recurrence.primaryTime.formattedText
            )
        }
    }

    private func formattedGeneralForm(_ generalFormRawValue: String) -> String {
        generalFormRawValue
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
            return String(localized: "medimport.availability.health_data_unavailable")
        case .unsupportedOS:
            return String(localized: "medimport.availability.unsupported_os")
        case .queryTimedOut:
            return String(localized: "medimport.error.query_timed_out")
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
