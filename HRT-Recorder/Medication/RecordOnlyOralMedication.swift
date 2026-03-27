import Foundation

enum RecordOnlyOralMedication: String, CaseIterable, Identifiable, Codable, Sendable {
    case cyproteroneAcetate
    case spironolactone
    case bicalutamide
    case finasteride
    case dutasteride

    nonisolated var id: Self { self }

    nonisolated var displayName: String {
        switch self {
        case .cyproteroneAcetate:
            return String(localized: "record_medication.cyproterone_acetate.name")
        case .spironolactone:
            return String(localized: "record_medication.spironolactone.name")
        case .bicalutamide:
            return String(localized: "record_medication.bicalutamide.name")
        case .finasteride:
            return String(localized: "record_medication.finasteride.name")
        case .dutasteride:
            return String(localized: "record_medication.dutasteride.name")
        }
    }

    nonisolated var defaultPlanName: String {
        String.localizedStringWithFormat(
            String(localized: "record_medication.plan_name_format"),
            displayName
        )
    }
}
