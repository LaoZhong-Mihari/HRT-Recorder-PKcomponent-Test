import SwiftUI
import UIKit

struct MedicationPlansView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject var vm: MedicationPlanVM
    @State private var activeSheet: MedicationPlansSheet?
    @State private var planPendingDeletion: MedicationPlan?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                overviewCard

                if let notificationMessage = vm.notificationMessage {
                    InlineNoticeCard(
                        title: "Reminders paused",
                        message: notificationMessage,
                        systemImage: "bell.slash.fill",
                        tint: .orange,
                        dismissAction: vm.clearNotificationMessage
                    )
                }

                if vm.plans.isEmpty {
                    emptyStateCard
                } else {
                    if !vm.activePlans.isEmpty {
                        sectionHeader(
                            title: "Active Plans",
                            subtitle: "Scheduled reminders that can notify you."
                        )

                        ForEach(vm.activePlans) { plan in
                            MedicationPlanCard(
                                plan: plan,
                                nextOccurrence: vm.nextOccurrence(for: plan),
                                isEnabled: Binding(
                                    get: { plan.isEnabled },
                                    set: { vm.setEnabled($0, for: plan) }
                                ),
                                onEdit: { activeSheet = .edit(plan) },
                                onDelete: { planPendingDeletion = plan }
                            )
                        }
                    }

                    if !vm.pausedPlans.isEmpty {
                        sectionHeader(
                            title: "Paused Plans",
                            subtitle: "Saved templates that are not currently scheduling reminders."
                        )

                        ForEach(vm.pausedPlans) { plan in
                            MedicationPlanCard(
                                plan: plan,
                                nextOccurrence: vm.nextOccurrence(for: plan),
                                isEnabled: Binding(
                                    get: { plan.isEnabled },
                                    set: { vm.setEnabled($0, for: plan) }
                                ),
                                onEdit: { activeSheet = .edit(plan) },
                                onDelete: { planPendingDeletion = plan }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Medication & Reminders")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    activeSheet = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .accessibilityLabel("Create medication plan")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                MedicationPlanEditorView(existingPlan: nil, importSuggestion: nil) { plan in
                    Task { await vm.savePlanRequestingNotificationsIfNeeded(plan) }
                }

            case .edit(let plan):
                MedicationPlanEditorView(existingPlan: plan, importSuggestion: nil) { updated in
                    Task { await vm.savePlanRequestingNotificationsIfNeeded(updated) }
                }

            case .import:
                MedicationImportView(vm: vm)
            }
        }
        .task {
            await vm.refreshSystemState()
        }
        .refreshable {
            await vm.refreshSystemState()
        }
        .alert(
            "Delete plan?",
            isPresented: Binding(
                get: { planPendingDeletion != nil },
                set: { if !$0 { planPendingDeletion = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let planPendingDeletion {
                    vm.removePlan(planPendingDeletion)
                }
                self.planPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                planPendingDeletion = nil
            }
        } message: {
            Text("This removes the reminder schedule but keeps your logged dose history unchanged.")
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stay ahead of each dose")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(overviewDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Image(systemName: "cross.case.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(12)
                    .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

            HStack(spacing: 12) {
                OverviewStatCard(
                    title: "Notifications",
                    value: notificationStatusTitle,
                    icon: notificationStatusIcon,
                    tint: notificationTint
                )

                OverviewStatCard(
                    title: "Active",
                    value: "\(vm.activePlanCount)",
                    icon: "bell.badge.fill",
                    tint: .blue
                )

                OverviewStatCard(
                    title: "Paused",
                    value: "\(vm.pausedPlanCount)",
                    icon: "pause.circle.fill",
                    tint: .orange
                )
            }

            if let nextReminder = vm.nextOverallOccurrence() {
                LabeledStatusRow(
                    title: "Next reminder",
                    value: nextReminder.scheduledDate.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar.badge.clock"
                )
            } else {
                LabeledStatusRow(
                    title: "Next reminder",
                    value: "No reminder is currently scheduled.",
                    systemImage: "calendar.badge.exclamationmark"
                )
            }

            HStack(spacing: 10) {
                Button {
                    activeSheet = .add
                } label: {
                    ActionChip(title: "New Plan", systemImage: "plus.circle.fill", prominent: true)
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .import
                } label: {
                    ActionChip(title: "Import from Health", systemImage: "heart.text.square.fill", prominent: false)
                }
                .buttonStyle(.plain)
                .disabled(!vm.supportsMedicationImport)
                .opacity(vm.supportsMedicationImport ? 1 : 0.55)
            }

            HStack(spacing: 10) {
                if vm.authorizationStatus == .notDetermined {
                    Button {
                        Task { await vm.requestNotificationAuthorization() }
                    } label: {
                        ActionChip(title: "Turn On Notifications", systemImage: "bell.fill", prominent: false)
                    }
                    .buttonStyle(.plain)
                } else if vm.authorizationStatus == .denied {
                    Button {
                        openAppSettings()
                    } label: {
                        ActionChip(title: "Open Settings", systemImage: "gearshape.fill", prominent: false)
                    }
                    .buttonStyle(.plain)
                }

                if !vm.supportsMedicationImport {
                    Text(vm.importAvailabilityDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.orange.opacity(0.12),
                            Color(uiColor: .secondarySystemBackground)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 20, x: 0, y: 12)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("No medication plans yet", systemImage: "capsule.portrait")
                .font(.headline)

            Text("Create a reusable plan for oral doses, injections, gels, or patch changes. The app can then prefill dose logging and schedule reminders for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    activeSheet = .add
                } label: {
                    ActionChip(title: "Create First Plan", systemImage: "plus.circle.fill", prominent: true)
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .import
                } label: {
                    ActionChip(title: "Import from Health", systemImage: "heart.text.square.fill", prominent: false)
                }
                .buttonStyle(.plain)
                .disabled(!vm.supportsMedicationImport)
                .opacity(vm.supportsMedicationImport ? 1 : 0.55)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.14), lineWidth: 1)
        )
    }

    private func sectionHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var overviewDescription: String {
        switch vm.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "Reminders are ready. Active plans will schedule local notifications and open straight into dose confirmation."
        case .denied:
            return "Notifications are turned off, so plans stay saved but reminders cannot be delivered until access is restored."
        case .notDetermined:
            return "Create plans now, then allow notifications the first time you enable reminders."
        @unknown default:
            return "Reminder status is unclear right now. Pull to refresh if this looks wrong."
        }
    }

    private var notificationStatusTitle: String {
        switch vm.authorizationStatus {
        case .authorized:
            return "Ready"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Temporary"
        case .denied:
            return "Blocked"
        case .notDetermined:
            return "Needs Access"
        @unknown default:
            return "Unknown"
        }
    }

    private var notificationStatusIcon: String {
        switch vm.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return "bell.badge.fill"
        case .denied:
            return "bell.slash.fill"
        case .notDetermined:
            return "bell.circle.fill"
        @unknown default:
            return "bell"
        }
    }

    private var notificationTint: Color {
        switch vm.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .green
        case .denied:
            return .orange
        case .notDetermined:
            return .blue
        @unknown default:
            return .gray
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

private enum MedicationPlansSheet: Identifiable {
    case add
    case edit(MedicationPlan)
    case `import`

    var id: String {
        switch self {
        case .add:
            return "add"
        case .edit(let plan):
            return plan.id.uuidString
        case .import:
            return "import"
        }
    }
}

private struct MedicationPlanCard: View {
    let plan: MedicationPlan
    let nextOccurrence: PlannedDoseOccurrence?
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusBadge(
                            title: plan.isEnabled ? "Active" : "Paused",
                            systemImage: plan.isEnabled ? "bell.fill" : "pause.fill",
                            tint: plan.isEnabled ? .green : .orange
                        )

                        if plan.sourceMedicationName != nil {
                            StatusBadge(
                                title: "Imported",
                                systemImage: "heart.text.square.fill",
                                tint: .pink
                            )
                        }
                    }

                    Text(plan.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(templateSummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Toggle("Enabled", isOn: $isEnabled)
                    .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledStatusRow(
                    title: "Schedule",
                    value: recurrenceSummary,
                    systemImage: "calendar"
                )

                if let nextOccurrence {
                    LabeledStatusRow(
                        title: "Next reminder",
                        value: nextOccurrence.scheduledDate.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock.badge.checkmark"
                    )
                } else {
                    LabeledStatusRow(
                        title: "Next reminder",
                        value: isEnabled ? "No upcoming slot was generated." : "This plan is paused.",
                        systemImage: isEnabled ? "clock.badge.xmark" : "pause.circle"
                    )
                }

                if let sourceMedicationName = plan.sourceMedicationName, !sourceMedicationName.isEmpty {
                    LabeledStatusRow(
                        title: "Imported from Health",
                        value: sourceMedicationName,
                        systemImage: "heart.text.square"
                    )
                }

            }

            HStack(spacing: 10) {
                Button {
                    onEdit()
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.14), lineWidth: 1)
        )
    }

    private var templateSummary: String {
        plan.template.planSummaryText
    }

    private var recurrenceSummary: String {
        switch plan.recurrence.kind {
        case .daily:
            let times = plan.recurrence.times
                .sorted(by: compareTimes)
                .map { timeText($0) }
                .joined(separator: ", ")
            return "Daily at \(times)"

        case .weekly:
            let calendar = Calendar.autoupdatingCurrent
            let weekdays = plan.recurrence.weekdays
                .sorted()
                .map {
                    let index = min(max($0 - 1, 0), calendar.shortStandaloneWeekdaySymbols.count - 1)
                    return calendar.shortStandaloneWeekdaySymbols[index]
                }
                .joined(separator: ", ")
            return "Weekly on \(weekdays) at \(timeText(plan.recurrence.primaryTime))"

        case .everyNDays:
            return "Every \(plan.recurrence.intervalDays) day\(plan.recurrence.intervalDays == 1 ? "" : "s") from \(plan.recurrence.startDate.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private func timeText(_ time: ReminderClockTime) -> String {
        let date = Calendar.autoupdatingCurrent.date(
            bySettingHour: time.hour,
            minute: time.minute,
            second: 0,
            of: Date()
        ) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func compareTimes(_ lhs: ReminderClockTime, _ rhs: ReminderClockTime) -> Bool {
        if lhs.hour == rhs.hour {
            return lhs.minute < rhs.minute
        }
        return lhs.hour < rhs.hour
    }
}

private struct MedicationImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vm: MedicationPlanVM
    @State private var editingSuggestion: MedicationImportSuggestion?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    importHeader

                    if vm.isImporting {
                        StateCard(
                            title: "Loading medications",
                            message: "Reading Apple Health medications and recent dose events.",
                            systemImage: "heart.text.square.fill",
                            tint: .pink,
                            showsProgress: true
                        )
                    } else if let error = vm.importErrorMessage {
                        StateCard(
                            title: "Import unavailable",
                            message: error,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        ) {
                            Button("Try Again") {
                                Task { await vm.loadImportSuggestions() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if vm.importSuggestions.isEmpty {
                        StateCard(
                            title: "No suggestions found",
                            message: "No medication records from Apple Health matched the supported import rules yet.",
                            systemImage: "cross.case.fill",
                            tint: .blue
                        )
                    } else {
                        ForEach(vm.importSuggestions) { suggestion in
                            MedicationImportSuggestionCard(suggestion: suggestion) {
                                editingSuggestion = suggestion
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Import from Health")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") {
                        Task { await vm.loadImportSuggestions() }
                    }
                    .disabled(vm.isImporting)
                }
            }
        }
        .task {
            await vm.loadImportSuggestions()
        }
        .refreshable {
            await vm.loadImportSuggestions()
        }
        .sheet(item: $editingSuggestion) { suggestion in
            MedicationPlanEditorView(existingPlan: nil, importSuggestion: suggestion) { plan in
                Task { await vm.savePlanRequestingNotificationsIfNeeded(plan) }
            }
        }
    }

    private var importHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring supported Apple Health medications into reusable reminder plans.")
                .font(.headline)

            Text(vm.importAvailabilityDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if vm.supportsMedicationImport {
                Text("High-confidence mappings are created automatically. Patch release rate, gel area, and other PK-specific values still need confirmation before saving.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.14), lineWidth: 1)
        )
    }
}

private struct MedicationPlanEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let existingPlan: MedicationPlan?
    private let importSuggestion: MedicationImportSuggestion?
    private let onSave: (MedicationPlan) -> Void

    @State private var name: String
    @State private var isEnabled: Bool
    @State private var template: MedicationDoseTemplate?
    @State private var recurrenceKind: MedicationPlanRecurrence.Kind
    @State private var dailyTimes: [ReminderClockTime]
    @State private var weeklyWeekdays: [Int]
    @State private var weeklyTime: Date
    @State private var intervalDays: Int
    @State private var intervalStartDate: Date
    @State private var isDoseEditorPresented = false

    init(
        existingPlan: MedicationPlan?,
        importSuggestion: MedicationImportSuggestion?,
        onSave: @escaping (MedicationPlan) -> Void
    ) {
        self.existingPlan = existingPlan
        self.importSuggestion = importSuggestion
        self.onSave = onSave

        let initialPlan = existingPlan
        let initialRecurrence = initialPlan?.recurrence ?? importSuggestion?.suggestedRecurrence ?? .daily()
        let initialTemplate = initialPlan?.template ?? importSuggestion?.suggestedTemplate
        let initialName = initialPlan?.name ?? importSuggestion?.sourceName ?? ""

        _name = State(initialValue: initialName)
        _isEnabled = State(initialValue: initialPlan?.isEnabled ?? true)
        _template = State(initialValue: initialTemplate)
        _recurrenceKind = State(initialValue: initialRecurrence.kind)
        _dailyTimes = State(initialValue: initialRecurrence.times.isEmpty ? [.defaultMorning] : initialRecurrence.times)
        _weeklyWeekdays = State(initialValue: initialRecurrence.weekdays.isEmpty ? [Calendar.autoupdatingCurrent.component(.weekday, from: Date())] : initialRecurrence.weekdays)
        _weeklyTime = State(initialValue: Self.date(for: initialRecurrence.primaryTime))
        _intervalDays = State(initialValue: max(1, initialRecurrence.intervalDays))
        _intervalStartDate = State(initialValue: initialRecurrence.startDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Plan") {
                    TextField("Plan name", text: $name)
                    Toggle("Notifications enabled", isOn: $isEnabled)
                }

                Section("Dose Template") {
                    Button(template == nil ? "Configure dose template" : "Edit dose template") {
                        isDoseEditorPresented = true
                    }

                    if let template {
                        Text(templateSummary(for: template))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("You need a dose template before saving the plan.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Reminder Schedule") {
                    Picker("Pattern", selection: $recurrenceKind) {
                        Text("Daily").tag(MedicationPlanRecurrence.Kind.daily)
                        Text("Weekly").tag(MedicationPlanRecurrence.Kind.weekly)
                        Text("Every N Days").tag(MedicationPlanRecurrence.Kind.everyNDays)
                    }
                    .pickerStyle(.segmented)

                    switch recurrenceKind {
                    case .daily:
                        ForEach(Array(dailyTimes.enumerated()), id: \.element.id) { index, _ in
                            HStack {
                                DatePicker(
                                    "Time \(index + 1)",
                                    selection: bindingForDailyTime(at: index),
                                    displayedComponents: .hourAndMinute
                                )

                                if dailyTimes.count > 1 {
                                    Button(role: .destructive) {
                                        dailyTimes.remove(at: index)
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                    }
                                }
                            }
                        }

                        Button("Add another time") {
                            dailyTimes.append(.defaultMorning)
                        }

                    case .weekly:
                        DatePicker("Time", selection: $weeklyTime, displayedComponents: .hourAndMinute)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                            ForEach(1...7, id: \.self) { weekday in
                                Button(weekdayLabel(weekday)) {
                                    toggleWeekday(weekday)
                                }
                                .buttonStyle(.bordered)
                                .tint(weeklyWeekdays.contains(weekday) ? .accentColor : .gray)
                            }
                        }

                    case .everyNDays:
                        Stepper("Every \(intervalDays) day\(intervalDays == 1 ? "" : "s")", value: $intervalDays, in: 1...90)
                        DatePicker("Start", selection: $intervalStartDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if let note = importSuggestion?.note, !note.isEmpty {
                    Section("Import Notes") {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(existingPlan == nil ? "Medication Plan" : "Edit Plan")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        savePlan()
                    }
                    .disabled(template == nil || !isRecurrenceValid)
                }
            }
        }
        .sheet(isPresented: $isDoseEditorPresented) {
            NavigationStack {
                InputEventView(
                    eventToEdit: nil,
                    seed: currentDoseSeed,
                    onSave: { event in
                        template = MedicationDoseTemplate(
                            route: event.route,
                            doseMG: event.doseMG,
                            ester: event.ester,
                            extras: event.extras
                        )
                    },
                    onCancel: nil
                )
                .padding()
            }
        }
    }

    private var currentDoseSeed: DoseEntrySeed {
        let baseTemplate = template ?? MedicationDoseTemplate.empty
        return DoseEntrySeed(date: intervalStartDate, template: baseTemplate)
    }

    private var isRecurrenceValid: Bool {
        switch recurrenceKind {
        case .daily:
            return !dailyTimes.isEmpty
        case .weekly:
            return !weeklyWeekdays.isEmpty
        case .everyNDays:
            return intervalDays > 0
        }
    }

    private func savePlan() {
        guard let template else { return }

        let recurrence: MedicationPlanRecurrence
        switch recurrenceKind {
        case .daily:
            recurrence = .daily(times: dailyTimes)
        case .weekly:
            recurrence = .weekly(
                weekdays: weeklyWeekdays.sorted(),
                time: clockTime(from: weeklyTime)
            )
        case .everyNDays:
            recurrence = .everyNDays(
                intervalDays: intervalDays,
                startDate: intervalStartDate,
                time: clockTime(from: intervalStartDate)
            )
        }

        let plan = MedicationPlan(
            id: existingPlan?.id ?? UUID(),
            name: name,
            template: template,
            recurrence: recurrence,
            isEnabled: isEnabled,
            sourceMedicationName: importSuggestion?.sourceMedicationName ?? existingPlan?.sourceMedicationName,
            sourceMedicationGeneralForm: importSuggestion?.generalFormText ?? existingPlan?.sourceMedicationGeneralForm,
            updatedAt: Date()
        )

        onSave(plan)
        dismiss()
    }

    private func templateSummary(for template: MedicationDoseTemplate) -> String {
        template.planSummaryText
    }

    private func toggleWeekday(_ weekday: Int) {
        if let index = weeklyWeekdays.firstIndex(of: weekday) {
            weeklyWeekdays.remove(at: index)
        } else {
            weeklyWeekdays.append(weekday)
        }
    }

    private func weekdayLabel(_ weekday: Int) -> String {
        let symbols = Calendar.autoupdatingCurrent.shortStandaloneWeekdaySymbols
        let index = min(max(weekday - 1, 0), symbols.count - 1)
        return symbols[index]
    }

    private func bindingForDailyTime(at index: Int) -> Binding<Date> {
        Binding<Date>(
            get: { Self.date(for: dailyTimes[index]) },
            set: { newValue in
                dailyTimes[index] = clockTime(from: newValue)
            }
        )
    }

    private func clockTime(from date: Date) -> ReminderClockTime {
        let calendar = Calendar.autoupdatingCurrent
        return ReminderClockTime(
            id: UUID(),
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date)
        )
    }

    nonisolated private static func date(for time: ReminderClockTime) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }
}

private struct OverviewStatCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)

            Text(value)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct InlineNoticeCard: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    let dismissAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                dismissAction()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct LabeledStatusRow: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }
        }
    }
}

