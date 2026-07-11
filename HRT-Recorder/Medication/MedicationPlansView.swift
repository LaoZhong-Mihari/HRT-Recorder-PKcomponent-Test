import SwiftUI
import UIKit

struct MedicationPlansView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var vm: MedicationPlanVM
    @State private var activeSheet: MedicationPlansSheet?
    @State private var planPendingDeletion: MedicationPlan?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                overviewCard

                if let notificationMessage = vm.notificationMessage {
                    InlineNoticeCard(
                        title: String(localized: "Reminders paused"),
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
                            title: String(localized: "Active Plans"),
                            subtitle: String(localized: "Plans with reminders on.")
                        )

                        ForEach(vm.activePlans) { plan in
                            MedicationPlanCard(
                                plan: plan,
                                nextOccurrence: vm.nextOccurrence(for: plan),
                                isEnabled: Binding(
                                    get: { vm.plan(withID: plan.id)?.isEnabled ?? plan.isEnabled },
                                    set: { newValue in
                                        let currentPlan = vm.plan(withID: plan.id) ?? plan
                                        vm.setEnabled(newValue, for: currentPlan)
                                    }
                                ),
                                onEdit: { activeSheet = .edit(plan) },
                                onDelete: { planPendingDeletion = plan }
                            )
                        }
                    }

                    if !vm.pausedPlans.isEmpty {
                        sectionHeader(
                            title: String(localized: "Paused Plans"),
                            subtitle: String(localized: "Saved plans with reminders off.")
                        )

                        ForEach(vm.pausedPlans) { plan in
                            MedicationPlanCard(
                                plan: plan,
                                nextOccurrence: vm.nextOccurrence(for: plan),
                                isEnabled: Binding(
                                    get: { vm.plan(withID: plan.id)?.isEnabled ?? plan.isEnabled },
                                    set: { newValue in
                                        let currentPlan = vm.plan(withID: plan.id) ?? plan
                                        vm.setEnabled(newValue, for: currentPlan)
                                    }
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
        .navigationTitle(dynamicTypeSize.isAccessibilitySize ? String(localized: "Medication Plans") : String(localized: "Medication & Reminders"))
        .navigationBarTitleDisplayMode(dynamicTypeSize.isAccessibilitySize ? .inline : .large)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    activeSheet = .add
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(String(localized: "Create medication plan"))
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
            Text("This only removes the reminder schedule. Logged doses stay.")
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top) {
                    overviewHeaderText
                    Spacer(minLength: 12)
                    overviewHeaderIcon
                }

                VStack(alignment: .leading, spacing: 12) {
                    overviewHeaderText
                    overviewHeaderIcon
                }
            }

            AdaptiveStack(spacing: 12) {
                OverviewStatCard(
                    title: String(localized: "Notifications"),
                    value: notificationStatusTitle,
                    icon: notificationStatusIcon,
                    tint: notificationTint
                )

                OverviewStatCard(
                    title: String(localized: "Active"),
                    value: "\(vm.activePlanCount)",
                    icon: "bell.badge.fill",
                    tint: .blue
                )

                OverviewStatCard(
                    title: String(localized: "Paused"),
                    value: "\(vm.pausedPlanCount)",
                    icon: "pause.circle.fill",
                    tint: .orange
                )
            }

            if let nextReminder = vm.nextOverallOccurrence() {
                LabeledStatusRow(
                    title: String(localized: "Next reminder"),
                    value: nextReminder.scheduledDate.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar.badge.clock"
                )
            } else {
                LabeledStatusRow(
                    title: String(localized: "Next reminder"),
                    value: String(localized: "No reminder scheduled."),
                    systemImage: "calendar.badge.exclamationmark"
                )
            }

            AdaptiveStack(spacing: 10) {
                Button {
                    activeSheet = .add
                } label: {
                    ActionChip(title: String(localized: "New Plan"), systemImage: "plus.circle.fill", prominent: true)
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .import
                } label: {
                    ActionChip(title: String(localized: "Import from Health"), systemImage: "heart.text.square.fill", prominent: false)
                }
                .buttonStyle(.plain)
                .disabled(!vm.supportsMedicationImport)
                .opacity(vm.supportsMedicationImport ? 1 : 0.55)
            }

            AdaptiveStack(spacing: 10) {
                if vm.authorizationStatus == .notDetermined {
                    Button {
                        Task { await vm.requestNotificationAuthorization() }
                    } label: {
                        ActionChip(title: String(localized: "Turn On Notifications"), systemImage: "bell.fill", prominent: false)
                    }
                    .buttonStyle(.plain)
                } else if vm.authorizationStatus == .denied {
                    Button {
                        openAppSettings()
                    } label: {
                        ActionChip(title: String(localized: "Open Settings"), systemImage: "gearshape.fill", prominent: false)
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
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .overlay {
                    ZStack {
                        LinearGradient(
                            colors: [
                                MedicationPalette.blue.opacity(0.14),
                                MedicationPalette.pink.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        Circle()
                            .fill(MedicationPalette.blue.opacity(0.22))
                            .frame(width: 230, height: 230)
                            .blur(radius: 28)
                            .offset(x: 130, y: -120)

                        Circle()
                            .fill(MedicationPalette.pink.opacity(0.18))
                            .frame(width: 210, height: 210)
                            .blur(radius: 32)
                            .offset(x: 120, y: 90)

                        Circle()
                            .fill(Color(uiColor: .systemBackground).opacity(0.12))
                            .frame(width: 150, height: 150)
                            .blur(radius: 24)
                            .offset(x: 155, y: -30)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.24), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 20, x: 0, y: 12)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("No medication plans yet", systemImage: "capsule.portrait")
                .font(.headline)

            Text("Create a plan for doses or patch changes. The app can fill medication details and schedule reminders.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            AdaptiveStack(spacing: 10) {
                Button {
                    activeSheet = .add
                } label: {
                    ActionChip(title: String(localized: "Create First Plan"), systemImage: "plus.circle.fill", prominent: true)
                }
                .buttonStyle(.plain)

                Button {
                    activeSheet = .import
                } label: {
                    ActionChip(title: String(localized: "Import from Health"), systemImage: "heart.text.square.fill", prominent: false)
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

    private var overviewHeaderText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reminder status")
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(overviewDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var overviewHeaderIcon: some View {
        Image(systemName: "cross.case.fill")
            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 24 : 28, weight: .semibold))
            .foregroundStyle(
                LinearGradient(
                    colors: [MedicationPalette.blue, MedicationPalette.pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .padding(12)
            .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var overviewDescription: String {
        switch vm.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return String(localized: "Plans and reminders are ready.")
        case .denied:
            return String(localized: "Turn on notifications in Settings.")
        case .notDetermined:
            return String(localized: "Allow notifications when you're ready.")
        @unknown default:
            return String(localized: "Pull to refresh reminder status.")
        }
    }

    private var notificationStatusTitle: String {
        switch vm.authorizationStatus {
        case .authorized:
            return String(localized: "Ready")
        case .provisional:
            return String(localized: "Provisional")
        case .ephemeral:
            return String(localized: "Temporary")
        case .denied:
            return String(localized: "Blocked")
        case .notDetermined:
            return String(localized: "Needs Access")
        @unknown default:
            return String(localized: "Unknown")
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

private enum MedicationPalette {
    static let blue = Color(red: 0.36, green: 0.56, blue: 0.98)
    static let pink = Color(red: 0.95, green: 0.5, blue: 0.74)
}

private struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: spacing, content: content)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: spacing, content: content)
                VStack(alignment: .leading, spacing: spacing, content: content)
            }
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    headerContent

                    Spacer(minLength: 12)

                    Toggle("Enabled", isOn: $isEnabled)
                        .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 12) {
                    headerContent

                    Toggle("Enabled", isOn: $isEnabled)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                LabeledStatusRow(
                    title: String(localized: "Schedule"),
                    value: recurrenceSummary,
                    systemImage: "calendar"
                )

                if let nextOccurrence {
                    LabeledStatusRow(
                        title: String(localized: "Next reminder"),
                        value: nextOccurrence.scheduledDate.formatted(date: .abbreviated, time: .shortened),
                        systemImage: "clock.badge.checkmark"
                    )
                } else {
                    LabeledStatusRow(
                        title: String(localized: "Next reminder"),
                        value: isEnabled ? String(localized: "No upcoming reminder.") : String(localized: "This plan is paused."),
                        systemImage: isEnabled ? "clock.badge.xmark" : "pause.circle"
                    )
                }

                if let sourceMedicationName = plan.sourceMedicationName, !sourceMedicationName.isEmpty {
                    LabeledStatusRow(
                        title: String(localized: "Imported from Health"),
                        value: sourceMedicationName,
                        systemImage: "heart.text.square"
                    )
                }

            }

            AdaptiveStack(spacing: 10) {
                Button {
                    onEdit()
                } label: {
                    PlanActionButton(
                        title: String(localized: "Edit"),
                        systemImage: "slider.horizontal.3",
                        style: .primary
                    )
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    PlanActionButton(
                        title: String(localized: "Delete"),
                        systemImage: "trash",
                        style: .destructive
                    )
                }
                .buttonStyle(.plain)
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

    private var headerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            AdaptiveStack(spacing: 8) {
                StatusBadge(
                    title: isEnabled ? String(localized: "Active") : String(localized: "Paused"),
                    systemImage: isEnabled ? "bell.fill" : "pause.fill",
                    tint: isEnabled ? .green : .orange
                )

                if let sourceMedicationName = plan.sourceMedicationName, !sourceMedicationName.isEmpty {
                    StatusBadge(
                        title: String(localized: "Imported"),
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var templateSummary: String {
        let slots = plan.resolvedDailyDoseSlots
        if slots.count > 1 {
            return slots
                .map { "\($0.time.formattedText) · \($0.template.planSummaryText)" }
                .joined(separator: "\n")
        }
        return slots.first?.template.planSummaryText ?? plan.template.planSummaryText
    }

    private var recurrenceSummary: String {
        switch plan.recurrence.kind {
        case .daily:
            let times = plan.dailyReminderTimes
                .sorted(by: compareTimes)
                .map { timeText($0) }
                .joined(separator: ", ")
            return String.localizedStringWithFormat(
                String(localized: "Daily at %@"),
                times
            )

        case .weekly:
            let calendar = Calendar.autoupdatingCurrent
            let weekdays = plan.recurrence.weekdays
                .sorted()
                .map {
                    let index = min(max($0 - 1, 0), calendar.shortStandaloneWeekdaySymbols.count - 1)
                    return calendar.shortStandaloneWeekdaySymbols[index]
                }
                .joined(separator: ", ")
            return String.localizedStringWithFormat(
                String(localized: "Weekly on %@ at %@"),
                weekdays,
                timeText(plan.recurrence.primaryTime)
            )

        case .everyNDays:
            return String.localizedStringWithFormat(
                String(localized: "Every %lld day%@ from %@"),
                Int64(plan.recurrence.intervalDays),
                plan.recurrence.intervalDays == 1 ? "" : "s",
                plan.recurrence.startDate.formatted(date: .abbreviated, time: .shortened)
            )
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
                            title: String(localized: "medplan.import.loading.title"),
                            message: String(localized: "medplan.import.loading.message"),
                            systemImage: "heart.text.square.fill",
                            tint: .pink,
                            showsProgress: true
                        )
                    } else if vm.importAuthorizationState == .needsAuthorization {
                        StateCard(
                            title: String(localized: "medplan.import.authorization.title"),
                            message: String(localized: "medplan.import.authorization.message"),
                            systemImage: "heart.text.square.fill",
                            tint: .pink
                        ) {
                            Button(String(localized: "medplan.import.authorization.button")) {
                                Task { await vm.requestImportAuthorizationAndLoadSuggestions() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if let error = vm.importErrorMessage {
                        StateCard(
                            title: String(localized: "Import unavailable"),
                            message: error,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .orange
                        ) {
                            Button("Try Again") {
                                Task { await vm.prepareImportSuggestions() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else if vm.importSuggestions.isEmpty {
                        StateCard(
                            title: String(localized: "medplan.import.empty.title"),
                            message: String(localized: "medplan.import.empty.message"),
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reload") {
                        Task {
                            if vm.importAuthorizationState == .needsAuthorization {
                                await vm.requestImportAuthorizationAndLoadSuggestions()
                            } else {
                                await vm.prepareImportSuggestions()
                            }
                        }
                    }
                    .disabled(vm.isImporting)
                }
            }
        }
        .task {
            await vm.prepareImportSuggestions()
        }
        .refreshable {
            await vm.prepareImportSuggestions()
        }
        .sheet(item: $editingSuggestion) { suggestion in
            MedicationPlanEditorView(existingPlan: nil, importSuggestion: suggestion) { plan in
                Task { await vm.savePlanRequestingNotificationsIfNeeded(plan) }
            }
        }
    }

    private var importHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("medplan.import.header.title")
                .font(.headline)

            Text(vm.importAvailabilityDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if vm.supportsMedicationImport {
                Text("medplan.import.header.message")
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
    @State private var sharedTemplate: MedicationDoseTemplate?
    @State private var recurrenceKind: MedicationPlanRecurrence.Kind
    @State private var previousRecurrenceKind: MedicationPlanRecurrence.Kind
    @State private var dailyDoseSlots: [EditableDailyDoseSlot]
    @State private var weeklyWeekdays: [Int]
    @State private var weeklyTime: Date
    @State private var intervalDays: Int
    @State private var intervalStartDate: Date
    @State private var activeDailySlotEditor: EditableDailyDoseSlot?
    @State private var isSharedDoseEditorPresented = false

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
        let initialTemplate = initialPlan?.primaryTemplate ?? importSuggestion?.suggestedTemplate
        let initialName = initialPlan?.name ?? importSuggestion?.sourceName ?? ""
        let initialDailyDoseSlots = Self.makeInitialDailyDoseSlots(
            existingPlan: initialPlan,
            recurrence: initialRecurrence,
            fallbackTemplate: initialTemplate
        )

        _name = State(initialValue: initialName)
        _isEnabled = State(initialValue: initialPlan?.isEnabled ?? true)
        _sharedTemplate = State(initialValue: initialTemplate ?? initialDailyDoseSlots.first?.template)
        _recurrenceKind = State(initialValue: initialRecurrence.kind)
        _previousRecurrenceKind = State(initialValue: initialRecurrence.kind)
        _dailyDoseSlots = State(initialValue: initialDailyDoseSlots)
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

                Section("Reminder Schedule") {
                    ViewThatFits(in: .horizontal) {
                        Picker("Pattern", selection: $recurrenceKind) {
                            Text("Daily").tag(MedicationPlanRecurrence.Kind.daily)
                            Text("Weekly").tag(MedicationPlanRecurrence.Kind.weekly)
                            Text("Every N Days").tag(MedicationPlanRecurrence.Kind.everyNDays)
                        }
                        .pickerStyle(.segmented)

                        Picker("Pattern", selection: $recurrenceKind) {
                            Text("Daily").tag(MedicationPlanRecurrence.Kind.daily)
                            Text("Weekly").tag(MedicationPlanRecurrence.Kind.weekly)
                            Text("Every N Days").tag(MedicationPlanRecurrence.Kind.everyNDays)
                        }
                    }

                    switch recurrenceKind {
                    case .daily:
                        Text("Each row has its own reminder time and dose, so one plan can handle mixed schedules like 2 mg in the morning and 1 mg later.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                    case .weekly:
                        DatePicker("Time", selection: $weeklyTime, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel)

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
                        Stepper(
                            String.localizedStringWithFormat(
                                String(localized: "Every %lld day%@"),
                                Int64(intervalDays),
                                intervalDays == 1 ? "" : "s"
                            ),
                            value: $intervalDays,
                            in: 1...90
                        )
                        DatePicker("Start", selection: $intervalStartDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                if recurrenceKind == .daily {
                    Section("Dose Schedule") {
                        ForEach(sortedDailyDoseSlots) { slot in
                            DailyDoseSlotCard(
                                slot: slot,
                                canDelete: dailyDoseSlots.count > 1,
                                onEdit: {
                                    activeDailySlotEditor = slot
                                },
                                onDelete: {
                                    removeDailyDoseSlot(id: slot.id)
                                }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        }

                        Button {
                            addDailyDoseSlot()
                        } label: {
                            Label("Add another time", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color(uiColor: .secondarySystemBackground))
                                )
                        }
                        .buttonStyle(.plain)

                        Text("medplan.editor.daily_schedule.help")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("medplan.editor.medication_details.title") {
                        Button {
                            isSharedDoseEditorPresented = true
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(sharedTemplate?.hasConfiguredDose == true ? String(localized: "medplan.editor.medication_details.edit") : String(localized: "medplan.editor.medication_details.configure"))
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    Text(sharedTemplate.map { templateSummary(for: $0) } ?? String(localized: "medplan.editor.medication_details.required"))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
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
            .navigationTitle(existingPlan == nil ? String(localized: "Medication Plan") : String(localized: "Edit Plan"))
            .navigationBarTitleDisplayMode(.inline)
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
                    .disabled(!canSavePlan)
                }
            }
        }
        .sheet(item: $activeDailySlotEditor) { slot in
            DailyDoseSlotEditorView(
                slot: slot,
                canDelete: dailyDoseSlots.count > 1,
                onSave: { updatedSlot in
                    upsertDailyDoseSlot(updatedSlot)
                },
                onDelete: {
                    removeDailyDoseSlot(id: slot.id)
                }
            )
        }
        .sheet(isPresented: $isSharedDoseEditorPresented) {
            InputEventView(
                eventToEdit: nil,
                seed: sharedDoseSeed,
                showsDatePicker: false,
                onSave: { event in
                    sharedTemplate = MedicationDoseTemplate(
                        route: event.route,
                        doseMG: event.doseMG,
                        ester: event.ester,
                        extras: event.extras,
                        recordOnlyOralMedication: event.recordOnlyOralMedication
                    )
                },
                onCancel: nil
            )
        }
        .onChange(of: recurrenceKind) { newValue in
            syncEditorStateForSelectedPattern(from: previousRecurrenceKind, to: newValue)
            previousRecurrenceKind = newValue
        }
    }

    private var sharedDoseSeed: DoseEntrySeed {
        let baseTemplate = sharedTemplate ?? dailyDoseSlots.first?.template ?? MedicationDoseTemplate.empty
        return DoseEntrySeed(date: intervalStartDate, template: baseTemplate)
    }

    private var isRecurrenceValid: Bool {
        switch recurrenceKind {
        case .daily:
            return !dailyDoseSlots.isEmpty
        case .weekly:
            return !weeklyWeekdays.isEmpty
        case .everyNDays:
            return intervalDays > 0
        }
    }

    private var canSavePlan: Bool {
        guard isRecurrenceValid else { return false }

        switch recurrenceKind {
        case .daily:
            return !dailyDoseSlots.isEmpty && dailyDoseSlots.allSatisfy { $0.template?.hasConfiguredDose == true }
        case .weekly, .everyNDays:
            return sharedTemplate?.hasConfiguredDose == true
        }
    }

    private var sortedDailyDoseSlots: [EditableDailyDoseSlot] {
        dailyDoseSlots.sorted(by: Self.compareEditableSlots)
    }

    private func savePlan() {
        let recurrence: MedicationPlanRecurrence
        let planTemplate: MedicationDoseTemplate
        let persistedDailyDoseSlots: [MedicationPlanDoseSlot]

        switch recurrenceKind {
        case .daily:
            let slots = sortedDailyDoseSlots.compactMap { slot -> MedicationPlanDoseSlot? in
                guard let template = slot.template else { return nil }
                return MedicationPlanDoseSlot(id: slot.id, time: slot.time, template: template)
            }
            guard let firstTemplate = slots.first?.template else { return }
            recurrence = .daily(times: slots.map(\.time))
            planTemplate = firstTemplate
            persistedDailyDoseSlots = slots
        case .weekly:
            guard let template = sharedTemplate else { return }
            recurrence = .weekly(
                weekdays: weeklyWeekdays.sorted(),
                time: clockTime(from: weeklyTime)
            )
            planTemplate = template
            persistedDailyDoseSlots = []
        case .everyNDays:
            guard let template = sharedTemplate else { return }
            recurrence = .everyNDays(
                intervalDays: intervalDays,
                startDate: intervalStartDate,
                time: clockTime(from: intervalStartDate)
            )
            planTemplate = template
            persistedDailyDoseSlots = []
        }

        let plan = MedicationPlan(
            id: existingPlan?.id ?? UUID(),
            name: name,
            template: planTemplate,
            dailyDoseSlots: persistedDailyDoseSlots,
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

    private func addDailyDoseSlot() {
        let newSlot = EditableDailyDoseSlot(
            time: suggestedDailyTimeForNewSlot(),
            template: sortedDailyDoseSlots.last?.template ?? sharedTemplate
        )
        dailyDoseSlots.append(newSlot)
        dailyDoseSlots.sort(by: Self.compareEditableSlots)
        activeDailySlotEditor = newSlot
    }

    private func upsertDailyDoseSlot(_ slot: EditableDailyDoseSlot) {
        if let index = dailyDoseSlots.firstIndex(where: { $0.id == slot.id }) {
            dailyDoseSlots[index] = slot
        } else {
            dailyDoseSlots.append(slot)
        }
        dailyDoseSlots.sort(by: Self.compareEditableSlots)
        sharedTemplate = sortedDailyDoseSlots.first?.template ?? sharedTemplate
    }

    private func removeDailyDoseSlot(id: UUID) {
        guard dailyDoseSlots.count > 1 else { return }
        dailyDoseSlots.removeAll { $0.id == id }
        if activeDailySlotEditor?.id == id {
            activeDailySlotEditor = nil
        }
        sharedTemplate = sortedDailyDoseSlots.first?.template ?? sharedTemplate
    }

    private func suggestedDailyTimeForNewSlot() -> ReminderClockTime {
        let existingTimes = Set(sortedDailyDoseSlots.map { "\($0.time.hour):\($0.time.minute)" })
        let baseDate: Date
        if let lastSlot = sortedDailyDoseSlots.last {
            let lastDate = Self.date(for: lastSlot.time)
            baseDate = Calendar.autoupdatingCurrent.date(byAdding: .hour, value: 4, to: lastDate) ?? lastDate
        } else {
            baseDate = Self.date(for: .defaultMorning)
        }

        var candidate = baseDate
        for _ in 0..<48 {
            let candidateTime = clockTime(from: candidate)
            let key = "\(candidateTime.hour):\(candidateTime.minute)"
            if !existingTimes.contains(key) {
                return candidateTime
            }
            candidate = Calendar.autoupdatingCurrent.date(byAdding: .minute, value: 30, to: candidate) ?? candidate
        }

        return clockTime(from: baseDate)
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

    private func syncEditorStateForSelectedPattern(from previousKind: MedicationPlanRecurrence.Kind, to newKind: MedicationPlanRecurrence.Kind) {
        switch newKind {
        case .daily:
            if dailyDoseSlots.isEmpty {
                let seedTime: ReminderClockTime
                switch previousKind {
                case .weekly:
                    seedTime = clockTime(from: weeklyTime)
                case .everyNDays:
                    seedTime = clockTime(from: intervalStartDate)
                case .daily:
                    seedTime = sortedDailyDoseSlots.first?.time ?? .defaultMorning
                }
                dailyDoseSlots = [
                    EditableDailyDoseSlot(
                        time: seedTime,
                        template: sharedTemplate
                    )
                ]
            }
            dailyDoseSlots.sort(by: Self.compareEditableSlots)
            sharedTemplate = sortedDailyDoseSlots.first?.template ?? sharedTemplate

        case .weekly:
            sharedTemplate = sharedTemplate ?? sortedDailyDoseSlots.first?.template
            if let firstSlot = sortedDailyDoseSlots.first {
                weeklyTime = Self.date(for: firstSlot.time)
            }
            if weeklyWeekdays.isEmpty {
                weeklyWeekdays = [Calendar.autoupdatingCurrent.component(.weekday, from: Date())]
            }

        case .everyNDays:
            sharedTemplate = sharedTemplate ?? sortedDailyDoseSlots.first?.template
            if let firstSlot = sortedDailyDoseSlots.first {
                intervalStartDate = intervalStartDate.settingTime(hour: firstSlot.time.hour, minute: firstSlot.time.minute)
            }
            intervalDays = max(intervalDays, 1)
        }
    }

    private func clockTime(from date: Date) -> ReminderClockTime {
        let calendar = Calendar.autoupdatingCurrent
        return ReminderClockTime(
            id: UUID(),
            hour: calendar.component(.hour, from: date),
            minute: calendar.component(.minute, from: date)
        )
    }

    nonisolated fileprivate static func date(for time: ReminderClockTime) -> Date {
        Calendar.autoupdatingCurrent.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: Date()) ?? Date()
    }

    private nonisolated static func compareEditableSlots(
        _ lhs: EditableDailyDoseSlot,
        _ rhs: EditableDailyDoseSlot
    ) -> Bool {
        if lhs.time.hour == rhs.time.hour {
            if lhs.time.minute == rhs.time.minute {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.time.minute < rhs.time.minute
        }
        return lhs.time.hour < rhs.time.hour
    }

    private nonisolated static func compareTimes(_ lhs: ReminderClockTime, _ rhs: ReminderClockTime) -> Bool {
        if lhs.hour == rhs.hour {
            return lhs.minute < rhs.minute
        }
        return lhs.hour < rhs.hour
    }

    private nonisolated static func makeInitialDailyDoseSlots(
        existingPlan: MedicationPlan?,
        recurrence: MedicationPlanRecurrence,
        fallbackTemplate: MedicationDoseTemplate?
    ) -> [EditableDailyDoseSlot] {
        guard recurrence.kind == .daily else { return [] }

        if let existingPlan {
            let existingSlots = existingPlan.resolvedDailyDoseSlots
            if !existingSlots.isEmpty {
                return existingSlots.map {
                    EditableDailyDoseSlot(
                        id: $0.id,
                        time: $0.time,
                        template: $0.template
                    )
                }
            }
        }

        let times = recurrence.times.isEmpty ? [.defaultMorning] : recurrence.times.sorted(by: compareTimes)
        return times.map { EditableDailyDoseSlot(time: $0, template: fallbackTemplate) }
    }
}

private struct EditableDailyDoseSlot: Identifiable, Equatable {
    let id: UUID
    var time: ReminderClockTime
    var template: MedicationDoseTemplate?

    init(
        id: UUID = UUID(),
        time: ReminderClockTime,
        template: MedicationDoseTemplate?
    ) {
        self.id = id
        self.time = time
        self.template = template
    }
}

private struct DailyDoseSlotCard: View {
    let slot: EditableDailyDoseSlot
    let canDelete: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                onEdit()
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slot.time.formattedText)
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(slot.template?.planSummaryText ?? String(localized: "medplan.editor.medication_details.configure"))
                            .font(.subheadline)
                            .foregroundStyle(slot.template?.hasConfiguredDose == true ? .secondary : .primary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if canDelete {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Remove this time", systemImage: "trash")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(uiColor: .separator).opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, 4)
    }
}

private struct DailyDoseSlotEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let slot: EditableDailyDoseSlot
    let canDelete: Bool
    let onSave: (EditableDailyDoseSlot) -> Void
    let onDelete: () -> Void

    @State private var time: Date
    @State private var template: MedicationDoseTemplate?
    @State private var isDoseEditorPresented = false

    init(
        slot: EditableDailyDoseSlot,
        canDelete: Bool,
        onSave: @escaping (EditableDailyDoseSlot) -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.slot = slot
        self.canDelete = canDelete
        self.onSave = onSave
        self.onDelete = onDelete
        _time = State(initialValue: MedicationPlanEditorView.date(for: slot.time))
        _template = State(initialValue: slot.template)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder Time") {
                    DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section("medplan.editor.medication_details.title") {
                    Button {
                        isDoseEditorPresented = true
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(template?.hasConfiguredDose == true ? String(localized: "medplan.editor.medication_details.edit") : String(localized: "medplan.editor.medication_details.configure"))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.primary)

                                Text(template?.planSummaryText ?? String(localized: "medplan.editor.slot.required"))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)

                    Text("medplan.editor.slot.help")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if canDelete {
                    Section {
                        Button("Delete this time", role: .destructive) {
                            onDelete()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Dose Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveSlot()
                    }
                    .disabled(template?.hasConfiguredDose != true)
                }
            }
        }
        .sheet(isPresented: $isDoseEditorPresented) {
            InputEventView(
                eventToEdit: nil,
                seed: currentDoseSeed,
                showsDatePicker: false,
                onSave: { event in
                    template = MedicationDoseTemplate(
                        route: event.route,
                        doseMG: event.doseMG,
                        ester: event.ester,
                        extras: event.extras,
                        recordOnlyOralMedication: event.recordOnlyOralMedication
                    )
                },
                onCancel: nil
            )
        }
    }

    private var currentDoseSeed: DoseEntrySeed {
        let baseTemplate = template ?? MedicationDoseTemplate.empty
        return DoseEntrySeed(date: time, template: baseTemplate)
    }

    private func saveSlot() {
        guard let template, template.hasConfiguredDose else { return }
        onSave(
            EditableDailyDoseSlot(
                id: slot.id,
                time: ReminderClockTime(
                    hour: Calendar.autoupdatingCurrent.component(.hour, from: time),
                    minute: Calendar.autoupdatingCurrent.component(.minute, from: time)
                ),
                template: template
            )
        )
        dismiss()
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
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
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
                    .frame(width: 44, height: 44)
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
                    .fixedSize(horizontal: false, vertical: true)
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
            .multilineTextAlignment(.center)
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var background: some ShapeStyle {
        if prominent {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [MedicationPalette.blue, MedicationPalette.pink],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Color(uiColor: .tertiarySystemGroupedBackground))
    }
}

private struct PlanActionButton: View {
    enum Style {
        case primary
        case destructive
    }

    let title: String
    let systemImage: String
    let style: Style

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foregroundStyle)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
    }

    private var foregroundStyle: Color {
        switch style {
        case .primary:
            return .white
        case .destructive:
            return .red
        }
    }

    private var background: some ShapeStyle {
        switch style {
        case .primary:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        MedicationPalette.blue.opacity(0.98),
                        MedicationPalette.pink.opacity(0.92)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        case .destructive:
            return AnyShapeStyle(Color(uiColor: .tertiarySystemGroupedBackground))
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return Color.white.opacity(0.18)
        case .destructive:
            return Color.red.opacity(0.12)
        }
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

                AdaptiveStack(spacing: 8) {
                    StatusBadge(
                        title: alignmentBadgeTitle,
                        systemImage: alignmentBadgeIcon,
                        tint: alignmentBadgeTint
                    )
                    StatusBadge(title: suggestion.generalFormText, systemImage: "capsule.portrait", tint: .blue)
                }
            }

            if let suggestedTemplate = suggestion.suggestedTemplate, suggestedTemplate.hasConfiguredDose {
                LabeledStatusRow(
                    title: String(localized: "Detected template"),
                    value: templateSummary(for: suggestedTemplate),
                    systemImage: "wand.and.stars"
                )
            } else if let suggestedTemplate = suggestion.suggestedTemplate {
                LabeledStatusRow(
                    title: String(localized: "Detected template"),
                    value: String.localizedStringWithFormat(
                        String(localized: "medplan.import.detected_template.confirmation_format"),
                        templateSummary(for: suggestedTemplate)
                    ),
                    systemImage: "exclamationmark.circle"
                )
            } else {
                LabeledStatusRow(
                    title: String(localized: "Detected template"),
                    value: String(localized: "Dose details still need confirmation."),
                    systemImage: "exclamationmark.circle"
                )
            }

            if let healthPlanSummary = suggestion.healthPlanSummary, !healthPlanSummary.isEmpty {
                LabeledStatusRow(
                    title: String(localized: "medplan.import.health_plan"),
                    value: healthPlanSummary,
                    systemImage: "calendar"
                )
            }

            if let latestDoseDescription = suggestion.latestDoseDescription, !latestDoseDescription.isEmpty {
                LabeledStatusRow(
                    title: String(localized: "Health dose"),
                    value: latestDoseDescription,
                    systemImage: "pills"
                )
            }

            LabeledStatusRow(
                title: String(localized: "medplan.import.health_mapping"),
                value: alignmentSummary,
                systemImage: alignmentBadgeIcon
            )

            if let note = suggestion.note, !note.isEmpty {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                onCreatePlan()
            } label: {
                PlanActionButton(
                    title: String(localized: "medplan.import.review_plan"),
                    systemImage: "slider.horizontal.3",
                    style: .primary
                )
            }
            .buttonStyle(.plain)
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

    private var alignmentSummary: String {
        switch suggestion.alignmentStatus {
        case .aligned:
            if let ruleName = suggestion.alignmentRuleName, !ruleName.isEmpty {
                return String.localizedStringWithFormat(
                    String(localized: "medplan.import.alignment.aligned_format"),
                    ruleName
                )
            }
            return String(localized: "medplan.import.alignment.aligned")
        case .needsDoseConfirmation:
            if let ruleName = suggestion.alignmentRuleName, !ruleName.isEmpty {
                return String.localizedStringWithFormat(
                    String(localized: "medplan.import.alignment.needs_dose_format"),
                    ruleName
                )
            }
            return String(localized: "medplan.import.alignment.needs_dose")
        case .needsRule:
            return String(localized: "medplan.import.alignment.needs_rule")
        }
    }

    private var alignmentBadgeTitle: String {
        switch suggestion.alignmentStatus {
        case .aligned:
            return String(localized: "medplan.import.badge.aligned")
        case .needsDoseConfirmation:
            return String(localized: "medplan.import.badge.check_dose")
        case .needsRule:
            return String(localized: "medplan.import.badge.needs_rule")
        }
    }

    private var alignmentBadgeIcon: String {
        switch suggestion.alignmentStatus {
        case .aligned:
            return "checkmark.circle.fill"
        case .needsDoseConfirmation:
            return "exclamationmark.circle"
        case .needsRule:
            return "questionmark.circle"
        }
    }

    private var alignmentBadgeTint: Color {
        switch suggestion.alignmentStatus {
        case .aligned:
            return .green
        case .needsDoseConfirmation:
            return .orange
        case .needsRule:
            return .secondary
        }
    }
}
