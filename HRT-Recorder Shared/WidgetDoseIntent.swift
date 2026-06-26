import AppIntents
import Foundation

struct WidgetDoseOptionEntity: AppEntity, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let isStale: Bool

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dose"
    static var defaultQuery = WidgetDoseOptionQuery()

    init(option: WidgetDoseOption) {
        id = option.id
        title = option.title
        subtitle = option.subtitle
        isStale = false
    }

    init(id: String, title: String, subtitle: String, isStale: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isStale = isStale
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)"
        )
    }
}

struct WidgetDoseOptionQuery: EntityQuery {
    func entities(for identifiers: [WidgetDoseOptionEntity.ID]) async throws -> [WidgetDoseOptionEntity] {
        let options = WidgetSharedStore.readSnapshot().doseOptions
        let byID = Dictionary(uniqueKeysWithValues: options.map { ($0.id, $0) })

        return identifiers.map { identifier in
            if let option = byID[identifier] {
                return WidgetDoseOptionEntity(option: option)
            }
            return WidgetDoseOptionEntity(
                id: identifier,
                title: String(localized: "Needs reconfiguration"),
                subtitle: String(localized: "Choose an available medication plan"),
                isStale: true
            )
        }
    }

    func suggestedEntities() async throws -> [WidgetDoseOptionEntity] {
        WidgetSharedStore.readSnapshot().doseOptions.map(WidgetDoseOptionEntity.init)
    }

    func defaultResult() async -> WidgetDoseOptionEntity? {
        WidgetSharedStore.readSnapshot().doseOptions.first.map(WidgetDoseOptionEntity.init)
    }
}

struct OpenDoseConfirmationIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Dose Confirmation"
    static var description = IntentDescription("Open HRT Recorder to confirm a dose from a medication plan.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Dose")
    var doseOption: WidgetDoseOptionEntity

    init() {
        doseOption = WidgetDoseOptionEntity(
            id: "",
            title: String(localized: "Dose"),
            subtitle: "",
            isStale: true
        )
    }

    init(doseOption: WidgetDoseOptionEntity) {
        self.doseOption = doseOption
    }

    func perform() async throws -> some IntentResult {
        guard !doseOption.id.isEmpty, !doseOption.isStale else {
            return .result()
        }

        WidgetSharedStore.writeDoseHandoff(
            WidgetDoseHandoff(optionID: doseOption.id, requestedAt: Date())
        )
        return .result()
    }
}
