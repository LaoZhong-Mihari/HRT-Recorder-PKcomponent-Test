import Foundation
import SwiftUI
import Combine
import WatchConnectivity

enum WatchMedicationCategory: String, CaseIterable, Identifiable, Codable {
    case estradiol
    case testosterone
    case antiAndrogen

    var id: Self { self }

    var displayName: String {
        switch self {
        case .estradiol: return WatchSimulatedHormone.estradiol.displayName
        case .testosterone: return WatchSimulatedHormone.testosterone.displayName
        case .antiAndrogen: return NSLocalizedString("Anti-androgen", comment: "Medication category")
        }
    }

    var simulatedHormone: WatchSimulatedHormone? {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        case .antiAndrogen: return nil
        }
    }
}

enum WatchSimulatedHormone: String, CaseIterable, Identifiable, Codable {
    case estradiol
    case testosterone

    var id: Self { self }

    var category: WatchMedicationCategory {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        }
    }

    var displayName: String {
        switch self {
        case .estradiol:
            return NSLocalizedString("Estradiol", comment: "Hormone name")
        case .testosterone:
            return NSLocalizedString("Testosterone", comment: "Hormone name")
        }
    }

    var concentrationUnit: WatchConcentrationUnit {
        WatchPKSharedCatalogResource.current.hormones[self]?.concentrationUnit ?? .pgPerML
    }

    var chartColor: Color {
        switch self {
        case .estradiol:
            return Color(red: 0.95, green: 0.50, blue: 0.74)
        case .testosterone:
            return .blue
        }
    }
}

enum WatchConcentrationUnit: String, Codable {
    case pgPerML
    case ngPerDL

    var symbol: String {
        switch self {
        case .pgPerML: return "pg/mL"
        case .ngPerDL: return "ng/dL"
        }
    }

    var concentrationScale: Double {
        switch self {
        case .pgPerML: return 1e9
        case .ngPerDL: return 1e8
        }
    }
}

struct WatchSimulationDisplayMetadata: Equatable, Codable {
    let hormone: WatchSimulatedHormone
    let concentrationUnit: WatchConcentrationUnit

    var concentrationSymbol: String { concentrationUnit.symbol }
}

enum WatchCompound: String, CaseIterable, Identifiable, Codable {
    case E2, EB, EV, EC, EN
    case T, TC, TE, TU

    var id: Self { self }

    var info: WatchCompoundInfo { WatchCompoundInfo.by(compound: self) }
    var fullName: String { info.fullName }
    var hormone: WatchSimulatedHormone { info.hormone }
    var medicationCategory: WatchMedicationCategory { hormone.category }

    var localizedName: String {
        NSLocalizedString(
            "compound.\(rawValue).name",
            tableName: nil,
            bundle: .main,
            value: fullName,
            comment: "Localized compound name"
        )
    }

    var abbreviation: String {
        NSLocalizedString(
            "compound.\(rawValue).abbr",
            tableName: nil,
            bundle: .main,
            value: rawValue,
            comment: "Localized compound abbreviation"
        )
    }
}

struct WatchCompoundInfo {
    let compound: WatchCompound
    let fullName: String
    let hormone: WatchSimulatedHormone
    let molecularWeight: Double
    let activeMolecularWeight: Double
    let isProdrug: Bool

    var toActiveFactor: Double {
        activeMolecularWeight / molecularWeight
    }

    static let all: [WatchCompound: WatchCompoundInfo] = Dictionary(
        uniqueKeysWithValues: WatchPKSharedCatalogResource.current.compounds.map { compound, config in
            (
                compound,
                WatchCompoundInfo(
                    compound: compound,
                    fullName: config.fullName,
                    hormone: config.hormone,
                    molecularWeight: config.molecularWeight,
                    activeMolecularWeight: config.activeMolecularWeight,
                    isProdrug: config.isProdrug
                )
            )
        }
    )

    static func by(compound: WatchCompound) -> WatchCompoundInfo {
        all[compound]!
    }
}

