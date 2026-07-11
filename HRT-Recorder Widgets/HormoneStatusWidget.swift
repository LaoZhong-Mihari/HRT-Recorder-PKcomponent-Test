import SwiftUI
import WidgetKit

struct HormoneStatusEntry: TimelineEntry {
    let date: Date
    let configuration: HormoneStatusWidgetIntent
    let snapshot: WidgetHormoneSnapshot
    let surroundingHours: Int
    let isExpired: Bool
}

struct HormoneStatusProvider: AppIntentTimelineProvider {
    private static let timelineInterval: TimeInterval = 15 * 60
    private static let timelineHorizon: TimeInterval = 12 * 60 * 60

    func placeholder(in context: Context) -> HormoneStatusEntry {
        HormoneStatusEntry(
            date: Date(),
            configuration: HormoneStatusWidgetIntent(),
            snapshot: WidgetHormoneSnapshot(
                hormone: .estradiol,
                displayName: "Estradiol",
                unitSymbol: "pg/mL",
                currentValue: 128,
                currentTimeH: Date().timeIntervalSince1970 / 3600.0,
                points: Self.samplePoints(),
                threshold: WidgetThresholdRange.defaultRange(for: .estradiol),
                updatedAt: Date()
            ),
            surroundingHours: WidgetDisplaySettings.defaultValue.surroundingHours,
            isExpired: false
        )
    }

    func snapshot(
        for configuration: HormoneStatusWidgetIntent,
        in context: Context
    ) async -> HormoneStatusEntry {
        entry(for: configuration, date: Date())
    }

    func timeline(
        for configuration: HormoneStatusWidgetIntent,
        in context: Context
    ) async -> Timeline<HormoneStatusEntry> {
        let now = Date()
        let snapshot = WidgetSharedStore.readSnapshot()
        let surroundingHours = WidgetSharedStore.displaySettings().surroundingHours
        let hormone = configuration.hormone?.kind ?? .estradiol
        let hormoneSnapshot = snapshot.hormoneSnapshot(for: hormone)
            ?? WidgetHormoneSnapshot.empty(hormone: hormone, updatedAt: now)
        let firstEntry = entry(
            for: configuration,
            date: now,
            hormoneSnapshot: hormoneSnapshot,
            surroundingHours: surroundingHours
        )

        guard hormoneSnapshot.hasData else {
            return Timeline(
                entries: [firstEntry],
                policy: .after(now.addingTimeInterval(Self.timelineInterval))
            )
        }

        let entries = Self.entryDates(
            from: now,
            snapshot: hormoneSnapshot,
            surroundingHours: surroundingHours
        ).map { date in
            entry(
                for: configuration,
                date: date,
                hormoneSnapshot: hormoneSnapshot,
                surroundingHours: surroundingHours
            )
        }
        let reloadDate = entries.last?.date.addingTimeInterval(Self.timelineInterval) ?? now.addingTimeInterval(Self.timelineInterval)

        return Timeline(
            entries: entries.isEmpty ? [firstEntry] : entries,
            policy: .after(reloadDate)
        )
    }

    private func entry(
        for configuration: HormoneStatusWidgetIntent,
        date: Date
    ) -> HormoneStatusEntry {
        let snapshot = WidgetSharedStore.readSnapshot()
        return entry(for: configuration, date: date, in: snapshot)
    }

    private func entry(
        for configuration: HormoneStatusWidgetIntent,
        date: Date,
        in snapshot: WidgetSnapshot
    ) -> HormoneStatusEntry {
        let hormone = configuration.hormone?.kind ?? .estradiol
        let hormoneSnapshot = snapshot.hormoneSnapshot(for: hormone)
            ?? WidgetHormoneSnapshot.empty(hormone: hormone, updatedAt: date)
        return entry(
            for: configuration,
            date: date,
            hormoneSnapshot: hormoneSnapshot,
            surroundingHours: WidgetSharedStore.displaySettings().surroundingHours
        )
    }

