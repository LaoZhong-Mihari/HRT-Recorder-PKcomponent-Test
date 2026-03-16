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

    @Published var bodyWeightKG: Double {
        didSet {
            UserDefaults.standard.set(bodyWeightKG, forKey: weightKey)
        }
    }
    @Published var isSimulating: Bool = false
    
    private var cancellables = Set<AnyCancellable>()
    private var simulationGeneration: UInt64 = 0
    /// First event time used as zero reference (hours)
    private var baseT0: Double? = nil
    private var onChange: (([DoseEvent]) -> Void)?
    init() {
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0
        self.onChange = nil
        self.dayGroups = []
        setupSubscriptions()
        runSimulation()
    }

    init(initialEvents: [DoseEvent], onChange: (([DoseEvent]) -> Void)? = nil) {
        self.events = initialEvents
        self.onChange = onChange
        let saved = UserDefaults.standard.double(forKey: weightKey)
        self.bodyWeightKG = saved > 0 ? saved : 70.0
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

    // **NEW**: A single function to handle both adding and updating events.
    func save(_ event: DoseEvent) {
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
    
    func remove(at offsets: IndexSet) {
        events.remove(atOffsets: offsets)
        runSimulation()
    }

    func replaceAllEvents(_ newEvents: [DoseEvent]) {
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
        try await HealthKitService.shared.requestAuthorizationIfNeeded()
    }

    func importLatestBodyWeightFromHealthKit() async throws -> Double {
        let weightKG = try await HealthKitService.shared.fetchLatestBodyMassKG()
        bodyWeightKG = weightKG
        return weightKG
    }

    func refreshLatestBodyWeightSilently() async {
        guard let weightKG = try? await HealthKitService.shared.fetchLatestBodyMassKG() else {
            return
        }
        bodyWeightKG = weightKG
    }

    func updateBodyWeightAndSyncToHealthKit(_ newWeightKG: Double) async throws {
        bodyWeightKG = newWeightKG
        try await HealthKitService.shared.saveBodyMassKG(newWeightKG)
    }

    func concentration(at date: Date) -> Double? {
        guard let result else { return nil }
        let hourValue = date.timeIntervalSince1970 / 3600.0
        return result.concentration(at: hourValue)
    }
}
