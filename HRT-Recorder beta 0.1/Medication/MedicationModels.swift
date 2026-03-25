import Foundation

struct MedicationDoseTemplate: Codable, Equatable, Sendable {
    var route: DoseEvent.Route
    var doseMG: Double
    var ester: Ester
    var extras: [DoseEvent.ExtraKey: Double]

    static let empty = MedicationDoseTemplate(route: .oral, doseMG: 0, ester: .E2, extras: [:])
}

extension MedicationDoseTemplate {
    nonisolated var rawDoseMG: Double {
        let factor = EsterInfo.by(ester: ester).toE2Factor
        guard doseMG > 0, factor > 0 else { return doseMG }
        return doseMG / factor
    }

    nonisolated var reminderDoseText: String {
        if let releaseRate = extras[.releaseRateUGPerDay] {
            return "\(Self.formattedNumber(releaseRate, maximumFractionDigits: 0))ug/day"
        }

        guard doseMG > 0 else {
            return ester.abbreviation
        }

        return "\(Self.formattedNumber(rawDoseMG))mg \(ester.abbreviation)"
    }

    nonisolated var reminderDoseLine: String {
        switch route {
        case .patchRemove:
            return "patch removal"
        default:
            return "\(route.reminderLabelLowercased) \(reminderDoseText)"
        }
    }

    nonisolated var planSummaryText: String {
        switch route {
        case .patchRemove:
            return route.planLabel
        default:
            return "\(route.planLabel) · \(reminderDoseText)"
        }
    }

    nonisolated private static func formattedNumber(
        _ value: Double,
        maximumFractionDigits: Int = 2
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

extension DoseEvent.Route {
    nonisolated var planLabel: String {
        switch self {
        case .injection:
            return "Injection"
        case .patchApply:
            return "Patch"
        case .patchRemove:
            return "Patch removal"
        case .gel:
            return "Gel"
        case .oral:
            return "Oral"
        case .sublingual:
            return "Sublingual"
        }
    }

    nonisolated var reminderLabelLowercased: String {
        switch self {
        case .injection:
            return "injection"
        case .patchApply:
            return "patch"
        case .patchRemove:
            return "patch removal"
        case .gel:
            return "gel"
        case .oral:
            return "oral"
        case .sublingual:
            return "sublingual"
        }
    }
}

struct ReminderMessageTemplate: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var titleTemplate: String
    var bodyTemplate: String
    var weight: Int

    nonisolated
    init(
        id: UUID = UUID(),
        titleTemplate: String,
        bodyTemplate: String,
        weight: Int
    ) {
        self.id = id
        self.titleTemplate = titleTemplate
        self.bodyTemplate = bodyTemplate
        self.weight = max(0, weight)
    }

    nonisolated var isEnabled: Bool {
        weight > 0
    }

    nonisolated static var defaultTemplates: [ReminderMessageTemplate] {
        [
            ReminderMessageTemplate(
                titleTemplate: "Hi!",
                bodyTemplate: "It's time for {{dose_line}}.",
                weight: 0
            ),
            ReminderMessageTemplate(
                titleTemplate: "Onii...Mahiro-chan!",
                bodyTemplate: "Don't forget about {{dose_line}}.",
                weight: 100
            ),
            ReminderMessageTemplate(
                titleTemplate: "Reminder",
                bodyTemplate: "{{time}} is your window for {{dose_line}}.",
                weight: 0
            ),
            ReminderMessageTemplate(
                titleTemplate: "Quick check-in",
                bodyTemplate: "Ready when you are: {{dose_line}}.",
                weight: 0
            )
        ]
    }
}

struct DoseEntrySeed: Identifiable, Equatable, Sendable {
    let id: UUID
    var date: Date
    var template: MedicationDoseTemplate
    var title: String?

    init(id: UUID = UUID(), date: Date, template: MedicationDoseTemplate, title: String? = nil) {
        self.id = id
        self.date = date
        self.template = template
        self.title = title
    }
}

struct ReminderClockTime: Codable, Hashable, Identifiable, Equatable, Sendable {
    var id: UUID
    var hour: Int
    var minute: Int

    init(id: UUID = UUID(), hour: Int, minute: Int) {
        self.id = id
        self.hour = hour
        self.minute = minute
    }

    nonisolated static var defaultMorning: ReminderClockTime {
        ReminderClockTime(hour: 9, minute: 0)
    }

