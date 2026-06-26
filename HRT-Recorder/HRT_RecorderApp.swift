//
//  HRT_RecorderApp.swift
//  HRT-Recorder
//
//  Created by wzzzz Shao on 2025/9/28.
//

import SwiftUI

@main
struct HRTRecorderApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var store: PersistedStore<[DoseEvent]>
    @StateObject private var medicationPlanStore: PersistedStore<[MedicationPlan]>
    @StateObject private var notificationCoordinator: NotificationCoordinator
    @StateObject private var timelineVM: DoseTimelineVM
    @StateObject private var medicationVM: MedicationPlanVM
    @StateObject private var watchDoseReceiver = WatchDoseReceiver()
    
    init() {
        let persistedStore = PersistedStore<[DoseEvent]>(
            filename: "dose_events.json",
            defaultValue: []
        )
        let persistedMedicationPlans = PersistedStore<[MedicationPlan]>(
            filename: "medication_plans.json",
            defaultValue: []
        )
        let notificationCoordinator = NotificationCoordinator()
        _store = StateObject(wrappedValue: persistedStore)
        _medicationPlanStore = StateObject(wrappedValue: persistedMedicationPlans)
        _notificationCoordinator = StateObject(wrappedValue: notificationCoordinator)
        _timelineVM = StateObject(wrappedValue: DoseTimelineVM(initialEvents: persistedStore.value) { updated in
            persistedStore.value = updated
        })
        _medicationVM = StateObject(
            wrappedValue: MedicationPlanVM(
                initialPlans: persistedMedicationPlans.value,
                notificationCoordinator: notificationCoordinator
            ) { updated in
                persistedMedicationPlans.value = updated
            }
        )
    }
    
    var body: some Scene {
        WindowGroup {
            TimelineScreen(vm: timelineVM, medicationVM: medicationVM)
                .task {
                    await medicationVM.configure()
                    refreshWidgetSnapshot(reloadTimelines: false)
                    scheduleWidgetDoseHandoffConsumption()
                    watchDoseReceiver.start(
                        onReceiveDoseEvent: { event, modifiedAt in
                            timelineVM.save(event, modifiedAt: modifiedAt > 0 ? modifiedAt : nil)
                        },
                        onReplaceAllEvents: { events, modifiedAt in
                            timelineVM.replaceAllEvents(events, modifiedAt: modifiedAt > 0 ? modifiedAt : nil)
                        },
                        currentStateProvider: {
                            (
                                events: timelineVM.events,
                                result: timelineVM.result,
                                bodyWeightKG: timelineVM.bodyWeightKG,
                                eventsModifiedAt: timelineVM.eventsModifiedAt
                            )
                        }
                    )
                    watchDoseReceiver.syncToWatch(
                        events: timelineVM.events,
                        result: timelineVM.result,
                        bodyWeightKG: timelineVM.bodyWeightKG,
                        eventsModifiedAt: timelineVM.eventsModifiedAt
                    )
                }
                .onReceive(timelineVM.$events) { events in
                    watchDoseReceiver.syncToWatch(
                        events: events,
                        result: timelineVM.result,
                        bodyWeightKG: timelineVM.bodyWeightKG,
                        eventsModifiedAt: timelineVM.eventsModifiedAt
                    )
                    refreshWidgetSnapshot()
                }
                .onReceive(timelineVM.$result) { result in
                    watchDoseReceiver.syncToWatch(
                        events: timelineVM.events,
                        result: result,
                        bodyWeightKG: timelineVM.bodyWeightKG,
                        eventsModifiedAt: timelineVM.eventsModifiedAt
                    )
                }
                .onReceive(timelineVM.$bodyWeightKG) { bodyWeightKG in
                    watchDoseReceiver.syncToWatch(
                        events: timelineVM.events,
                        result: timelineVM.result,
                        bodyWeightKG: bodyWeightKG,
                        eventsModifiedAt: timelineVM.eventsModifiedAt
                    )
                    refreshWidgetSnapshot()
                }
                .onReceive(timelineVM.$eventsModifiedAt) { eventsModifiedAt in
                    watchDoseReceiver.syncToWatch(
                        events: timelineVM.events,
                        result: timelineVM.result,
                        bodyWeightKG: timelineVM.bodyWeightKG,
                        eventsModifiedAt: eventsModifiedAt
                    )
                }
                .onReceive(timelineVM.$selectedConcentrationUnit) { _ in
                    refreshWidgetSnapshot()
                }
                .onReceive(medicationVM.$plans) { _ in
                    refreshWidgetSnapshot()
                }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .active {
                scheduleWidgetDoseHandoffConsumption()
                Task {
                    await timelineVM.beginBodyWeightHealthKitSync()
                    await timelineVM.refreshLatestBodyWeightSilently()
                    await medicationVM.refreshSystemState()
                    scheduleWidgetDoseHandoffConsumption()
                    refreshWidgetSnapshot()
                }
            } else if newPhase == .inactive || newPhase == .background {
                store.saveSync()
                medicationPlanStore.saveSync()
                refreshWidgetSnapshot(reloadTimelines: false)
            }
        }
    }

    private func refreshWidgetSnapshot(reloadTimelines: Bool = true) {
        WidgetSnapshotCoordinator.writeSnapshot(
            events: timelineVM.events,
            bodyWeightKG: timelineVM.bodyWeightKG,
            plans: medicationVM.plans,
            reloadTimelines: reloadTimelines
        )
    }

    private func scheduleWidgetDoseHandoffConsumption() {
        Task { @MainActor in
            for delay in [UInt64(0), 250_000_000, 1_000_000_000, 2_000_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                consumeWidgetDoseHandoffIfNeeded()
            }
        }
    }

    @MainActor
    private func consumeWidgetDoseHandoffIfNeeded() {
        guard let handoff = WidgetSharedStore.consumeDoseHandoff() else { return }
        _ = medicationVM.prepareDoseSeed(
            forWidgetOptionID: handoff.optionID,
            requestedAt: handoff.requestedAt
        )
    }
}
