import AppIntents
import Foundation
import WidgetKit

enum WidgetHormoneSelection: String, AppEnum {
    case estradiol
    case testosterone

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Hormone"
    static var caseDisplayRepresentations: [WidgetHormoneSelection: DisplayRepresentation] {
        [
            .estradiol: "Estradiol",
            .testosterone: "Testosterone"
        ]
    }

    var kind: WidgetHormoneKind {
        switch self {
        case .estradiol:
            return .estradiol
        case .testosterone:
            return .testosterone
        }
    }
}

struct HormoneStatusWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Hormone Status"
    static var description = IntentDescription("Choose the hormone shown in the concentration widget.")

    @Parameter(title: "Hormone")
    var hormone: WidgetHormoneSelection?

    init() {
        hormone = .estradiol
    }

    init(hormone: WidgetHormoneSelection?) {
        self.hormone = hormone
    }
}

struct QuickDoseWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quick Dose"
    static var description = IntentDescription("Choose the medication plan opened by the quick dose widget.")

    @Parameter(title: "Dose")
    var doseOption: WidgetDoseOptionEntity?

    init() {
        doseOption = nil
    }

    init(doseOption: WidgetDoseOptionEntity?) {
        self.doseOption = doseOption
    }
}
