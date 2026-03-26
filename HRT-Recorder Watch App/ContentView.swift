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
    @State private var isInlineChartActive = false
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
            .scrollDisabled(isInlineChartActive)
            .navigationTitle("timeline.title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isInlineChartActive = false
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

    private var concentrationForDisplay: Double? {
        syncService.currentConcentration ?? timelineVM.currentConcentration
    }

    private var concentrationSection: some View {
        Section("chart.title") {
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(currentConcentrationText)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(concentrationForDisplay == nil ? .secondary : .primary)
            }

            if !chartPointsForDisplay.isEmpty {
                WatchInteractiveChartCard(
                    points: chartPointsForDisplay,
                    isInlineChartActive: $isInlineChartActive
                )
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
                        isInlineChartActive = false
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
            return String(format: "%.1f pg/mL", locale: Locale.current, value)
        }
        return "--"
    }

    private func save(_ event: WatchDoseEvent) {
        store.upsert(event)
        syncService.replaceAll(events: store.events)
    }
}

private struct WatchInteractiveChartCard: View {
    let points: [WatchChartPoint]
    @Binding var isInlineChartActive: Bool
    @State private var isFullscreenPresented = false

    var body: some View {
        WatchInlineConcentrationChart(
            points: points,
            isInlineChartActive: $isInlineChartActive
        ) {
            isInlineChartActive = false
            isFullscreenPresented = true
        }
        .fullScreenCover(isPresented: $isFullscreenPresented) {
            WatchFullscreenConcentrationChart(points: points, isPresented: $isFullscreenPresented)
        }
    }
}

private struct WatchInlineConcentrationChart: View {
    let points: [WatchChartPoint]
    @Binding var isInlineChartActive: Bool
    let onExpand: () -> Void

    @FocusState private var isFocused: Bool
    @State private var scrollPosition: Double = 0
    @State private var crownSelection: Double = 0
    @State private var isCursorActive = false

    private let visibleHours = 72.0

    private var sortedPoints: [WatchChartPoint] {
        points.sorted { $0.timeH < $1.timeH }
    }

    private var selectedPoint: WatchChartPoint? {
        guard isCursorActive, !sortedPoints.isEmpty else { return nil }
        return sortedPoints[selectedIndex]
    }

    private var selectedIndex: Int {
        guard !sortedPoints.isEmpty else { return 0 }
        return min(max(Int(crownSelection.rounded()), 0), sortedPoints.count - 1)
    }

    private var maxSelectionValue: Double {
        Double(max(sortedPoints.count - 1, 0))
    }

    private var dataSignature: String {
        let lower = sortedPoints.first?.timeH ?? 0
        let upper = sortedPoints.last?.timeH ?? 0
        return "\(sortedPoints.count)-\(lower)-\(upper)"
    }

    private var footerText: String {
        guard selectedPoint == nil else {
            return ""
        }
        return WatchChartFormatter.footerDateLabel(for: scrollPosition + visibleHours / 2, visibleHours: visibleHours)
    }

    var body: some View {
        Group {
            if isCursorActive {
                activeChart
            } else {
                inactiveChart
            }
        }
        .task(id: dataSignature) {
            syncState()
        }
        .onChange(of: crownSelection) { _, _ in
            guard isCursorActive else { return }
            scrollSelectionIntoView()
        }
        .onChange(of: isFocused) { _, focused in
            if !focused {
                deactivateCursor()
            }
        }
        .onChange(of: isCursorActive) { _, isActive in
            isInlineChartActive = isActive
            guard isActive else { return }
            requestChartFocus()
        }
    }

    private var inactiveChart: some View {
        chartBase
            .onTapGesture {
                activateCursor()
            }
    }

