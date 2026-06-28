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
    var id: String { day }
    let day: String
    let events: [DoseEvent]
}

private func makeTimelineDayGroups(from events: [DoseEvent]) -> [TimelineDayGroup] {
    let sortedEvents = events.sorted { $0.timeH < $1.timeH }

    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")

    let groupedDictionary = Dictionary(grouping: sortedEvents) { formatter.string(from: $0.date) }

    return groupedDictionary.map { TimelineDayGroup(day: $0.key, events: $0.value) }
        .sorted { ($0.events.first?.timeH ?? .leastNormalMagnitude) > ($1.events.first?.timeH ?? .leastNormalMagnitude) }
}

enum BodyWeightSyncSource: String {
    case healthKit
    case manual
}

@MainActor
final class DoseTimelineVM: ObservableObject {
    @Published var events: [DoseEvent] = [] {
        didSet {
            onChange?(events)
        }
    }
    @Published var labSamples: [LabSample] = [] {
        didSet {
            onLabSamplesChange?(labSamples)
            runSimulation()
        }
    }
    @Published var result: SimulationResult? = nil
    @Published private(set) var calibrationResult = CalibrationResult()
    var dayGroups: [TimelineDayGroup] {
        let visibleEvents = events.filter { $0.appearsInTimeline(for: selectedHormone) }
        return makeTimelineDayGroups(from: visibleEvents)
    }
    @Published var selectedHormone: SimulatedHormone = .estradiol {
        didSet {
            UserDefaults.standard.set(selectedHormone.rawValue, forKey: selectedHormoneKey)
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
    private let selectedHormoneKey = "timeline.selectedHormone"

    @Published private(set) var eventsModifiedAt: TimeInterval {
        didSet {
            UserDefaults.standard.set(eventsModifiedAt, forKey: eventsModifiedKey)
        }
    }

    @Published var bodyWeightKG: Double {
        didSet {
            UserDefaults.standard.set(bodyWeightKG, forKey: weightKey)
        }
    }
    @Published private(set) var lastBodyWeightSyncDate: Date?
    @Published private(set) var bodyWeightSyncSource: BodyWeightSyncSource?
    @Published var isSimulating: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var simulationGeneration: UInt64 = 0
    /// First event time used as zero reference (hours)
    private var baseT0: Double? = nil
    private var onChange: (([DoseEvent]) -> Void)?
    private var onLabSamplesChange: (([LabSample]) -> Void)?
    init() {
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let initialSelectedHormone: SimulatedHormone
        if let raw = UserDefaults.standard.string(forKey: selectedHormoneKey),
           let hormone = SimulatedHormone(rawValue: raw) {
            initialSelectedHormone = hormone
        } else {
            initialSelectedHormone = .estradiol
        }
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
        self.onLabSamplesChange = nil
        setupSubscriptions()
        runSimulation()
    }

    init(
        initialEvents: [DoseEvent],
        initialLabSamples: [LabSample] = [],
        onChange: (([DoseEvent]) -> Void)? = nil,
        onLabSamplesChange: (([LabSample]) -> Void)? = nil
    ) {
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        self.events = initialEvents
        self.labSamples = initialLabSamples
        self.onChange = onChange
        self.onLabSamplesChange = onLabSamplesChange
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let initialSelectedHormone: SimulatedHormone
        if let raw = UserDefaults.standard.string(forKey: selectedHormoneKey),
           let hormone = SimulatedHormone(rawValue: raw) {
            initialSelectedHormone = hormone
        } else {
            initialSelectedHormone = .estradiol
        }
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

    func replaceAllEvents(_ newEvents: [DoseEvent], modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        events = newEvents.sorted { $0.timeH < $1.timeH }
        runSimulation()
    }

    func saveLabSample(_ sample: LabSample) {
        saveLabSamples([sample])
    }

    func saveLabSamples(_ samples: [LabSample]) {
        guard !samples.isEmpty else { return }
        var updatedSamples = labSamples
        for sample in samples {
            if let index = updatedSamples.firstIndex(where: { $0.id == sample.id }) {
                updatedSamples[index] = sample
            } else {
                updatedSamples.append(sample)
            }
        }
        labSamples = updatedSamples.sorted { $0.timeH < $1.timeH }
    }

    func removeLabSamples(withIDs ids: [UUID]) {
        guard !ids.isEmpty else { return }
        labSamples.removeAll { ids.contains($0.id) }
    }

    var availableConcentrationUnits: [ConcentrationUnit] {
        selectedHormone.supportedConcentrationUnits
    }

    var labResultsSettingsSummary: String {
        guard !labSamples.isEmpty else {
            return String(localized: "No saved hormone lab results")
        }

        let countText = String.localizedStringWithFormat(
            String(localized: "%d saved result(s)"),
            labSamples.count
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
        guard !events.isEmpty else {
            result = nil
            isSimulating = false
            return
        }

        let selectedHormone = self.selectedHormone
        let simulatedEvents = events.filter(\.participatesInSimulation)
            .filter { $0.simulatedHormone == selectedHormone }
        guard !simulatedEvents.isEmpty else {
            result = nil
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

        DispatchQueue.global(qos: .userInitiated).async {
            let calibration = PKCalibrator.fit(
                events: allSimulatedEvents,
                labs: labSamples,
                bodyWeightKG: weight
            )
            let simulationResult = simulateTimelineResult(
                events: sortedEvents,
                hormone: selectedHormone,
                bodyWeightKG: weight,
                calibration: calibration
            )

            DispatchQueue.main.async {
                guard generation == self.simulationGeneration else { return }
                self.calibrationResult = calibration
                self.result = simulationResult.converted(to: self.selectedConcentrationUnit)
                self.isSimulating = false
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
        guard let result else { return nil }
        let hourValue = date.timeIntervalSince1970 / 3600.0
        return result.concentration(at: hourValue)
    }

    private func applySelectedConcentrationUnit(_ unit: ConcentrationUnit) {
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
