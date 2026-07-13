import Combine
import Foundation
import HealthKit
import UserNotifications

@MainActor
final class MedicationPlanVM: ObservableObject {
    @Published private(set) var plans: [MedicationPlan]
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var importSuggestions: [MedicationImportSuggestion] = []
    @Published private(set) var importAuthorizationState: MedicationImportAuthorizationState = .ready
    @Published private(set) var isImporting = false
    @Published var importErrorMessage: String?
    @Published var notificationMessage: String?
    @Published private(set) var pendingDoseSeed: DoseEntrySeed?

    private let notificationCoordinator: NotificationCoordinator
    private let importService: any MedicationImportServicing
    private let onChange: (([MedicationPlan]) -> Void)?
    private var cancellables = Set<AnyCancellable>()
    private var notificationAuthorizationTask: Task<Void, Never>?
    private var notificationAuthorizationGeneration: UInt64 = 0

    init(
        initialPlans: [MedicationPlan],
        notificationCoordinator: NotificationCoordinator,
        onChange: (([MedicationPlan]) -> Void)? = nil
    ) {
        self.plans = Self.sortedPlans(initialPlans)
        self.notificationCoordinator = notificationCoordinator
        self.importService = Self.makeImportService()
        self.onChange = onChange

        notificationCoordinator.$authorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.authorizationStatus = status
            }
            .store(in: &cancellables)

