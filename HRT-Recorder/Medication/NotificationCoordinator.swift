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

    func configure() {
        center.delegate = self
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
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized || authorizationStatus == .provisional || authorizationStatus == .ephemeral else {
            await removeAllManagedNotifications()
            return
        }

        await removeAllManagedNotifications()

        for plan in plans where plan.isEnabled {
            let occurrences = plan.upcomingOccurrences(limit: 12, horizonDays: 45)
            for occurrence in occurrences {
                await scheduleNotification(for: occurrence, plan: plan)
            }
        }
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
            routeLabel: template.route.planLabel,
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
        switch template.route {
        case .patchRemove:
            return "\(template.route.planLabel) is due at \(timeText(for: scheduledDate))."
        default:
            return "\(template.route.planLabel) \(doseText(for: template)) is due at \(timeText(for: scheduledDate))."
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

    private func actionVerb(for route: DoseEvent.Route) -> String {
        switch route {
        case .injection:
            return "inject"
        case .patchApply:
            return "apply"
        case .patchRemove:
            return "remove"
        case .gel:
            return "apply"
        case .oral:
            return "take"
        case .sublingual:
            return "take"
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
