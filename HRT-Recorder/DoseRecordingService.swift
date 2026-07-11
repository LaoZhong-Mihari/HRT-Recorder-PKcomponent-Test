import Foundation

enum DoseRecordingError: LocalizedError {
    case invalidDoseOption
    case missingMedicationPlan
    case missingConfiguredDose
    case missingRoute
    case missingDoseAmount
    case missingRecordOnlyMedication
    case missingMedication
    case inconsistentMedication
    case disabledMedicationPlan
    case unsupportedCompound
    case invalidDoseConfiguration
    case invalidRecordedAt
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
        case .missingMedication:
            return String(localized: "Tell me the specific medication or choose an active medication plan.")
        case .inconsistentMedication:
            return String(localized: "Those medication details do not describe the same dose. Please review them before recording.")
        case .disabledMedicationPlan:
            return String(localized: "That medication plan is paused. Enable it or choose an active plan.")
        case .unsupportedCompound:
            return String(localized: "That compound is not supported for the selected route.")
        case .invalidDoseConfiguration:
            return String(localized: "Those dose details are incomplete or inconsistent. Please review them before recording.")
        case .invalidRecordedAt:
            return String(localized: "Use the current time or a past time for a dose record.")
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
    var volumeML: Double?
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
    private static let medicationPlansFileName = "medication_plans.json"
    private static let labReportsFileName = "lab_reports.json"
    private static let legacyLabSamplesFileName = "lab_samples.json"
    private static let bodyWeightKey = "user.weightKg"

    static func loadPersistedEvents() throws -> [DoseEvent] {
        try DoseStore.load().events
    }

    static func loadMedicationPlans() throws -> [MedicationPlan] {
        try loadValue(filename: medicationPlansFileName, defaultValue: [])
    }

    static func loadDoseOptions() throws -> [WidgetDoseOption] {
        WidgetSnapshotCoordinator.makeDoseOptions(from: try loadMedicationPlans())
    }

