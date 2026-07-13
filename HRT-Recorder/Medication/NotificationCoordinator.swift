import Foundation
import Combine
import UserNotifications

@MainActor
final class NotificationCoordinator: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var pendingLaunchContext: ReminderLaunchContext?

    private let center = UNUserNotificationCenter.current()
    private let requestPrefix = "med-plan-"
    private let userInfoPlanID = "medicationPlanID"
    private let userInfoScheduledDate = "scheduledDate"
    private let userInfoDoseSlotID = "doseSlotID"
    private let maximumManagedPendingRequests = 64
    private var notificationSyncTask: Task<Void, Never>?
    private var notificationSyncGeneration: UInt64 = 0

    override init() {
        super.init()
        // Notification responses can cold-launch the app. Install the delegate
        // when the coordinator is created, before SwiftUI's root `.task` runs.
        center.delegate = self
    }

    func configure() {
        Task { await refreshAuthorizationStatus() }
    }

    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        await refreshAuthorizationStatus()

        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                await refreshAuthorizationStatus()
                return granted
            } catch {
                await refreshAuthorizationStatus()
                return false
            }
        @unknown default:
            return false
        }
    }

    func syncNotifications(for plans: [MedicationPlan]) async {
        notificationSyncGeneration &+= 1
        let generation = notificationSyncGeneration
        let previousTask = notificationSyncTask
        previousTask?.cancel()
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self, self.isCurrentSync(generation) else { return }
            await self.performNotificationSync(for: plans, generation: generation)
        }
        notificationSyncTask = task
        await task.value
        if generation == notificationSyncGeneration {
            notificationSyncTask = nil
        }
    }

    private func performNotificationSync(
        for plans: [MedicationPlan],
        generation: UInt64
    ) async {
        await refreshAuthorizationStatus()
        guard isCurrentSync(generation) else { return }
        guard authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral else {
            await removeAllManagedNotifications()
            return
        }

        await removeAllManagedNotifications()
        guard isCurrentSync(generation) else { return }

        let enabledPlansByID = Dictionary(
            uniqueKeysWithValues: plans.filter(\.isEnabled).map { ($0.id, $0) }
        )
        let occurrences = enabledPlansByID.values
            .flatMap {
                $0.upcomingOccurrences(
                    limit: maximumManagedPendingRequests,
                    horizonDays: 365
                )
            }
            .sorted { $0.scheduledDate < $1.scheduledDate }
            .prefix(maximumManagedPendingRequests)

        for occurrence in occurrences {
            guard isCurrentSync(generation) else { return }
            guard let plan = enabledPlansByID[occurrence.planID] else { continue }
            await scheduleNotification(for: occurrence, plan: plan)
        }
    }

    private func isCurrentSync(_ generation: UInt64) -> Bool {
        !Task.isCancelled && generation == notificationSyncGeneration
    }

    func clearPendingLaunchContext() {
        pendingLaunchContext = nil
    }

    private func removeAllManagedNotifications() async {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending
            .filter { $0.identifier.hasPrefix(requestPrefix) }
            .map(\.identifier)
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func scheduleNotification(for occurrence: PlannedDoseOccurrence, plan: MedicationPlan) async {
        let content = UNMutableNotificationContent()
        let message = reminderMessage(for: occurrence, plan: plan)
        content.title = message.title
        content.body = message.body
        content.sound = .default
        content.userInfo = [
            userInfoPlanID: occurrence.planID.uuidString,
            userInfoScheduledDate: occurrence.scheduledDate.timeIntervalSince1970
        ]
        if let doseSlotID = occurrence.doseSlotID {
            content.userInfo[userInfoDoseSlotID] = doseSlotID.uuidString
        }

        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence.scheduledDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: occurrence.notificationIdentifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            #if DEBUG
            print("Notification schedule failed:", error)
            #endif
        }
    }

    private func reminderMessage(for occurrence: PlannedDoseOccurrence, plan: MedicationPlan) -> (title: String, body: String) {
        let template = plan.template(for: occurrence.scheduledDate, doseSlotID: occurrence.doseSlotID)
        let context = ReminderMessageContext(
            planName: occurrence.planName,
            action: actionVerb(for: template.route),
            routeLabel: routeLabel(for: template),
            doseText: doseText(for: template),
            doseLine: doseLine(for: template),
            timeText: timeText(for: occurrence.scheduledDate)
        )

        if let selectedTemplate = selectedReminderTemplate(
            from: ReminderMessageTemplate.defaultTemplates,
            seedSource: occurrence.notificationIdentifier
        ) {
            let title = render(template: selectedTemplate.titleTemplate, context: context).trimmingCharacters(in: .whitespacesAndNewlines)
            let body = render(template: selectedTemplate.bodyTemplate, context: context).trimmingCharacters(in: .whitespacesAndNewlines)

            return (
                title.isEmpty ? occurrence.planName : title,
                body.isEmpty ? fallbackNotificationBody(for: template, scheduledDate: occurrence.scheduledDate) : body
            )
        }

        return (
            occurrence.planName,
            fallbackNotificationBody(for: template, scheduledDate: occurrence.scheduledDate)
        )
    }

    private func fallbackNotificationBody(for template: MedicationDoseTemplate, scheduledDate: Date) -> String {
        if template.recordOnlyOralMedication != nil {
            return String.localizedStringWithFormat(
                String(localized: "record_medication.notification_due_format"),
                sentenceCased(template.reminderDoseLine),
                timeText(for: scheduledDate)
            )
        }

        switch template.route {
        case .patchRemove:
            return String.localizedStringWithFormat(
                String(localized: "notification.fallback.patch_remove"),
                template.route.planLabel,
                timeText(for: scheduledDate)
            )
        default:
            return String.localizedStringWithFormat(
                String(localized: "notification.fallback.default"),
                template.route.planLabel,
                doseText(for: template),
                timeText(for: scheduledDate)
            )
        }
    }

    private func timeText(for scheduledDate: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: scheduledDate)
    }

    private func doseText(for template: MedicationDoseTemplate) -> String {
        template.reminderDoseText
    }

    private func doseLine(for template: MedicationDoseTemplate) -> String {
        template.reminderDoseLine
    }

    private func routeLabel(for template: MedicationDoseTemplate) -> String {
        template.recordOnlyOralMedication?.displayName ?? template.route.planLabel
    }

    private func actionVerb(for route: DoseEvent.Route) -> String {
        switch route {
        case .injection:
            return String(localized: "notification.action.inject")
        case .patchApply:
            return String(localized: "notification.action.apply")
        case .patchRemove:
            return String(localized: "notification.action.remove")
        case .gel:
            return String(localized: "notification.action.apply")
        case .oral:
            return String(localized: "notification.action.take")
        case .sublingual:
            return String(localized: "notification.action.take")
        }
    }

    private func selectedReminderTemplate(
        from templates: [ReminderMessageTemplate],
        seedSource: String
    ) -> ReminderMessageTemplate? {
        let activeTemplates = templates.filter {
            $0.weight > 0
                && (!$0.titleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !$0.bodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        let totalWeight = activeTemplates.reduce(0) { $0 + max($1.weight, 0) }
        guard totalWeight > 0 else { return nil }

        let target = Int(stableHash(for: seedSource) % UInt64(totalWeight))
        var runningWeight = 0

        for template in activeTemplates {
            runningWeight += template.weight
            if target < runningWeight {
                return template
            }
        }

        return activeTemplates.last
    }

    private func render(template: String, context: ReminderMessageContext) -> String {
        [
            "{{plan_name}}": context.planName,
            "{{action}}": context.action,
            "{{route}}": context.routeLabel,
            "{{dose}}": context.doseText,
            "{{dose_line}}": context.doseLine,
            "{{time}}": context.timeText
        ]
        .reduce(template) { partial, replacement in
            partial.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func stableHash(for value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    private func sentenceCased(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    private func launchContext(from userInfo: [AnyHashable: Any]) -> ReminderLaunchContext? {
        guard let idString = userInfo[userInfoPlanID] as? String,
              let planID = UUID(uuidString: idString),
              let timestamp = userInfo[userInfoScheduledDate] as? TimeInterval else {
            return nil
        }

        let doseSlotID = (userInfo[userInfoDoseSlotID] as? String).flatMap(UUID.init(uuidString:))
        return ReminderLaunchContext(
            planID: planID,
            scheduledDate: Date(timeIntervalSince1970: timestamp),
            doseSlotID: doseSlotID
        )
    }
}

private struct ReminderMessageContext {
    let planName: String
    let action: String
    let routeLabel: String
    let doseText: String
    let doseLine: String
    let timeText: String
}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            self.pendingLaunchContext = self.launchContext(from: response.notification.request.content.userInfo)
            completionHandler()
        }
    }
}
