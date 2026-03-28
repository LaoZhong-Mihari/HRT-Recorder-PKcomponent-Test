//
//  TimelineScreen.swift
//  HRTRecorder
//
//  Created by mihari-zhong on 2025/8/1.
//

import Foundation
import SwiftUI

extension DoseEvent {
    var date: Date { Date(timeIntervalSince1970: timeH * 3600.0) }
}

private enum TimelineSheet: Identifiable {
    case add(UUID)
    case edit(DoseEvent)
    case scheduledDose(DoseEntrySeed)
    case weight
    case settings

    var id: UUID {
        switch self {
        case .add(let token): return token
        case .edit(let event): return event.id
        case .scheduledDose(let seed): return seed.id
        case .weight: return UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        case .settings: return UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        }
    }
}

struct TimelineScreen: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject var vm: DoseTimelineVM
    @ObservedObject var medicationVM: MedicationPlanVM

    init(vm: DoseTimelineVM, medicationVM: MedicationPlanVM) {
        _vm = StateObject(wrappedValue: vm)
        self.medicationVM = medicationVM
    }

    // **NEW**: State to manage which event is being edited.
    @State private var activeSheet: TimelineSheet?
    @State private var healthMessage: String?
    @State private var isHealthActionRunning = false
    @State private var isChartCollapsed = false

    private var hasVisibleChart: Bool {
        guard let sim = vm.result else { return false }
        return !sim.timeH.isEmpty
    }

    private var shouldShowEmptyState: Bool {
        vm.dayGroups.isEmpty && !vm.isSimulating && !hasVisibleChart
    }

    private var chartOverlayReserveHeight: CGFloat {
        guard hasVisibleChart else { return 0 }
        return isChartCollapsed ? 92 : (dynamicTypeSize.isAccessibilitySize ? 470 : 360)
    }

    @ViewBuilder
    private var timelineSections: some View {
        ForEach(vm.dayGroups, id: \.day) { dayGroup in
            Section(header: Text(dayGroup.day)) {
                ForEach(dayGroup.events) { event in
                    Button(action: {
                        activeSheet = .edit(event)
                    }) {
                        TimelineRowView(event: event)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .onDelete { indexSet in
                    let originalIndices = findOriginalIndices(for: indexSet, in: dayGroup, from: vm.events)
                    vm.remove(at: originalIndices)
                }
            }
        }
    }

    private var timelineList: some View {
        List {
            timelineSections
        }
        .listStyle(InsetGroupedListStyle())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                timelineList

                if shouldShowEmptyState {
                    TimelineEmptyStateView {
                        activeSheet = .add(UUID())
                    }
                    .padding(.horizontal, 20)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if hasVisibleChart {
                    Color.clear
                        .frame(height: chartOverlayReserveHeight)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let sim = vm.result, hasVisibleChart {
                    TimelineChartOverlay(
                        sim: sim,
                        isCollapsed: isChartCollapsed,
                        onToggleCollapse: toggleChartCollapse
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("timeline.title")
            .toolbar {
                // Left: settings entry page
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        activeSheet = .settings
                    } label: {
                        if isHealthActionRunning {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("settings.title", systemImage: "ellipsis.circle.fill")
                                .font(.body)
                                .accessibilityLabel(Text("settings.toolbar.accessibility"))
                        }
                    }
                }

                // Right: explicit trailing item for adding events
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        activeSheet = .add(UUID())
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .accessibilityLabel(Text("timeline.toolbar.add"))
                    }
                }
            }
            .sheet(item: $activeSheet) { mode in
                switch mode {
                case .add(_):
                    InputEventView(eventToEdit: nil) { event in
                        vm.save(event)
                    }

                case .scheduledDose(let seed):
                    InputEventView(
                        eventToEdit: nil,
                        seed: seed,
                        navigationTitleOverride: seed.title,
                        onSave: { event in
                            vm.save(event)
                            medicationVM.consumePendingDoseSeed()
                        },
                        onCancel: {
                            medicationVM.consumePendingDoseSeed()
                        }
                    )

                case .weight:
                    // Present a dedicated WeightEditorView which keeps a temporary value until saved.
                    NavigationStack {
                        WeightEditorView(initialWeight: vm.bodyWeightKG) { newWeight in
                            Task { await saveEditedWeightAndSync(newWeight) }
                        } onCancel: {
                            activeSheet = nil
                        }
                    }

                case .settings:
                    NavigationStack {
                        HealthSettingsView(
                            weightStatusText: vm.bodyWeightHealthStatusText,
                            medicationVM: medicationVM,
                            onEditWeight: { activeSheet = .weight },
                            onImportWeight: {
                                activeSheet = nil
                                Task { await importBodyWeight() }
                            }
                        )
                    }

                case .edit(let event):
                    InputEventView(eventToEdit: event) { updated in
                        vm.save(updated)
                    }
                }
            }
            .alert("HealthKit", isPresented: Binding(
                get: { healthMessage != nil },
                set: { if !$0 { healthMessage = nil } }
            )) {
                Button("common.ok", role: .cancel) { healthMessage = nil }
            } message: {
                Text(healthMessage ?? "")
            }
            .onChange(of: medicationVM.pendingDoseSeed) { _, newSeed in
                guard let newSeed else { return }
                activeSheet = .scheduledDose(newSeed)
            }
        }
    }

    private func toggleChartCollapse() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            isChartCollapsed.toggle()
        }
    }

    private func importBodyWeight() async {
        guard !isHealthActionRunning else { return }
        isHealthActionRunning = true
        defer { isHealthActionRunning = false }

        do {
            try await vm.requestHealthKitAuthorization()
            let weight = try await vm.importLatestBodyWeightFromHealthKit()
            let formattedWeight = String(format: "%.1f", locale: Locale.current, weight)
            healthMessage = String(
                format: NSLocalizedString("settings.health.importWeight.success", comment: "Weight import success message"),
                locale: Locale.current,
                formattedWeight
            )
        } catch {
            healthMessage = String(
                format: NSLocalizedString("settings.health.error", comment: "HealthKit error message"),
                locale: Locale.current,
                error.localizedDescription
            )
        }
    }

    private func saveEditedWeightAndSync(_ newWeight: Double) async {
        do {
            try await vm.requestHealthKitAuthorization()
            try await vm.updateBodyWeightAndSyncToHealthKit(newWeight)
            activeSheet = nil
        } catch {
            vm.updateBodyWeightLocally(newWeight)
            activeSheet = nil
            healthMessage = String(
                format: NSLocalizedString("settings.health.weightSync.partialFailure", comment: "Weight sync partial failure message"),
                locale: Locale.current,
                error.localizedDescription
            )
        }
    }

    // ... (findOriginalIndices helper remains the same)
    private func findOriginalIndices(for localIndexSet: IndexSet, in dayGroup: TimelineDayGroup, from allEvents: [DoseEvent]) -> IndexSet {
        let idsToDelete = localIndexSet.map { dayGroup.events[$0].id }
        let originalIndices = allEvents.enumerated()
            .filter { idsToDelete.contains($0.element.id) }
            .map { $0.offset }
        return IndexSet(originalIndices)
    }

}

