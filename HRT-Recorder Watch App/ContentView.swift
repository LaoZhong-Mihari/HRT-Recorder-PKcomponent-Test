import SwiftUI
import Charts
import Combine

private enum WatchEditorSheet: Identifiable {
    case add(UUID)
    case edit(WatchDoseEvent)

    var id: UUID {
        switch self {
        case .add(let token): return token
        case .edit(let event): return event.id
        }
    }
}

struct ContentView: View {
    @StateObject private var store: WatchDoseStore
    @StateObject private var syncService: WatchDoseSyncService
    @StateObject private var timelineVM: WatchDoseTimelineVM
    @State private var activeSheet: WatchEditorSheet?
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        let store = WatchDoseStore()
        let syncService = WatchDoseSyncService()
        _store = StateObject(wrappedValue: store)
        _syncService = StateObject(wrappedValue: syncService)
        _timelineVM = StateObject(wrappedValue: WatchDoseTimelineVM(store: store))
    }

    var body: some View {
        NavigationStack {
            List {
                concentrationSection
                eventSection
            }
            .navigationTitle("timeline.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        activeSheet = .add(UUID())
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("timeline.toolbar.add"))
                }
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .add:
                    WatchAddDoseView { event in
                        save(event)
                    }
                case .edit(let event):
                    WatchAddDoseView(eventToEdit: event) { updatedEvent in
                        save(updatedEvent)
                    }
                }
            }
            .task {
                syncService.attach(store: store) { syncedWeight in
                    timelineVM.bodyWeightKG = syncedWeight
                }
            }
            .onReceive(timer) { _ in
                timelineVM.runSimulation()
            }
        }
    }

    private var chartPointsForDisplay: [WatchChartPoint] {
        let sourcePoints = syncService.chartPoints.isEmpty ? timelineVM.localChartPoints : syncService.chartPoints
        return sourcePoints.sorted { $0.timeH < $1.timeH }
    }

    private var chartDomain: ClosedRange<Date> {
        guard let firstDate = chartPointsForDisplay.first?.date,
              let lastDate = chartPointsForDisplay.last?.date else {
            let now = Date()
            return now...now
        }
        return firstDate...lastDate
    }

    private var concentrationForDisplay: Double? {
        syncService.currentConcentration ?? timelineVM.currentConcentration
    }

    private var concentrationSection: some View {
        Section("chart.title") {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(currentConcentrationText)
                    .font(.headline)
                    .foregroundStyle(concentrationForDisplay == nil ? .secondary : .primary)
            }

            if !chartPointsForDisplay.isEmpty {
                Chart(chartPointsForDisplay) { point in
                    LineMark(
                        x: .value(xAxisLabel, point.date),
                        y: .value(yAxisLabel, point.concentration)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.pink)
                }
                .chartXScale(domain: chartDomain)
                .frame(height: 90)
            }
        }
    }

    private var eventSection: some View {
        Section("watch.section.events") {
            if store.events.isEmpty {
                Text("watch.events.empty")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.events) { event in
                    Button {
                        activeSheet = .edit(event)
                    } label: {
                        WatchEventRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    store.delete(at: offsets)
                    syncService.replaceAll(events: store.events)
                }
            }
        }
    }

    private var currentConcentrationText: String {
        if let value = concentrationForDisplay {
            let formatted = String(format: "%.1f", locale: Locale.current, value)
            return String(
                format: NSLocalizedString("chart.currentConc.value", comment: "Current concentration label"),
                locale: Locale.current,
                formatted
            )
        }
        return NSLocalizedString("chart.currentConc.missing", comment: "Current concentration unavailable")
    }

    private var xAxisLabel: String {
        NSLocalizedString("chart.axis.time", comment: "X-axis label")
    }

    private var yAxisLabel: String {
        NSLocalizedString("chart.axis.conc", comment: "Y-axis label")
    }

    private func save(_ event: WatchDoseEvent) {
        store.upsert(event)
        syncService.replaceAll(events: store.events)
    }
}

private struct WatchEventRow: View {
    let event: WatchDoseEvent

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
        switch event.route {
        case .injection:
            return String(
                format: NSLocalizedString("timeline.row.injection", comment: "Timeline row title for injection"),
                locale: Locale.current,
                event.ester.abbreviation
            )
        case .patchApply:
            return NSLocalizedString("timeline.row.patchApply", comment: "Timeline row title for patch apply")
        case .patchRemove:
            return NSLocalizedString("timeline.row.patchRemove", comment: "Timeline row title for patch removal")
        case .gel:
            return NSLocalizedString("timeline.row.gel", comment: "Timeline row title for gel dosing")
        case .oral:
            return String(
                format: NSLocalizedString("timeline.row.oral", comment: "Timeline row title for oral"),
                locale: Locale.current,
                event.ester.abbreviation
            )
        case .sublingual:
            return String(
                format: NSLocalizedString("timeline.row.sublingual", comment: "Timeline row title for sublingual"),
                locale: Locale.current,
                event.ester.abbreviation
            )
        }
    }

    private var doseText: String? {
        if event.route == .patchRemove {
            return nil
        }

        if let rateUG = event.extras[.releaseRateUGPerDay] {
            let rounded = String(format: "%.0f", locale: Locale.current, rateUG)
            return String(
                format: NSLocalizedString("timeline.row.dose.releaseRate", comment: "Release rate label"),
                locale: Locale.current,
                rounded
            )
        }

        guard event.doseMG > 0 else { return nil }
        let formattedDose = String(format: "%.2f", locale: Locale.current, event.doseMG)
        return String(
            format: NSLocalizedString("timeline.row.dose.mg", comment: "Dose label in mg"),
            locale: Locale.current,
            formattedDose
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(event.date, style: .time)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let doseText {
                    Text(doseText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView()
}
