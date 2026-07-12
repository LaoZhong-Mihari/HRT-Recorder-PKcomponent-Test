//
//  LabReportModels.swift
//  HRT-Recorder
//

import Foundation

/// A parsed mass or molar concentration. The parser understands SI prefixes
/// and volume denominators instead of enumerating hospital-specific unit
/// spellings, so report values can remain in their original units.
nonisolated struct LabConcentrationUnit: Equatable, Sendable {
    nonisolated enum Basis: Equatable, Sendable {
        case mass
        case amount
    }

    let basis: Basis
    let numeratorToBase: Double
    let denominatorLiters: Double

    nonisolated static func parse(_ rawValue: String) -> LabConcentrationUnit? {
        var token = rawValue
            .precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "μ", with: "u")
            .replacingOccurrences(of: "µ", with: "u")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "⁻", with: "-")
            .replacingOccurrences(of: "¹", with: "1")
            .replacingOccurrences(of: "per", with: "/", options: [.caseInsensitive])
            .replacingOccurrences(of: "·", with: "/")
            .replacingOccurrences(of: "⋅", with: "/")
            .replacingOccurrences(of: "∙", with: "/")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}"))
        token = token.replacingOccurrences(of: "^", with: "")
        token = token.replacingOccurrences(of: "mcg", with: "ug")

        let components: [Substring]
        if token.contains("/") {
            components = token.split(separator: "/", omittingEmptySubsequences: false)
        } else if token.hasSuffix("-1"),
                  let separated = splitInverseVolumeUnit(String(token.dropLast(2))) {
            components = [Substring(separated.numerator), Substring(separated.denominator)]
        } else if let separated = splitInverseVolumeUnit(token) {
            components = [Substring(separated.numerator), Substring(separated.denominator)]
        } else {
            return nil
        }

        guard components.count == 2 else { return nil }
        var denominatorToken = String(components[1])
        if denominatorToken.hasSuffix("-1") {
            denominatorToken.removeLast(2)
        }

        guard let numerator = parseNumerator(String(components[0])),
              let denominatorLiters = parseVolume(denominatorToken),
              denominatorLiters > 0 else {
            return nil
        }

        return LabConcentrationUnit(
            basis: numerator.basis,
            numeratorToBase: numerator.scale,
            denominatorLiters: denominatorLiters
        )
    }

    nonisolated func convertedValue(
        _ value: Double,
        hormone: SimulatedHormone,
        to targetUnit: ConcentrationUnit
    ) -> Double? {
        guard value.isFinite, value >= 0 else { return nil }
        let basePerLiter = value * numeratorToBase / denominatorLiters
        let gramsPerLiter: Double
        switch basis {
        case .mass:
            gramsPerLiter = basePerLiter
        case .amount:
            gramsPerLiter = basePerLiter * hormone.molecularWeight
        }

        let targetScale = targetUnit.gramsPerLiterPerUnit(for: hormone)
        guard gramsPerLiter.isFinite, targetScale > 0 else { return nil }
        let convertedValue = gramsPerLiter / targetScale
        return convertedValue.isFinite ? convertedValue : nil
    }

    nonisolated func isNumericallyEquivalent(
        to unit: ConcentrationUnit,
        hormone: SimulatedHormone
    ) -> Bool {
        let sourceScale: Double
        switch basis {
        case .mass:
            sourceScale = numeratorToBase / denominatorLiters
        case .amount:
            sourceScale = numeratorToBase / denominatorLiters * hormone.molecularWeight
        }
        let targetScale = unit.gramsPerLiterPerUnit(for: hormone)
        let tolerance = max(abs(sourceScale), abs(targetScale)) * 1e-12
        return abs(sourceScale - targetScale) <= max(tolerance, Double.leastNonzeroMagnitude)
    }

    private nonisolated static func splitInverseVolumeUnit(
        _ token: String
    ) -> (numerator: String, denominator: String)? {
        let volumeSuffixes = ["ul", "ml", "dl", "cl", "l"]
        guard let suffix = volumeSuffixes.first(where: { token.hasSuffix($0) }) else {
            return nil
        }
        let numerator = String(token.dropLast(suffix.count))
        guard !numerator.isEmpty else { return nil }
        return (numerator, suffix)
    }

    private nonisolated static func parseNumerator(
        _ token: String
    ) -> (basis: Basis, scale: Double)? {
        if token.hasSuffix("mol") {
            let prefix = String(token.dropLast(3))
            return prefixScale(prefix).map { (.amount, $0) }
        }
        if token.hasSuffix("g") {
            let prefix = String(token.dropLast())
            return prefixScale(prefix).map { (.mass, $0) }
        }
        return nil
    }

    private nonisolated static func parseVolume(_ token: String) -> Double? {
        var multiplier = 1.0
        var volumeToken = token
        let numericPrefix = volumeToken.prefix { $0.isNumber || $0 == "." }
        if !numericPrefix.isEmpty {
            guard let parsedMultiplier = Double(numericPrefix), parsedMultiplier > 0 else {
                return nil
            }
            multiplier = parsedMultiplier
            volumeToken.removeFirst(numericPrefix.count)
        }

        guard volumeToken.hasSuffix("l") else { return nil }
        let prefix = String(volumeToken.dropLast())
        guard let litersPerUnit = prefixScale(prefix) else { return nil }
        return multiplier * litersPerUnit
    }

    private nonisolated static func prefixScale(_ prefix: String) -> Double? {
        switch prefix {
        case "": return 1
        case "f": return 1e-15
        case "p": return 1e-12
        case "n": return 1e-9
        case "u": return 1e-6
        case "m": return 1e-3
        case "c": return 1e-2
        case "d": return 1e-1
        case "h": return 1e2
        case "k": return 1e3
        default: return nil
        }
    }
}