    private func entry(
        for configuration: HormoneStatusWidgetIntent,
        date: Date,
        hormoneSnapshot: WidgetHormoneSnapshot,
        surroundingHours: Int
    ) -> HormoneStatusEntry {
        let visibleWindowHours = Double(surroundingHours)
        let resolvedSnapshot = hormoneSnapshot.resolved(
            at: date,
            visibleWindowHours: visibleWindowHours
        )

        return HormoneStatusEntry(
            date: date,
            configuration: configuration,
            snapshot: resolvedSnapshot,
            surroundingHours: surroundingHours,
            isExpired: hormoneSnapshot.isExpired(
                at: date,
                visibleWindowHours: visibleWindowHours,
                maxAge: Self.timelineHorizon
            )
        )
    }

    private static func entryDates(
        from startDate: Date,
        snapshot: WidgetHormoneSnapshot,
        surroundingHours: Int
    ) -> [Date] {
        let lastFullWindowDate = snapshot.points.last.map {
            Date(timeIntervalSince1970: ($0.timeH - Double(surroundingHours)) * 3600)
        } ?? startDate
        let requestedEndDate = startDate.addingTimeInterval(timelineHorizon)
        let endDate = min(requestedEndDate, lastFullWindowDate)

        guard endDate > startDate else {
            return [startDate]
        }

        var dates: [Date] = []
        var date = startDate
        while date <= endDate {
            dates.append(date)
            date = date.addingTimeInterval(timelineInterval)
        }
        return dates
    }

    private static func samplePoints() -> [WidgetChartPoint] {
        let nowH = Date().timeIntervalSince1970 / 3600.0
        return (0..<25).map { index in
            let offset = -6.0 + Double(index) * 0.5
            let value = 90 + sin(Double(index) / 24.0 * .pi) * 70
            return WidgetChartPoint(timeH: nowH + offset, concentration: value)
        }
    }
}

