import Foundation
import HealthKit

@MainActor
final class HealthKitService {
    static let shared = HealthKitService()

    private let store = HKHealthStore()
    private var bodyMassObserverQuery: HKObserverQuery?
    private var bodyMassUpdateHandler: ((Double, Date) -> Void)?
    private let bodyMassAnchorKey = "healthkit.bodyMass.anchor"
    private let medicationAuthorizationRequestedKey = "healthkit.medication.authorization.requested"

    private init() {}

    private var bodyMassType: HKQuantityType? {
        HKObjectType.quantityType(forIdentifier: .bodyMass)
    }

    private var bodyMassReadTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []

        if let bodyMassType {
            types.insert(bodyMassType)
        }

        return types
    }

    private var bodyMassShareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = []

        if let bodyMassType {
            types.insert(bodyMassType)
        }

        return types
    }

    @available(iOS 26.0, *)
    private var medicationReadTypes: Set<HKObjectType> {
        [HKObjectType.userAnnotatedMedicationType()]
    }

    func requestBodyMassAuthorizationIfNeeded() async throws {
        try await requestAuthorization(toShare: bodyMassShareTypes, read: bodyMassReadTypes)
    }

    func requestMedicationAuthorizationIfNeeded() async throws {
        guard #available(iOS 26.0, *) else { return }
        guard !UserDefaults.standard.bool(forKey: medicationAuthorizationRequestedKey) else {
            return
        }

        let medicationType = HKObjectType.userAnnotatedMedicationType()
        if medicationType.requiresPerObjectAuthorization() {
            let predicate = HKQuery.predicateForUserAnnotatedMedications(isArchived: false)
            try await requestPerObjectReadAuthorization(for: medicationType, predicate: predicate)
        } else {
            try await requestAuthorization(toShare: [], read: medicationReadTypes)
        }

        UserDefaults.standard.set(true, forKey: medicationAuthorizationRequestedKey)
    }

    private func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(
                domain: "HealthKitService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.unavailable")]
            )
        }

        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    @available(iOS 26.0, *)
    private func requestPerObjectReadAuthorization(for objectType: HKObjectType, predicate: NSPredicate?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestPerObjectReadAuthorization(for: objectType, predicate: predicate) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitService",
                        code: 8,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.medication_authorization_cancelled")]
                    ))
                }
            }
        }
    }

    func fetchLatestBodyMassKG() async throws -> Double {
        try await fetchLatestBodyMassSample().weightKG
    }

    func fetchLatestBodyMassSample() async throws -> (weightKG: Double, recordedAt: Date) {
        guard let bodyMassType else {
            throw NSError(
                domain: "HealthKitService",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.body_mass_read_unavailable")]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(sampleType: bodyMassType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let sample = samples?.first as? HKQuantitySample else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitService",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.body_mass_missing")]
                    ))
                    return
                }

                let valueKG = sample.quantity.doubleValue(for: HKUnit.gramUnit(with: .kilo))
                continuation.resume(returning: (valueKG, sample.endDate))
            }
            store.execute(query)
        }
    }

    func saveBodyMassKG(_ weightKG: Double, at date: Date = Date()) async throws {
        guard let bodyMassType = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            throw NSError(
                domain: "HealthKitService",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.body_mass_write_unavailable")]
            )
        }

        let quantity = HKQuantity(unit: HKUnit.gramUnit(with: .kilo), doubleValue: weightKG)
        let sample = HKQuantitySample(type: bodyMassType, quantity: quantity, start: date, end: date)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(sample) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitService",
                        code: 6,
                        userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.body_mass_save_failed")]
                    ))
                }
            }
        }
    }

    func startBodyMassBackgroundSync(onUpdate: @escaping (Double, Date) -> Void) async throws {
        guard let bodyMassType else {
            throw NSError(
                domain: "HealthKitService",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "healthkit.error.body_mass_subscription_unavailable")]
            )
        }

        bodyMassUpdateHandler = onUpdate

        if bodyMassObserverQuery == nil {
            let query = HKObserverQuery(sampleType: bodyMassType, predicate: nil) { [weak self] _, completionHandler, error in
                guard let self else {
                    completionHandler()
                    return
                }

                Task { @MainActor in
                    defer { completionHandler() }

                    guard error == nil else { return }
                    try? await self.syncLatestBodyMassFromAnchoredQuery()
                }
            }

            bodyMassObserverQuery = query
            store.execute(query)
        }

        try await store.enableBackgroundDelivery(for: bodyMassType, frequency: .immediate)
        try await syncLatestBodyMassFromAnchoredQuery()
    }

    private func syncLatestBodyMassFromAnchoredQuery() async throws {
        let result = try await fetchBodyMassChanges()
        if let newestSample = result.samples.max(by: { $0.endDate < $1.endDate }) {
            let valueKG = newestSample.quantity.doubleValue(for: HKUnit.gramUnit(with: .kilo))
            bodyMassUpdateHandler?(valueKG, newestSample.endDate)
        }
        saveBodyMassAnchor(result.anchor)
    }

    private func fetchBodyMassChanges() async throws -> (samples: [HKQuantitySample], anchor: HKQueryAnchor?) {
        guard let bodyMassType else {
            return ([], nil)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: bodyMassType,
                predicate: nil,
                anchor: loadBodyMassAnchor(),
                limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let quantitySamples = (samples as? [HKQuantitySample]) ?? []
                continuation.resume(returning: (quantitySamples, newAnchor))
            }

            store.execute(query)
        }
    }

    private func loadBodyMassAnchor() -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: bodyMassAnchorKey) else {
            return nil
        }

        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveBodyMassAnchor(_ anchor: HKQueryAnchor?) {
        guard let anchor,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }

        UserDefaults.standard.set(data, forKey: bodyMassAnchorKey)
    }
}
