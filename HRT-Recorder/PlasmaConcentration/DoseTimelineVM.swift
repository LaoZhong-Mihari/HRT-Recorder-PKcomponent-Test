//
//  DoseTimelineVM.swift
//  HRTRecorder
//
//    Created by mihari-zhong on 2025/8/1.
//

import Foundation
import Combine
import SwiftUI

struct TimelineDayGroup: Identifiable {
    let id: Date
    let day: String
    let events: [DoseEvent]
}

private func makeTimelineDayGroups(from events: [DoseEvent]) -> [TimelineDayGroup] {
    let sortedEvents = events.sorted { $0.timeH < $1.timeH }
    let calendar = Calendar.autoupdatingCurrent

    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")

    let groupedDictionary = Dictionary(grouping: sortedEvents) {
        calendar.startOfDay(for: $0.date)
    }

    return groupedDictionary.map { dayStart, events in
        TimelineDayGroup(
            id: dayStart,
            day: formatter.string(from: dayStart),
            events: events
        )
    }
    .sorted { $0.id > $1.id }
}

enum BodyWeightSyncSource: String {
    case healthKit
    case manual
}

@MainActor
final class DoseTimelineVM: ObservableObject {
    @Published var events: [DoseEvent] = [] {
        didSet {
            exactConcentrationCache.removeAll(keepingCapacity: true)
            refreshTimelineDayGroups()
            guard !isApplyingCanonicalSnapshot, let onChange else { return }
            let canonicalEvents = onChange(events)
            guard canonicalEvents != events else { return }
            isApplyingCanonicalSnapshot = true
            events = canonicalEvents.sorted { $0.timeH < $1.timeH }
            // Assigning a property from inside its own observer does not invoke
            // `didSet` again, so refresh the cache from the canonical snapshot.
            refreshTimelineDayGroups()
            isApplyingCanonicalSnapshot = false
        }
    }
    @Published var labReports: [LabReport] = [] {
        didSet {
            onLabReportsChange?(labReports)
            runSimulation()
        }
    }
    @Published var result: SimulationResult? = nil
    @Published private(set) var calibrationResult = CalibrationResult()
    @Published private(set) var dayGroups: [TimelineDayGroup] = []
    var allLabSamples: [LabSample] {
        labReports
            .flatMap(\.calibrationSamples)
            .sorted { $0.timeH < $1.timeH }
    }
    var labSamples: [LabSample] {
        allLabSamples.filter { $0.hormone == selectedHormone }
    }
    @Published private(set) var selectedHormone: SimulatedHormone = .estradiol {
        didSet {
            exactConcentrationCache.removeAll(keepingCapacity: true)
            refreshTimelineDayGroups()
            let preferredUnit = preferredConcentrationUnit(for: selectedHormone)
            if selectedConcentrationUnit != preferredUnit {
                selectedConcentrationUnit = preferredUnit
            } else {
                runSimulation()
            }
        }
    }
    @Published private(set) var selectedConcentrationUnit: ConcentrationUnit
    private let weightKey = "user.weightKg"
    private let eventsModifiedKey = "dose.events.modifiedAt"
    private let weightSyncDateKey = "user.weight.syncDate"
    private let weightSyncSourceKey = "user.weight.syncSource"
    private let hrtProfilePreferences: HRTProfilePreferences

    @Published private(set) var eventsModifiedAt: TimeInterval {
        didSet {
            UserDefaults.standard.set(eventsModifiedAt, forKey: eventsModifiedKey)
        }
    }