    nonisolated var formattedText: String {
        let date = Calendar.autoupdatingCurrent.date(
            bySettingHour: hour,
            minute: minute,
            second: 0,
            of: Date()
        ) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct MedicationPlanDoseSlot: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var time: ReminderClockTime
    var template: MedicationDoseTemplate

    init(
        id: UUID = UUID(),
        time: ReminderClockTime,
        template: MedicationDoseTemplate
    ) {
        self.id = id
        self.time = time
        self.template = template
    }
}

struct MedicationPlanRecurrence: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case daily
        case weekly
        case everyNDays

        var id: String { rawValue }
    }

    var kind: Kind
    var times: [ReminderClockTime]
    var weekdays: [Int]
    var intervalDays: Int
    var startDate: Date

    static func daily(times: [ReminderClockTime] = [.defaultMorning]) -> MedicationPlanRecurrence {
        MedicationPlanRecurrence(
            kind: .daily,
            times: times,
            weekdays: [],
            intervalDays: 1,
            startDate: Date()
        )
    }

    static func weekly(
        weekdays: [Int] = [Calendar.autoupdatingCurrent.component(.weekday, from: Date())],
        time: ReminderClockTime = .defaultMorning
    ) -> MedicationPlanRecurrence {
        MedicationPlanRecurrence(
            kind: .weekly,
            times: [time],
            weekdays: weekdays,
            intervalDays: 7,
            startDate: Date()
        )
    }

    static func everyNDays(
        intervalDays: Int = 7,
        startDate: Date = Date(),
        time: ReminderClockTime = .defaultMorning
    ) -> MedicationPlanRecurrence {
        MedicationPlanRecurrence(
            kind: .everyNDays,
            times: [time],
            weekdays: [],
            intervalDays: max(1, intervalDays),
            startDate: startDate.settingTime(hour: time.hour, minute: time.minute)
        )
    }

    nonisolated var primaryTime: ReminderClockTime {
        times.first ?? .defaultMorning
    }
}