private struct TimelineChartOverlay: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let sim: SimulationResult
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    private var toggleButtonSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 48 : 40
    }

    private var cardCornerRadius: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 30 : 26
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedButton
            } else {
                expandedCard
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isCollapsed)
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                collapseButton
                Spacer(minLength: 0)
            }

            ResultChartView(sim: sim)
        }
        .padding(dynamicTypeSize.isAccessibilitySize ? 14 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.12), radius: 22, x: 0, y: 14)
    }

    private var collapseButton: some View {
        Button(action: onToggleCollapse) {
            Image(systemName: "chevron.down")
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 19 : 16, weight: .semibold))
                .frame(width: toggleButtonSize, height: toggleButtonSize)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.black.opacity(0.78)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("timeline.chart.collapse.accessibility"))
    }

    private var collapsedButton: some View {
        Button(action: onToggleCollapse) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 21 : 18, weight: .semibold))
                .frame(width: toggleButtonSize, height: toggleButtonSize)
                .foregroundStyle(.white)
                .background(Circle().fill(Color.black.opacity(0.82)))
                .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("timeline.chart.expand.accessibility"))
    }
}

private struct TimelineEmptyStateView: View {
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.pink)

            Text("timeline.empty")
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Button(action: onAdd) {
                Label("timeline.toolbar.add", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.pink)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 10)
    }
}

