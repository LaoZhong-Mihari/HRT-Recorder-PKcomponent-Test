import AppIntents
import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct IntentMedicationEntity: AppEntity, Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let category: MedicationCategory
    let route: DoseEvent.Route?
    let compound: Compound?
    let recordOnlyOralMedication: RecordOnlyOralMedication?
    let searchTerms: [String]
    let sortPriority: Int

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Medication"
    static var defaultQuery = IntentMedicationQuery()

    init(plan: MedicationPlan, sortPriority: Int) {
        let template = plan.primaryTemplate
        id = "plan:\(plan.id.uuidString)"
        title = plan.displayName
        subtitle = template.planSummaryText
        category = template.category
        route = template.recordOnlyOralMedication == nil ? template.route : .oral
        compound = template.recordOnlyOralMedication == nil ? template.compound : nil
        recordOnlyOralMedication = template.recordOnlyOralMedication
        searchTerms = Self.terms(
            title: plan.displayName,
            subtitle: template.planSummaryText,
            compound: template.recordOnlyOralMedication == nil ? template.compound : nil,
            recordOnlyOralMedication: template.recordOnlyOralMedication
        )
        self.sortPriority = sortPriority
    }

    init(compound: Compound, sortPriority: Int) {
        let info = CompoundInfo.by(compound: compound)
        id = "compound:\(compound.rawValue)"
        title = info.fullName
        subtitle = "\(compound.abbreviation) · \(info.hormone.displayName)"
        category = compound.medicationCategory
        route = nil
        self.compound = compound
        recordOnlyOralMedication = nil
        searchTerms = Self.terms(
            title: info.fullName,
            subtitle: compound.abbreviation,
            compound: compound,
            recordOnlyOralMedication: nil
        )
        self.sortPriority = sortPriority
    }

    init(recordOnlyOralMedication: RecordOnlyOralMedication, sortPriority: Int) {
        id = "record-only:\(recordOnlyOralMedication.rawValue)"
        title = recordOnlyOralMedication.displayName
        subtitle = String(localized: "Oral medication")
        category = .antiAndrogen
        route = .oral
        compound = nil
        self.recordOnlyOralMedication = recordOnlyOralMedication
        searchTerms = Self.terms(
            title: recordOnlyOralMedication.displayName,
            subtitle: String(localized: "Oral medication"),
            compound: nil,
            recordOnlyOralMedication: recordOnlyOralMedication
        )
        self.sortPriority = sortPriority
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    func matches(_ query: String) -> Bool {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return true }

        if searchableText.contains(normalizedQuery) {
            return true
        }

        let tokens = normalizedQuery.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { searchableText.contains($0) }
    }

    func matchRank(for query: String) -> Int {
        let normalizedQuery = Self.normalized(query)
        guard !normalizedQuery.isEmpty else { return sortPriority }

        if Self.normalized(title) == normalizedQuery {
            return sortPriority
        }
        if searchTerms.map(Self.normalized).contains(normalizedQuery) {
            return sortPriority + 10
        }
        if Self.normalized(title).contains(normalizedQuery) {
            return sortPriority + 20
        }
        if searchableText.contains(normalizedQuery) {
            return sortPriority + 30
        }
        return sortPriority + 100
    }

    static func allEntities(from plans: [MedicationPlan]) -> [IntentMedicationEntity] {
        let planEntities = plans
            .enumerated()
            .filter { $0.element.isEnabled && $0.element.primaryTemplate.hasConfiguredDose }
            .map { index, plan in
                IntentMedicationEntity(plan: plan, sortPriority: index)
            }

        return planEntities + catalogEntities(startingAt: 10_000)
    }

    static func entity(for identifier: String, plans: [MedicationPlan]) -> IntentMedicationEntity? {
        allEntities(from: plans).first { $0.id == identifier }
    }

    private var searchableText: String {
        Self.normalized(([title, subtitle] + searchTerms).joined(separator: " "))
    }

    private static func catalogEntities(startingAt offset: Int) -> [IntentMedicationEntity] {
        let compounds = Compound.allCases.enumerated().map { index, compound in
            IntentMedicationEntity(compound: compound, sortPriority: offset + index)
        }
        let recordOnly = RecordOnlyOralMedication.allCases.enumerated().map { index, medication in
            IntentMedicationEntity(
                recordOnlyOralMedication: medication,
                sortPriority: offset + 1_000 + index
            )
        }
        return compounds + recordOnly
    }

    private static func terms(
        title: String,
        subtitle: String,
        compound: Compound?,
        recordOnlyOralMedication: RecordOnlyOralMedication?
    ) -> [String] {
        var terms = [title, subtitle]

        if let compound {
            let info = CompoundInfo.by(compound: compound)
            terms.append(contentsOf: [compound.rawValue, compound.abbreviation, info.fullName])
        }
        if let recordOnlyOralMedication {
            terms.append(recordOnlyOralMedication.displayName)
        }

        return Array(Set(terms.map(normalized).filter { !$0.isEmpty })).sorted()
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

struct IntentMedicationQuery: EntityStringQuery {
    func entities(for identifiers: [IntentMedicationEntity.ID]) async throws -> [IntentMedicationEntity] {
        let plans = try await MainActor.run {
            try DoseRecordingService.loadMedicationPlans()
        }
        return identifiers.compactMap { IntentMedicationEntity.entity(for: $0, plans: plans) }
    }

    func suggestedEntities() async throws -> [IntentMedicationEntity] {
        try await MainActor.run {
            try IntentMedicationEntity.allEntities(from: DoseRecordingService.loadMedicationPlans())
        }
    }

    func entities(matching string: String) async throws -> [IntentMedicationEntity] {
        let entities = try await MainActor.run {
            try IntentMedicationEntity.allEntities(from: DoseRecordingService.loadMedicationPlans())
        }
        return entities
            .filter { $0.matches(string) }
            .sorted {
                let lhsRank = $0.matchRank(for: string)
                let rhsRank = $1.matchRank(for: string)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
    }

    func defaultResult() async -> IntentMedicationEntity? {
        // Medication is safety-critical input. Siri must not populate an
        // arbitrary first plan or catalog item for a bare recording request.
        nil
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension IntentMedicationEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .data)
        attributes.title = title
        // Keep the index minimal: dose, route, and free-form aliases remain in
        // the live AppEntity query / on-device model context, not Spotlight.
        attributes.keywords = [title]
        return attributes
    }
}

@available(iOS 18.0, macOS 15.0, visionOS 2.0, *)
extension DoseOptionEntity: IndexedEntity {
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .data)
        attributes.title = title
        attributes.keywords = [title]
        return attributes
    }
}

