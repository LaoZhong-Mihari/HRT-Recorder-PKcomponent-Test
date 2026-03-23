import Foundation
import SwiftUI
import Combine
import WatchConnectivity

struct WatchDoseEvent: Identifiable, Codable, Equatable {
    enum Route: String, CaseIterable, Codable {
        case injection
        case patchApply
        case patchRemove
        case gel
        case oral
        case sublingual

        var localizationKey: String {
            switch self {
            case .injection: return "route.injection"
            case .patchApply: return "route.patchApply"
            case .patchRemove: return "route.patchRemove"
            case .gel: return "route.gel"
            case .oral: return "route.oral"
            case .sublingual: return "route.sublingual"
            }
        }

        var displayName: String {
            NSLocalizedString(localizationKey, comment: "Localized route name")
        }
    }

    enum Ester: String, CaseIterable, Codable {
        case E2
        case EB
        case EV
        case EC
        case EN

        var localizedName: String {
            NSLocalizedString(
                "ester.\(rawValue).name",
                tableName: nil,
                bundle: .main,
                value: defaultName,
                comment: "Localized ester name"
            )
        }

        var abbreviation: String {
            NSLocalizedString(
                "ester.\(rawValue).abbr",
                tableName: nil,
                bundle: .main,
                value: rawValue,
                comment: "Localized ester abbreviation"
            )
        }

        var toE2Factor: Double {
            guard self != .E2 else { return 1.0 }
            return Self.e2MolecularWeight / molecularWeight
        }

        private var defaultName: String {
            switch self {
            case .E2: return "Estradiol"
            case .EB: return "Estradiol Benzoate"
            case .EV: return "Estradiol Valerate"
            case .EC: return "Estradiol Cypionate"
            case .EN: return "Estradiol Enanthate"
            }
        }

        private var molecularWeight: Double {
            switch self {
            case .E2: return Self.e2MolecularWeight
            case .EB: return 376.50
            case .EV: return 356.50
            case .EC: return 396.58
            case .EN: return 384.56
            }
        }

        private static let e2MolecularWeight = 272.38
    }

    enum ExtraKey: String, Codable, CaseIterable {
        case concentrationMGmL
        case areaCM2
        case releaseRateUGPerDay
        case sublingualTheta
        case sublingualTier
    }

    let id: UUID
    let route: Route
    let date: Date
    let doseMG: Double
    let ester: Ester
    let extras: [ExtraKey: Double]

    var timeH: Double {
        date.timeIntervalSince1970 / 3600.0
    }
}

struct WatchChartPoint: Codable, Identifiable {
    let timeH: Double
    let concentration: Double

    var id: Double { timeH }

    var date: Date {
        Date(timeIntervalSince1970: timeH * 3600.0)
    }
}

struct WatchDoseBridgeEvent: Codable {
    let id: UUID
    let routeRawValue: String
    let timeH: Double
    let doseMG: Double
    let esterRawValue: String
    let extras: [String: Double]

    enum CodingKeys: String, CodingKey {
        case id
        case routeRawValue = "route"
        case timeH
        case doseMG
        case esterRawValue = "ester"
        case extras
    }
}

struct WatchDoseSnapshot: Codable {
    let events: [WatchDoseBridgeEvent]
    let chartPoints: [WatchChartPoint]
    let bodyWeightKG: Double?
    let eventsModifiedAt: TimeInterval
}

struct WatchDoseEventPayload: Codable {
    let event: WatchDoseBridgeEvent
    let modifiedAt: TimeInterval
}

struct WatchDoseReplacePayload: Codable {
    let events: [WatchDoseBridgeEvent]
    let modifiedAt: TimeInterval
}

final class WatchDoseStore: ObservableObject {
    @Published private(set) var events: [WatchDoseEvent] = []
    @Published private(set) var eventsModifiedAt: TimeInterval = 0

    private let storageKey = "watch.dose.events"
    private let modifiedAtKey = "watch.dose.events.modifiedAt"

    init() {
        load()
    }

    func add(_ event: WatchDoseEvent) {
        upsert(event)
    }