    @Published var bodyWeightKG: Double {
        didSet {
            exactConcentrationCache.removeAll(keepingCapacity: true)
            UserDefaults.standard.set(bodyWeightKG, forKey: weightKey)
        }
    }
    @Published private(set) var lastBodyWeightSyncDate: Date?
    @Published private(set) var bodyWeightSyncSource: BodyWeightSyncSource?
    @Published var isSimulating: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var simulationGeneration: UInt64 = 0
    private var simulationTask: Task<Void, Never>?
    private var exactConcentrationCache: [Double: Double] = [:]
    /// First event time used as zero reference (hours)
    private var baseT0: Double? = nil
    private var onChange: (([DoseEvent]) -> [DoseEvent])?
    private var isApplyingCanonicalSnapshot = false
    private var onLabReportsChange: (([LabReport]) -> Void)?
    init(hrtProfilePreferences: HRTProfilePreferences = HRTProfilePreferences()) {
        self.hrtProfilePreferences = hrtProfilePreferences
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let initialSelectedHormone = hrtProfilePreferences.suggestedHormone
        self.selectedHormone = initialSelectedHormone
        self.selectedConcentrationUnit = initialSelectedHormone.preferredUnit(
            from: UserDefaults.standard.string(forKey: Self.concentrationUnitKey(for: initialSelectedHormone))
        )
        let syncDate = UserDefaults.standard.double(forKey: weightSyncDateKey)
        self.lastBodyWeightSyncDate = syncDate > 0 ? Date(timeIntervalSince1970: syncDate) : nil
        if let rawValue = UserDefaults.standard.string(forKey: weightSyncSourceKey) {
            self.bodyWeightSyncSource = BodyWeightSyncSource(rawValue: rawValue)
        } else {
            self.bodyWeightSyncSource = nil
        }
        self.onChange = nil
        self.onLabReportsChange = nil
        setupSubscriptions()
        refreshTimelineDayGroups()
        runSimulation()
    }

    init(
        initialEvents: [DoseEvent],
        initialLabReports: [LabReport] = [],
        onChange: (([DoseEvent]) -> [DoseEvent])? = nil,
        onLabReportsChange: (([LabReport]) -> Void)? = nil,
        hrtProfilePreferences: HRTProfilePreferences = HRTProfilePreferences()
    ) {
        self.hrtProfilePreferences = hrtProfilePreferences
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        self.events = initialEvents
        self.labReports = initialLabReports
        self.onChange = onChange
        self.onLabReportsChange = onLabReportsChange
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let initialSelectedHormone = hrtProfilePreferences.suggestedHormone
        self.selectedHormone = initialSelectedHormone
        self.selectedConcentrationUnit = initialSelectedHormone.preferredUnit(
            from: UserDefaults.standard.string(forKey: Self.concentrationUnitKey(for: initialSelectedHormone))
        )
        let syncDate = UserDefaults.standard.double(forKey: weightSyncDateKey)
        self.lastBodyWeightSyncDate = syncDate > 0 ? Date(timeIntervalSince1970: syncDate) : nil
        if let rawValue = UserDefaults.standard.string(forKey: weightSyncSourceKey) {
            self.bodyWeightSyncSource = BodyWeightSyncSource(rawValue: rawValue)
        } else {
            self.bodyWeightSyncSource = nil
        }
        setupSubscriptions()
        refreshTimelineDayGroups()
        if !initialEvents.isEmpty {
            runSimulation()
        }
    }
    
    private func setupSubscriptions() {
        $bodyWeightKG
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.runSimulation() }
            .store(in: &cancellables)

