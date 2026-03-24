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
            dayGroups = makeTimelineDayGroups(from: events)
            onChange?(events)
        }
    }
    @Published var result: SimulationResult? = nil
    @Published private(set) var dayGroups: [TimelineDayGroup] = []
    private let weightKey = "user.weightKg"
    private let eventsModifiedKey = "dose.events.modifiedAt"
    private let weightSyncDateKey = "user.weight.syncDate"
    private let weightSyncSourceKey = "user.weight.syncSource"

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
    init() {
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let syncDate = UserDefaults.standard.double(forKey: weightSyncDateKey)
        self.lastBodyWeightSyncDate = syncDate > 0 ? Date(timeIntervalSince1970: syncDate) : nil
        if let rawValue = UserDefaults.standard.string(forKey: weightSyncSourceKey) {
            self.bodyWeightSyncSource = BodyWeightSyncSource(rawValue: rawValue)
        } else {
            self.bodyWeightSyncSource = nil
        }
        self.onChange = nil
        self.dayGroups = []
        setupSubscriptions()
        runSimulation()
    }

    init(initialEvents: [DoseEvent], onChange: (([DoseEvent]) -> Void)? = nil) {
        let savedModifiedAt = UserDefaults.standard.double(forKey: eventsModifiedKey)
        self.events = initialEvents
        self.onChange = onChange
        self.eventsModifiedAt = savedModifiedAt > 0 ? savedModifiedAt : 0
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        let syncDate = UserDefaults.standard.double(forKey: weightSyncDateKey)
        self.lastBodyWeightSyncDate = syncDate > 0 ? Date(timeIntervalSince1970: syncDate) : nil
        if let rawValue = UserDefaults.standard.string(forKey: weightSyncSourceKey) {
            self.bodyWeightSyncSource = BodyWeightSyncSource(rawValue: rawValue)
        } else {
            self.bodyWeightSyncSource = nil
        }
        self.dayGroups = makeTimelineDayGroups(from: initialEvents)
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
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            // 更新已有事件 —— 保持绝对小时不变（1970-epoch）
            events[index] = event
        } else {
            // 新增事件 —— 直接存绝对小时
            events.append(event)
            events.sort { $0.timeH < $1.timeH }
        }
        runSimulation()
    }

    func remove(at offsets: IndexSet, modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        events.remove(atOffsets: offsets)
        runSimulation()
    }

    func replaceAllEvents(_ newEvents: [DoseEvent], modifiedAt: TimeInterval? = nil) {
        eventsModifiedAt = resolvedModifiedAt(modifiedAt)
        events = newEvents.sorted { $0.timeH < $1.timeH }
        runSimulation()
    }
    
    func runSimulation() {
        guard !events.isEmpty else {
            result = nil
            isSimulating = false
            return
        }
        
        let sortedEvents = events
        let weight = self.bodyWeightKG
        
        isSimulating = true
        simulationGeneration &+= 1
        let generation = simulationGeneration

        DispatchQueue.global(qos: .userInitiated).async {
            let simulationResult = simulateTimelineResult(events: sortedEvents, bodyWeightKG: weight)

            DispatchQueue.main.async {
                guard generation == self.simulationGeneration else { return }
                self.result = simulationResult
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

    func concentration(at date: Date) -> Double? {
        guard let result else { return nil }
        let hourValue = date.timeIntervalSince1970 / 3600.0
        return result.concentration(at: hourValue)
    }

    var bodyWeightHealthStatusText: String {
        let weightText = String(format: "%.1f kg", locale: Locale.current, bodyWeightKG)
        guard let lastBodyWeightSyncDate, let bodyWeightSyncSource else {
            return "Current \(weightText)"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale.current
        let relative = formatter.localizedString(for: lastBodyWeightSyncDate, relativeTo: Date())

        switch bodyWeightSyncSource {
        case .healthKit:
            return "Current \(weightText) · synced from Health \(relative)"
        case .manual:
            return "Current \(weightText) · manually updated \(relative)"
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
