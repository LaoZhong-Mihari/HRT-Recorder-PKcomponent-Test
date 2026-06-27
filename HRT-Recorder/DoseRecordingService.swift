import Foundation

enum DoseRecordingError: LocalizedError {
    case invalidDoseOption
    case missingMedicationPlan
    case missingConfiguredDose
    case missingRoute
    case missingDoseAmount
    case missingRecordOnlyMedication
    case unsupportedCompound
    case readFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidDoseOption:
            return String(localized: "This dose is no longer available. Choose a medication plan again.")
        case .missingMedicationPlan:
            return String(localized: "I could not find that medication plan.")
        case .missingConfiguredDose:
            return String(localized: "That medication plan does not have a configured dose.")
        case .missingRoute:
            return String(localized: "Tell me the dosing route, such as oral, injection, gel, patch, or sublingual.")
        case .missingDoseAmount:
            return String(localized: "Tell me the dose amount to record.")
        case .missingRecordOnlyMedication:
            return String(localized: "Tell me which record-only medication to record.")
        case .unsupportedCompound:
            return String(localized: "That compound is not supported for the selected route.")
        case .readFailed:
            return String(localized: "I could not read your saved dosing data.")
        case .writeFailed:
            return String(localized: "I could not save the dose.")
        }
    }
}

struct RecordedDoseSummary: Sendable {
    let event: DoseEvent
    let planName: String
    let doseDescription: String
    let recordedAt: Date

    var dialogText: String {
        String.localizedStringWithFormat(
            String(localized: "Recorded %@ at %@."),
            doseDescription,
            recordedAt.formatted(date: .omitted, time: .shortened)
        )
    }
}

struct CustomDoseRecordingRequest {
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
    var recordedAt: Date
}

struct HormoneConcentrationSummary {
    let hormone: SimulatedHormone
    let value: Double?
    let unit: ConcentrationUnit
    let measuredAt: Date
    let eventCount: Int

    var dialogText: String {
        guard let value else {
            return String.localizedStringWithFormat(
                String(localized: "I do not have enough %@ dosing data to estimate a concentration yet."),
                hormone.displayName
            )
        }

        let formatted = String(format: "%.1f", locale: Locale.current, value)
        return String.localizedStringWithFormat(
            String(localized: "%@ is about %@ %@ at %@."),
            hormone.displayName,
            formatted,
            unit.symbol,
            measuredAt.formatted(date: .omitted, time: .shortened)
        )
    }
}

enum DoseRecordingService {
    private static let eventsFileName = "dose_events.json"
    private static let medicationPlansFileName = "medication_plans.json"
    private static let bodyWeightKey = "user.weightKg"
    private static let eventsModifiedKey = "dose.events.modifiedAt"
    private static let lock = NSLock()

    static func loadPersistedEvents() throws -> [DoseEvent] {
        try loadValue(filename: eventsFileName, defaultValue: [])
    }

    static func loadMedicationPlans() throws -> [MedicationPlan] {
        try loadValue(filename: medicationPlansFileName, defaultValue: [])
    }

    static func loadDoseOptions() throws -> [WidgetDoseOption] {
        WidgetSnapshotCoordinator.makeDoseOptions(from: try loadMedicationPlans())
    }

