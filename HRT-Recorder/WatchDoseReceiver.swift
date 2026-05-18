import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchDoseReceiver: NSObject, ObservableObject {
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var onReceiveDoseEvent: ((DoseEvent, TimeInterval) -> Void)?
    private var onReplaceAllEvents: (([DoseEvent], TimeInterval) -> Void)?
    private var currentStateProvider: (() -> (events: [DoseEvent], result: SimulationResult?, bodyWeightKG: Double, eventsModifiedAt: TimeInterval))?

    func start(
        onReceiveDoseEvent: @escaping (DoseEvent, TimeInterval) -> Void,
        onReplaceAllEvents: @escaping ([DoseEvent], TimeInterval) -> Void,
        currentStateProvider: @escaping () -> (events: [DoseEvent], result: SimulationResult?, bodyWeightKG: Double, eventsModifiedAt: TimeInterval)
    ) {
        self.onReceiveDoseEvent = onReceiveDoseEvent
        self.onReplaceAllEvents = onReplaceAllEvents
        self.currentStateProvider = currentStateProvider

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func syncToWatch(events: [DoseEvent], result: SimulationResult?, bodyWeightKG: Double, eventsModifiedAt: TimeInterval) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let bridgeEvents = events.map(WatchDoseBridgeEvent.init)
        let payload = WatchDoseSnapshot(
            events: bridgeEvents,
            chartPoints: nil,
            bodyWeightKG: bodyWeightKG,
            eventsModifiedAt: eventsModifiedAt
        )

        guard let data = try? encoder.encode(payload) else { return }
        try? session.updateApplicationContext(["doseSnapshot": data])
    }

    private func makeDoseEvent(from bridge: WatchDoseBridgeEvent) -> DoseEvent? {
        guard let route = DoseEvent.Route(rawValue: bridge.routeRawValue) else {
            return nil
        }

        let extras = bridge.extras.compactMapKeys { DoseEvent.ExtraKey(rawValue: $0) }
        let category = bridge.categoryRawValue.flatMap(MedicationCategory.init(rawValue:))
        let recordOnly = bridge.recordOnlyOralMedicationRawValue.flatMap(RecordOnlyOralMedication.init(rawValue:))
        let compound = (bridge.compoundRawValue ?? bridge.esterRawValue).flatMap(Compound.init(rawValue:))
            ?? Compound.fallback(
                for: category,
                route: route,
                recordOnlyOralMedication: recordOnly
            )
        return DoseEvent(
            id: bridge.id,
            category: category,
            route: route,
            timeH: bridge.timeH,
            doseMG: bridge.doseMG,
            compound: compound,
            extras: extras,
            recordOnlyOralMedication: recordOnly
        )
    }

    private func decodeDoseEvent(from payload: Data) -> (event: DoseEvent, modifiedAt: TimeInterval)? {
        if let wrapped = try? decoder.decode(WatchDoseEventPayload.self, from: payload),
           let event = makeDoseEvent(from: wrapped.event) {
            return (event, wrapped.modifiedAt)
        }

        guard let bridge = try? decoder.decode(WatchDoseBridgeEvent.self, from: payload),
              let event = makeDoseEvent(from: bridge) else {
            return nil
        }

        return (event, 0)
    }

    private func decodeEventList(from payload: Data) -> (events: [DoseEvent], modifiedAt: TimeInterval)? {
        if let wrapped = try? decoder.decode(WatchDoseReplacePayload.self, from: payload) {
            return (
                wrapped.events.compactMap { self.makeDoseEvent(from: $0) },
                wrapped.modifiedAt
            )
        }

        guard let watchEvents = try? decoder.decode([WatchDoseBridgeEvent].self, from: payload) else {
            return nil
        }

        return (watchEvents.compactMap { self.makeDoseEvent(from: $0) }, 0)
    }

    private func pushCurrentSnapshotToWatch() {
        guard let state = currentStateProvider?() else { return }
        syncToWatch(
            events: state.events,
            result: state.result,
            bodyWeightKG: state.bodyWeightKG,
            eventsModifiedAt: state.eventsModifiedAt
        )
    }
}

