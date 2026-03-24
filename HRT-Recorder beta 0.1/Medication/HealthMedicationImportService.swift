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
            return "Health data isn't available on this device."
        }

        if #available(iOS 26.0, *) {
            return "Import plans from Apple Health medications."
        }

        return "Medication import requires iOS 26 or later."
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

        let identifiers = Set(medications.map { $0.medication.identifier })
        let doseEvents = try await fetchDoseEvents(for: identifiers)
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
        let generalFormText = formattedGeneralForm(concept.generalForm)
        let combinedText: String = [
            medication.nickname,
            concept.displayText,
            generalFormText
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()

        let ester = inferEster(from: combinedText)
        let route = inferRoute(generalForm: concept.generalForm, text: combinedText)
        let latestEvent = doseEvents.sorted(by: doseEventSort).first
        let recurrence = inferRecurrence(
            hasSchedule: medication.hasSchedule,
            route: route,
            doseEvents: doseEvents
        )

        var noteParts: [String] = []
        var suggestedTemplate: MedicationDoseTemplate?

        if let template = makeTemplate(route: route, ester: ester, latestEvent: latestEvent) {
            suggestedTemplate = template
        } else {
            noteParts.append("Dose from Health needs confirmation before the plan can be saved.")
        }

        switch route {
        case .patchApply:
            noteParts.append("Patch release rate is not available from Health. Please confirm the patch model.")
        case .gel:
            noteParts.append("Gel area is not available from Health. The app will use its default area unless you edit it.")
        case .sublingual:
            noteParts.append("Sublingual dosing isn't auto-detected. Please confirm if this should stay oral or become sublingual.")
        default:
            break
        }

        if medication.hasSchedule {
            noteParts.append("Reminder pattern is inferred from recent scheduled dose events when possible.")
        } else {
            noteParts.append("Health marks this medication as taken as needed. Add a reminder plan manually if needed.")
        }

        return MedicationImportSuggestion(
            id: UUID(),
            sourceName: concept.displayText,
            nickname: medication.nickname,
            generalFormText: generalFormText,
            latestDoseDescription: latestDoseDescription(for: latestEvent),
            suggestedTemplate: suggestedTemplate,
            suggestedRecurrence: recurrence,
            note: noteParts.joined(separator: " "),
            sourceMedicationName: concept.displayText
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

    private func inferEster(from text: String) -> Ester {
        if text.contains("valerate") {
            return .EV
        }
        if text.contains("cypionate") {
            return .EC
        }
        if text.contains("benzoate") {
            return .EB
        }
        if text.contains("enanthate") {
            return .EN
        }
        return .E2
    }

    @available(iOS 26.0, *)
    private func makeTemplate(
        route: DoseEvent.Route,
        ester: Ester,
        latestEvent: HKMedicationDoseEvent?
    ) -> MedicationDoseTemplate? {
        guard let latestEvent else {
            return nil
        }

        guard let rawDoseMG = convertedMassInMilligrams(from: latestEvent) else {
            return nil
        }

        let convertedDoseMG = rawDoseMG * EsterInfo.by(ester: ester).toE2Factor
        return MedicationDoseTemplate(route: route, doseMG: convertedDoseMG, ester: ester, extras: [:])
    }

    @available(iOS 26.0, *)
    private func convertedMassInMilligrams(from doseEvent: HKMedicationDoseEvent) -> Double? {
        let quantity = doseEvent.doseQuantity ?? doseEvent.scheduledDoseQuantity
        guard let quantity else { return nil }

        let unit = doseEvent.unit.unitString.lowercased()
        switch unit {
        case "mg", "milligram", "milligrams":
            return quantity
        case "g", "gram", "grams":
            return quantity * 1000
        case "mcg", "ug", "μg", "µg":
            return quantity / 1000
        default:
            return nil
        }
    }

    @available(iOS 26.0, *)
    private func inferRecurrence(
        hasSchedule: Bool,
        route: DoseEvent.Route,
        doseEvents: [HKMedicationDoseEvent]
    ) -> MedicationPlanRecurrence {
        let scheduledDates = doseEvents
            .compactMap(\.scheduledDate)
            .sorted()

        guard hasSchedule else {
            return defaultRecurrence(for: route, date: Date())
        }

        guard !scheduledDates.isEmpty else {
            return defaultRecurrence(for: route, date: Date())
        }

        let times = uniqueTimes(from: scheduledDates)
        let primaryTime = times.first ?? .defaultMorning

        switch route {
        case .oral, .gel, .sublingual:
            if !times.isEmpty {
                return .daily(times: times)
            }
            return .daily(times: [primaryTime])

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

    private func defaultRecurrence(for route: DoseEvent.Route, date: Date) -> MedicationPlanRecurrence {
        switch route {
        case .oral, .gel, .sublingual:
            return .daily(times: [clockTime(from: date)])
        case .injection, .patchApply, .patchRemove:
            return .everyNDays(intervalDays: 7, startDate: date, time: clockTime(from: date))
        }
    }

    private func uniqueTimes(from dates: [Date]) -> [ReminderClockTime] {
        let times = dates.map(clockTime(from:))
        let unique = Array(Set(times))
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

    @available(iOS 26.0, *)
    private func latestDoseDescription(for event: HKMedicationDoseEvent?) -> String? {
        guard let event else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let dateText = formatter.string(from: event.endDate)
        let quantity = event.doseQuantity ?? event.scheduledDoseQuantity
        let quantityText = quantity.map(formattedQuantity(_:)) ?? "-"
        let unit = event.unit.unitString
        return "\(statusText(for: event.logStatus)) · \(quantityText) \(unit) · \(dateText)"
    }

    @available(iOS 26.0, *)
    private func statusText(for status: HKMedicationDoseEvent.LogStatus) -> String {
        switch status {
        case .taken:
            return "Taken"
        case .skipped:
            return "Skipped"
        case .snoozed:
            return "Snoozed"
        case .notificationNotSent:
            return "Notification failed"
        case .notInteracted:
            return "Not interacted"
        case .notLogged:
            return "Not logged"
        @unknown default:
            return "Unknown"
        }
    }

    @available(iOS 26.0, *)
    private func doseEventSort(_ lhs: HKMedicationDoseEvent, _ rhs: HKMedicationDoseEvent) -> Bool {
        let lhsDate = lhs.scheduledDate ?? lhs.endDate
        let rhsDate = rhs.scheduledDate ?? rhs.endDate
        return lhsDate > rhsDate
    }

    private func formattedQuantity(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
            return "Health data isn't available on this device."
        case .unsupportedOS:
            return "Medication import requires iOS 26 or later."
        case .queryTimedOut:
            return "Apple Health took too long to answer. Close the sheet and try again."
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