    func upsert(_ event: WatchDoseEvent, modifiedAt: TimeInterval? = nil) {
        var updatedEvents = events
        if let index = updatedEvents.firstIndex(where: { $0.id == event.id }) {
            updatedEvents[index] = event
        } else {
            updatedEvents.append(event)
        }
        apply(events: updatedEvents, modifiedAt: modifiedAt)
    }

    func replace(with newEvents: [WatchDoseEvent], modifiedAt: TimeInterval? = nil) {
        apply(events: newEvents, modifiedAt: modifiedAt)
    }

    func delete(at offsets: IndexSet) {
        var updatedEvents = events
        updatedEvents.remove(atOffsets: offsets)
        apply(events: updatedEvents, modifiedAt: nil)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            events = []
            eventsModifiedAt = UserDefaults.standard.double(forKey: modifiedAtKey)
            return
        }
        events = (try? JSONDecoder().decode([WatchDoseEvent].self, from: data)) ?? []
        events.sort { $0.date > $1.date }
        eventsModifiedAt = UserDefaults.standard.double(forKey: modifiedAtKey)
    }

    private func apply(events newEvents: [WatchDoseEvent], modifiedAt: TimeInterval?) {
        events = newEvents.sorted { $0.date > $1.date }
        if let modifiedAt, modifiedAt > 0 {
            eventsModifiedAt = modifiedAt
        } else {
            eventsModifiedAt = Date().timeIntervalSince1970
        }
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        UserDefaults.standard.set(eventsModifiedAt, forKey: modifiedAtKey)
    }
}

@MainActor
final class WatchDoseSyncService: NSObject, ObservableObject {
    @Published private(set) var chartPoints: [WatchChartPoint] = []

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private weak var store: WatchDoseStore?
    private var onReceiveSyncedBodyWeight: ((Double) -> Void)?

    private let pendingKey = "watch.sync.pending.userinfo"
    private var pendingMessages: [PendingUserInfo] = []

    override init() {
        super.init()
        loadPendingMessages()
        activateIfNeeded()
    }

    func attach(store: WatchDoseStore, onReceiveSyncedBodyWeight: ((Double) -> Void)? = nil) {
        self.store = store
        self.onReceiveSyncedBodyWeight = onReceiveSyncedBodyWeight
        requestSnapshot()
    }

    func send(event: WatchDoseEvent) {
        let payloadEvent = WatchDoseBridgeEvent(
            id: event.id,
            routeRawValue: event.route.rawValue,
            timeH: event.timeH,
            doseMG: event.doseMG,
            esterRawValue: event.ester.rawValue,
            extras: event.extras.reduce(into: [:]) { partialResult, pair in
                partialResult[pair.key.rawValue] = pair.value
            }
        )
        let wrappedPayload = WatchDoseEventPayload(
            event: payloadEvent,
            modifiedAt: store?.eventsModifiedAt ?? Date().timeIntervalSince1970
        )
        guard let payload = try? encoder.encode(wrappedPayload) else { return }
        enqueueOrSend(PendingUserInfo(key: "watchDoseEvent", data: payload, boolValue: nil))
    }

    func replaceAll(events: [WatchDoseEvent]) {
        let payloadEvents = events.map { event in
            WatchDoseBridgeEvent(
                id: event.id,
                routeRawValue: event.route.rawValue,
                timeH: event.timeH,
                doseMG: event.doseMG,
                esterRawValue: event.ester.rawValue,
                extras: event.extras.reduce(into: [:]) { partialResult, pair in
                    partialResult[pair.key.rawValue] = pair.value
                }
            )
        }
        let wrappedPayload = WatchDoseReplacePayload(
            events: payloadEvents,
            modifiedAt: store?.eventsModifiedAt ?? Date().timeIntervalSince1970
        )
        guard let payload = try? encoder.encode(wrappedPayload) else { return }
        enqueueOrSend(PendingUserInfo(key: "watchDoseReplace", data: payload, boolValue: nil))
    }

    func requestSnapshot() {
        enqueueOrSend(PendingUserInfo(key: "watchRequestSnapshot", data: nil, boolValue: true))
    }

    var currentConcentration: Double? {
        guard !chartPoints.isEmpty else { return nil }
        let nowH = Date().timeIntervalSince1970 / 3600.0
        return interpolateConcentration(at: nowH)
    }