extension WatchDoseReceiver: WCSessionDelegate {
    private func handleIncomingUserInfo(_ userInfo: [String: Any]) {
        if let payload = userInfo["watchDoseEvent"] as? Data,
           let decoded = self.decodeDoseEvent(from: payload) {
            self.onReceiveDoseEvent?(decoded.event, decoded.modifiedAt)
            self.pushCurrentSnapshotToWatch()
            return
        }

        if let payload = userInfo["watchDoseReplace"] as? Data,
           let decoded = self.decodeEventList(from: payload) {
            let currentState = currentStateProvider?()
            let currentModifiedAt = currentState?.eventsModifiedAt ?? 0
            if decoded.modifiedAt > 0, decoded.modifiedAt < currentModifiedAt {
                self.pushCurrentSnapshotToWatch()
                return
            }

            self.onReplaceAllEvents?(decoded.events, decoded.modifiedAt)
            self.pushCurrentSnapshotToWatch()
            return
        }

        if (userInfo["watchRequestSnapshot"] as? Bool) == true {
            self.pushCurrentSnapshotToWatch()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String : Any] = [:]) {
        Task { @MainActor in
            self.handleIncomingUserInfo(userInfo)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        Task { @MainActor in
            self.handleIncomingUserInfo(message)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.pushCurrentSnapshotToWatch()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.pushCurrentSnapshotToWatch()
        }
    }
}

private extension Dictionary {
    func compactMapKeys<NewKey: Hashable>(_ transform: (Key) -> NewKey?) -> [NewKey: Value] {
        var result: [NewKey: Value] = [:]
        for (key, value) in self {
            guard let newKey = transform(key) else { continue }
            result[newKey] = value
        }
        return result
    }
}

struct WatchDoseBridgeEvent: Codable {
    let id: UUID
    let categoryRawValue: String?
    let routeRawValue: String
    let timeH: Double
    let doseMG: Double
    let compoundRawValue: String?
    let esterRawValue: String?
    let extras: [String: Double]
    let recordOnlyOralMedicationRawValue: String?

    init(
        id: UUID,
        categoryRawValue: String?,
        routeRawValue: String,
        timeH: Double,
        doseMG: Double,
        compoundRawValue: String?,
        esterRawValue: String?,
        extras: [String: Double],
        recordOnlyOralMedicationRawValue: String?
    ) {
        self.id = id
        self.categoryRawValue = categoryRawValue
        self.routeRawValue = routeRawValue
        self.timeH = timeH
        self.doseMG = doseMG
        self.compoundRawValue = compoundRawValue
        self.esterRawValue = esterRawValue
        self.extras = extras
        self.recordOnlyOralMedicationRawValue = recordOnlyOralMedicationRawValue
    }

    init(event: DoseEvent) {
        self.id = event.id
        self.categoryRawValue = event.category.rawValue
        self.routeRawValue = event.route.rawValue
        self.timeH = event.timeH
        self.doseMG = event.doseMG
        self.compoundRawValue = event.compound.rawValue
        self.esterRawValue = event.compound.rawValue
        self.extras = event.extras.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key.rawValue] = pair.value
        }
        self.recordOnlyOralMedicationRawValue = event.recordOnlyOralMedication?.rawValue
    }

    enum CodingKeys: String, CodingKey {
        case id
        case categoryRawValue = "category"
        case routeRawValue = "route"
        case timeH
        case doseMG
        case compoundRawValue = "compound"
        case esterRawValue = "ester"
        case extras
        case recordOnlyOralMedicationRawValue = "recordOnlyOralMedication"
    }
}

struct WatchChartPoint: Codable {
    let timeH: Double
    let concentration: Double
}

struct WatchDoseEventPayload: Codable {
    let event: WatchDoseBridgeEvent
    let modifiedAt: TimeInterval
}

struct WatchDoseReplacePayload: Codable {
    let events: [WatchDoseBridgeEvent]
    let modifiedAt: TimeInterval
}

struct WatchDoseSnapshot: Codable {
    let events: [WatchDoseBridgeEvent]
    let chartPoints: [WatchChartPoint]?
    let bodyWeightKG: Double
    let eventsModifiedAt: TimeInterval
}