    static func hormoneConcentration(
        for hormone: SimulatedHormone,
        at date: Date = Date()
    ) throws -> HormoneConcentrationSummary {
        let events = try loadPersistedEvents()
        let bodyWeightKG = persistedBodyWeightKG()
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
        let labSamples = persistedLabSamples()
        let calibration = labSamples.isEmpty
            ? CalibrationResult()
            : PKCalibrator.fit(
                events: events.filter(\.participatesInSimulation),
                labs: labSamples,
                bodyWeightKG: bodyWeightKG
            )
        let result = SimulationEngine(
            events: simulatedEvents,
            hormone: hormone,
            bodyWeightKG: bodyWeightKG,
            startTimeH: timeH - 0.5,
            endTimeH: timeH + 0.5,
            numberOfSteps: 3,
            vdPerKGOverride: calibration.vdPerKGOverride(for: hormone),
            kaMultiplier: calibration.kaMultiplier(for: hormone)
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
        (try? DoseStore.load().modifiedAt) ?? 0
    }

    @discardableResult
    static func recordDose(
        optionID: String,
        at date: Date = Date(),
        mutationID: UUID = UUID(),
        fingerprint: String? = nil
    ) async throws -> RecordedDoseSummary {
        try validateRecordedAt(date)
        guard let parsedID = WidgetDoseOption.parseID(optionID) else {
            throw DoseRecordingError.invalidDoseOption
        }

        let plans = try loadMedicationPlans()
        guard let plan = plans.first(where: { $0.id == parsedID.planID }) else {
            throw DoseRecordingError.missingMedicationPlan
        }
        guard plan.isEnabled else {
            throw DoseRecordingError.disabledMedicationPlan
        }

        guard let template = plan.exactTemplate(forDoseSlotID: parsedID.doseSlotID) else {
            throw DoseRecordingError.invalidDoseOption
        }
        guard template.hasConfiguredDose else {
            throw DoseRecordingError.missingConfiguredDose
        }

        let event = makeDoseEvent(from: template, at: date)
        let result = try DoseStore.apply(
            DoseStoreMutation(
                id: mutationID,
                operation: .upsert(event),
                source: "planned-dose",
                fingerprint: fingerprint
            )
        )
        await refreshProjections(with: result.snapshot, plans: plans)

        return RecordedDoseSummary(
            event: result.resolvedEvent ?? event,
            planName: plan.displayName,
            doseDescription: template.reminderDoseText,
            recordedAt: date
        )
    }

    @discardableResult
    static func recordDose(
        _ request: CustomDoseRecordingRequest,
        mutationID: UUID = UUID(),
        fingerprint: String? = nil
    ) async throws -> RecordedDoseSummary {
        try validateRecordedAt(request.recordedAt)
        let plans = try loadMedicationPlans()
        let event = try makeDoseEvent(from: request)
        let result = try DoseStore.apply(
            DoseStoreMutation(
                id: mutationID,
                operation: .upsert(event),
                source: "custom-dose",
                fingerprint: fingerprint
            )
        )
        await refreshProjections(with: result.snapshot, plans: plans)

        return RecordedDoseSummary(
            event: result.resolvedEvent ?? event,
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
            guard request.category == nil || request.category == .antiAndrogen,
                  request.route == nil || request.route == .oral,
                  request.compound == nil,
                  request.activeEquivalentDoseMG == nil,
                  request.releaseRateUGPerDay == nil,
                  request.concentrationMGmL == nil,
                  request.volumeML == nil,
                  request.areaCM2 == nil,
                  request.sublingualTier == nil,
                  request.sublingualTheta == nil else {
                throw DoseRecordingError.inconsistentMedication
            }
            guard let enteredDoseMG = request.enteredDoseMG,
                  enteredDoseMG.isFinite,
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
        guard let compound = request.compound else {
            throw DoseRecordingError.missingMedication
        }
        let category = request.category ?? compound.medicationCategory
        guard category == compound.medicationCategory else {
            throw DoseRecordingError.inconsistentMedication
        }

        guard CompoundSupport.availableCompounds(for: category, route: route).contains(compound) else {
            throw DoseRecordingError.unsupportedCompound
        }

        var doseMG = 0.0
        var extras: [DoseEvent.ExtraKey: Double] = [:]
        var enteredDoseMG = request.enteredDoseMG
        let activeEquivalentDoseMG = request.activeEquivalentDoseMG
        let concentrationMGmL = request.concentrationMGmL
        let volumeML = request.volumeML
        let areaCM2 = request.areaCM2
        let releaseRateUGPerDay = request.releaseRateUGPerDay
        let sublingualTier = request.sublingualTier
        let sublingualTheta = request.sublingualTheta

        if let concentrationMGmL,
           (!concentrationMGmL.isFinite || concentrationMGmL <= 0 || concentrationMGmL > 1_000) {
            throw DoseRecordingError.invalidDoseConfiguration
        }
        if let volumeML,
           (!volumeML.isFinite || volumeML <= 0 || volumeML > 100 || concentrationMGmL == nil) {
            throw DoseRecordingError.invalidDoseConfiguration
        }
        if let concentrationMGmL, let volumeML {
            let calculatedDose = concentrationMGmL * volumeML
            if let enteredDoseMG,
               !approximatelyEqual(enteredDoseMG, calculatedDose) {
                throw DoseRecordingError.invalidDoseConfiguration
            }
            enteredDoseMG = calculatedDose
        }
        if let areaCM2,
           (!areaCM2.isFinite || areaCM2 <= 0 || areaCM2 > 10_000) {
            throw DoseRecordingError.invalidDoseConfiguration
        }
        if let releaseRateUGPerDay,
           (!releaseRateUGPerDay.isFinite || releaseRateUGPerDay <= 0 || releaseRateUGPerDay > 10_000) {
            throw DoseRecordingError.invalidDoseConfiguration
        }
        if let sublingualTheta,
           (!sublingualTheta.isFinite || !(0...1).contains(sublingualTheta)) {
            throw DoseRecordingError.invalidDoseConfiguration
        }
        if let enteredDoseMG, let activeEquivalentDoseMG {
            let expectedActive = enteredDoseMG * CompoundInfo.by(compound: compound).toActiveFactor
            guard approximatelyEquivalent(activeEquivalentDoseMG, expectedActive) else {
                throw DoseRecordingError.invalidDoseConfiguration
            }
        }

        switch route {
        case .injection:
            guard areaCM2 == nil,
                  releaseRateUGPerDay == nil,
                  sublingualTier == nil,
                  sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }
            if let concentrationMGmL {
                extras[.concentrationMGmL] = concentrationMGmL
            }

        case .gel:
            guard concentrationMGmL == nil,
                  volumeML == nil,
                  releaseRateUGPerDay == nil,
                  sublingualTier == nil,
                  sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }
            if let areaCM2 {
                extras[.areaCM2] = areaCM2
            }

        case .oral:
            guard concentrationMGmL == nil,
                  volumeML == nil,
                  areaCM2 == nil,
                  releaseRateUGPerDay == nil,
                  sublingualTier == nil,
                  sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }

        case .sublingual:
            guard concentrationMGmL == nil,
                  volumeML == nil,
                  areaCM2 == nil,
                  releaseRateUGPerDay == nil,
                  sublingualTier == nil || sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }

