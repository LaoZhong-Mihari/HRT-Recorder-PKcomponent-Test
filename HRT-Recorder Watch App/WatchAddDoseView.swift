import SwiftUI

private enum WatchPatchInputMode: String, CaseIterable, Identifiable {
    case totalDose
    case releaseRate

    var id: Self { self }

    var labelKey: LocalizedStringKey {
        switch self {
        case .totalDose: return "patch.mode.totalDose"
        case .releaseRate: return "patch.mode.releaseRate"
        }
    }
}

struct WatchAddDoseView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date
    @State private var route: WatchDoseEvent.Route
    @State private var ester: WatchDoseEvent.Ester
    @State private var doseText: String

    @State private var patchMode: WatchPatchInputMode
    @State private var patchReleaseRateText: String

    @State private var sublingualTierIndex: Int
    @State private var useCustomTheta: Bool
    @State private var customThetaText: String

    private let editingID: UUID?
    let onSave: (WatchDoseEvent) -> Void

    init(eventToEdit: WatchDoseEvent? = nil, onSave: @escaping (WatchDoseEvent) -> Void) {
        let event = eventToEdit

        _date = State(initialValue: event?.date ?? Date())
        _route = State(initialValue: event?.route ?? .injection)
        _ester = State(initialValue: event?.ester ?? .EV)
        _patchMode = State(
            initialValue: event?.extras[.releaseRateUGPerDay] == nil ? .totalDose : .releaseRate
        )
        _patchReleaseRateText = State(
            initialValue: event?.extras[.releaseRateUGPerDay].map { Self.format($0, decimals: 0) } ?? ""
        )
        _sublingualTierIndex = State(
            initialValue: event?.extras[.sublingualTier].map { min(max(Int($0.rounded()), 0), 3) } ?? 2
        )
        _useCustomTheta = State(initialValue: event?.extras[.sublingualTheta] != nil)
        _customThetaText = State(
            initialValue: event?.extras[.sublingualTheta].map { Self.format($0, decimals: 2) } ?? ""
        )
        _doseText = State(initialValue: Self.initialDoseText(for: event))

        self.editingID = event?.id
        self.onSave = onSave
    }

    private var availableEsters: [WatchDoseEvent.Ester] {
        switch route {
        case .injection:
            return [.EB, .EV, .EC, .EN]
        case .oral, .sublingual:
            return [.E2, .EV]
        case .gel, .patchApply, .patchRemove:
            return [.E2]
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("input.time") {
                    WatchCalendarDatePicker(selection: $date)

                    DatePicker(
                        date.formatted(date: .omitted, time: .shortened),
                        selection: $date,
                        displayedComponents: .hourAndMinute
                    )
                    .datePickerStyle(.automatic)
                }

                Section {
                    Picker("input.route", selection: $route) {
                        ForEach(WatchDoseEvent.Route.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .onChange(of: route) { _, _ in
                        doseText = ""
                        ester = availableEsters.first ?? .E2
                        if route != .patchApply {
                            patchMode = .totalDose
                            patchReleaseRateText = ""
                        }
                        if route != .sublingual {
                            sublingualTierIndex = 2
                            useCustomTheta = false
                            customThetaText = ""
                        }
                    }
                }

                if route != .patchRemove {
                    Section("input.drugDetails") {
                        if availableEsters.count > 1 {
                            Picker("input.drugEster", selection: $ester) {
                                ForEach(availableEsters, id: \.self) { value in
                                    Text(value.localizedName).tag(value)
                                }
                            }
                            .onChange(of: ester) { oldValue, newValue in
                                syncDoseText(from: oldValue, to: newValue)
                            }
                        }

                        if route != .patchApply {
                            TextField(dosePlaceholder, text: $doseText)
                        }

                        if let e2PreviewText {
                            Text(e2PreviewText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if route == .patchApply {
                    Section("input.patchMode") {
                        Picker("input.patchMode.label", selection: $patchMode) {
                            ForEach(WatchPatchInputMode.allCases) { mode in
                                Text(mode.labelKey).tag(mode)
                            }
                        }

                        if patchMode == .totalDose {
                            TextField("input.patchMode.totalDose", text: $doseText)
                        } else {
                            TextField("input.patchMode.releaseRate", text: $patchReleaseRateText)
                        }
                    }
                }

                if route == .sublingual {
                    Section("input.sublingual") {
                        Picker("input.sublingual.hold", selection: $sublingualTierIndex) {
                            Text(sublingualOptionText(for: .quick)).tag(0)
                            Text(sublingualOptionText(for: .casual)).tag(1)
                            Text(sublingualOptionText(for: .standard)).tag(2)
                            Text(sublingualOptionText(for: .strict)).tag(3)
                        }

                        Text(sublingualSuggestionText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Text("input.sublingual.instructions")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("input.sublingual.customTheta", isOn: $useCustomTheta)
                        if useCustomTheta {
                            TextField("input.sublingual.customThetaPlaceholder", text: $customThetaText)
                        }
                    }
                }
            }
            .navigationTitle(editingID == nil ? Text("input.title.add") : Text("input.title.edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        switch route {
        case .patchRemove:
            return true
        case .patchApply:
            if patchMode == .totalDose {
                return parsedDouble(doseText) != nil
            }
            return parsedDouble(patchReleaseRateText) != nil
        case .sublingual:
            if parsedDouble(doseText) == nil { return false }
            if useCustomTheta {
                guard let theta = parsedDouble(customThetaText) else { return false }
                return theta >= 0 && theta <= 1
            }
            return true
        default:
            return parsedDouble(doseText) != nil
        }
    }

    private var dosePlaceholder: String {
        if ester == .E2 {
            return NSLocalizedString("input.dose.e2", comment: "E2-equivalent dose placeholder")
        }
        return String(
            format: NSLocalizedString("input.dose.raw", comment: "Dose input placeholder"),
            locale: Locale.current,
            ester.abbreviation
        )
    }

    private var e2PreviewText: String? {
        guard route != .patchApply,
              route != .patchRemove,
              ester != .E2,
              let rawDose = parsedDouble(doseText) else {
            return nil
        }

        let converted = Self.format(rawDose * ester.toE2Factor, decimals: 2)
        return String(
            format: NSLocalizedString("watch.input.e2EquivalentPreview", comment: "E2-equivalent preview"),
            locale: Locale.current,
            converted
        )
    }

    private var sublingualSuggestionText: String {
        let index = min(max(sublingualTierIndex, 0), 3)
        let tier = WatchSublingualTier(rawValue: index) ?? .standard
        let hold = WatchSublingualTheta.holdMinutes[tier] ?? 0
        let theta = WatchSublingualTheta.recommended[tier] ?? 0.11
        return String(
            format: NSLocalizedString("input.sublingual.suggestion", comment: "Sublingual suggestion"),
            locale: Locale.current,
            hold,
            theta
        )
    }

    private func sublingualOptionText(for tier: WatchSublingualTier) -> String {
        let labelKey: String
        switch tier {
        case .quick:
            labelKey = "input.sublingual.quick"
        case .casual:
            labelKey = "input.sublingual.casual"
        case .standard:
            labelKey = "input.sublingual.standard"
        case .strict:
            labelKey = "input.sublingual.strict"
        }

        let label = NSLocalizedString(labelKey, comment: "Sublingual tier label")
        let hold = WatchSublingualTheta.holdMinutes[tier] ?? 0
        return String(
            format: NSLocalizedString("watch.input.sublingual.option", comment: "Watch sublingual option label"),
            locale: Locale.current,
            label,
            hold
        )
    }

    private func parsedDouble(_ text: String) -> Double? {
        Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private func syncDoseText(from oldValue: WatchDoseEvent.Ester, to newValue: WatchDoseEvent.Ester) {
        guard let enteredDose = parsedDouble(doseText) else { return }

        let e2Equivalent = oldValue == .E2 ? enteredDose : enteredDose * oldValue.toE2Factor
        let nextValue = newValue == .E2 ? e2Equivalent : e2Equivalent / newValue.toE2Factor
        doseText = Self.format(nextValue, decimals: 2)
    }

    private func save() {
        var dose = 0.0
        var extras: [WatchDoseEvent.ExtraKey: Double] = [:]

        switch route {
        case .patchRemove:
            dose = 0
        case .patchApply:
            if patchMode == .releaseRate {
                dose = 0
                if let rate = parsedDouble(patchReleaseRateText) {
                    extras[.releaseRateUGPerDay] = rate
                }
            } else {
                dose = parsedDouble(doseText) ?? 0
            }
        case .sublingual:
            let rawDose = parsedDouble(doseText) ?? 0
            dose = rawDose * ester.toE2Factor
            if useCustomTheta, let theta = parsedDouble(customThetaText) {
                extras[.sublingualTheta] = max(0, min(1, theta))
            } else {
                extras[.sublingualTier] = Double(min(max(sublingualTierIndex, 0), 3))
            }
        default:
            let rawDose = parsedDouble(doseText) ?? 0
            dose = rawDose * ester.toE2Factor
        }

        let event = WatchDoseEvent(
            id: editingID ?? UUID(),
            route: route,
            date: date,
            doseMG: dose,
            ester: ester,
            extras: extras
        )
        onSave(event)
        dismiss()
    }

    private static func initialDoseText(for event: WatchDoseEvent?) -> String {
        guard let event else { return "" }
        guard event.route != .patchRemove else { return "" }

        if event.route == .patchApply, event.extras[.releaseRateUGPerDay] != nil {
            return ""
        }

        let rawDose = event.route == .patchApply || event.ester == .E2
            ? event.doseMG
            : event.doseMG / event.ester.toE2Factor
        return rawDose > 0 ? format(rawDose, decimals: 2) : ""
    }

    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: Locale.current, value)
    }
}

private struct WatchCalendarDatePicker: View {
    @Binding var selection: Date
    @State private var displayedMonth: Date

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)

    init(selection: Binding<Date>) {
        _selection = selection
        _displayedMonth = State(initialValue: Self.monthStart(for: selection.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    displayedMonth = shiftMonth(displayedMonth, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer(minLength: 0)

                Text(displayedMonth, format: .dateTime.year().month(.abbreviated))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                Button {
                    displayedMonth = shiftMonth(displayedMonth, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }

                ForEach(dayCells) { cell in
                    if let date = cell.date {
                        Button {
                            selection = mergingDay(date, into: selection)
                        } label: {
                            Text("\(calendar.component(.day, from: date))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(foregroundStyle(for: date))
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(background(for: date))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(height: 24)
                    }
                }
            }

            Button("common.today") {
                selection = Date()
                displayedMonth = Self.monthStart(for: selection)
            }
            .font(.footnote)
        }
        .onChange(of: selection) { _, newValue in
            let month = Self.monthStart(for: newValue)
            if !calendar.isDate(month, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = month
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = max(calendar.firstWeekday - 1, 0)
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private var dayCells: [WatchCalendarDayCell] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let firstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start),
              let lastVisibleDate = calendar.date(byAdding: .day, value: -1, to: monthInterval.end),
              let lastWeek = calendar.dateInterval(of: .weekOfMonth, for: lastVisibleDate) else {
            return []
        }

        var dates: [WatchCalendarDayCell] = []
        var cursor = firstWeek.start
        while cursor < lastWeek.end {
            let isCurrentMonth = calendar.isDate(cursor, equalTo: displayedMonth, toGranularity: .month)
            dates.append(WatchCalendarDayCell(date: isCurrentMonth ? cursor : nil))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return dates
    }

    private func foregroundStyle(for date: Date) -> Color {
        calendar.isDate(date, inSameDayAs: selection) ? .white : .primary
    }

    @ViewBuilder
    private func background(for date: Date) -> some View {
        if calendar.isDate(date, inSameDayAs: selection) {
            Circle()
                .fill(Color.accentColor)
        } else if calendar.isDateInToday(date) {
            Circle()
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
        }
    }

    private func mergingDay(_ day: Date, into original: Date) -> Date {
        let originalComponents = calendar.dateComponents([.hour, .minute, .second], from: original)
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)

        var merged = DateComponents()
        merged.year = dayComponents.year
        merged.month = dayComponents.month
        merged.day = dayComponents.day
        merged.hour = originalComponents.hour
        merged.minute = originalComponents.minute
        merged.second = originalComponents.second

        return calendar.date(from: merged) ?? day
    }

    private func shiftMonth(_ date: Date, by offset: Int) -> Date {
        calendar.date(byAdding: .month, value: offset, to: date) ?? date
    }

    private static func monthStart(for date: Date) -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}

private struct WatchCalendarDayCell: Identifiable {
    let id = UUID()
    let date: Date?
}