struct MedicationPlan: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var template: MedicationDoseTemplate
    var dailyDoseSlots: [MedicationPlanDoseSlot]
    var recurrence: MedicationPlanRecurrence
    var isEnabled: Bool
    var reminderTemplates: [ReminderMessageTemplate]
    var sourceMedicationName: String?
    var sourceMedicationGeneralForm: String?
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case template
        case dailyDoseSlots
        case recurrence
        case isEnabled
        case reminderTemplates
        case sourceMedicationName
        case sourceMedicationGeneralForm
        case updatedAt
    }

    init(
        id: UUID = UUID(),
        name: String,
        template: MedicationDoseTemplate,
        dailyDoseSlots: [MedicationPlanDoseSlot] = [],
        recurrence: MedicationPlanRecurrence,
        isEnabled: Bool = true,
        reminderTemplates: [ReminderMessageTemplate] = ReminderMessageTemplate.defaultTemplates,
        sourceMedicationName: String? = nil,
        sourceMedicationGeneralForm: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.recurrence = recurrence
        self.dailyDoseSlots = Self.normalizedDailyDoseSlots(
            dailyDoseSlots,
            fallbackTemplate: template,
            recurrence: recurrence
        )
        self.isEnabled = isEnabled
        self.reminderTemplates = reminderTemplates.isEmpty ? ReminderMessageTemplate.defaultTemplates : reminderTemplates
        self.sourceMedicationName = sourceMedicationName
        self.sourceMedicationGeneralForm = sourceMedicationGeneralForm
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        template = try container.decode(MedicationDoseTemplate.self, forKey: .template)
        recurrence = try container.decode(MedicationPlanRecurrence.self, forKey: .recurrence)
        dailyDoseSlots = Self.normalizedDailyDoseSlots(
            try container.decodeIfPresent([MedicationPlanDoseSlot].self, forKey: .dailyDoseSlots) ?? [],
            fallbackTemplate: template,
            recurrence: recurrence
        )
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        reminderTemplates = try container.decodeIfPresent([ReminderMessageTemplate].self, forKey: .reminderTemplates) ?? ReminderMessageTemplate.defaultTemplates
        sourceMedicationName = try container.decodeIfPresent(String.self, forKey: .sourceMedicationName)
        sourceMedicationGeneralForm = try container.decodeIfPresent(String.self, forKey: .sourceMedicationGeneralForm)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(template, forKey: .template)
        try container.encode(dailyDoseSlots, forKey: .dailyDoseSlots)
        try container.encode(recurrence, forKey: .recurrence)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(reminderTemplates, forKey: .reminderTemplates)
        try container.encodeIfPresent(sourceMedicationName, forKey: .sourceMedicationName)
        try container.encodeIfPresent(sourceMedicationGeneralForm, forKey: .sourceMedicationGeneralForm)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    nonisolated var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return defaultPlanName
    }

    nonisolated var defaultPlanName: String {
        switch primaryTemplate.route {
        case .injection:
            return "Inject \(primaryTemplate.ester.abbreviation)"
        case .patchApply:
            return "Apply patch"
        case .patchRemove:
            return "Remove patch"
        case .gel:
            return "Apply gel"
        case .oral:
            return "Take \(primaryTemplate.ester.abbreviation)"
        case .sublingual:
            return "Take \(primaryTemplate.ester.abbreviation) sublingually"
        }
    }

    nonisolated var enabledReminderTemplateCount: Int {
        reminderTemplates.filter(\.isEnabled).count
    }

    nonisolated var primaryTemplate: MedicationDoseTemplate {
        resolvedDailyDoseSlots.first?.template ?? template
    }

    nonisolated var resolvedDailyDoseSlots: [MedicationPlanDoseSlot] {
        guard recurrence.kind == .daily else { return [] }
        let slots = dailyDoseSlots.isEmpty
            ? recurrence.times.map { MedicationPlanDoseSlot(time: $0, template: template) }
            : dailyDoseSlots
        return slots.sorted(by: Self.compareDoseSlots)
    }

    nonisolated var dailyReminderTimes: [ReminderClockTime] {
        if recurrence.kind == .daily {
            return resolvedDailyDoseSlots.map(\.time)
        }
        return recurrence.times.sorted(by: Self.compareTimes)
    }

    nonisolated func doseSlot(
        for scheduledDate: Date,
        doseSlotID: UUID? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MedicationPlanDoseSlot? {
        let slots = resolvedDailyDoseSlots
        guard !slots.isEmpty else { return nil }

        if let doseSlotID,
           let matchedSlot = slots.first(where: { $0.id == doseSlotID }) {
            return matchedSlot
        }

        let hour = calendar.component(.hour, from: scheduledDate)
        let minute = calendar.component(.minute, from: scheduledDate)
        return slots.first {
            $0.time.hour == hour && $0.time.minute == minute
        }
    }

    nonisolated func template(
        for scheduledDate: Date,
        doseSlotID: UUID? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MedicationDoseTemplate {
        doseSlot(for: scheduledDate, doseSlotID: doseSlotID, calendar: calendar)?.template ?? primaryTemplate
    }

    private nonisolated static func normalizedDailyDoseSlots(
        _ dailyDoseSlots: [MedicationPlanDoseSlot],
        fallbackTemplate: MedicationDoseTemplate,
        recurrence: MedicationPlanRecurrence
    ) -> [MedicationPlanDoseSlot] {
        guard recurrence.kind == .daily else { return [] }
        let slots = dailyDoseSlots.isEmpty
            ? recurrence.times.map { MedicationPlanDoseSlot(time: $0, template: fallbackTemplate) }
            : dailyDoseSlots
        return slots.sorted(by: compareDoseSlots)
    }
}

struct PlannedDoseOccurrence: Identifiable, Equatable, Sendable {
    let planID: UUID
    let planName: String
    let scheduledDate: Date
    let doseSlotID: UUID?

    var id: String {
        notificationIdentifier
    }

    var notificationIdentifier: String {
        let timestamp = Int(scheduledDate.timeIntervalSince1970)
        if let doseSlotID {
            return "med-plan-\(planID.uuidString)-\(doseSlotID.uuidString)-\(timestamp)"
        }
        return "med-plan-\(planID.uuidString)-\(timestamp)"
    }
}

struct ReminderLaunchContext: Identifiable, Equatable, Sendable {
    let planID: UUID
    let scheduledDate: Date
    let doseSlotID: UUID?

    var id: String {
        let timestamp = Int(scheduledDate.timeIntervalSince1970)
        if let doseSlotID {
            return "\(planID.uuidString)-\(doseSlotID.uuidString)-\(timestamp)"
        }
        return "\(planID.uuidString)-\(timestamp)"
    }
}

struct MedicationImportSuggestion: Identifiable, Equatable, Sendable {
    let id: UUID
    var sourceName: String
    var nickname: String?
    var generalFormText: String
    var latestDoseDescription: String?
    var suggestedTemplate: MedicationDoseTemplate?
    var suggestedRecurrence: MedicationPlanRecurrence
    var note: String?
    var sourceMedicationName: String?
}

extension MedicationPlan {
    nonisolated func upcomingOccurrences(
        startingFrom referenceDate: Date = Date(),
        limit: Int = 12,
        horizonDays: Int = 60,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [PlannedDoseOccurrence] {
        guard limit > 0 else { return [] }

        let horizonEnd = calendar.date(byAdding: .day, value: max(horizonDays, 1), to: referenceDate) ?? referenceDate
        var occurrences: [PlannedDoseOccurrence] = []

        switch recurrence.kind {
        case .daily:
            let slots = resolvedDailyDoseSlots
            guard !slots.isEmpty else { return [] }

            var day = calendar.startOfDay(for: referenceDate)
            while day <= horizonEnd && occurrences.count < limit {
                for slot in slots {
                    let candidate = calendar.date(
                        bySettingHour: slot.time.hour,
                        minute: slot.time.minute,
                        second: 0,
                        of: day
                    ) ?? day

                    if candidate >= referenceDate {
                        occurrences.append(
                            PlannedDoseOccurrence(
                                planID: id,
                                planName: displayName,
                                scheduledDate: candidate,
                                doseSlotID: slot.id
                            )
                        )
                        if occurrences.count == limit {
                            break
                        }
                    }
                }

                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }

        case .weekly:
            let weekdaySet = Set(recurrence.weekdays.filter { (1...7).contains($0) })
            guard !weekdaySet.isEmpty else { return [] }
            let time = recurrence.primaryTime

            var day = calendar.startOfDay(for: referenceDate)
            while day <= horizonEnd && occurrences.count < limit {
                let weekday = calendar.component(.weekday, from: day)
                if weekdaySet.contains(weekday) {
                    let candidate = calendar.date(
                        bySettingHour: time.hour,
                        minute: time.minute,
                        second: 0,
                        of: day
                    ) ?? day

                    if candidate >= referenceDate {
                        occurrences.append(
                            PlannedDoseOccurrence(
                                planID: id,
                                planName: displayName,
                                scheduledDate: candidate,
                                doseSlotID: nil
                            )
                        )
                    }
                }

                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = nextDay
            }

        case .everyNDays:
            let time = recurrence.primaryTime
            var current = recurrence.startDate.settingTime(hour: time.hour, minute: time.minute)
            let interval = max(recurrence.intervalDays, 1)

            while current < referenceDate {
                guard let next = calendar.date(byAdding: .day, value: interval, to: current) else { break }
                current = next
            }

            while current <= horizonEnd && occurrences.count < limit {
                if current >= referenceDate {
                    occurrences.append(
                        PlannedDoseOccurrence(
                            planID: id,
                            planName: displayName,
                            scheduledDate: current,
                            doseSlotID: nil
                        )
                    )
                }

                guard let next = calendar.date(byAdding: .day, value: interval, to: current) else { break }
                current = next
            }
        }

        return occurrences
    }

    nonisolated func nextOccurrence(
        after date: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> PlannedDoseOccurrence? {
        upcomingOccurrences(startingFrom: date, limit: 1, calendar: calendar).first
    }

    private nonisolated static func compareTimes(_ lhs: ReminderClockTime, _ rhs: ReminderClockTime) -> Bool {
        if lhs.hour == rhs.hour {
            return lhs.minute < rhs.minute
        }
        return lhs.hour < rhs.hour
    }

    private nonisolated static func compareDoseSlots(
        _ lhs: MedicationPlanDoseSlot,
        _ rhs: MedicationPlanDoseSlot
    ) -> Bool {
        if lhs.time.hour == rhs.time.hour {
            if lhs.time.minute == rhs.time.minute {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.time.minute < rhs.time.minute
        }
        return lhs.time.hour < rhs.time.hour
    }
}

extension Date {
    nonisolated func settingTime(hour: Int, minute: Int, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(
            bySettingHour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            second: 0,
            of: self
        ) ?? self
    }
}