private struct StatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct ActionChip: View {
    let title: String
    let systemImage: String
    let prominent: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(prominent ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var background: some ShapeStyle {
        if prominent {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.78)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Color.white.opacity(0.62))
    }
}

private struct StateCard<Actions: View>: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color
    var showsProgress = false
    @ViewBuilder let actions: () -> Actions

    init(
        title: String,
        message: String,
        systemImage: String,
        tint: Color,
        showsProgress: Bool = false,
        @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.showsProgress = showsProgress
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(tint)

                Text(title)
                    .font(.headline)

                Spacer()

                if showsProgress {
                    ProgressView()
                }
            }

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            actions()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct MedicationImportSuggestionCard: View {
    let suggestion: MedicationImportSuggestion
    let onCreatePlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.sourceName)
                        .font(.headline)

                    if let nickname = suggestion.nickname, !nickname.isEmpty {
                        Text(nickname)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                StatusBadge(title: suggestion.generalFormText, systemImage: "capsule.portrait", tint: .blue)
            }

            if let suggestedTemplate = suggestion.suggestedTemplate {
                LabeledStatusRow(
                    title: "Detected template",
                    value: templateSummary(for: suggestedTemplate),
                    systemImage: "wand.and.stars"
                )
            } else {
                LabeledStatusRow(
                    title: "Detected template",
                    value: "Dose details still need confirmation.",
                    systemImage: "exclamationmark.circle"
                )
            }

            if let latestDoseDescription = suggestion.latestDoseDescription {
                LabeledStatusRow(
                    title: "Latest Health event",
                    value: latestDoseDescription,
                    systemImage: "clock.arrow.circlepath"
                )
            }

            if let note = suggestion.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onCreatePlan()
            } label: {
                Label("Create Plan", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.14), lineWidth: 1)
        )
    }

    private func templateSummary(for template: MedicationDoseTemplate) -> String {
        template.planSummaryText
    }
}