private struct HealthSettingsView: View {
    let weightStatusText: String
    @ObservedObject var medicationVM: MedicationPlanVM
    let onEditWeight: () -> Void
    let onImportWeight: () -> Void

    var body: some View {
        Form {
            Section("settings.section.weight") {
                Button(action: onEditWeight) {
                    SettingsRow(
                        title: "settings.weight.edit.title",
                        subtitle: "settings.weight.edit.subtitle"
                    )
                }
                .buttonStyle(.plain)

                Button(action: onImportWeight) {
                    DynamicSettingsRow(
                        title: "settings.weight.import.title",
                        subtitle: weightStatusText
                    )
                }
                .buttonStyle(.plain)
            }

            Section("about.settings.section") {
                NavigationLink {
                    ProjectCreditsView()
                } label: {
                    SettingsRow(
                        title: "about.settings.entry.title",
                        subtitle: "about.settings.entry.subtitle"
                    )
                }
            }

            Section("settings.section.medication") {
                NavigationLink {
                    MedicationPlansView(vm: medicationVM)
                } label: {
                    DynamicSettingsRow(
                        title: "Medication & Reminders",
                        subtitle: medicationVM.settingsSummaryText()
                    )
                }
            }
        }
        .navigationTitle("settings.title")
    }
}

private struct SettingsRow: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct DynamicSettingsRow: View {
    let title: LocalizedStringKey
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private enum ProjectCreditsLinks {
    static let algorithm = URL(string: "https://github.com/LaoZhong-Mihari")!
    static let appDeveloper = URL(string: "https://github.com/RyouDYFZ")!
    static let openSource = URL(string: "https://github.com/LaoZhong-Mihari/HRT-Recorder-PKcomponent-Test")!
    static let transmtfRepo = URL(string: "https://github.com/TransmtfTeam/Transmtf-HRT-Tracker")!
    static let transmtfWeb = URL(string: "https://hrt.transmtf.com")!
    static let oyamaRepo = URL(string: "https://github.com/SmirnovaOyama/Oyama-s-HRT-Tracker")!
    static let oyamaWeb = URL(string: "https://hrt.mahiro.uk")!
    static let contact = URL(string: "mailto:mihari.suki@icloud.com")!
}

private struct ProjectCreditsView: View {
    var body: some View {
        List {
            Section {
                ExternalLinkButton(
                    destination: ProjectCreditsLinks.algorithm,
                    title: NSLocalizedString("about.developer.algorithm.title", comment: "Algorithm developer title"),
                    subtitle: "@Laozhong-Mihari"
                )

                ExternalLinkButton(
                    destination: ProjectCreditsLinks.appDeveloper,
                    title: NSLocalizedString("about.developer.app.title", comment: "App developer title"),
                    subtitle: "@RyouDYFZ"
                )
            } header: {
                Text("about.section.developers")
            }

            Section {
                ExternalLinkButton(
                    destination: ProjectCreditsLinks.openSource,
                    title: NSLocalizedString("about.opensource.repo.title", comment: "Open source repository title"),
                    subtitle: ProjectCreditsLinks.openSource.absoluteString
                )
            } header: {
                Text("about.section.opensource")
            }

            Section {
                SisterProjectCard(
                    name: "Transmtf-HRT-Tracker",
                    repoURL: ProjectCreditsLinks.transmtfRepo,
                    websiteURL: ProjectCreditsLinks.transmtfWeb
                )

                SisterProjectCard(
                    name: "Oyama's HRT Tracker",
                    repoURL: ProjectCreditsLinks.oyamaRepo,
                    websiteURL: ProjectCreditsLinks.oyamaWeb
                )
            } header: {
                Text("about.section.sisters")
            } footer: {
                Text("about.sisters.footer")
            }

            Section {
                ExternalLinkButton(
                    destination: ProjectCreditsLinks.contact,
                    title: NSLocalizedString("about.contact.title", comment: "Contact us title"),
                    subtitle: "mihari.suki@icloud.com"
                )
            } header: {
                Text("about.section.contact")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("about.title")
    }
}

private struct SisterProjectCard: View {
    let name: String
    let repoURL: URL
    let websiteURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: name)
                .font(.headline)

            ExternalLinkButton(
                destination: repoURL,
                title: NSLocalizedString("about.link.github", comment: "GitHub link label"),
                subtitle: repoURL.absoluteString
            )

            ExternalLinkButton(
                destination: websiteURL,
                title: NSLocalizedString("about.link.website", comment: "Website link label"),
                subtitle: websiteURL.absoluteString
            )
        }
        .padding(.vertical, 4)
    }
}