enum WatchRecordOnlyOralMedication: String, CaseIterable, Identifiable, Codable {
    case cyproteroneAcetate
    case spironolactone
    case bicalutamide
    case finasteride
    case dutasteride

    var id: Self { self }

    var displayName: String {
        switch self {
        case .cyproteroneAcetate:
            return NSLocalizedString("record_medication.cyproterone_acetate.name", comment: "Cyproterone acetate")
        case .spironolactone:
            return NSLocalizedString("record_medication.spironolactone.name", comment: "Spironolactone")
        case .bicalutamide:
            return NSLocalizedString("record_medication.bicalutamide.name", comment: "Bicalutamide")
        case .finasteride:
            return NSLocalizedString("record_medication.finasteride.name", comment: "Finasteride")
        case .dutasteride:
            return NSLocalizedString("record_medication.dutasteride.name", comment: "Dutasteride")
        }
    }
}

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

    enum ExtraKey: String, Codable, CaseIterable {
        case concentrationMGmL
        case areaCM2
        case releaseRateUGPerDay
        case sublingualTheta
        case sublingualTier
    }

    let id: UUID
    let category: WatchMedicationCategory
    let route: Route
    let date: Date
    let doseMG: Double
    let compound: WatchCompound
    let extras: [ExtraKey: Double]
    let recordOnlyOralMedication: WatchRecordOnlyOralMedication?

    init(
        id: UUID,
        category: WatchMedicationCategory? = nil,
        route: Route,
        date: Date,
        doseMG: Double,
        compound: WatchCompound,
        extras: [ExtraKey: Double],
        recordOnlyOralMedication: WatchRecordOnlyOralMedication?
    ) {
        let resolvedCategory = category
            ?? (recordOnlyOralMedication != nil ? .antiAndrogen : compound.medicationCategory)

        self.id = id
        self.category = resolvedCategory
        self.route = route
        self.date = date
        self.doseMG = doseMG
        self.compound = compound
        self.extras = extras
        self.recordOnlyOralMedication = recordOnlyOralMedication
    }

    var timeH: Double {
        date.timeIntervalSince1970 / 3600.0
    }

    var ester: WatchCompound { compound }

    var simulatedHormone: WatchSimulatedHormone? {
        category.simulatedHormone
    }

    var participatesInSimulation: Bool {
        recordOnlyOralMedication == nil && simulatedHormone != nil
    }

    func appearsInTimeline(for hormone: WatchSimulatedHormone) -> Bool {
        switch category {
        case .estradiol:
            return hormone == .estradiol
        case .testosterone:
            return hormone == .testosterone
        case .antiAndrogen:
            return hormone == .estradiol
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case category
        case route
        case date
        case doseMG
        case compound
        case ester
        case extras
        case recordOnlyOralMedication
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let route = try container.decode(Route.self, forKey: .route)
        let date = try container.decode(Date.self, forKey: .date)
        let doseMG = try container.decode(Double.self, forKey: .doseMG)
        let compound = try container.decodeIfPresent(WatchCompound.self, forKey: .compound)
            ?? container.decode(WatchCompound.self, forKey: .ester)
        let extras = try container.decodeIfPresent([ExtraKey: Double].self, forKey: .extras) ?? [:]
        let recordOnly = try container.decodeIfPresent(WatchRecordOnlyOralMedication.self, forKey: .recordOnlyOralMedication)
        let category = try container.decodeIfPresent(WatchMedicationCategory.self, forKey: .category)

        self.init(
            id: id,
            category: category,
            route: route,
            date: date,
            doseMG: doseMG,
            compound: compound,
            extras: extras,
            recordOnlyOralMedication: recordOnly
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(category, forKey: .category)
        try container.encode(route, forKey: .route)
        try container.encode(date, forKey: .date)
        try container.encode(doseMG, forKey: .doseMG)
        try container.encode(compound, forKey: .compound)
        try container.encode(extras, forKey: .extras)
        try container.encodeIfPresent(recordOnlyOralMedication, forKey: .recordOnlyOralMedication)
    }
}

enum WatchCompoundSupport {
    static func availableCompounds(for category: WatchMedicationCategory, route: WatchDoseEvent.Route) -> [WatchCompound] {
        switch category {
        case .antiAndrogen:
            return [.E2]
        case .estradiol:
            switch route {
            case .injection: return [.EB, .EV, .EC, .EN]
            case .patchApply, .patchRemove, .gel: return [.E2]
            case .oral, .sublingual: return [.E2, .EV]
            }
        case .testosterone:
            switch route {
            case .injection: return [.TC, .TE, .TU]
            case .patchApply, .patchRemove, .gel: return [.T]
            case .oral: return [.TU]
            case .sublingual: return []
            }
        }
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

    init(event: WatchDoseEvent) {
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

struct WatchDoseSnapshot: Codable {
    let events: [WatchDoseBridgeEvent]
    let chartPoints: [WatchChartPoint]?
    let bodyWeightKG: Double?
    let eventsModifiedAt: TimeInterval

    init(
        events: [WatchDoseBridgeEvent],
        chartPoints: [WatchChartPoint]? = nil,
        bodyWeightKG: Double?,
        eventsModifiedAt: TimeInterval
    ) {
        self.events = events
        self.chartPoints = chartPoints
        self.bodyWeightKG = bodyWeightKG
        self.eventsModifiedAt = eventsModifiedAt
    }
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
        let wrappedPayload = WatchDoseEventPayload(
            event: WatchDoseBridgeEvent(event: event),
            modifiedAt: store?.eventsModifiedAt ?? Date().timeIntervalSince1970
        )
        guard let payload = try? encoder.encode(wrappedPayload) else { return }
        enqueueOrSend(PendingUserInfo(key: "watchDoseEvent", data: payload, boolValue: nil))
    }

    func replaceAll(events: [WatchDoseEvent]) {
        let wrappedPayload = WatchDoseReplacePayload(
            events: events.map(WatchDoseBridgeEvent.init),
            modifiedAt: store?.eventsModifiedAt ?? Date().timeIntervalSince1970
        )
        guard let payload = try? encoder.encode(wrappedPayload) else { return }
        enqueueOrSend(PendingUserInfo(key: "watchDoseReplace", data: payload, boolValue: nil))
    }

    func requestSnapshot() {
        enqueueOrSend(PendingUserInfo(key: "watchRequestSnapshot", data: nil, boolValue: true))
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

    private func makeEvent(from payload: WatchDoseBridgeEvent) -> WatchDoseEvent? {
        guard let route = WatchDoseEvent.Route(rawValue: payload.routeRawValue) else {
            return nil
        }
        guard let compound = WatchCompound(rawValue: payload.compoundRawValue ?? payload.esterRawValue ?? "") else {
            return nil
        }

        let extras = payload.extras.compactMapKeys { WatchDoseEvent.ExtraKey(rawValue: $0) }
        let category = payload.categoryRawValue.flatMap(WatchMedicationCategory.init(rawValue:))
        let recordOnly = payload.recordOnlyOralMedicationRawValue.flatMap(WatchRecordOnlyOralMedication.init(rawValue:))
        let date = Date(timeIntervalSince1970: payload.timeH * 3600.0)
        return WatchDoseEvent(
            id: payload.id,
            category: category,
            route: route,
            date: date,
            doseMG: payload.doseMG,
            compound: compound,
            extras: extras,
            recordOnlyOralMedication: recordOnly
        )
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
            if let bodyWeightKG = snapshot.bodyWeightKG, bodyWeightKG > 0 {
                onReceiveSyncedBodyWeight?(bodyWeightKG)
            }
            return
        }

        let convertedEvents = snapshot.events.compactMap { makeEvent(from: $0) }
        let appliedModifiedAt = snapshot.eventsModifiedAt > 0
            ? snapshot.eventsModifiedAt
            : store?.eventsModifiedAt
        store?.replace(with: convertedEvents, modifiedAt: appliedModifiedAt)

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

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {}
#endif

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