        $selectedConcentrationUnit
            .dropFirst()
            .sink { [weak self] unit in
                self?.applySelectedConcentrationUnit(unit)
            }
            .store(in: &cancellables)
    }

    private func refreshTimelineDayGroups() {
        let visibleEvents = events.filter {
            $0.appearsInTimeline(for: selectedHormone)
        }
        dayGroups = makeTimelineDayGroups(from: visibleEvents)
    }

    var requiresHRTProfileSelection: Bool {
        hrtProfilePreferences.requiresSelectionPrompt
    }

    func selectHRTType(_ hormone: SimulatedHormone) {
        hrtProfilePreferences.confirm(hormone)
        guard selectedHormone != hormone else {
            runSimulation()
            return
        }

        // The picker and lab filtering change immediately. Invalidate the old
        // async generation and remove its curve so the UI cannot briefly pair
        // the new HRT label with the previous hormone's simulation.
        simulationGeneration &+= 1
        result = nil
        calibrationResult = CalibrationResult()
        isSimulating = false
        selectedHormone = hormone
    }

    private func resolvedModifiedAt(_ modifiedAt: TimeInterval?) -> TimeInterval {
        if let modifiedAt, modifiedAt > 0 {
            return modifiedAt
        }
        return Date().timeIntervalSince1970
    }

    // **NEW**: A single function to handle both adding and updating events.
    func save(_ event: DoseEvent, modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        var updatedEvents = events
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            // 更新已有事件 —— 保持绝对小时不变（1970-epoch）
            updatedEvents[index] = event
        } else {
            // 新增事件 —— 直接存绝对小时
            updatedEvents.append(event)
        }
        events = updatedEvents.sorted { $0.timeH < $1.timeH }
        runSimulation()
    }

    func remove(at offsets: IndexSet, modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        var updatedEvents = events
        updatedEvents.remove(atOffsets: offsets)
        events = updatedEvents
        runSimulation()
    }

    /// Applies a repository snapshot without turning it into a new UI write.
    func applyCanonicalSnapshot(_ newEvents: [DoseEvent], modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        isApplyingCanonicalSnapshot = true
        events = newEvents.sorted { $0.timeH < $1.timeH }
        isApplyingCanonicalSnapshot = false
        runSimulation()
    }

    /// Legacy Watch snapshots do not carry deletions. Merge their events into
    /// the canonical store rather than replacing phone/Siri entries.
    func mergeRemoteEvents(_ newEvents: [DoseEvent], modifiedAt: TimeInterval? = nil) {
        var merged = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for event in newEvents {
            merged[event.id] = event
        }
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        events = merged.values.sorted { $0.timeH < $1.timeH }
        runSimulation()
    }

    func removeEvents(withIDs ids: [UUID], modifiedAt: TimeInterval? = nil) {
        guard !ids.isEmpty else { return }
        let idSet = Set(ids)
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        events.removeAll { idSet.contains($0.id) }
        runSimulation()
    }

    func saveLabReport(_ report: LabReport) {
        saveLabReports([report])
    }

    func saveLabReports(_ reports: [LabReport]) {
        guard !reports.isEmpty else { return }
        var updatedReports = labReports
        for report in reports {
            if let index = updatedReports.firstIndex(where: { $0.id == report.id }) {
                updatedReports[index] = report
            } else {
                updatedReports.append(report)
            }
        }
        labReports = updatedReports.sorted { $0.collectedAt < $1.collectedAt }
    }

    func removeLabReports(withIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        labReports.removeAll { ids.contains($0.id) }
    }

    func saveLabSample(_ sample: LabSample) {
        saveLabSamples([sample])
    }

    func saveLabSamples(_ samples: [LabSample]) {
        let reports = samples.map { sample in
            LabReport(
                id: sample.reportID ?? UUID(),
                collectedAt: sample.collectedAt,
                sourceKind: .manual,
                analytes: [
                    LabAnalyteResult(
                        id: sample.id,
                        kind: labAnalyteKind(for: sample.hormone),
                        name: sample.analyteName ?? sample.hormone.displayName,
                        value: sample.concentration,
                        unitSymbol: sample.unit.symbol,
                        concentrationUnit: sample.unit,
                        sourceLine: sample.sourceLine
                    )
                ]
            )
        }
        saveLabReports(reports)
    }

    func removeLabSamples(withIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        labReports = labReports.compactMap { report in
            var updated = report
            updated.analytes.removeAll { ids.contains($0.id) }
            return updated.analytes.isEmpty ? nil : updated
        }
    }

    var availableConcentrationUnits: [ConcentrationUnit] {
        selectedHormone.supportedConcentrationUnits
    }

    var labResultsSettingsSummary: String {
        guard !labReports.isEmpty else {
            return String(localized: "No saved hormone lab results")
        }

        let sampleCount = labSamples.count
        let countText = String.localizedStringWithFormat(
            String(localized: "%d report(s), %d calibration point(s)"),
            labReports.count,
            sampleCount
        )

        if let info = calibrationResult.infoByHormone[selectedHormone] {
            return String.localizedStringWithFormat(
                String(localized: "%@ · %@ calibrated from %d sample(s)"),
                countText,
                selectedHormone.displayName,
                info.sampleCount
            )
        }

        return countText
    }

    func setSelectedConcentrationUnit(_ unit: ConcentrationUnit) {
        guard unit.isSupported(for: selectedHormone), selectedConcentrationUnit != unit else { return }
        selectedConcentrationUnit = unit
    }
    
    func runSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        exactConcentrationCache.removeAll(keepingCapacity: true)

        guard !events.isEmpty else {
            simulationGeneration &+= 1
            result = nil
            calibrationResult = CalibrationResult()
            isSimulating = false
            return
        }

        let selectedHormone = self.selectedHormone
        let simulatedEvents = events.filter(\.participatesInSimulation)
            .filter { $0.simulatedHormone == selectedHormone }
        guard !simulatedEvents.isEmpty else {
            simulationGeneration &+= 1
            result = nil
            calibrationResult = CalibrationResult()
            isSimulating = false
            return
        }

        let allSimulatedEvents = events.filter(\.participatesInSimulation)
        let sortedEvents = simulatedEvents
        let weight = self.bodyWeightKG
        let labSamples = self.labSamples
        
        isSimulating = true
        simulationGeneration &+= 1
        let generation = simulationGeneration

        simulationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let cancellationCheck: @Sendable () -> Bool = { Task.isCancelled }
            let calibration = PKCalibrator.fit(
                events: allSimulatedEvents,
                labs: labSamples,
                bodyWeightKG: weight,
                cancellationCheck: cancellationCheck
            )
            guard !Task.isCancelled else { return }
            let simulationResult = simulateTimelineResult(
                events: sortedEvents,
                hormone: selectedHormone,
                bodyWeightKG: weight,
                calibration: calibration,
                cancellationCheck: cancellationCheck
            )
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard generation == self.simulationGeneration else { return }
                self.exactConcentrationCache.removeAll(keepingCapacity: true)
                self.calibrationResult = calibration
                self.result = simulationResult.converted(to: self.selectedConcentrationUnit)
                self.isSimulating = false
                self.simulationTask = nil
            }
        }
    }

    func requestHealthKitAuthorization() async throws {
        try await HealthKitService.shared.requestBodyMassAuthorizationIfNeeded()
    }

    func importLatestBodyWeightFromHealthKit() async throws -> Double {
        let sample = try await HealthKitService.shared.fetchLatestBodyMassSample()
        applyBodyWeightFromHealthKit(sample.weightKG, at: sample.recordedAt)
        return sample.weightKG
    }

    func refreshLatestBodyWeightSilently() async {
        guard await HealthKitService.shared.canAccessBodyMassWithoutPrompt() else {
            return
        }
        guard let sample = try? await HealthKitService.shared.fetchLatestBodyMassSample() else {
            return
        }
        applyBodyWeightFromHealthKit(sample.weightKG, at: sample.recordedAt)
    }

    func updateBodyWeightAndSyncToHealthKit(_ newWeightKG: Double) async throws {
        bodyWeightKG = newWeightKG
        try await HealthKitService.shared.saveBodyMassKG(newWeightKG)
        storeWeightSyncMetadata(source: .manual, date: Date())
    }

    func updateBodyWeightLocally(_ newWeightKG: Double) {
        bodyWeightKG = newWeightKG
        storeWeightSyncMetadata(source: .manual, date: Date())
    }

    func beginBodyWeightHealthKitSync() async {
        guard await HealthKitService.shared.canAccessBodyMassWithoutPrompt() else {
            return
        }
        do {
            try await HealthKitService.shared.startBodyMassBackgroundSync { [weak self] weightKG, date in
                self?.applyBodyWeightFromHealthKit(weightKG, at: date)
            }
        } catch {
            #if DEBUG
            print("Body mass sync setup failed:", error)
            #endif
        }
    }

    func shouldRequestHealthKitAuthorization() async -> Bool {
        (try? await HealthKitService.shared.shouldRequestBodyMassAuthorization()) ?? false
    }

    func concentration(at date: Date) -> Double? {
        guard result != nil else { return nil }
        let hourValue = date.timeIntervalSince1970 / 3600.0
        if let cached = exactConcentrationCache[hourValue] {
            return cached
        }
        // Lab comparisons should use the same exact analytic model as
        // calibration, not interpolation from the chart's bounded sample grid.
        let simulatedEvents = events.filter {
            $0.participatesInSimulation && $0.simulatedHormone == selectedHormone
        }
        guard !simulatedEvents.isEmpty else { return nil }
        let engine = SimulationEngine(
            events: simulatedEvents,
            hormone: selectedHormone,
            bodyWeightKG: bodyWeightKG,
            startTimeH: hourValue - 0.5,
            endTimeH: hourValue + 0.5,
            numberOfSteps: 2,
            vdPerKGOverride: calibrationResult.vdPerKGOverride(for: selectedHormone),
            kaMultiplier: calibrationResult.kaMultiplier(for: selectedHormone)
        )
        let nativeValue = engine.predictedConcentration(atTimeH: hourValue)
        let convertedValue = ConcentrationUnit.convert(
            nativeValue,
            from: selectedHormone.concentrationUnit,
            to: selectedConcentrationUnit,
            hormone: selectedHormone
        )
        exactConcentrationCache[hourValue] = convertedValue
        return convertedValue
    }

    private func applySelectedConcentrationUnit(_ unit: ConcentrationUnit) {
        exactConcentrationCache.removeAll(keepingCapacity: true)
        guard unit.isSupported(for: selectedHormone) else {
            let fallback = selectedHormone.concentrationUnit
            if selectedConcentrationUnit != fallback {
                selectedConcentrationUnit = fallback
            }
            return
        }

        UserDefaults.standard.set(unit.rawValue, forKey: Self.concentrationUnitKey(for: selectedHormone))

        if let result, result.displayMetadata.hormone == selectedHormone {
            self.result = result.converted(to: unit)
        } else if !events.isEmpty {
            runSimulation()
        }
    }

    private func preferredConcentrationUnit(for hormone: SimulatedHormone) -> ConcentrationUnit {
        hormone.preferredUnit(from: UserDefaults.standard.string(forKey: Self.concentrationUnitKey(for: hormone)))
    }

    private static func concentrationUnitKey(for hormone: SimulatedHormone) -> String {
        "timeline.selectedConcentrationUnit.\(hormone.rawValue)"
    }

    private func labAnalyteKind(for hormone: SimulatedHormone) -> LabAnalyteKind {
        switch hormone {
        case .estradiol:
            return .estradiol
        case .testosterone:
            return .testosterone
        }
    }

    var bodyWeightHealthStatusText: String {
        let weightText = String(format: "%.1f kg", locale: Locale.current, bodyWeightKG)
        guard let lastBodyWeightSyncDate, let bodyWeightSyncSource else {
            return String.localizedStringWithFormat(
                String(localized: "settings.weight.status.current"),
                weightText
            )
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        let relative = formatter.localizedString(for: lastBodyWeightSyncDate, relativeTo: Date())

        switch bodyWeightSyncSource {
        case .healthKit:
            return String.localizedStringWithFormat(
                String(localized: "settings.weight.status.health"),
                weightText,
                relative
            )
        case .manual:
            return String.localizedStringWithFormat(
                String(localized: "settings.weight.status.manual"),
                weightText,
                relative
            )
        }
    }

    private func applyBodyWeightFromHealthKit(_ weightKG: Double, at date: Date) {
        bodyWeightKG = weightKG
        storeWeightSyncMetadata(source: .healthKit, date: date)
    }

    private func storeWeightSyncMetadata(source: BodyWeightSyncSource, date: Date) {
        lastBodyWeightSyncDate = date
        bodyWeightSyncSource = source
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: weightSyncDateKey)
        UserDefaults.standard.set(source.rawValue, forKey: weightSyncSourceKey)
    }
}
