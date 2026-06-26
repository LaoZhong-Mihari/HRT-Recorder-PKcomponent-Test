import AppIntents
import SwiftUI
import WidgetKit

struct QuickDoseEntry: TimelineEntry {
    let date: Date
    let configuration: QuickDoseWidgetIntent
    let selectedOption: WidgetDoseOptionEntity?
    let isStale: Bool
}

struct QuickDoseProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> QuickDoseEntry {
        QuickDoseEntry(
            date: Date(),
            configuration: QuickDoseWidgetIntent(),
            selectedOption: WidgetDoseOptionEntity(
                id: "preview",
                title: String(localized: "Morning dose"),
                subtitle: String(localized: "9:00 AM · oral 2 mg E2"),
                isStale: false
            ),
            isStale: false
        )
    }

    func snapshot(
        for configuration: QuickDoseWidgetIntent,
        in context: Context
    ) async -> QuickDoseEntry {
        entry(for: configuration, date: Date())
    }

    func timeline(
        for configuration: QuickDoseWidgetIntent,
        in context: Context
    ) async -> Timeline<QuickDoseEntry> {
        let now = Date()
        return Timeline(
            entries: [entry(for: configuration, date: now)],
            policy: .after(now.addingTimeInterval(30 * 60))
        )
    }

    private func entry(
        for configuration: QuickDoseWidgetIntent,
        date: Date
    ) -> QuickDoseEntry {
        let snapshot = WidgetSharedStore.readSnapshot()
        guard let configured = configuration.doseOption else {
            return QuickDoseEntry(
                date: date,
                configuration: configuration,
                selectedOption: nil,
                isStale: false
            )
        }

        let currentOption = snapshot.doseOptions.first { $0.id == configured.id }
        let resolved = currentOption.map(WidgetDoseOptionEntity.init) ?? configured
        let isStale = currentOption == nil || resolved.isStale

        return QuickDoseEntry(
            date: date,
            configuration: configuration,
            selectedOption: resolved,
            isStale: isStale
        )
    }
}

struct QuickDoseWidget: Widget {
    let kind = "QuickDoseWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: QuickDoseWidgetIntent.self,
            provider: QuickDoseProvider()
        ) { entry in
            QuickDoseWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Quick Dose")
        .description("Open HRT Recorder to confirm a configured medication plan dose.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct QuickDoseWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: QuickDoseEntry

    var body: some View {
        Group {
            if let option = entry.selectedOption, !entry.isStale {
                configuredLayout(option)
            } else if entry.isStale {
                staleLayout
            } else {
                unconfiguredLayout
            }
        }
        .padding(family == .systemSmall ? 14 : 16)
    }

    private func configuredLayout(_ option: WidgetDoseOptionEntity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(intent: OpenDoseConfirmationIntent(doseOption: option)) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: family == .systemSmall ? 24 : 28, weight: .semibold))
                    .foregroundStyle(.pink)
                    .frame(width: 34, height: 34, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Confirm in App")

            VStack(alignment: .leading, spacing: 4) {
                Text(option.title)
                    .font(.headline)
                    .lineLimit(family == .systemSmall ? 2 : 1)
                Text(option.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemSmall ? 2 : 3)
            }

            Spacer(minLength: 0)

            Button(intent: OpenDoseConfirmationIntent(doseOption: option)) {
                Label("Confirm in App", systemImage: "arrow.up.forward.app.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.pink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 8)
                    .background(.pink.opacity(0.14), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.pink.opacity(0.3), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
    }

    private var staleLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Needs reconfiguration")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Choose an available medication plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }

    private var unconfiguredLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.pink)

            Text("Choose a dose")
                .font(.headline)
            Text("Edit this widget and select a medication plan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
