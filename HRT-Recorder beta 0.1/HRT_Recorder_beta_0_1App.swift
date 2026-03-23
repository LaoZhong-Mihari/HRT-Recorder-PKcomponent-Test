//
//  HRT_Recorder_beta_0_1App.swift
//  HRT-Recorder beta 0.1
//
//  Created by wzzzz Shao on 2025/9/28.
//

import SwiftUI

@main
struct HRTRecorderBetaApp: App {
    @Environment(\.scenePhase) private var phase
    @AppStorage("healthkit.weight.authorization.requested") private var didRequestHealthKitWeightAuthorization = false
    @StateObject private var store: PersistedStore<[DoseEvent]>
    @StateObject private var timelineVM: DoseTimelineVM
    @StateObject private var watchDoseReceiver = WatchDoseReceiver()
    
    init() {
        let persistedStore = PersistedStore<[DoseEvent]>(
            filename: "dose_events.json",
            defaultValue: []
        )
        _store = StateObject(wrappedValue: persistedStore)
        _timelineVM = StateObject(wrappedValue: DoseTimelineVM(initialEvents: persistedStore.value) { updated in
            persistedStore.value = updated
        })
    }
    
    var body: some Scene {
        WindowGroup {
            TimelineScreen(vm: timelineVM)
                .task {
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
                }
                .onReceive(timelineVM.$eventsModifiedAt) { eventsModifiedAt in
                    watchDoseReceiver.syncToWatch(
                        events: timelineVM.events,
                        result: timelineVM.result,
                        bodyWeightKG: timelineVM.bodyWeightKG,
                        eventsModifiedAt: eventsModifiedAt
                    )
                }
        }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active {
                Task {
                    if !didRequestHealthKitWeightAuthorization {
                        try? await timelineVM.requestHealthKitAuthorization()
                        didRequestHealthKitWeightAuthorization = true
                    }
                    await timelineVM.refreshLatestBodyWeightSilently()
                }
            } else if newPhase == .inactive || newPhase == .background {
                store.saveSync()
            }
        }
    }
}
