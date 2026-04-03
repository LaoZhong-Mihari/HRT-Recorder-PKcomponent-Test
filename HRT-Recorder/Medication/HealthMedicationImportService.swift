import Foundation
import HealthKit

private struct ImportedDoseDetails: Sendable {
    let rawDoseMG: Double?
    let extras: [DoseEvent.ExtraKey: Double]
    let description: String?
}

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
        let timingDates = timingDates(hasSchedule: medication.hasSchedule, doseEvents: doseEvents)
        let doseSeedEvent = preferredDoseSeedEvent(
            scheduleDoseEvents: scheduledDoseEvents,
            allDoseEvents: doseEvents
        )
        let doseDetails = alignmentRule.map {
            resolveDoseDetails(from: doseSeedEvent, snapshot: snapshot, rule: $0)
        }
        let recurrence = inferRecurrence(
            hasSchedule: medication.hasSchedule,
            route: route,
            timingDates: timingDates
        )
        let suggestedTemplate: MedicationDoseTemplate?
        if let alignmentRule, let doseDetails {
            suggestedTemplate = makeTemplate(from: snapshot, rule: alignmentRule, doseDetails: doseDetails)
        } else {
            suggestedTemplate = nil
        }
        let alignmentStatus = alignmentStatus(for: alignmentRule, template: suggestedTemplate)
        let healthPlanSummary = makeHealthPlanSummary(
            hasSchedule: medication.hasSchedule,
            recurrence: recurrence,
            timingDates: timingDates
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
            latestDoseDescription: doseDetails?.description ?? fallbackDoseDescription(from: doseSeedEvent),
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

        if normalizedGeneralForm.contains("inject")
            || normalizedGeneralForm.contains("device")
            || text.contains("inject")
            || text.contains("injector")
            || text.contains("intramuscular") {
            return .injection
        }
        if normalizedGeneralForm.contains("patch") || text.contains("patch") {
            return .patchApply
        }
        if normalizedGeneralForm.contains("gel")
            || normalizedGeneralForm.contains("cream")
            || normalizedGeneralForm.contains("lotion")
            || normalizedGeneralForm.contains("ointment")
            || normalizedGeneralForm.contains("foam")
            || normalizedGeneralForm.contains("spray")
            || normalizedGeneralForm.contains("topical")
            || text.contains("gel")
            || text.contains("foam")
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
        doseDetails: ImportedDoseDetails
    ) -> MedicationDoseTemplate? {
        let rawDoseMG = doseDetails.rawDoseMG

        if let recordOnlyOralMedication = rule.recordOnlyOralMedication {
            return MedicationDoseTemplate(
                route: rule.route,
                doseMG: rawDoseMG ?? 0,
                ester: .E2,
                extras: doseDetails.extras,
                recordOnlyOralMedication: recordOnlyOralMedication
            )
        }

        guard let compound = rule.ester else { return nil }
        let convertedDoseMG = (rawDoseMG ?? 0) * CompoundInfo.by(compound: compound).toActiveFactor
        return MedicationDoseTemplate(
            route: rule.route,
            doseMG: convertedDoseMG,
            compound: compound,
            extras: doseDetails.extras,
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
            .filter { $0.scheduleType == .schedule }
            .sorted { eventDate(for: $0) < eventDate(for: $1) }
    }

    @available(iOS 26.0, *)
    private func scheduleSeedEvent(from scheduleDoseEvents: [HKMedicationDoseEvent]) -> HKMedicationDoseEvent? {
        let now = Date()
        if let upcoming = scheduleDoseEvents.first(where: { eventDate(for: $0) >= now }) {
            return upcoming
        }
        return scheduleDoseEvents.last
    }

    @available(iOS 26.0, *)
    private func preferredDoseSeedEvent(
        scheduleDoseEvents: [HKMedicationDoseEvent],
        allDoseEvents: [HKMedicationDoseEvent]
    ) -> HKMedicationDoseEvent? {
        if let scheduled = scheduleSeedEvent(from: scheduleDoseEvents),
           scheduled.scheduledDoseQuantity != nil || scheduled.doseQuantity != nil {
            return scheduled
        }

        return allDoseEvents
            .filter { $0.scheduledDoseQuantity != nil || $0.doseQuantity != nil }
            .max { eventDate(for: $0) < eventDate(for: $1) }
    }

    @available(iOS 26.0, *)
    private func resolveDoseDetails(
        from doseSeedEvent: HKMedicationDoseEvent?,
        snapshot: HealthMedicationSnapshot,
        rule: MedicationAlignmentRule
    ) -> ImportedDoseDetails {
        let parsedStrengths = parsedStrengths(from: snapshot)
        let parsedConcentrationMGPerML = parsedStrengths
            .first(where: { $0.denominatorUnit == "ml" && $0.denominatorQuantity > 0 })
            .map { $0.massMG / $0.denominatorQuantity }
        let parsedPatchReleaseUGPerDay = (rule.route == .patchApply)
            ? parsedReleaseRateUGPerDay(from: snapshot)
            : nil

        var extras: [DoseEvent.ExtraKey: Double] = [:]
        if let concentration = parsedConcentrationMGPerML {
            extras[.concentrationMGmL] = concentration
        }
        if let releaseRate = parsedPatchReleaseUGPerDay {
            extras[.releaseRateUGPerDay] = releaseRate
        }

        let quantity = doseSeedEvent?.scheduledDoseQuantity ?? doseSeedEvent?.doseQuantity
        let normalizedUnit = doseSeedEvent.map { normalizedDoseUnit($0.unit.unitString) } ?? ""

        let resolvedRawDoseMG: Double? = {
            guard let quantity else {
                return fallbackRawDoseMG(from: snapshot, rule: rule)
            }

            switch normalizedUnit {
            case "mg":
                return quantity
            case "g":
                return quantity * 1000
            case "mcg", "ug", "μg", "µg":
                return quantity / 1000
            case "ml":
                guard let concentration = parsedConcentrationMGPerML else { return nil }
                return quantity * concentration
            case "l":
                guard let concentration = parsedConcentrationMGPerML else { return nil }
                return quantity * 1000 * concentration
            case "tablet", "capsule", "caplet", "softgel", "patch", "pump", "actuation", "application", "packet", "sachet", "dose", "vial":
                if let perUnitStrength = parsedStrength(for: normalizedUnit, in: parsedStrengths) {
                    return quantity * perUnitStrength.massMG / max(perUnitStrength.denominatorQuantity, 1)
                }
                if let singleUnitStrength = fallbackRawDoseMG(from: snapshot, rule: rule) {
                    return quantity * singleUnitStrength
                }
                return nil
            default:
                if let perUnitStrength = parsedStrength(for: normalizedUnit, in: parsedStrengths) {
                    return quantity * perUnitStrength.massMG / max(perUnitStrength.denominatorQuantity, 1)
                }
                return fallbackRawDoseMG(from: snapshot, rule: rule)
            }
        }()

        return ImportedDoseDetails(
            rawDoseMG: resolvedRawDoseMG,
            extras: extras,
            description: makeDoseDescription(
                from: doseSeedEvent,
                rawDoseMG: resolvedRawDoseMG,
                extras: extras
            )
        )
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
        timingDates: [Date]
    ) -> MedicationPlanRecurrence {
        guard hasSchedule, !timingDates.isEmpty else {
            return defaultRecurrence(for: route, date: Date())
        }

        let times = uniqueTimes(from: timingDates)
        let primaryTime = times.first ?? .defaultMorning

        switch route {
        case .oral, .gel, .sublingual:
            return .daily(times: times.isEmpty ? [primaryTime] : times)
        case .injection, .patchApply, .patchRemove:
            let interval = inferredIntervalDays(from: timingDates)
            let roundedInterval = max(1, interval ?? 7)
            return .everyNDays(
                intervalDays: roundedInterval,
                startDate: timingDates.last ?? Date(),
                time: primaryTime
            )
        }
    }

    @available(iOS 26.0, *)
    private func makeHealthPlanSummary(
        hasSchedule: Bool,
        recurrence: MedicationPlanRecurrence,
        timingDates: [Date]
    ) -> String {
        guard hasSchedule else {
            return String(localized: "medimport.summary.as_needed")
        }

        guard !timingDates.isEmpty else {
            return String(localized: "medimport.summary.schedule_unavailable")
        }

        return recurrenceSummary(recurrence)
    }

    private func parsedStrengths(from snapshot: HealthMedicationSnapshot) -> [MedicationStrengthPerUnit] {
        MedicationStrengthParser.parseStrengthPerUnit(from: snapshot.displayName)
            + MedicationStrengthParser.parseStrengthPerUnit(from: snapshot.nickname ?? "")
    }

    private func parsedReleaseRateUGPerDay(from snapshot: HealthMedicationSnapshot) -> Double? {
        MedicationStrengthParser.parseReleaseRateUGPerDay(from: snapshot.displayName)
            ?? MedicationStrengthParser.parseReleaseRateUGPerDay(from: snapshot.nickname ?? "")
    }

    private func parsedStrength(
        for normalizedUnit: String,
        in strengths: [MedicationStrengthPerUnit]
    ) -> MedicationStrengthPerUnit? {
        strengths.first { $0.denominatorUnit == normalizedUnit }
    }

    private func normalizedDoseUnit(_ unitString: String) -> String {
        unitString
            .lowercased()
            .replacingOccurrences(of: "milliliters", with: "ml")
            .replacingOccurrences(of: "milliliter", with: "ml")
            .replacingOccurrences(of: "millilitres", with: "ml")
            .replacingOccurrences(of: "millilitre", with: "ml")
            .replacingOccurrences(of: "grams", with: "g")
            .replacingOccurrences(of: "gram", with: "g")
            .replacingOccurrences(of: "milligrams", with: "mg")
            .replacingOccurrences(of: "milligram", with: "mg")
            .replacingOccurrences(of: "micrograms", with: "mcg")
            .replacingOccurrences(of: "microgram", with: "mcg")
            .replacingOccurrences(of: "tablets", with: "tablet")
            .replacingOccurrences(of: "capsules", with: "capsule")
            .replacingOccurrences(of: "caplets", with: "caplet")
            .replacingOccurrences(of: "patches", with: "patch")
            .replacingOccurrences(of: "pumps", with: "pump")
            .replacingOccurrences(of: "actuations", with: "actuation")
            .replacingOccurrences(of: "applications", with: "application")
            .replacingOccurrences(of: "packets", with: "packet")
            .replacingOccurrences(of: "sachets", with: "sachet")
            .replacingOccurrences(of: "doses", with: "dose")
            .replacingOccurrences(of: "softgels", with: "softgel")
            .replacingOccurrences(of: "vials", with: "vial")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @available(iOS 26.0, *)
    private func makeDoseDescription(
        from doseSeedEvent: HKMedicationDoseEvent?,
        rawDoseMG: Double?,
        extras: [DoseEvent.ExtraKey: Double]
    ) -> String? {
        guard let doseSeedEvent else {
            if let releaseRate = extras[.releaseRateUGPerDay] {
                return String.localizedStringWithFormat(
                    String(localized: "medimport.dose.parsed_release_rate"),
                    formattedNumber(releaseRate, maximumFractionDigits: 0)
                )
            }
            if let rawDoseMG {
                return String.localizedStringWithFormat(
                    String(localized: "medimport.dose.parsed_mass"),
                    formattedNumber(rawDoseMG)
                )
            }
            return nil
        }

        let quantity = doseSeedEvent.scheduledDoseQuantity ?? doseSeedEvent.doseQuantity
        let unitString = doseSeedEvent.unit.unitString
        let normalizedUnit = normalizedDoseUnit(unitString)

        if let quantity,
           let concentration = extras[.concentrationMGmL],
           (normalizedUnit == "ml" || normalizedUnit == "l"),
           let rawDoseMG {
            return String.localizedStringWithFormat(
                String(localized: "medimport.dose.volume_times_concentration"),
                formattedNumber(quantity),
                unitString,
                formattedNumber(concentration),
                formattedNumber(rawDoseMG)
            )
        }

        if let quantity,
           let releaseRate = extras[.releaseRateUGPerDay] {
            return String.localizedStringWithFormat(
                String(localized: "medimport.dose.release_rate_quantity"),
                formattedNumber(quantity),
                unitString,
                formattedNumber(releaseRate, maximumFractionDigits: 0)
            )
        }

        if let quantity,
           let rawDoseMG {
            return String.localizedStringWithFormat(
                String(localized: "medimport.dose.quantity_to_mg"),
                formattedNumber(quantity),
                unitString,
                formattedNumber(rawDoseMG)
            )
        }

        if let releaseRate = extras[.releaseRateUGPerDay] {
            return String.localizedStringWithFormat(
                String(localized: "medimport.dose.parsed_release_rate"),
                formattedNumber(releaseRate, maximumFractionDigits: 0)
            )
        }

        return rawDoseMG.map {
            String.localizedStringWithFormat(
                String(localized: "medimport.dose.parsed_mass"),
                formattedNumber($0)
            )
        }
    }

    @available(iOS 26.0, *)
    private func fallbackDoseDescription(from doseSeedEvent: HKMedicationDoseEvent?) -> String? {
        guard let doseSeedEvent,
              let quantity = doseSeedEvent.scheduledDoseQuantity ?? doseSeedEvent.doseQuantity else {
            return nil
        }
        return "\(formattedNumber(quantity)) \(doseSeedEvent.unit.unitString)"
    }

    private func timingDates(
        hasSchedule: Bool,
        doseEvents: [HKMedicationDoseEvent]
    ) -> [Date] {
        guard hasSchedule else { return [] }

        let exactScheduleDates = doseEvents
            .filter { $0.scheduleType == .schedule }
            .compactMap(\.scheduledDate)
            .sorted()
        if !exactScheduleDates.isEmpty {
            return exactScheduleDates
        }

        let scheduledEventDates = doseEvents
            .filter { $0.scheduleType == .schedule }
            .map(\.startDate)
            .sorted()
        if !scheduledEventDates.isEmpty {
            return scheduledEventDates
        }

        return doseEvents.map(\.startDate).sorted()
    }

    @available(iOS 26.0, *)
    private func eventDate(for event: HKMedicationDoseEvent) -> Date {
        event.scheduledDate ?? event.startDate
    }

    private func formattedNumber(
        _ value: Double,
        maximumFractionDigits: Int = 2
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
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