    private func enqueueOrSend(_ pending: PendingUserInfo) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default

        if session.activationState == .activated {
            transfer(session: session, pending: pending)
        } else {
            pendingMessages.append(pending)
            persistPendingMessages()
            session.activate()
        }
    }

    private func transfer(session: WCSession, pending: PendingUserInfo) {
        var userInfo: [String: Any] = [:]
        if let data = pending.data {
            userInfo[pending.key] = data
        } else if let boolValue = pending.boolValue {
            userInfo[pending.key] = boolValue
        }

        guard !userInfo.isEmpty else { return }
        session.transferUserInfo(userInfo)

        if session.isReachable {
            session.sendMessage(userInfo, replyHandler: nil, errorHandler: nil)
        }
    }

    private func flushPendingMessages() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }

        let messages = pendingMessages
        pendingMessages.removeAll()
        persistPendingMessages()

        for pending in messages {
            transfer(session: session, pending: pending)
        }
    }

    private func loadPendingMessages() {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let decoded = try? decoder.decode([PendingUserInfo].self, from: data) else {
            pendingMessages = []
            return
        }
        pendingMessages = decoded
    }

    private func persistPendingMessages() {
        guard let data = try? encoder.encode(pendingMessages) else { return }
        UserDefaults.standard.set(data, forKey: pendingKey)
    }

    private func interpolateConcentration(at hour: Double) -> Double? {
        let sorted = chartPoints.sorted { $0.timeH < $1.timeH }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        if hour <= first.timeH { return first.concentration }
        if hour >= last.timeH { return last.concentration }

        var low = 0
        var high = sorted.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if sorted[mid].timeH < hour {
                low = mid
            } else {
                high = mid
            }
        }

        let left = sorted[low]
        let right = sorted[high]
        let ratio = (hour - left.timeH) / (right.timeH - left.timeH)
        return left.concentration + (right.concentration - left.concentration) * ratio
    }

    private func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    private func applySnapshot(_ snapshot: WatchDoseSnapshot) {
        let localModifiedAt = store?.eventsModifiedAt ?? 0
        if snapshot.eventsModifiedAt > 0, snapshot.eventsModifiedAt < localModifiedAt {
            chartPoints = []
            if let bodyWeightKG = snapshot.bodyWeightKG, bodyWeightKG > 0 {
                onReceiveSyncedBodyWeight?(bodyWeightKG)
            }
            return
        }

        let convertedEvents = snapshot.events.compactMap { payload -> WatchDoseEvent? in
            guard let route = WatchDoseEvent.Route(rawValue: payload.routeRawValue),
                  let ester = WatchDoseEvent.Ester(rawValue: payload.esterRawValue) else {
                return nil
            }
            let extras = payload.extras.compactMapKeys { WatchDoseEvent.ExtraKey(rawValue: $0) }
            let date = Date(timeIntervalSince1970: payload.timeH * 3600.0)
            return WatchDoseEvent(
                id: payload.id,
                route: route,
                date: date,
                doseMG: payload.doseMG,
                ester: ester,
                extras: extras
            )
        }

        let appliedModifiedAt = snapshot.eventsModifiedAt > 0
            ? snapshot.eventsModifiedAt
            : store?.eventsModifiedAt
        store?.replace(with: convertedEvents, modifiedAt: appliedModifiedAt)
        chartPoints = snapshot.chartPoints.sorted { $0.timeH < $1.timeH }

        if let bodyWeightKG = snapshot.bodyWeightKG, bodyWeightKG > 0 {
            onReceiveSyncedBodyWeight?(bodyWeightKG)
        }
    }
}

extension WatchDoseSyncService: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            self.flushPendingMessages()
            self.requestSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String : Any]) {
        guard let data = applicationContext["doseSnapshot"] as? Data else { return }
        Task { @MainActor in
            guard let snapshot = try? self.decoder.decode(WatchDoseSnapshot.self, from: data) else { return }
            self.applySnapshot(snapshot)
        }
    }
}

private struct PendingUserInfo: Codable {
    let key: String
    let data: Data?
    let boolValue: Bool?
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