private struct ExternalLinkButton: View {
    @Environment(\.openURL) private var openURL

    let destination: URL
    let title: String
    let subtitle: String

    var body: some View {
        Button {
            openURL(destination)
        } label: {
            ExternalLinkRow(title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }
}

private struct ExternalLinkRow: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .foregroundColor(.primary)
                Text(verbatim: subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Spacer()

            Image(systemName: "arrow.up.right.square.fill")
                .foregroundColor(.secondary)
                .padding(.top, 2)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Timeline Row View
struct TimelineRowView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let event: DoseEvent
    
    // ... (icon, title, doseText computed properties remain the same)
    private var icon: (name: String, color: Color) {
        switch event.route {
        case .injection: return ("syringe.fill", .red)
        case .patchApply: return ("app.badge.fill", .orange)
        case .patchRemove: return ("app.badge", .gray)
        case .gel: return ("drop.fill", .cyan)
        case .oral: return ("pills.fill", .purple)
        case .sublingual: return ("pills.fill", .teal)
        }
    }
    
    private var title: String {
        if let recordOnlyOralMedication = event.recordOnlyOralMedication {
            return recordOnlyOralMedication.displayName
        }

        switch event.route {
        case .injection:
            return String(format: NSLocalizedString("timeline.row.injection", comment: "Timeline row title for injection"), locale: Locale.current, event.ester.abbreviation)
        case .patchApply:
            return NSLocalizedString("timeline.row.patchApply", comment: "Timeline row title for patch apply")
        case .patchRemove:
            return NSLocalizedString("timeline.row.patchRemove", comment: "Timeline row title for patch removal")
        case .gel:
            return NSLocalizedString("timeline.row.gel", comment: "Timeline row title for gel dosing")
        case .oral:
            return String(format: NSLocalizedString("timeline.row.oral", comment: "Timeline row title for oral"), locale: Locale.current, event.ester.abbreviation)
        case .sublingual:
            return String(format: NSLocalizedString("timeline.row.sublingual", comment: "Timeline row title for sublingual"), locale: Locale.current, event.ester.abbreviation)
        }
    }
    
    /// Returns dose string:
    /// • if patch apply with zero‑order extras → “XX µg/d”
    /// • otherwise for non‑zero doseMG → “YY mg”
    private var doseText: String? {
        // hide for patch removal or zero dose injection
        if event.route == .patchRemove { return nil }
        
        // zero‑order patch: show release rate
        if let rateUG = event.extras[.releaseRateUGPerDay] {
            let rounded = String(format: "%.0f", locale: Locale.current, rateUG)
            return String(format: NSLocalizedString("timeline.row.dose.releaseRate", comment: "Release rate label"), locale: Locale.current, rounded)
        }

        // other routes: show mg
        guard event.doseMG > 0 else { return nil }
        return String(format: NSLocalizedString("timeline.row.dose.mg", comment: "Dose label in mg"), locale: Locale.current, String(format: "%.2f", locale: Locale.current, event.doseMG))
    }
    
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 15) {
                rowIcon
                rowTextContent
                Spacer()
                doseBadge
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 15) {
                    rowIcon
                    rowTextContent
                }
                doseBadge
            }
        }
        .padding(.vertical, 8)
    }

    private var rowIcon: some View {
        Image(systemName: icon.name)
            .font(dynamicTypeSize.isAccessibilitySize ? .title3 : .title2)
            .foregroundColor(.white)
            .frame(width: 40, height: 40)
            .background(icon.color)
            .clipShape(Circle())
    }

    private var rowTextContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(event.date, style: .time)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var doseBadge: some View {
        if let doseText = doseText {
            Text(doseText)
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(uiColor: .systemGray6))
                .clipShape(Capsule())
        }
    }
}

