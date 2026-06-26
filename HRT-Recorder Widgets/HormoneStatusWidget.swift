import SwiftUI
import WidgetKit

struct HormoneStatusEntry: TimelineEntry {
    let date: Date
    let configuration: HormoneStatusWidgetIntent
    let snapshot: WidgetHormoneSnapshot
    let isExpired: Bool
}

struct HormoneStatusProvider: AppIntentTimelineProvider {
    private static let timelineInterval: TimeInterval = 15 * 60
    private static let timelineHorizon: TimeInterval = 12 * 60 * 60
    private static let chartWindowPaddingHours = 6.0

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
        let hormone = configuration.hormone?.kind ?? .estradiol
        let hormoneSnapshot = snapshot.hormoneSnapshot(for: hormone)
            ?? WidgetHormoneSnapshot.empty(hormone: hormone, updatedAt: now)
        let firstEntry = entry(for: configuration, date: now, hormoneSnapshot: hormoneSnapshot)

        guard hormoneSnapshot.hasData else {
            return Timeline(
                entries: [firstEntry],
                policy: .after(now.addingTimeInterval(Self.timelineInterval))
            )
        }

        let entries = Self.entryDates(from: now, snapshot: hormoneSnapshot).map { date in
            entry(for: configuration, date: date, hormoneSnapshot: hormoneSnapshot)
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
        return entry(for: configuration, date: date, hormoneSnapshot: hormoneSnapshot)
    }

    private func entry(
        for configuration: HormoneStatusWidgetIntent,
        date: Date,
        hormoneSnapshot: WidgetHormoneSnapshot
    ) -> HormoneStatusEntry {
        let resolvedSnapshot = hormoneSnapshot.resolved(
            at: date,
            visibleWindowHours: Self.chartWindowPaddingHours
        )

        return HormoneStatusEntry(
            date: date,
            configuration: configuration,
            snapshot: resolvedSnapshot,
            isExpired: hormoneSnapshot.isExpired(
                at: date,
                visibleWindowHours: Self.chartWindowPaddingHours,
                maxAge: Self.timelineHorizon
            )
        )
    }

    private static func entryDates(from startDate: Date, snapshot: WidgetHormoneSnapshot) -> [Date] {
        let lastFullWindowDate = snapshot.points.last.map {
            Date(timeIntervalSince1970: ($0.timeH - chartWindowPaddingHours) * 3600)
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
        VStack(alignment: .leading, spacing: 8) {
            header(compact: true)
            Spacer(minLength: 0)
            ConcentrationValueView(snapshot: entry.snapshot, accentColor: accentColor, compact: true)
            StatusPill(level: level)
            MiniConcentrationChart(snapshot: entry.snapshot, accentColor: accentColor)
                .frame(height: 34)
        }
    }

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                header(compact: false)
                Spacer(minLength: 8)
                ConcentrationValueView(snapshot: entry.snapshot, accentColor: accentColor, compact: false)
            }

            MiniConcentrationChart(snapshot: entry.snapshot, accentColor: accentColor)
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

            MiniConcentrationChart(snapshot: entry.snapshot, accentColor: accentColor)
                .frame(maxHeight: .infinity)

            HStack {
                Text("Past 6h")
                Spacer()
                Text("Now")
                    .foregroundStyle(accentColor)
                Spacer()
                Text("Next 6h")
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

private struct MiniConcentrationChart: View {
    let snapshot: WidgetHormoneSnapshot
    let accentColor: Color

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let path = linePath(in: size)
            let current = currentPoint(in: size)

            ZStack {
                horizontalGuide(in: size, value: snapshot.threshold.low)
                    .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                horizontalGuide(in: size, value: snapshot.threshold.high)
                    .stroke(Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                path
                    .stroke(accentColor.opacity(0.28), lineWidth: 7)
                    .blur(radius: 4)

                path
                    .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                Path { path in
                    path.move(to: CGPoint(x: current.x, y: 0))
                    path.addLine(to: CGPoint(x: current.x, y: size.height))
                }
                .stroke(accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                    .position(current)
            }
        }
    }

    private func linePath(in size: CGSize) -> Path {
        Path { path in
            let points = snapshot.points.map { point(in: size, for: $0) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }

    private func horizontalGuide(in size: CGSize, value: Double) -> Path {
        Path { path in
            let y = yPosition(in: size, concentration: value)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
    }

    private func currentPoint(in size: CGSize) -> CGPoint {
        let concentration = snapshot.currentValue ?? 0
        return CGPoint(
            x: xPosition(in: size, timeH: snapshot.currentTimeH),
            y: yPosition(in: size, concentration: concentration)
        )
    }

    private func point(in size: CGSize, for chartPoint: WidgetChartPoint) -> CGPoint {
        CGPoint(
            x: xPosition(in: size, timeH: chartPoint.timeH),
            y: yPosition(in: size, concentration: chartPoint.concentration)
        )
    }

    private func xPosition(in size: CGSize, timeH: Double) -> CGFloat {
        guard let first = snapshot.points.first?.timeH,
              let last = snapshot.points.last?.timeH,
              last > first else {
            return size.width / 2
        }
        let ratio = min(max((timeH - first) / (last - first), 0), 1)
        return size.width * CGFloat(ratio)
    }

    private func yPosition(in size: CGSize, concentration: Double) -> CGFloat {
        let values = snapshot.points.map(\.concentration) + [snapshot.threshold.low, snapshot.threshold.high, snapshot.currentValue ?? 0]
        let maxValue = max(values.max() ?? 1, 1)
        let minValue = min(values.min() ?? 0, 0)
        let range = max(maxValue - minValue, 1)
        let ratio = min(max((concentration - minValue) / range, 0), 1)
        return size.height - size.height * CGFloat(ratio)
    }
}

private struct StatusPill: View {
    let level: ConcentrationLevel

    var body: some View {
        Text(level.titleKey)
            .font(.caption2.weight(.semibold))
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
}