        notificationCoordinator.$pendingLaunchContext
            .receive(on: RunLoop.main)
            .sink { [weak self] context in
                self?.handlePendingLaunchContext(context)
            }
            .store(in: &cancellables)
    }

    func configure() async {
        notificationCoordinator.configure()
        await notificationCoordinator.refreshAuthorizationStatus()
        await syncNotifications()
    }

    func refreshSystemState() async {
        await notificationCoordinator.refreshAuthorizationStatus()
        await syncNotifications()
        if !canDeliverNotifications, !activePlans.isEmpty {
            notificationMessage = notificationPermissionMessage(for: authorizationStatus)
        } else if canDeliverNotifications {
            notificationMessage = nil
        }
    }

    func loadImportSuggestions() async {
        guard !isImporting else { return }

        isImporting = true
        importErrorMessage = nil
        defer { isImporting = false }

        do {
            setImportSuggestions(try await importService.loadSuggestions())
        } catch {
            importSuggestions = []
            importErrorMessage = error.localizedDescription
        }
    }

    func prepareImportSuggestions() async {
        importErrorMessage = nil
        let authorizationState = await importService.authorizationState()
        importAuthorizationState = authorizationState

        guard authorizationState == .ready else {
            importSuggestions = []
            return
        }

        await loadImportSuggestions()
    }

    func requestImportAuthorizationAndLoadSuggestions() async {
        guard !isImporting else { return }

        isImporting = true
        importErrorMessage = nil
        defer { isImporting = false }

        do {
            try await importService.requestAuthorizationIfNeeded()
            importAuthorizationState = await importService.authorizationState()
            setImportSuggestions(try await importService.loadSuggestions())
        } catch {
            importSuggestions = []
            importErrorMessage = error.localizedDescription
        }
    }

    func clearImportError() {
        importErrorMessage = nil
    }

    func clearNotificationMessage() {
        notificationMessage = nil
    }

    func savePlanRequestingNotificationsIfNeeded(_ plan: MedicationPlan) async {
        persist(plan: plan)
        guard plan.isEnabled, !canDeliverNotifications else { return }

        let granted = await notificationCoordinator.requestAuthorizationIfNeeded()
        if self.plan(withID: plan.id)?.isEnabled == true {
            notificationMessage = granted
                ? nil
                : notificationPermissionMessage(for: notificationCoordinator.authorizationStatus)
        }
        await syncNotifications()
    }

    func savePlan(_ plan: MedicationPlan) {
        persist(plan: plan)
    }

    func removePlans(at offsets: IndexSet) {
        var updatedPlans = plans
        for index in offsets.sorted(by: >) {
            updatedPlans.remove(at: index)
        }
        apply(plans: updatedPlans)
    }

    func removePlan(_ plan: MedicationPlan) {
        let updatedPlans = plans.filter { $0.id != plan.id }
        apply(plans: updatedPlans)
    }

    func setEnabled(_ isEnabled: Bool, for plan: MedicationPlan) {
        notificationAuthorizationGeneration &+= 1
        let authorizationGeneration = notificationAuthorizationGeneration
        var updated = self.plan(withID: plan.id) ?? plan
        updated.isEnabled = isEnabled
        updated.updatedAt = Date()
        persist(plan: updated)

        guard isEnabled, !canDeliverNotifications else {
            notificationAuthorizationTask?.cancel()
            notificationAuthorizationTask = nil
            if !isEnabled {
                notificationMessage = nil
            }
            return
        }

        notificationAuthorizationTask?.cancel()
        notificationAuthorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await self.notificationCoordinator.requestAuthorizationIfNeeded()
            guard !Task.isCancelled,
                  authorizationGeneration == self.notificationAuthorizationGeneration else {
                return
            }
            self.notificationMessage = granted
                ? nil
                : self.notificationPermissionMessage(for: self.notificationCoordinator.authorizationStatus)
            await self.syncNotifications()
            if !Task.isCancelled,
               authorizationGeneration == self.notificationAuthorizationGeneration {
                self.notificationAuthorizationTask = nil
            }
        }
    }

    func nextOccurrence(for plan: MedicationPlan) -> PlannedDoseOccurrence? {
        plan.nextOccurrence()
    }

    func plan(withID id: UUID) -> MedicationPlan? {
        plans.first { $0.id == id }
    }

    func nextOverallOccurrence() -> PlannedDoseOccurrence? {
        plans
            .filter(\.isEnabled)
            .compactMap(nextOccurrence(for:))
            .min { $0.scheduledDate < $1.scheduledDate }
    }

    func requestNotificationAuthorization() async {
        let granted = await notificationCoordinator.requestAuthorizationIfNeeded()
        if granted {
            notificationMessage = nil
        } else {
            notificationMessage = notificationPermissionMessage(for: notificationCoordinator.authorizationStatus)
        }
        await syncNotifications()
    }

    func consumePendingDoseSeed() {
        pendingDoseSeed = nil
        notificationCoordinator.clearPendingLaunchContext()
    }

    func settingsSummaryText() -> String {
        let activeCount = plans.filter { $0.isEnabled }.count
        let statusText = notificationStatusText()
        return String.localizedStringWithFormat(
            String(localized: "%lld active plan%@ · %@"),
            Int64(activeCount),
            activeCount == 1 ? "" : "s",
            statusText
        )
    }

    func notificationStatusText() -> String {
        switch authorizationStatus {
        case .authorized:
            return String(localized: "notifications allowed")
        case .provisional:
            return String(localized: "notifications provisional")
        case .ephemeral:
            return String(localized: "notifications temporary")
        case .denied:
            return String(localized: "notifications denied")
        case .notDetermined:
            return String(localized: "notifications not set")
        @unknown default:
            return String(localized: "notifications unknown")
        }
    }

    var activePlans: [MedicationPlan] {
        plans.filter(\.isEnabled)
    }

    var pausedPlans: [MedicationPlan] {
        plans.filter { !$0.isEnabled }
    }

    var activePlanCount: Int {
        activePlans.count
    }

    var pausedPlanCount: Int {
        pausedPlans.count
    }

    var supportsMedicationImport: Bool {
        importService.isSupported
    }

    var canDeliverNotifications: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    var importAvailabilityDescription: String {
        importService.availabilityDescription
    }

    private static func makeImportService() -> any MedicationImportServicing {
        if #available(iOS 26.0, *), HKHealthStore.isHealthDataAvailable() {
            return HealthMedicationImportService()
        }

        return UnsupportedMedicationImportService()
    }

    func makeSeed(for plan: MedicationPlan, at date: Date) -> DoseEntrySeed {
        makeSeed(for: plan, at: date, doseSlotID: nil)
    }

    func makeSeed(for plan: MedicationPlan, at date: Date, doseSlotID: UUID?) -> DoseEntrySeed {
        DoseEntrySeed(
            date: date,
            template: plan.template(for: date, doseSlotID: doseSlotID),
            title: plan.displayName
        )
    }

    @discardableResult
    func prepareDoseSeed(forWidgetOptionID optionID: String, requestedAt: Date = Date()) -> Bool {
        guard let parsedID = WidgetDoseOption.parseID(optionID),
              let plan = plans.first(where: { $0.id == parsedID.planID }),
              plan.isEnabled,
              let template = plan.exactTemplate(forDoseSlotID: parsedID.doseSlotID) else {
            return false
        }

        pendingDoseSeed = DoseEntrySeed(
            date: requestedAt,
            template: template,
            title: plan.displayName
        )
        return true
    }

    private func apply(plans updatedPlans: [MedicationPlan]) {
        plans = Self.sortedPlans(updatedPlans)
        importSuggestions = reconciledImportSuggestions(importSuggestions)
        onChange?(plans)

        Task { @MainActor in
            await self.syncNotifications()
        }
    }

    private func syncNotifications() async {
        await notificationCoordinator.syncNotifications(for: plans)
    }

    private func handlePendingLaunchContext(_ context: ReminderLaunchContext?) {
        guard let context,
              let plan = plans.first(where: { $0.id == context.planID }) else {
            return
        }

        pendingDoseSeed = makeSeed(for: plan, at: context.scheduledDate, doseSlotID: context.doseSlotID)
    }

    private func persist(plan: MedicationPlan) {
        var updatedPlans = plans
        if let index = updatedPlans.firstIndex(where: { $0.id == plan.id }) {
            updatedPlans[index] = plan
        } else {
            updatedPlans.append(plan)
        }
        apply(plans: updatedPlans)
    }

    private func notificationPermissionMessage(for status: UNAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return String(localized: "Notifications are off. Turn them on in Settings.")
        case .notDetermined:
            return String(localized: "Couldn't finish notification setup. Try again from the status card.")
        case .authorized, .provisional, .ephemeral:
            return String(localized: "Notification access is available.")
        @unknown default:
            return String(localized: "Notification access is unavailable right now.")
        }
    }

    private static func sortedPlans(_ plans: [MedicationPlan]) -> [MedicationPlan] {
        plans.sorted { lhs, rhs in
            if lhs.isEnabled != rhs.isEnabled {
                return lhs.isEnabled && !rhs.isEnabled
            }

            let lhsDate = lhs.nextOccurrence()?.scheduledDate ?? .distantFuture
            let rhsDate = rhs.nextOccurrence()?.scheduledDate ?? .distantFuture
            if lhsDate != rhsDate {
                return lhsDate < rhsDate
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func setImportSuggestions(_ suggestions: [MedicationImportSuggestion]) {
        importSuggestions = reconciledImportSuggestions(suggestions)
    }

    private func reconciledImportSuggestions(
        _ suggestions: [MedicationImportSuggestion]
    ) -> [MedicationImportSuggestion] {
        let normalizedSourceNameCounts = Dictionary(
            grouping: suggestions.compactMap { normalizedSourceName(for: $0) },
            by: { $0 }
        )
        .mapValues(\.count)

        return suggestions.map { suggestion in
            var reconciled = suggestion
            let normalizedName = normalizedSourceName(for: suggestion)
            let canUseLegacyName = normalizedName.map {
                normalizedSourceNameCounts[$0] == 1
            } ?? false
            reconciled.existingPlanID = linkedPlan(
                for: suggestion,
                canUseLegacyName: canUseLegacyName
            )?.id
            return reconciled
        }
    }

    private func linkedPlan(
        for suggestion: MedicationImportSuggestion,
        canUseLegacyName: Bool
    ) -> MedicationPlan? {
        if let identifierArchive = suggestion.sourceMedicationIdentifierArchive,
           let linked = plans.first(where: {
               guard let storedArchive = $0.healthMedicationLink?.conceptIdentifierArchive else {
                   return false
               }
               return medicationIdentifierArchivesMatch(storedArchive, identifierArchive)
           }) {
            return linked
        }

        // One-time migration for plans imported before the stable Health link
        // was persisted. Avoid guessing when duplicate legacy names exist.
        guard canUseLegacyName,
              let normalizedSourceName = normalizedSourceName(for: suggestion) else {
            return nil
        }
        let legacyMatches = plans.filter { plan in
            guard plan.healthMedicationLink == nil else { return false }
            return plan.sourceMedicationName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedLowercase == normalizedSourceName
        }
        return legacyMatches.count == 1 ? legacyMatches[0] : nil
    }

    private func normalizedSourceName(
        for suggestion: MedicationImportSuggestion
    ) -> String? {
        let normalized = suggestion.sourceMedicationName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        guard let normalized, !normalized.isEmpty else { return nil }
        return normalized
    }

    private func medicationIdentifierArchivesMatch(_ lhs: Data, _ rhs: Data) -> Bool {
        if lhs == rhs { return true }
        guard #available(iOS 26.0, *),
              let lhsIdentifier = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: HKHealthConceptIdentifier.self,
                  from: lhs
              ),
              let rhsIdentifier = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: HKHealthConceptIdentifier.self,
                  from: rhs
              ) else {
            return false
        }
        return lhsIdentifier == rhsIdentifier
    }
}