enum AppIntentIndexingCoordinator {
    private static let medicationIDsKey = "appintent.indexedMedicationEntityIDs"
    private static let doseOptionIDsKey = "appintent.indexedDoseOptionEntityIDs"
    private static var indexingTask: Task<Void, Never>?

    static func refreshMedicationIndex(plans: [MedicationPlan]) {
        guard #available(iOS 18.0, macOS 15.0, visionOS 2.0, *) else { return }

        let medicationEntities = IntentMedicationEntity.allEntities(from: plans)
        let plannedDoseEntities = WidgetSnapshotCoordinator
            .makeDoseOptions(from: plans)
            .map(DoseOptionEntity.init)

        let medicationIDs = Set(medicationEntities.map(\.id))
        let doseOptionIDs = Set(plannedDoseEntities.map(\.id))
        let medicationIDsKey = Self.medicationIDsKey
        let doseOptionIDsKey = Self.doseOptionIDsKey
        let previousTask = indexingTask

        // Chain refreshes so an older detached index operation cannot finish
        // after a newer plan snapshot and restore stale Spotlight entities.
        indexingTask = Task(priority: .utility) {
            await previousTask?.value
            let previousMedicationIDs = Set(UserDefaults.standard.stringArray(forKey: medicationIDsKey) ?? [])
            let previousDoseOptionIDs = Set(UserDefaults.standard.stringArray(forKey: doseOptionIDsKey) ?? [])
            let deletedMedicationIDs = Array(previousMedicationIDs.subtracting(medicationIDs))
            let deletedDoseOptionIDs = Array(previousDoseOptionIDs.subtracting(doseOptionIDs))
            do {
                if !deletedMedicationIDs.isEmpty {
                    try await CSSearchableIndex.default().deleteAppEntities(
                        identifiedBy: deletedMedicationIDs,
                        ofType: IntentMedicationEntity.self
                    )
                }
                if !deletedDoseOptionIDs.isEmpty {
                    try await CSSearchableIndex.default().deleteAppEntities(
                        identifiedBy: deletedDoseOptionIDs,
                        ofType: DoseOptionEntity.self
                    )
                }
                try await CSSearchableIndex.default().indexAppEntities(medicationEntities, priority: 10)
                try await CSSearchableIndex.default().indexAppEntities(plannedDoseEntities, priority: 8)
                UserDefaults.standard.set(Array(medicationIDs), forKey: medicationIDsKey)
                UserDefaults.standard.set(Array(doseOptionIDs), forKey: doseOptionIDsKey)
            } catch {
                // Spotlight indexing is opportunistic; Siri and Shortcuts still have direct queries.
            }
        }
    }
}
