//
//  LabReportModels.swift
//  HRT-Recorder
//

import Foundation

enum LabAnalyteKind: String, CaseIterable, Codable, Hashable, Sendable {
    case estradiol
    case testosterone
    case luteinizingHormone
    case follicleStimulatingHormone
    case prolactin
    case progesterone
    case sexHormoneBindingGlobulin
    case freeTestosterone
    case other

    nonisolated var defaultName: String {
        switch self {
        case .estradiol: return "Estradiol"
        case .testosterone: return "Testosterone"
        case .luteinizingHormone: return "LH"
        case .follicleStimulatingHormone: return "FSH"
        case .prolactin: return "Prolactin"
        case .progesterone: return "Progesterone"
        case .sexHormoneBindingGlobulin: return "SHBG"
        case .freeTestosterone: return "Free Testosterone"
        case .other: return "Other"
        }
    }

    nonisolated var simulatedHormone: SimulatedHormone? {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        default: return nil
        }
    }
}

struct LabAnalyteResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: LabAnalyteKind
    var name: String
    var value: Double?
    var unitSymbol: String
    var concentrationUnit: ConcentrationUnit?
    var referenceRange: String?
    var method: String?
    var sourceLine: String?
    var note: String?

    init(
        id: UUID = UUID(),
        kind: LabAnalyteKind,
        name: String? = nil,
        value: Double? = nil,
        unitSymbol: String = "",
        concentrationUnit: ConcentrationUnit? = nil,
        referenceRange: String? = nil,
        method: String? = nil,
        sourceLine: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name ?? kind.defaultName
        self.value = value
        self.unitSymbol = unitSymbol
        self.concentrationUnit = concentrationUnit
        self.referenceRange = referenceRange
        self.method = method
        self.sourceLine = sourceLine
        self.note = note
    }

    nonisolated var simulatedHormone: SimulatedHormone? {
        kind.simulatedHormone
    }

    nonisolated func labSample(reportID: UUID, collectedAt: Date) -> LabSample? {
        guard let hormone = simulatedHormone,
              let value,
              let concentrationUnit,
              concentrationUnit.isSupported(for: hormone) else {
            return nil
        }

        return LabSample(
            id: id,
            hormone: hormone,
            collectedAt: collectedAt,
            concentration: value,
            unit: concentrationUnit,
            reportID: reportID,
            analyteName: name,
            sourceLine: sourceLine
        )
    }
}

enum LabReportSourceKind: String, Codable, Hashable, Sendable {
    case scanner
    case imageUpload
    case pastedText
    case manual
}

struct LabReport: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var collectedAt: Date
    var reportedAt: Date?
    var institution: String
    var location: String
    var specimen: String
    var method: String
    var sourceKind: LabReportSourceKind
    var sourceText: String
    var analytes: [LabAnalyteResult]
    var note: String

    init(
        id: UUID = UUID(),
        collectedAt: Date,
        reportedAt: Date? = nil,
        institution: String = "",
        location: String = "",
        specimen: String = "",
        method: String = "",
        sourceKind: LabReportSourceKind,
        sourceText: String = "",
        analytes: [LabAnalyteResult] = [],
        note: String = ""
    ) {
        self.id = id
        self.collectedAt = collectedAt
        self.reportedAt = reportedAt
        self.institution = institution
        self.location = location
        self.specimen = specimen
        self.method = method
        self.sourceKind = sourceKind
        self.sourceText = sourceText
        self.analytes = analytes
        self.note = note
    }

    nonisolated var calibrationSamples: [LabSample] {
        analytes.compactMap { $0.labSample(reportID: id, collectedAt: collectedAt) }
    }

    nonisolated var hormoneSummary: String {
        let displayValues = analytes.compactMap { analyte -> String? in
            guard let value = analyte.value else { return nil }
            let unit = analyte.concentrationUnit?.symbol ?? analyte.unitSymbol
            return String(format: "%@: %.2f %@", locale: Locale.current, analyte.name, value, unit)
        }
        guard !displayValues.isEmpty else {
            return analytes.map(\.name).joined(separator: ", ")
        }
        return displayValues.joined(separator: " · ")
    }
}