// New: dedicated weight editor view used by the sheet above
struct WeightEditorView: View {
    @State private var tempWeight: Double
    @State private var weightText: String
    @FocusState private var fieldFocused: Bool

    // keep original for change detection
    private let originalWeight: Double

    let onSave: (Double) -> Void
    let onCancel: () -> Void

    init(initialWeight: Double, onSave: @escaping (Double) -> Void, onCancel: @escaping () -> Void) {
        _tempWeight = State(initialValue: initialWeight)
        _weightText = State(initialValue: String(format: "%.1f", locale: Locale.current, initialWeight))
        self.originalWeight = (initialWeight * 10).rounded() / 10
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var roundedTemp: Double { (tempWeight * 10).rounded() / 10 }
    private var isDirty: Bool { roundedTemp != originalWeight }

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 20)

            // Center band: minus - big number - plus
            HStack(alignment: .center, spacing: 20) {
                // Decrease
                Button(action: {
                    withAnimation { tempWeight = max(30.0, (tempWeight - 0.1)) }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .resizable().scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundColor(.pink)
                        .accessibilityLabel(Text("common.decrease"))
                }

                // Number + unit
                VStack(spacing: 6) {
                    ZStack {
                        Text(String(format: "%.1f", roundedTemp))
                            .font(.system(size: 56, weight: .bold, design: .default))
                            .minimumScaleFactor(0.5)
                            .accessibilityLabel(Text("timeline.bodyWeight.accessibility.value"))
                            .onTapGesture { fieldFocused = true }
                            .offset(y: 2)

                        // Invisible TextField to receive input
                        TextField("", text: $weightText)
                            .keyboardType(.decimalPad)
                            .submitLabel(.done)
                            .focused($fieldFocused)
                            .onSubmit { fieldFocused = false }
                            .onChange(of: weightText) { _old, newValue in
                                let sanitized = newValue.replacingOccurrences(of: ",", with: ".")
                                if sanitized.isEmpty {
                                    tempWeight = 0.0
                                } else if let value = Double(sanitized) {
                                    tempWeight = value
                                }
                            }
                            .opacity(0.01)
                            .frame(width: 140, height: 44)
                            .accessibilityHidden(true)
                    }
                    .frame(height: 56)

                    // Unit placed under the number (previous helper area)
                    Text("timeline.bodyWeight.unit")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 120)

                // Increase
                Button(action: {
                    withAnimation { tempWeight = min(200.0, (tempWeight + 0.1)) }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .resizable().scaledToFit()
                        .frame(width: 56, height: 56)
                        .foregroundColor(.pink)
                        .accessibilityLabel(Text("common.increase"))
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .navigationTitle("timeline.bodyWeight.title")
        .toolbar {
            // Cancel in navigation bar leading
            ToolbarItem(placement: .navigationBarLeading) {
                Button("common.cancel") { onCancel() }
            }

            // Save in navigation bar trailing
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    let clamped = min(max(roundedTemp, 30.0), 200.0)
                    onSave(clamped)
                }) {
                    Text("common.save")
                }
                .disabled(!isDirty)
                .buttonStyle(.borderedProminent)
                .tint(.pink)
            }

            // Keep keyboard Done button
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("common.done") { fieldFocused = false }
            }
        }
        // Helper text moved to bottom safe area
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Divider()
                Text("timeline.bodyWeight.help")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            .background(Color(UIColor.systemBackground))
        }
        // Sync textual representation when not editing
        .onChange(of: tempWeight) { _old, _new in
            if !fieldFocused {
                weightText = String(format: "%.1f", locale: Locale.current, roundedTemp)
            }
        }
        // When editing finishes, clamp and format
        .onChange(of: fieldFocused) { _old, focused in
            if !focused {
                let clamped = min(max(tempWeight, 30.0), 200.0)
                tempWeight = clamped
                let rounded = (clamped * 10).rounded() / 10
                weightText = String(format: "%.1f", locale: Locale.current, rounded)
            }
        }
    }
}
