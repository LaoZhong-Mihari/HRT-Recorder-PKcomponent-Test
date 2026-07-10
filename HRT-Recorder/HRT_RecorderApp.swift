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
    @StateObject private var doseStoreController: DoseStoreController
    @StateObject private var labReportStore: PersistedStore<[LabReport]>
    @StateObject private var medicationPlanStore: PersistedStore<[MedicationPlan]>
    @StateObject private var notificationCoordinator: NotificationCoordinator
    @StateObject private var timelineVM: DoseTimelineVM
    @StateObject private var medicationVM: MedicationPlanVM
    @StateObject private var watchDoseReceiver = WatchDoseReceiver()
    
    init() {
        #if DEBUG && LAB_REPORT_SELF_TESTS
        LabReportOCRFallbackSelfTest.runIfRequested()
        Task {
            await LabReportImagePipelineSelfTest.runIfRequested()
        }
        #endif

        let doseStoreController = DoseStoreController()
        let persistedLabReports = PersistedStore<[LabReport]>(
            filename: "lab_reports.json",
            defaultValue: []
        )
        let legacyLabSamples = PersistedStore<[LabSample]>(
            filename: "lab_samples.json",
            defaultValue: []
        )
        if persistedLabReports.value.isEmpty, !legacyLabSamples.value.isEmpty {
            persistedLabReports.value = Self.legacyReports(from: legacyLabSamples.value)
        }
        let persistedMedicationPlans = PersistedStore<[MedicationPlan]>(
            filename: "medication_plans.json",
            defaultValue: [],
            appGroupIdentifier: WidgetSharedStore.appGroupIdentifier
        )
        let notificationCoordinator = NotificationCoordinator()
        _doseStoreController = StateObject(wrappedValue: doseStoreController)
        _labReportStore = StateObject(wrappedValue: persistedLabReports)
        _medicationPlanStore = StateObject(wrappedValue: persistedMedicationPlans)
        _notificationCoordinator = StateObject(wrappedValue: notificationCoordinator)
        _timelineVM = StateObject(
            wrappedValue: DoseTimelineVM(
                initialEvents: doseStoreController.events,
                initialLabReports: persistedLabReports.value,
                onChange: { updated in
                    doseStoreController.commitPresentationChanges(proposed: updated).events
                },
                onLabReportsChange: { updated in
                    persistedLabReports.value = updated
                }
            )
        )
        _medicationVM = StateObject(
            wrappedValue: MedicationPlanVM(
                initialPlans: persistedMedicationPlans.value,
                notificationCoordinator: notificationCoordinator
            ) { updated in
                persistedMedicationPlans.value = updated
                persistedMedicationPlans.saveSync()
            }
        )
    }
    
    var body: some Scene {
        WindowGroup {
            TimelineScreen(vm: timelineVM, medicationVM: medicationVM)
                .task {
                    doseStoreController.startObserving()
                    doseStoreController.reload()
                    await medicationVM.configure()
                    refreshWidgetSnapshot(reloadTimelines: false)
                    AppIntentIndexingCoordinator.refreshMedicationIndex(plans: medicationVM.plans)
                    scheduleWidgetDoseHandoffConsumption()
                    watchDoseReceiver.start(
                        onReceiveDoseEvent: { event, modifiedAt in
                            timelineVM.save(event, modifiedAt: modifiedAt > 0 ? modifiedAt : nil)
                        },
                        onReplaceAllEvents: { events, modifiedAt in
                            timelineVM.mergeRemoteEvents(events, modifiedAt: modifiedAt > 0 ? modifiedAt : nil)
                        },
                        onDeleteEvents: { eventIDs, modifiedAt in
                            timelineVM.removeEvents(
                                withIDs: eventIDs,
                                modifiedAt: modifiedAt > 0 ? modifiedAt : nil
                            )
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
                .onReceive(doseStoreController.$snapshot) { snapshot in
                    guard snapshot.events != timelineVM.events else { return }
                    timelineVM.applyCanonicalSnapshot(
                        snapshot.events,
                        modifiedAt: snapshot.modifiedAt
                    )
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
                .onReceive(timelineVM.$labReports) { _ in
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
                    AppIntentIndexingCoordinator.refreshMedicationIndex(plans: medicationVM.plans)
                }
        }
        .onChange(of: phase) { newPhase in
            if newPhase == .active {
                scheduleWidgetDoseHandoffConsumption()
                Task {
                    doseStoreController.reload()
                    await timelineVM.beginBodyWeightHealthKitSync()
                    await timelineVM.refreshLatestBodyWeightSilently()
                    await medicationVM.refreshSystemState()
                    scheduleWidgetDoseHandoffConsumption()
                    refreshWidgetSnapshot()
                    AppIntentIndexingCoordinator.refreshMedicationIndex(plans: medicationVM.plans)
                }
            } else if newPhase == .inactive || newPhase == .background {
                labReportStore.saveSync()
                medicationPlanStore.saveSync()
                refreshWidgetSnapshot(reloadTimelines: false)
            }
        }
    }

    private func refreshWidgetSnapshot(reloadTimelines: Bool = true) {
        WidgetSnapshotCoordinator.writeSnapshot(
            events: timelineVM.events,
            bodyWeightKG: timelineVM.bodyWeightKG,
            labSamples: timelineVM.labSamples,
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

    private static func legacyReports(from samples: [LabSample]) -> [LabReport] {
        let grouped = Dictionary(grouping: samples) { sample in
            sample.reportID ?? sample.id
        }
        return grouped.map { reportID, samples in
            let collectedAt = samples.map(\.collectedAt).min() ?? Date()
            return LabReport(
                id: reportID,
                collectedAt: collectedAt,
                sourceKind: .manual,
                analytes: samples.map { sample in
                    LabAnalyteResult(
                        id: sample.id,
                        kind: sample.hormone == .estradiol ? .estradiol : .testosterone,
                        name: sample.analyteName ?? sample.hormone.displayName,
                        value: sample.concentration,
                        unitSymbol: sample.unit.symbol,
                        concentrationUnit: sample.unit,
                        sourceLine: sample.sourceLine
                    )
                }
            )
        }.sorted { $0.collectedAt < $1.collectedAt }
    }
}