    static func defaultDoseOption(at date: Date = Date()) throws -> WidgetDoseOption? {
        let plans = try loadMedicationPlans()
        let options = WidgetSnapshotCoordinator.makeDoseOptions(from: plans)
        let optionByID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })

        let nextOption = plans
            .filter(\.isEnabled)
            .compactMap { plan -> (Date, WidgetDoseOption)? in
                guard let occurrence = plan.nextOccurrence(after: date) else {
                    return nil
                }
                let optionID = WidgetDoseOption.makeID(
                    planID: occurrence.planID,
                    doseSlotID: occurrence.doseSlotID
                )
                guard let option = optionByID[optionID] else {
                    return nil
                }
                return (occurrence.scheduledDate, option)
            }
            .min { lhs, rhs in lhs.0 < rhs.0 }?
            .1

        return nextOption ?? options.first
    }

    static func hormoneConcentration(
        for hormone: SimulatedHormone,
        at date: Date = Date()
    ) throws -> HormoneConcentrationSummary {
        let events = try loadPersistedEvents()
        let simulatedEvents = events
            .filter { $0.participatesInSimulation && $0.simulatedHormone == hormone }
            .sorted { $0.timeH < $1.timeH }
        let unit = preferredConcentrationUnit(for: hormone)

        guard !simulatedEvents.isEmpty else {
            return HormoneConcentrationSummary(
                hormone: hormone,
                value: nil,
                unit: unit,
                measuredAt: date,
                eventCount: 0
            )
        }

        let timeH = date.timeIntervalSince1970 / 3600.0
        let result = SimulationEngine(
            events: simulatedEvents,
            hormone: hormone,
            bodyWeightKG: persistedBodyWeightKG(),
            startTimeH: timeH - 0.5,
            endTimeH: timeH + 0.5,
            numberOfSteps: 3
        )
        .run()
        .converted(to: unit)

        return HormoneConcentrationSummary(
            hormone: hormone,
            value: result.concentration(at: timeH),
            unit: unit,
            measuredAt: date,
            eventCount: simulatedEvents.count
        )
    }

    static func persistedEventsModifiedAt() -> TimeInterval {
        UserDefaults.standard.double(forKey: eventsModifiedKey)
    }

    @discardableResult
    static func recordDose(optionID: String, at date: Date = Date()) throws -> RecordedDoseSummary {
        lock.lock()
        defer { lock.unlock() }

        guard let parsedID = WidgetDoseOption.parseID(optionID) else {
            throw DoseRecordingError.invalidDoseOption
        }

        let plans = try loadMedicationPlans()
        guard let plan = plans.first(where: { $0.id == parsedID.planID }) else {
            throw DoseRecordingError.missingMedicationPlan
        }

        let template = plan.template(for: date, doseSlotID: parsedID.doseSlotID)
        guard template.hasConfiguredDose else {
            throw DoseRecordingError.missingConfiguredDose
        }

        var events = try loadPersistedEvents()
        let event = makeDoseEvent(from: template, at: date)
        try append(event, to: &events, plans: plans)

        return RecordedDoseSummary(
            event: event,
            planName: plan.displayName,
            doseDescription: template.reminderDoseText,
            recordedAt: date
        )
    }

    @discardableResult
    static func recordDose(_ request: CustomDoseRecordingRequest) throws -> RecordedDoseSummary {
        lock.lock()
        defer { lock.unlock() }

        let plans = try loadMedicationPlans()
        var events = try loadPersistedEvents()
        let event = try makeDoseEvent(from: request)
        try append(event, to: &events, plans: plans)

        return RecordedDoseSummary(
            event: event,
            planName: String(localized: "Custom dose"),
            doseDescription: doseDescription(for: event),
            recordedAt: request.recordedAt
        )
    }

    private static func makeDoseEvent(from template: MedicationDoseTemplate, at date: Date) -> DoseEvent {
        DoseEvent(
            id: UUID(),
            category: template.category,
            route: template.recordOnlyOralMedication == nil ? template.route : .oral,
            timeH: date.timeIntervalSince1970 / 3600.0,
            doseMG: template.doseMG,
            compound: template.recordOnlyOralMedication == nil ? template.compound : .E2,
            extras: template.extras,
            recordOnlyOralMedication: template.recordOnlyOralMedication
        )
    }

    private static func makeDoseEvent(from request: CustomDoseRecordingRequest) throws -> DoseEvent {
        let recordedAt = request.recordedAt

        if let recordOnlyOralMedication = request.recordOnlyOralMedication {
            guard let enteredDoseMG = request.enteredDoseMG ?? request.activeEquivalentDoseMG,
                  enteredDoseMG > 0 else {
                throw DoseRecordingError.missingDoseAmount
            }

            return DoseEvent(
                id: UUID(),
                category: .antiAndrogen,
                route: .oral,
                timeH: recordedAt.timeIntervalSince1970 / 3600.0,
                doseMG: enteredDoseMG,
                compound: .E2,
                extras: [:],
                recordOnlyOralMedication: recordOnlyOralMedication
            )
        }

        if request.category == .antiAndrogen {
            throw DoseRecordingError.missingRecordOnlyMedication
        }

        let route = try resolvedRoute(from: request)
        let requestedCategory = request.category ?? request.compound?.medicationCategory ?? .estradiol
        let compound = request.compound ?? Compound.fallback(
            for: requestedCategory,
            route: route,
            recordOnlyOralMedication: nil
        )
        let category = request.category ?? compound.medicationCategory

        guard CompoundSupport.availableCompounds(for: category, route: route).contains(compound) else {
            throw DoseRecordingError.unsupportedCompound
        }

        var doseMG = 0.0
        var extras: [DoseEvent.ExtraKey: Double] = [:]

        if let concentrationMGmL = request.concentrationMGmL, concentrationMGmL > 0 {
            extras[.concentrationMGmL] = concentrationMGmL
        }
        if let areaCM2 = request.areaCM2, areaCM2 > 0 {
            extras[.areaCM2] = areaCM2
        }

        switch route {
        case .patchRemove:
            doseMG = 0

        case .patchApply where (request.releaseRateUGPerDay ?? 0) > 0:
            doseMG = 0
            extras[.releaseRateUGPerDay] = request.releaseRateUGPerDay

        default:
            guard let enteredDoseMG = request.enteredDoseMG ?? request.activeEquivalentDoseMG,
                  enteredDoseMG > 0 else {
                throw DoseRecordingError.missingDoseAmount
            }

            if let activeEquivalentDoseMG = request.activeEquivalentDoseMG, activeEquivalentDoseMG > 0 {
                doseMG = activeEquivalentDoseMG
                if let rawDose = request.enteredDoseMG, rawDose > 0, route != .patchApply {
                    extras[.rawCompoundDoseMG] = rawDose
                }
            } else if route == .patchApply {
                doseMG = enteredDoseMG
            } else {
                let factor = CompoundInfo.by(compound: compound).toActiveFactor
                doseMG = enteredDoseMG * factor
                if compound.info.isProdrug {
                    extras[.rawCompoundDoseMG] = enteredDoseMG
                }
            }
        }

        if route == .sublingual {
            if let theta = request.sublingualTheta {
                extras[.sublingualTheta] = max(0.0, min(1.0, theta))
            } else if let tier = request.sublingualTier {
                extras[.sublingualTier] = tierCode(for: tier)
            } else {
                extras[.sublingualTier] = tierCode(for: .standard)
            }
        }

        return DoseEvent(
            id: UUID(),
            category: category,
            route: route,
            timeH: recordedAt.timeIntervalSince1970 / 3600.0,
            doseMG: doseMG,
            compound: compound,
            extras: extras,
            recordOnlyOralMedication: nil
        )
    }

    private static func resolvedRoute(from request: CustomDoseRecordingRequest) throws -> DoseEvent.Route {
        if request.releaseRateUGPerDay != nil {
            return .patchApply
        }
        guard let route = request.route else {
            throw DoseRecordingError.missingRoute
        }
        return route
    }

    private static func append(_ event: DoseEvent, to events: inout [DoseEvent], plans: [MedicationPlan]) throws {
        events.append(event)
        events.sort { $0.timeH < $1.timeH }

        try saveEvents(events)

        let modifiedAt = Date().timeIntervalSince1970
        UserDefaults.standard.set(modifiedAt, forKey: eventsModifiedKey)

        WidgetSnapshotCoordinator.writeSnapshot(
            events: events,
            bodyWeightKG: persistedBodyWeightKG(),
            plans: plans
        )
        AppIntentIndexingCoordinator.refreshMedicationIndex(plans: plans)
    }

    private static func doseDescription(for event: DoseEvent) -> String {
        let template = MedicationDoseTemplate(
            category: event.category,
            route: event.route,
            doseMG: event.doseMG,
            compound: event.compound,
            extras: event.extras,
            recordOnlyOralMedication: event.recordOnlyOralMedication
        )
        return template.reminderDoseText
    }

    private static func tierCode(for tier: SublingualTier) -> Double {
        switch tier {
        case .quick: return 0
        case .casual: return 1
        case .standard: return 2
        case .strict: return 3
        }
    }

    private static func persistedBodyWeightKG() -> Double {
        let saved = UserDefaults.standard.double(forKey: bodyWeightKey)
        return saved > 0 ? saved : 70.0
    }

    private static func preferredConcentrationUnit(for hormone: SimulatedHormone) -> ConcentrationUnit {
        hormone.preferredUnit(
            from: UserDefaults.standard.string(
                forKey: "timeline.selectedConcentrationUnit.\(hormone.rawValue)"
            )
        )
    }

    private static func loadValue<T: Decodable>(filename: String, defaultValue: T) throws -> T {
        let url = try fileURL(named: filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return defaultValue
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DoseRecordingError.readFailed
        }
    }

    private static func saveEvents(_ events: [DoseEvent]) throws {
        do {
            let url = try fileURL(named: eventsFileName)
            let data = try JSONEncoder().encode(events)
            try data.write(to: url, options: .atomic)
        } catch {
            throw DoseRecordingError.writeFailed
        }
    }

    private static func fileURL(named fileName: String) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName)
        } catch {
            throw DoseRecordingError.writeFailed
        }
    }
}