        case .patchRemove:
            guard enteredDoseMG == nil,
                  activeEquivalentDoseMG == nil,
                  releaseRateUGPerDay == nil,
                  concentrationMGmL == nil,
                  volumeML == nil,
                  areaCM2 == nil,
                  sublingualTier == nil,
                  sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }
            doseMG = 0

        case .patchApply:
            guard let releaseRate = releaseRateUGPerDay else {
                throw DoseRecordingError.missingDoseAmount
            }
            guard releaseRate.isFinite, releaseRate > 0,
                  enteredDoseMG == nil,
                  activeEquivalentDoseMG == nil,
                  concentrationMGmL == nil,
                  volumeML == nil,
                  areaCM2 == nil,
                  sublingualTier == nil,
                  sublingualTheta == nil else {
                throw DoseRecordingError.invalidDoseConfiguration
            }
            doseMG = 0
            extras[.releaseRateUGPerDay] = releaseRate

        }

        switch route {
        case .patchApply, .patchRemove:
            break
        case .injection, .gel, .oral, .sublingual:
            guard let enteredDose = enteredDoseMG ?? activeEquivalentDoseMG,
                  enteredDose.isFinite,
                  enteredDose > 0 else {
                throw DoseRecordingError.missingDoseAmount
            }

            if let activeEquivalentDoseMG, activeEquivalentDoseMG > 0 {
                doseMG = activeEquivalentDoseMG
                if let rawDose = enteredDoseMG, rawDose > 0 {
                    extras[.rawCompoundDoseMG] = rawDose
                }
            } else {
                let factor = CompoundInfo.by(compound: compound).toActiveFactor
                doseMG = enteredDose * factor
                if compound.info.isProdrug {
                    extras[.rawCompoundDoseMG] = enteredDose
                }
            }
        }

        if route == .sublingual {
            if let theta = sublingualTheta {
                extras[.sublingualTheta] = theta
            } else if let tier = sublingualTier {
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
        guard let route = request.route else {
            throw DoseRecordingError.missingRoute
        }
        return route
    }

    private static func validateRecordedAt(_ date: Date) throws {
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite,
              date <= Date().addingTimeInterval(5 * 60) else {
            throw DoseRecordingError.invalidRecordedAt
        }
    }

    private static func approximatelyEqual(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(0.001, max(abs(lhs), abs(rhs)) * 0.001)
    }

    private static func approximatelyEquivalent(_ lhs: Double, _ rhs: Double) -> Bool {
        abs(lhs - rhs) <= max(0.01, max(abs(lhs), abs(rhs)) * 0.02)
    }

    private static func refreshProjections(
        with snapshot: DoseStoreSnapshot,
        plans: [MedicationPlan]
    ) async {
        let ticket = WidgetSnapshotCoordinator.enqueueSnapshotWrite(
            events: snapshot.events,
            bodyWeightKG: persistedBodyWeightKG(),
            labSamples: persistedLabSamples(),
            plans: plans,
            debounce: false
        )
        await WidgetSnapshotCoordinator.waitForCommit(of: ticket)
        AppIntentIndexingCoordinator.refreshMedicationIndex(plans: plans)
    }

    private static func persistedLabSamples() -> [LabSample] {
        guard let selectedHormone = HRTProfilePreferences().confirmedHormone else {
            return []
        }

        let reports: [LabReport] = (try? loadValue(
            filename: labReportsFileName,
            defaultValue: []
        )) ?? []
        if !reports.isEmpty {
            return reports
                .flatMap(\.calibrationSamples)
                .filter { $0.hormone == selectedHormone }
                .sorted { $0.timeH < $1.timeH }
        }

        let legacySamples: [LabSample] = (try? loadValue(
            filename: legacyLabSamplesFileName,
            defaultValue: []
        )) ?? []
        return legacySamples
            .filter { $0.hormone == selectedHormone }
            .sorted { $0.timeH < $1.timeH }
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
        let sourceURL: URL
        if FileManager.default.fileExists(atPath: url.path) {
            sourceURL = url
        } else if let legacyURL = legacyFileURL(named: filename),
                  FileManager.default.fileExists(atPath: legacyURL.path) {
            sourceURL = legacyURL
        } else {
            return defaultValue
        }

        do {
            let data = try Data(contentsOf: sourceURL)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DoseRecordingError.readFailed
        }
    }

    private static func fileURL(named fileName: String) throws -> URL {
        let directory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedStore.appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(fileName)
        } catch {
            throw DoseRecordingError.writeFailed
        }
    }

    private static func legacyFileURL(named fileName: String) -> URL? {
        let legacyDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let sharedDirectory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSharedStore.appGroupIdentifier
        )
        guard sharedDirectory?.path != legacyDirectory.path else { return nil }
        return legacyDirectory.appendingPathComponent(fileName)
    }
}