    private var activeChart: some View {
#if os(watchOS)
        chartBase
            .focusable()
            .focused($isFocused)
            .digitalCrownRotation(
                $crownSelection,
                from: 0,
                through: maxSelectionValue,
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onTapGesture {
                expandChart()
            }
#else
        chartBase
            .focusable()
            .focused($isFocused)
            .onTapGesture {
                expandChart()
            }
#endif
    }

    private var chartBase: some View {
        WatchConcentrationChartSurface(
            points: sortedPoints,
            visibleHours: visibleHours,
            scrollPosition: $scrollPosition,
            selectedPoint: selectedPoint,
            allowsInteractiveScrolling: false,
            frameHeight: 120,
            footerText: footerText,
            footerAlignment: .center
        )
        .padding(.vertical, 2)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isCursorActive ? Color.green : Color.clear, lineWidth: 2)
                .shadow(color: isCursorActive ? Color.green.opacity(0.35) : .clear, radius: 4)
        }
        .animation(.easeInOut(duration: 0.15), value: isCursorActive)
        .onAppear {
            guard isCursorActive else { return }
            requestChartFocus()
        }
    }

    private func activateCursor() {
        guard !sortedPoints.isEmpty else { return }
        isInlineChartActive = true
        crownSelection = Double(nearestIndex(to: scrollPosition + visibleHours / 2))
        isCursorActive = true
        scrollSelectionIntoView()
        requestChartFocus()
    }

    private func expandChart() {
        deactivateCursor()
        onExpand()
    }

    private func deactivateCursor() {
        isCursorActive = false
        isFocused = false
        isInlineChartActive = false
    }

    private func requestChartFocus() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func syncState() {
        guard let bounds = timeBounds else { return }
        let seedHour = selectedPoint?.timeH ?? clamp(Date().timeIntervalSince1970 / 3600.0, within: bounds)
        crownSelection = Double(nearestIndex(to: seedHour))
        scrollPosition = clampedLeadingHour(centeredOn: seedHour, visibleHours: visibleHours)
    }

    private func scrollSelectionIntoView() {
        guard let point = selectedPoint else { return }
        let margin = visibleHours * 0.24
        var leading = clampedLeadingHour(scrollPosition, visibleHours: visibleHours)

        if point.timeH < leading + margin {
            leading = point.timeH - margin
        } else if point.timeH > leading + visibleHours - margin {
            leading = point.timeH - visibleHours + margin
        }

        scrollPosition = clampedLeadingHour(leading, visibleHours: visibleHours)
    }

    private var timeBounds: ClosedRange<Double>? {
        guard let first = sortedPoints.first?.timeH,
              let last = sortedPoints.last?.timeH else {
            return nil
        }
        return first...last
    }

    private func nearestIndex(to hour: Double) -> Int {
        guard !sortedPoints.isEmpty else { return 0 }

        var low = 0
        var high = sortedPoints.count - 1

        while low < high {
            let mid = (low + high) / 2
            if sortedPoints[mid].timeH < hour {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperIndex = low
        let lowerIndex = max(upperIndex - 1, 0)

        if abs(sortedPoints[upperIndex].timeH - hour) < abs(sortedPoints[lowerIndex].timeH - hour) {
            return upperIndex
        }
        return lowerIndex
    }

    private func clampedLeadingHour(centeredOn centerHour: Double, visibleHours: Double) -> Double {
        clampedLeadingHour(centerHour - visibleHours / 2, visibleHours: visibleHours)
    }

    private func clampedLeadingHour(_ candidate: Double, visibleHours: Double) -> Double {
        guard let bounds = timeBounds else { return candidate }
        let totalSpan = bounds.upperBound - bounds.lowerBound
        guard totalSpan > visibleHours else {
            return bounds.lowerBound
        }
        return min(max(candidate, bounds.lowerBound), bounds.upperBound - visibleHours)
    }

    private func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct WatchFullscreenConcentrationChart: View {
    let points: [WatchChartPoint]
    @Binding var isPresented: Bool

    @FocusState private var isFocused: Bool
    @State private var scrollPosition: Double = 0
    @State private var visibleHours: Double = 72
    @State private var crownSelection: Double = 0
    @State private var isCursorActive = false

    private var sortedPoints: [WatchChartPoint] {
        points.sorted { $0.timeH < $1.timeH }
    }

    private var selectedPoint: WatchChartPoint? {
        guard isCursorActive, !sortedPoints.isEmpty else { return nil }
        return sortedPoints[selectedIndex]
    }

    private var selectedIndex: Int {
        guard !sortedPoints.isEmpty else { return 0 }
        return min(max(Int(crownSelection.rounded()), 0), sortedPoints.count - 1)
    }

    private var maxSelectionValue: Double {
        Double(max(sortedPoints.count - 1, 0))
    }

    private var dataSignature: String {
        let lower = sortedPoints.first?.timeH ?? 0
        let upper = sortedPoints.last?.timeH ?? 0
        return "\(sortedPoints.count)-\(lower)-\(upper)"
    }

    private var zoomRange: ClosedRange<Double> {
        guard let bounds = timeBounds else { return 24...24 }
        let totalSpan = max(bounds.upperBound - bounds.lowerBound, 12)
        let minimum = min(12.0, totalSpan)
        return minimum...totalSpan
    }

    private var zoomStep: Double {
        zoomRange.upperBound > 240 ? 6 : 2
    }

    private var footerText: String {
        guard selectedPoint == nil else {
            return ""
        }
        return WatchChartFormatter.footerDateLabel(for: scrollPosition + visibleHours / 2, visibleHours: visibleHours)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                Spacer(minLength: 0)
                interactiveChart
                Spacer(minLength: 0)
            }

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: "Close"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.001))
        .task(id: dataSignature) {
            syncState()
            isFocused = true
        }
        .onChange(of: crownSelection) { _, _ in
            guard isCursorActive else { return }
            scrollSelectionIntoView()
        }
        .onChange(of: visibleHours) { oldValue, newValue in
            guard !isCursorActive else { return }
            let center = scrollPosition + oldValue / 2
            scrollPosition = clampedLeadingHour(center - newValue / 2, visibleHours: newValue)
        }
    }

    @ViewBuilder
    private var interactiveChart: some View {
        let baseChart = WatchConcentrationChartSurface(
            points: sortedPoints,
            visibleHours: visibleHours,
            scrollPosition: $scrollPosition,
            selectedPoint: selectedPoint,
            allowsInteractiveScrolling: !isCursorActive,
            frameHeight: 180,
            footerText: footerText,
            footerAlignment: .center
        )
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .containerShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .focusable()
        .focused($isFocused)
        .onTapGesture {
            toggleCursorMode()
        }

#if os(watchOS)
        if isCursorActive {
            baseChart.digitalCrownRotation(
                $crownSelection,
                from: 0,
                through: maxSelectionValue,
                by: 1,
                sensitivity: .low,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        } else {
            baseChart.digitalCrownRotation(
                $visibleHours,
                from: zoomRange.lowerBound,
                through: zoomRange.upperBound,
                by: zoomStep,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
        }
#else
        baseChart
#endif
    }

    private func toggleCursorMode() {
        guard !sortedPoints.isEmpty else { return }
        if isCursorActive {
            isCursorActive = false
            isFocused = true
            return
        }

        crownSelection = Double(nearestIndex(to: scrollPosition + visibleHours / 2))
        isCursorActive = true
        scrollSelectionIntoView()
        isFocused = true
    }

    private func syncState() {
        guard let bounds = timeBounds else { return }

        visibleHours = min(max(visibleHours, zoomRange.lowerBound), zoomRange.upperBound)

        let seedHour = selectedPoint?.timeH ?? clamp(Date().timeIntervalSince1970 / 3600.0, within: bounds)
        crownSelection = Double(nearestIndex(to: seedHour))
        scrollPosition = clampedLeadingHour(centeredOn: seedHour, visibleHours: visibleHours)
    }

    private func scrollSelectionIntoView() {
        guard let point = selectedPoint else { return }
        let margin = visibleHours * 0.24
        var leading = clampedLeadingHour(scrollPosition, visibleHours: visibleHours)

        if point.timeH < leading + margin {
            leading = point.timeH - margin
        } else if point.timeH > leading + visibleHours - margin {
            leading = point.timeH - visibleHours + margin
        }

        scrollPosition = clampedLeadingHour(leading, visibleHours: visibleHours)
    }

    private var timeBounds: ClosedRange<Double>? {
        guard let first = sortedPoints.first?.timeH,
              let last = sortedPoints.last?.timeH else {
            return nil
        }
        return first...last
    }

    private func nearestIndex(to hour: Double) -> Int {
        guard !sortedPoints.isEmpty else { return 0 }

        var low = 0
        var high = sortedPoints.count - 1

        while low < high {
            let mid = (low + high) / 2
            if sortedPoints[mid].timeH < hour {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upperIndex = low
        let lowerIndex = max(upperIndex - 1, 0)

        if abs(sortedPoints[upperIndex].timeH - hour) < abs(sortedPoints[lowerIndex].timeH - hour) {
            return upperIndex
        }
        return lowerIndex
    }

    private func clampedLeadingHour(centeredOn centerHour: Double, visibleHours: Double) -> Double {
        clampedLeadingHour(centerHour - visibleHours / 2, visibleHours: visibleHours)
    }

    private func clampedLeadingHour(_ candidate: Double, visibleHours: Double) -> Double {
        guard let bounds = timeBounds else { return candidate }
        let totalSpan = bounds.upperBound - bounds.lowerBound
        guard totalSpan > visibleHours else {
            return bounds.lowerBound
        }
        return min(max(candidate, bounds.lowerBound), bounds.upperBound - visibleHours)
    }

    private func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct WatchConcentrationChartSurface: View {
    let points: [WatchChartPoint]
    let visibleHours: Double
    @Binding var scrollPosition: Double
    let selectedPoint: WatchChartPoint?
    let allowsInteractiveScrolling: Bool
    let frameHeight: CGFloat
    let footerText: String
    let footerAlignment: Alignment

    private var visibleRange: ClosedRange<Double> {
        let upper = scrollPosition + visibleHours
        return scrollPosition...upper
    }

    private var yAxisDomain: ClosedRange<Double> {
        let visiblePoints = points.filter { visibleRange.contains($0.timeH) }
        let sourcePoints = visiblePoints.isEmpty ? points : visiblePoints
        let maxConcentration = sourcePoints.map(\.concentration).max() ?? 0
        let topBoundary = max(maxConcentration, 10) * 1.1
        return 0...topBoundary
    }

    private var axisStep: Double {
        WatchChartFormatter.axisStep(for: visibleHours)
    }

    private var xAxisValues: [Double] {
        guard let first = points.first?.timeH,
              let last = points.last?.timeH else {
            return []
        }

        let start = ceil(max(first, visibleRange.lowerBound) / axisStep) * axisStep
        let end = min(last, visibleRange.upperBound)

        var values: [Double] = []
        var current = start
        while current <= end + 0.001 {
            values.append(current)
            current += axisStep
        }

        if values.isEmpty, let midpoint = points[safe: points.count / 2]?.timeH {
            values.append(midpoint)
        }

        return values
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("Time", point.timeH),
                        y: .value("Concentration", point.concentration)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.pink)
                }

                if let selectedPoint {
                    RuleMark(x: .value("Time", selectedPoint.timeH))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))

                    PointMark(
                        x: .value("Time", selectedPoint.timeH),
                        y: .value("Concentration", selectedPoint.concentration)
                    )
                    .foregroundStyle(.pink)
                    .symbolSize(22)
                    .annotation(position: .top) {
                        WatchChartBadge(text: WatchChartFormatter.concentrationLabel(for: selectedPoint.concentration))
                    }
                }
            }
            .modifier(
                WatchChartScrollingModifier(
                    allowsInteractiveScrolling: allowsInteractiveScrolling,
                    scrollPosition: $scrollPosition,
                    fullDomain: xDomain,
                    visibleDomain: staticVisibleXDomain,
                    visibleHours: visibleHours
                )
            )
            .chartYScale(domain: yAxisDomain)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let selectedPoint,
                       let xPosition = proxy.position(forX: selectedPoint.timeH),
                       let plotFrameAnchor = proxy.plotFrame {
                        let plotFrame = geometry[plotFrameAnchor]
                        WatchChartBadge(text: WatchChartFormatter.cursorTimeLabel(for: selectedPoint.timeH))
                            .position(x: plotFrame.origin.x + xPosition, y: plotFrame.maxY + 14)
                    }
                }
                .allowsHitTesting(false)
            }
            .chartXAxis {
                AxisMarks(values: xAxisValues) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Double.self) {
                            if shouldHideAxisLabel(at: hour) {
                                EmptyView()
                            } else {
                                Text(WatchChartFormatter.axisLabel(for: hour, visibleHours: visibleHours))
                                    .font(.caption2.monospacedDigit())
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let concentration = value.as(Double.self) {
                            Text(WatchChartFormatter.yAxisLabel(for: concentration))
                                .font(.caption2.monospacedDigit())
                        }
                    }
                }
            }
            .frame(height: frameHeight)

            if !footerText.isEmpty {
                Text(footerText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: footerAlignment)
            }
        }
    }

    private func shouldHideAxisLabel(at hour: Double) -> Bool {
        guard let selectedPoint else { return false }
        return abs(selectedPoint.timeH - hour) < axisStep * 0.45
    }

    private var staticVisibleXDomain: ClosedRange<Double> {
        guard let first = points.first?.timeH,
              let last = points.last?.timeH else {
            return 0...1
        }

        let leading = min(max(scrollPosition, first), max(first, last - visibleHours))
        let trailing = min(max(leading + visibleHours, first), last)
        return leading...max(trailing, leading + 0.001)
    }

    private var xDomain: ClosedRange<Double> {
        guard let first = points.first?.timeH,
              let last = points.last?.timeH else {
            return 0...1
        }
        return first...last
    }
}