struct HormoneStatusWidget: Widget {
    let kind = "HormoneStatusWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: HormoneStatusWidgetIntent.self,
            provider: HormoneStatusProvider()
        ) { entry in
            HormoneStatusWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Blood Level Status")
        .description("Current concentration, status color, and the nearby trend curve.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HormoneStatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let entry: HormoneStatusEntry

    private var level: ConcentrationLevel {
        ConcentrationLevel(value: entry.snapshot.currentValue, threshold: entry.snapshot.threshold)
    }

    private var accentColor: Color {
        level.color
    }

    var body: some View {
        Group {
            if entry.isExpired {
                expiredLayout
            } else if entry.snapshot.hasData {
                switch family {
                case .systemSmall:
                    smallLayout
                case .systemLarge:
                    largeLayout
                default:
                    mediumLayout
                }
            } else {
                emptyLayout
            }
        }
        .padding(family == .systemSmall ? 14 : 16)
    }

    private var smallLayout: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(entry.snapshot.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.65 : 0.8)
                Spacer(minLength: 0)
                if dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: level.compactSymbolName)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(level.color)
                        .accessibilityLabel(Text(level.titleKey))
                } else {
                    StatusPill(level: level)
                }
            }

            ConcentrationValueView(snapshot: entry.snapshot, accentColor: accentColor, compact: true)
            MiniConcentrationChart(
                snapshot: entry.snapshot,
                accentColor: accentColor,
                style: .compact,
                surroundingHours: entry.surroundingHours
            )
            .frame(minHeight: 32, idealHeight: 40, maxHeight: .infinity)
            .layoutPriority(1)
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                header(compact: false)
                Spacer(minLength: 8)
                ConcentrationValueView(snapshot: entry.snapshot, accentColor: accentColor, compact: false)
            }

            MiniConcentrationChart(
                snapshot: entry.snapshot,
                accentColor: accentColor,
                style: .regular,
                surroundingHours: entry.surroundingHours
            )
            .frame(maxHeight: .infinity)

            HStack {
                StatusPill(level: level)
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var largeLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                header(compact: false)
                Spacer(minLength: 12)
                StatusPill(level: level)
            }

            ConcentrationValueView(snapshot: entry.snapshot, accentColor: accentColor, compact: false)

            MiniConcentrationChart(
                snapshot: entry.snapshot,
                accentColor: accentColor,
                style: .expanded,
                surroundingHours: entry.surroundingHours
            )
            .frame(maxHeight: .infinity)

            HStack {
                Text(verbatim: "−\(entry.surroundingHours)h")
                    .accessibilityLabel(Text("Hours before now: \(entry.surroundingHours)"))
                Spacer()
                Text("Now")
                    .foregroundStyle(accentColor)
                Spacer()
                Text(verbatim: "+\(entry.surroundingHours)h")
                    .accessibilityLabel(Text("Hours after now: \(entry.surroundingHours)"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var expiredLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.system(size: family == .systemSmall ? 22 : 26, weight: .semibold))
                Text("Data stale")
                    .font(family == .systemSmall ? .headline : .title3.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.orange)

            Text(entry.snapshot.displayName)
                .font(.headline)
                .lineLimit(1)

            Text("Open HRT Recorder to refresh the curve.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if family != .systemSmall {
                HStack(spacing: 4) {
                    Text("Last synced")
                    Text(entry.snapshot.updatedAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private var emptyLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: family == .systemSmall ? 24 : 30, weight: .semibold))
                .foregroundStyle(.pink)

            Text(entry.snapshot.displayName)
                .font(.headline)
                .lineLimit(1)

            Text("Open HRT Recorder to sync or add a dose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private func header(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.displayName)
                .font(compact ? .caption.weight(.semibold) : .headline)
                .lineLimit(1)
            Text("Current")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConcentrationValueView: View {
    let snapshot: WidgetHormoneSnapshot
    let accentColor: Color
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(Self.formatted(snapshot.currentValue))
                .font(.system(size: compact ? 32 : 38, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.55)
                .lineLimit(1)
                .foregroundStyle(accentColor)
            Text(snapshot.unitSymbol)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "--" }
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

private enum MiniChartStyle {
    case compact
    case regular
    case expanded

    var maximumPointCount: Int {
        switch self {
        case .compact: return 64
        case .regular: return 120
        case .expanded: return 180
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .compact: return 2.25
        case .regular: return 2.5
        case .expanded: return 3
        }
    }

    var verticalInset: CGFloat {
        switch self {
        case .compact: return 3
        case .regular: return 4
        case .expanded: return 5
        }
    }

    var areaOpacity: Double {
        switch self {
        case .compact: return 0.16
        case .regular: return 0.13
        case .expanded: return 0.11
        }
    }

    var showsGlow: Bool {
        self == .expanded
    }
}

private struct MiniChartScale {
    let xDomain: ClosedRange<Double>
    let yDomain: ClosedRange<Double>
    let visibleThresholds: [Double]

    init(snapshot: WidgetHormoneSnapshot, surroundingHours: Int) {
        let points = snapshot.points.filter {
            $0.timeH.isFinite && $0.concentration.isFinite && $0.concentration >= 0
        }
        let fallbackTime = snapshot.currentTimeH.isFinite ? snapshot.currentTimeH : 0
        let resolvedHours = Double(
            WidgetDisplaySettings(surroundingHours: surroundingHours).surroundingHours
        )
        xDomain = (fallbackTime - resolvedHours)...(fallbackTime + resolvedHours)

        var values = points.map(\.concentration)
        if let currentValue = snapshot.currentValue,
           currentValue.isFinite,
           currentValue >= 0 {
            values.append(currentValue)
        }

        let thresholds = [snapshot.threshold.low, snapshot.threshold.high]
            .filter { $0.isFinite && $0 >= 0 }
        let resolvedDomain = Self.yDomain(for: values, nearbyThresholds: thresholds)
        yDomain = resolvedDomain
        visibleThresholds = thresholds.filter(resolvedDomain.contains)
    }

    private static func yDomain(
        for values: [Double],
        nearbyThresholds thresholds: [Double]
    ) -> ClosedRange<Double> {
        guard let rawMinimum = values.min(),
              let rawMaximum = values.max(),
              rawMinimum.isFinite,
              rawMaximum.isFinite else {
            return 0...1
        }

        var minimum = rawMinimum
        var maximum = rawMaximum
        let initialCenter = (minimum + maximum) / 2
        let minimumSpan = max(abs(initialCenter) * 0.15, 1)
        if maximum - minimum < minimumSpan {
            minimum = initialCenter - minimumSpan / 2
            maximum = initialCenter + minimumSpan / 2
        }

        let initialSpan = max(maximum - minimum, minimumSpan)
        let initialPadding = initialSpan * 0.12
        let initialLowerBound = minimum - initialPadding
        let initialUpperBound = maximum + initialPadding
        let proximity = max((initialUpperBound - initialLowerBound) * 0.45, minimumSpan * 0.5)
        let includedThresholds = thresholds.filter {
            $0 >= initialLowerBound - proximity && $0 <= initialUpperBound + proximity
        }

        if let thresholdMinimum = includedThresholds.min() {
            minimum = min(minimum, thresholdMinimum)
        }
        if let thresholdMaximum = includedThresholds.max() {
            maximum = max(maximum, thresholdMaximum)
        }

        let center = (minimum + maximum) / 2
        let resolvedMinimumSpan = max(abs(center) * 0.15, 1)
        if maximum - minimum < resolvedMinimumSpan {
            minimum = center - resolvedMinimumSpan / 2
            maximum = center + resolvedMinimumSpan / 2
        }

        let span = max(maximum - minimum, resolvedMinimumSpan)
        let padding = span * 0.12
        let lowerBound = max(minimum - padding, 0)
        let proposedUpperBound = maximum + padding
        let upperBound = proposedUpperBound.isFinite
            ? proposedUpperBound
            : max(maximum, lowerBound + 1)
        return lowerBound...max(upperBound, lowerBound + 0.001)
    }
}

private enum MiniChartSampler {
    private struct ExtremaCandidate {
        let index: Int
        let salience: Double
    }

    static func sample(
        _ points: [WidgetChartPoint],
        maximumCount: Int,
        preserving currentPoint: WidgetChartPoint?
    ) -> [WidgetChartPoint] {
        let validPoints = points.filter {
            $0.timeH.isFinite && $0.concentration.isFinite && $0.concentration >= 0
        }
        guard maximumCount >= 5, !validPoints.isEmpty else {
            return Array(validPoints.prefix(max(maximumCount, 0)))
        }

        let resolvedCurrent = currentPoint.flatMap { point -> WidgetChartPoint? in
            guard point.timeH.isFinite,
                  point.concentration.isFinite,
                  point.concentration >= 0,
                  let firstTime = validPoints.first?.timeH,
                  let lastTime = validPoints.last?.timeH,
                  point.timeH >= firstTime,
                  point.timeH <= lastTime else {
                return nil
            }
            return point
        }
        let currentLocation = locateCurrentPoint(resolvedCurrent, in: validPoints)
        let insertsCurrent = resolvedCurrent != nil && currentLocation.exactIndex == nil
        let rawBudget = max(maximumCount - (insertsCurrent ? 1 : 0), 2)

        guard validPoints.count > rawBudget else {
            return merge(currentPoint: resolvedCurrent, into: validPoints)
        }

        var selected = [Bool](repeating: false, count: validPoints.count)
        var selectedCount = 0

        func select(_ index: Int?) {
            guard let index,
                  validPoints.indices.contains(index),
                  !selected[index],
                  selectedCount < rawBudget else {
                return
            }
            selected[index] = true
            selectedCount += 1
        }

        select(validPoints.startIndex)
        select(validPoints.index(before: validPoints.endIndex))
        let globalExtrema = globalExtremaIndices(in: validPoints)
        select(globalExtrema.minimum)
        select(globalExtrema.maximum)
        select(currentLocation.exactIndex)
        select(currentLocation.previousIndex)
        select(currentLocation.nextIndex)

        let extrema = extremaCandidates(in: validPoints)
        let extremaCapacity = max(rawBudget - selectedCount, 0)
        if extrema.count <= extremaCapacity {
            for candidate in extrema {
                select(candidate.index)
            }
        } else if extremaCapacity > 0 {
            // Preserve the most visually significant extremum in each temporal
            // region. This retains multiple nearby dose peaks when the point
            // budget permits, while keeping the complete operation O(n).
            for bucket in 0..<extremaCapacity {
                let start = bucket * extrema.count / extremaCapacity
                let end = (bucket + 1) * extrema.count / extremaCapacity
                guard start < end else { continue }

                var best = extrema[start]
                for candidate in extrema[(start + 1)..<end]
                    where candidate.salience > best.salience {
                    best = candidate
                }
                select(best.index)
            }
        }

        fillRemainingBudget(
            points: validPoints,
            selected: &selected,
            selectedCount: &selectedCount,
            budget: rawBudget
        )

        var sampled: [WidgetChartPoint] = []
        sampled.reserveCapacity(maximumCount)
        for index in validPoints.indices where selected[index] {
            sampled.append(validPoints[index])
        }
        return merge(currentPoint: resolvedCurrent, into: sampled)
    }

    private static func globalExtremaIndices(
        in points: [WidgetChartPoint]
    ) -> (minimum: Int?, maximum: Int?) {
        guard let firstIndex = points.indices.first else { return (nil, nil) }

        var minimumIndex = firstIndex
        var maximumIndex = firstIndex
        for index in points.indices.dropFirst() {
            if points[index].concentration < points[minimumIndex].concentration {
                minimumIndex = index
            }
            if points[index].concentration > points[maximumIndex].concentration {
                maximumIndex = index
            }
        }
        return (minimumIndex, maximumIndex)
    }

    private static func extremaCandidates(
        in points: [WidgetChartPoint]
    ) -> [ExtremaCandidate] {
        guard points.count >= 3 else { return [] }

        var candidates: [ExtremaCandidate] = []
        candidates.reserveCapacity(points.count / 4)
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1].concentration
            let current = points[index].concentration
            let next = points[index + 1].concentration
            let isMaximum = (current > previous && current >= next)
                || (current >= previous && current > next)
            let isMinimum = (current < previous && current <= next)
                || (current <= previous && current < next)
            guard isMaximum || isMinimum else { continue }

            candidates.append(
                ExtremaCandidate(
                    index: index,
                    salience: abs(current - (previous + next) / 2)
                )
            )
        }
        return candidates
    }

    private static func fillRemainingBudget(
        points: [WidgetChartPoint],
        selected: inout [Bool],
        selectedCount: inout Int,
        budget: Int
    ) {
        let remaining = budget - selectedCount
        guard remaining > 0, points.count > 2 else { return }

        let interiorCount = points.count - 2
        let bucketCount = max((remaining + 1) / 2, 1)
        for bucket in 0..<bucketCount where selectedCount < budget {
            let start = 1 + bucket * interiorCount / bucketCount
            let end = 1 + (bucket + 1) * interiorCount / bucketCount
            guard start < end else { continue }

            var minimumIndex = start
            var maximumIndex = start
            for index in (start + 1)..<min(end, points.count - 1) {
                if points[index].concentration < points[minimumIndex].concentration {
                    minimumIndex = index
                }
                if points[index].concentration > points[maximumIndex].concentration {
                    maximumIndex = index
                }
            }

            for index in [minimumIndex, maximumIndex]
                where selectedCount < budget && !selected[index] {
                selected[index] = true
                selectedCount += 1
            }
        }

        // Critical points may overlap bucket extrema. Use an evenly distributed
        // final pass so that duplicate selections do not waste the point budget.
        guard selectedCount < budget else { return }
        let desired = budget - selectedCount
        let stride = max((points.count - 2) / max(desired, 1), 1)
        var index = 1
        while index < points.count - 1 && selectedCount < budget {
            if !selected[index] {
                selected[index] = true
                selectedCount += 1
            }
            index += stride
        }
    }

    private static func locateCurrentPoint(
        _ currentPoint: WidgetChartPoint?,
        in points: [WidgetChartPoint]
    ) -> (exactIndex: Int?, previousIndex: Int?, nextIndex: Int?) {
        guard let currentPoint else { return (nil, nil, nil) }
        let tolerance = 0.000_001
        var previousIndex: Int?

        for index in points.indices {
            let delta = points[index].timeH - currentPoint.timeH
            if abs(delta) <= tolerance {
                return (index, index > points.startIndex ? index - 1 : nil,
                        index < points.index(before: points.endIndex) ? index + 1 : nil)
            }
            if delta > 0 {
                return (nil, previousIndex, index)
            }
            previousIndex = index
        }
        return (nil, previousIndex, nil)
    }

    private static func merge(
        currentPoint: WidgetChartPoint?,
        into points: [WidgetChartPoint]
    ) -> [WidgetChartPoint] {
        guard let currentPoint else { return points }
        let tolerance = 0.000_001
        var result: [WidgetChartPoint] = []
        result.reserveCapacity(points.count + 1)
        var inserted = false

        for point in points {
            if !inserted, abs(point.timeH - currentPoint.timeH) <= tolerance {
                result.append(currentPoint)
                inserted = true
            } else {
                if !inserted, point.timeH > currentPoint.timeH {
                    result.append(currentPoint)
                    inserted = true
                }
                result.append(point)
            }
        }

        if !inserted {
            result.append(currentPoint)
        }
        return result
    }
}

private struct MiniConcentrationChart: View {
    let snapshot: WidgetHormoneSnapshot
    let accentColor: Color
    let style: MiniChartStyle
    let surroundingHours: Int

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 2
            let plotRect = CGRect(
                x: horizontalInset,
                y: style.verticalInset,
                width: max(proxy.size.width - horizontalInset * 2, 1),
                height: max(proxy.size.height - style.verticalInset * 2, 1)
            )
            let scale = MiniChartScale(
                snapshot: snapshot,
                surroundingHours: surroundingHours
            )
            let exactCurrentPoint = snapshot.currentValue.map {
                WidgetChartPoint(
                    timeH: snapshot.currentTimeH,
                    concentration: $0
                )
            }
            let sampledPoints = MiniChartSampler.sample(
                snapshot.points,
                maximumCount: style.maximumPointCount,
                preserving: exactCurrentPoint
            )
            let renderedPoints = sampledPoints.map { point(in: plotRect, scale: scale, for: $0) }
            let curve = linePath(points: renderedPoints)

            ZStack {
                areaPath(points: renderedPoints, baseline: plotRect.maxY)
                    .fill(
                        LinearGradient(
                            colors: [accentColor.opacity(style.areaOpacity), accentColor.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                ForEach(scale.visibleThresholds, id: \.self) { threshold in
                    horizontalGuide(in: plotRect, scale: scale, value: threshold)
                        .stroke(
                            Color.secondary.opacity(0.22),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                }

                if style.showsGlow {
                    curve
                        .stroke(accentColor.opacity(0.2), lineWidth: style.lineWidth + 3)
                        .blur(radius: 2.5)
                }

                curve
                    .stroke(
                        accentColor,
                        style: StrokeStyle(
                            lineWidth: style.lineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                if let current = currentPoint(in: plotRect, scale: scale) {
                    Path { path in
                        path.move(to: CGPoint(x: current.x, y: plotRect.minY))
                        path.addLine(to: CGPoint(x: current.x, y: plotRect.maxY))
                    }
                    .stroke(
                        accentColor.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 3])
                    )

                    Circle()
                        .fill(accentColor)
                        .frame(
                            width: style == .compact ? 7 : 8,
                            height: style == .compact ? 7 : 8
                        )
                        .position(current)
                }
            }
            .clipped()
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func areaPath(points: [CGPoint], baseline: CGFloat) -> Path {
        Path { path in
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: baseline))
            path.addLine(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            path.addLine(to: CGPoint(x: last.x, y: baseline))
            path.closeSubpath()
        }
    }

    private func horizontalGuide(
        in rect: CGRect,
        scale: MiniChartScale,
        value: Double
    ) -> Path {
        Path { path in
            let y = yPosition(in: rect, domain: scale.yDomain, concentration: value)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
    }

    private func currentPoint(in rect: CGRect, scale: MiniChartScale) -> CGPoint? {
        guard let concentration = snapshot.currentValue,
              concentration.isFinite,
              concentration >= 0 else {
            return nil
        }
        return CGPoint(
            x: xPosition(in: rect, domain: scale.xDomain, timeH: snapshot.currentTimeH),
            y: yPosition(in: rect, domain: scale.yDomain, concentration: concentration)
        )
    }

    private func point(
        in rect: CGRect,
        scale: MiniChartScale,
        for chartPoint: WidgetChartPoint
    ) -> CGPoint {
        CGPoint(
            x: xPosition(in: rect, domain: scale.xDomain, timeH: chartPoint.timeH),
            y: yPosition(in: rect, domain: scale.yDomain, concentration: chartPoint.concentration)
        )
    }

    private func xPosition(
        in rect: CGRect,
        domain: ClosedRange<Double>,
        timeH: Double
    ) -> CGFloat {
        let span = max(domain.upperBound - domain.lowerBound, 0.001)
        let ratio = min(max((timeH - domain.lowerBound) / span, 0), 1)
        return rect.minX + rect.width * CGFloat(ratio)
    }

    private func yPosition(
        in rect: CGRect,
        domain: ClosedRange<Double>,
        concentration: Double
    ) -> CGFloat {
        let span = max(domain.upperBound - domain.lowerBound, 0.001)
        let ratio = min(max((concentration - domain.lowerBound) / span, 0), 1)
        return rect.maxY - rect.height * CGFloat(ratio)
    }
}

private struct StatusPill: View {
    let level: ConcentrationLevel

    var body: some View {
        Text(level.titleKey)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(level.color)
            .background(level.color.opacity(0.12), in: Capsule())
    }
}

private enum ConcentrationLevel {
    case low
    case medium
    case high
    case unavailable

    init(value: Double?, threshold: WidgetThresholdRange) {
        guard let value, value.isFinite else {
            self = .unavailable
            return
        }

        if value < threshold.low {
            self = .low
        } else if value > threshold.high {
            self = .high
        } else {
            self = .medium
        }
    }

    var titleKey: LocalizedStringKey {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .unavailable:
            return "No Data"
        }
    }

    var color: Color {
        switch self {
        case .low:
            return .blue
        case .medium:
            return .green
        case .high:
            return .orange
        case .unavailable:
            return .secondary
        }
    }

    var compactSymbolName: String {
        switch self {
        case .low:
            return "arrow.down.circle.fill"
        case .medium:
            return "checkmark.circle.fill"
        case .high:
            return "arrow.up.circle.fill"
        case .unavailable:
            return "questionmark.circle.fill"
        }
    }
}