nonisolated extension ConcentrationUnit {
    nonisolated func gramsPerLiterPerUnit(for hormone: SimulatedHormone) -> Double {
        switch self {
        case .pgPerML: return 1e-9
        case .pmolPerL: return 1e-12 * hormone.molecularWeight
        case .ngPerDL: return 1e-8
        case .ngPerML: return 1e-6
        case .nmolPerL: return 1e-9 * hormone.molecularWeight
        }
    }
}

nonisolated struct LabCalibrationMeasurement: Equatable, Sendable {
    let concentration: Double
    let unit: ConcentrationUnit
}

enum LabAnalyteKind: String, CaseIterable, Codable, Hashable, Sendable {
    case estradiol
    case testosterone
    case luteinizingHormone
    case follicleStimulatingHormone
    case prolactin
    case progesterone
    case sexHormoneBindingGlobulin
    case freeTestosterone
    case dehydroepiandrosteroneSulfate
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
        case .dehydroepiandrosteroneSulfate: return "DHEA-S"
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
    /// Exact value text returned by the report extraction/review path. Optional
    /// for compatibility with reports saved by earlier app versions.
    var reportedValueText: String?
    /// Exact unit text returned by the report extraction/review path. The
    /// canonical calibration unit is derived and never overwrites this value.
    var reportedUnitText: String?
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
        reportedValueText: String? = nil,
        reportedUnitText: String? = nil,
        referenceRange: String? = nil,
        method: String? = nil,
        sourceLine: String? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.kind = kind
        let cleanedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = kind == .other && cleanedName?.isEmpty == false ? cleanedName! : kind.defaultName
        self.value = value
        self.unitSymbol = unitSymbol
        self.concentrationUnit = concentrationUnit
        self.reportedValueText = Self.nonEmptyReportedText(reportedValueText)
        self.reportedUnitText = Self.nonEmptyReportedText(reportedUnitText)
        self.referenceRange = referenceRange
        self.method = method
        self.sourceLine = sourceLine
        self.note = note
    }

    nonisolated var displayName: String {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return kind == .other && !cleanedName.isEmpty ? cleanedName : kind.defaultName
    }

    nonisolated var simulatedHormone: SimulatedHormone? {
        kind.simulatedHormone
    }

    nonisolated var displayedValueText: String? {
        if let reportedValueText = Self.nonEmptyReportedText(reportedValueText) {
            return reportedValueText
        }
        // Swift's shortest round-trippable representation prevents an old
        // report from losing precision merely by opening and saving review.
        return value.map { String($0) }
    }

    nonisolated var displayedUnitText: String {
        Self.nonEmptyReportedText(reportedUnitText)
            ?? Self.nonEmptyReportedText(unitSymbol)
            ?? concentrationUnit?.symbol
            ?? ""
    }

    nonisolated var calibrationMeasurement: LabCalibrationMeasurement? {
        guard let hormone = simulatedHormone,
              let value,
              value.isFinite,
              value >= 0,
              !hasQualifiedReportedValue else {
            return nil
        }

        let targetUnit = hormone.concentrationUnit
        let rawReportedUnit = Self.nonEmptyReportedText(reportedUnitText)
        let legacyUnitSymbol = Self.nonEmptyReportedText(unitSymbol)
        let sourceUnitText = rawReportedUnit ?? legacyUnitSymbol
        if let sourceUnitText,
           let sourceUnit = LabConcentrationUnit.parse(sourceUnitText) {
            // OCR fallback may retain a raw token while separately proposing
            // an interpreted unit. A dimensional disagreement needs review;
            // never calibrate using either interpretation silently.
            if let interpretedText = Self.nonEmptyReportedText(unitSymbol),
               let interpretedUnit = LabConcentrationUnit.parse(interpretedText),
               interpretedUnit != sourceUnit {
                return nil
            }
            guard let convertedValue = sourceUnit.convertedValue(
                value,
                hormone: hormone,
                to: targetUnit
            ) else {
                return nil
            }
            return LabCalibrationMeasurement(concentration: convertedValue, unit: targetUnit)
        }

        // A present raw unit is authoritative. If it cannot be parsed, retain
        // the report row but never fall through to a stale legacy enum.
        guard rawReportedUnit == nil else { return nil }

        // Older saved reports may only contain the legacy enum. Preserve their
        // existing calibration behavior when no raw unit text can be parsed.
        guard let concentrationUnit,
              concentrationUnit.isSupported(for: hormone),
              legacyUnitSymbol == nil
                || legacyUnitSymbol?.caseInsensitiveCompare(concentrationUnit.symbol) == .orderedSame else {
            return nil
        }
        return LabCalibrationMeasurement(
            concentration: ConcentrationUnit.convert(
                value,
                from: concentrationUnit,
                to: targetUnit,
                hormone: hormone
            ),
            unit: targetUnit
        )
    }

    nonisolated func labSample(reportID: UUID, collectedAt: Date) -> LabSample? {
        guard let hormone = simulatedHormone,
              let calibrationMeasurement else {
            return nil
        }

        return LabSample(
            id: id,
            hormone: hormone,
            collectedAt: collectedAt,
            concentration: calibrationMeasurement.concentration,
            unit: calibrationMeasurement.unit,
            reportID: reportID,
            analyteName: displayName,
            sourceLine: sourceLine
        )
    }

    private nonisolated var hasQualifiedReportedValue: Bool {
        guard let reportedValueText else { return false }
        return reportedValueText.rangeOfCharacter(
            from: CharacterSet(charactersIn: "<>≤≥")
        ) != nil
    }

    private nonisolated static func nonEmptyReportedText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            guard let valueText = analyte.displayedValueText else { return nil }
            let unitText = analyte.displayedUnitText
            return unitText.isEmpty
                ? "\(analyte.displayName): \(valueText)"
                : "\(analyte.displayName): \(valueText) \(unitText)"
        }
        guard !displayValues.isEmpty else {
            return analytes.map(\.displayName).joined(separator: ", ")
        }
        return displayValues.joined(separator: " · ")
    }
}