private struct WatchChartScrollingModifier: ViewModifier {
    let allowsInteractiveScrolling: Bool
    @Binding var scrollPosition: Double
    let fullDomain: ClosedRange<Double>
    let visibleDomain: ClosedRange<Double>
    let visibleHours: Double

    func body(content: Content) -> some View {
        if allowsInteractiveScrolling {
            content
                .chartScrollableAxes(.horizontal)
                .chartScrollPosition(x: $scrollPosition)
                .chartXScale(domain: fullDomain)
                .chartXVisibleDomain(length: visibleHours)
        } else {
            content
                .chartXScale(domain: visibleDomain)
        }
    }
}

private enum WatchChartFormatter {
    static func concentrationLabel(for concentration: Double) -> String {
        String(format: "%.1f pg/mL", locale: Locale.current, concentration)
    }

    static func yAxisLabel(for concentration: Double) -> String {
        if concentration >= 100 {
            return String(format: "%.0f", locale: Locale.current, concentration)
        }
        if concentration >= 10 {
            return String(format: "%.1f", locale: Locale.current, concentration)
        }
        return String(format: "%.1f", locale: Locale.current, concentration)
    }

    static func axisStep(for visibleHours: Double) -> Double {
        let targetStep = max(visibleHours / 4.0, 6)
        let preferredSteps: [Double] = [6, 12, 24, 48, 72, 96, 168, 240, 336, 504, 720]
        if let step = preferredSteps.first(where: { $0 >= targetStep }) {
            return step
        }
        return ceil(targetStep / 168) * 168
    }

