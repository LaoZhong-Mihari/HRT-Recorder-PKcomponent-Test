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
    }

    func loadImportSuggestions() async {
        guard !isImporting else { return }

        isImporting = true
        importErrorMessage = nil
        defer { isImporting = false }

        do {
            importSuggestions = try await importService.loadSuggestions()
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
            importSuggestions = try await importService.loadSuggestions()
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
        let resolvedPlan = await resolvedPlanForNotificationAuthorization(from: plan)
        persist(plan: resolvedPlan)
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
        var updated = plan
        updated.isEnabled = isEnabled
        updated.updatedAt = Date()

        Task { @MainActor in
            let resolved = isEnabled
                ? await self.resolvedPlanForNotificationAuthorization(from: updated)
                : updated
            self.persist(plan: resolved)
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

    private func resolvedPlanForNotificationAuthorization(from plan: MedicationPlan) async -> MedicationPlan {
        guard plan.isEnabled else {
            notificationMessage = nil
            return plan
        }

        let granted = await notificationCoordinator.requestAuthorizationIfNeeded()
        guard granted else {
            var disabledPlan = plan
            disabledPlan.isEnabled = false
            disabledPlan.updatedAt = Date()
            notificationMessage = notificationPermissionMessage(for: notificationCoordinator.authorizationStatus)
            return disabledPlan
        }

        notificationMessage = nil
        return plan
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
}