    static func axisLabel(for hour: Double, visibleHours: Double) -> String {
        let date = Date(timeIntervalSince1970: hour * 3600.0)
        let components = Calendar.current.dateComponents([.month, .day, .hour], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let clockHour = components.hour ?? 0

        if visibleHours < 48 {
            return String(format: "%d/%d\n%02d:00", locale: Locale.current, month, day, clockHour)
        }
        return String(format: "%d/%d", locale: Locale.current, month, day)
    }

    static func footerDateLabel(for hour: Double, visibleHours: Double) -> String {
        let date = Date(timeIntervalSince1970: hour * 3600.0)
        let components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let clockHour = components.hour ?? 0
        let minute = components.minute ?? 0

        if visibleHours < 168 {
            return String(format: "%d/%d %02d:%02d", locale: Locale.current, month, day, clockHour, minute)
        }
        return String(format: "%d/%d", locale: Locale.current, month, day)
    }

    static func cursorTimeLabel(for hour: Double) -> String {
        let date = Date(timeIntervalSince1970: hour * 3600.0)
        let components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: date)
        let month = components.month ?? 0
        let day = components.day ?? 0
        let clockHour = components.hour ?? 0
        let minute = components.minute ?? 0
        return String(format: "%d/%d %02d:%02d", locale: Locale.current, month, day, clockHour, minute)
    }
}

private struct WatchChartBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.black))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
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

    private var timestampText: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(event.date) {
            return event.date.formatted(date: .omitted, time: .shortened)
        }
        return event.date.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(timestampText)
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

private struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
