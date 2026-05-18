//  HRT-Recorder
//    Created by mihari-zhong
//
//  Shared PK metadata for estradiol / testosterone modeling in the iPhone app.

import Foundation
import SwiftUI

enum MedicationCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case estradiol
    case testosterone
    case antiAndrogen

    nonisolated var id: Self { self }

    nonisolated var simulatedHormone: SimulatedHormone? {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        case .antiAndrogen: return nil
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .estradiol: return SimulatedHormone.estradiol.displayName
        case .testosterone: return SimulatedHormone.testosterone.displayName
        case .antiAndrogen: return String(localized: "Anti-androgen")
        }
    }
}

enum SimulatedHormone: String, CaseIterable, Identifiable, Codable, Sendable {
    case estradiol
    case testosterone

    nonisolated var id: Self { self }

    nonisolated var category: MedicationCategory {
        switch self {
        case .estradiol: return .estradiol
        case .testosterone: return .testosterone
        }
    }

    nonisolated var displayName: String {
        switch self {
        case .estradiol:
            return String(localized: "Estradiol")
        case .testosterone:
            return String(localized: "Testosterone")
        }
    }

    nonisolated var analyteCompound: Compound {
        switch self {
        case .estradiol: return .E2
        case .testosterone: return .T
        }
    }

    nonisolated var molecularWeight: Double {
        analyteCompound.info.activeMolecularWeight
    }

    nonisolated var concentrationUnit: ConcentrationUnit {
        switch self {
        case .estradiol: return .pgPerML
        case .testosterone: return .ngPerDL
        }
    }

    nonisolated var supportedConcentrationUnits: [ConcentrationUnit] {
        ConcentrationUnit.supportedUnits(for: self)
    }

    nonisolated var chartColor: Color {
        switch self {
        case .estradiol:
            return Color(red: 0.95, green: 0.50, blue: 0.74)
        case .testosterone:
            return .blue
        }
    }
}

enum ConcentrationUnit: String, CaseIterable, Identifiable, Codable, Sendable {
    case pgPerML
    case pmolPerL
    case ngPerDL
    case ngPerML
    case nmolPerL

    nonisolated var id: Self { self }

    nonisolated var symbol: String {
        switch self {
        case .pgPerML: return "pg/mL"
        case .pmolPerL: return "pmol/L"
        case .ngPerDL: return "ng/dL"
        case .ngPerML: return "ng/mL"
        case .nmolPerL: return "nmol/L"
        }
    }

    nonisolated func concentrationScale(for hormone: SimulatedHormone) -> Double {
        switch self {
        case .pgPerML: return 1e9
        case .ngPerDL: return 1e8
        case .ngPerML: return 1e6
        case .pmolPerL: return 1e12 / hormone.molecularWeight
        case .nmolPerL: return 1e9 / hormone.molecularWeight
        }
    }

    nonisolated var aucSymbol: String {
        switch self {
        case .pgPerML: return "pg·h/mL"
        case .pmolPerL: return "pmol·h/L"
        case .ngPerDL: return "ng·h/dL"
        case .ngPerML: return "ng·h/mL"
        case .nmolPerL: return "nmol·h/L"
        }
    }

    nonisolated func isSupported(for hormone: SimulatedHormone) -> Bool {
        Self.supportedUnits(for: hormone).contains(self)
    }

    nonisolated static func supportedUnits(for hormone: SimulatedHormone) -> [ConcentrationUnit] {
        switch hormone {
        case .estradiol:
            return [.pgPerML, .pmolPerL]
        case .testosterone:
            return [.ngPerDL, .ngPerML, .nmolPerL]
        }
    }

    nonisolated static func convert(
        _ value: Double,
        from sourceUnit: ConcentrationUnit,
        to targetUnit: ConcentrationUnit,
        hormone: SimulatedHormone
    ) -> Double {
        guard sourceUnit != targetUnit else { return value }
        let baseValue = value / sourceUnit.concentrationScale(for: hormone)
        return baseValue * targetUnit.concentrationScale(for: hormone)
    }

    nonisolated static func convertAUC(
        _ value: Double,
        from sourceUnit: ConcentrationUnit,
        to targetUnit: ConcentrationUnit,
        hormone: SimulatedHormone
    ) -> Double {
        convert(value, from: sourceUnit, to: targetUnit, hormone: hormone)
    }

    nonisolated var localizedLabel: String {
        symbol
    }
}

extension SimulatedHormone {
    nonisolated func preferredUnit(from rawValue: String?) -> ConcentrationUnit {
        guard let rawValue,
              let unit = ConcentrationUnit(rawValue: rawValue),
              unit.isSupported(for: self) else {
            return concentrationUnit
        }
        return unit
    }
}

struct SimulationDisplayMetadata: Equatable, Codable, Sendable {
    let hormone: SimulatedHormone
    let concentrationUnit: ConcentrationUnit

    nonisolated var concentrationSymbol: String { concentrationUnit.symbol }
    nonisolated var aucSymbol: String { concentrationUnit.aucSymbol }
}

extension SimulationDisplayMetadata {
    nonisolated func withUnit(_ concentrationUnit: ConcentrationUnit) -> SimulationDisplayMetadata {
        SimulationDisplayMetadata(hormone: hormone, concentrationUnit: concentrationUnit)
    }
}

enum Compound: String, CaseIterable, Identifiable, Codable, Sendable {
    case E2, EB, EV, EC, EN
    case T, TC, TE, TU

    nonisolated var id: Self { self }

    nonisolated var info: CompoundInfo { CompoundInfo.by(compound: self) }

    nonisolated var fullName: String { info.fullName }

    nonisolated var hormone: SimulatedHormone { info.hormone }

    nonisolated var medicationCategory: MedicationCategory { hormone.category }

    nonisolated var localizedNameKey: LocalizedStringKey {
        LocalizedStringKey("compound.\(rawValue).name")
    }

    nonisolated var abbreviation: String {
        NSLocalizedString(
            "compound.\(rawValue).abbr",
            tableName: nil,
            bundle: .main,
            value: rawValue,
            comment: "Localized compound abbreviation"
        )
    }
}

typealias Ester = Compound
typealias EsterInfo = CompoundInfo

struct CompoundInfo: Sendable {
    let compound: Compound
    let fullName: String
    let hormone: SimulatedHormone
    let molecularWeight: Double
    let activeMolecularWeight: Double
    let isProdrug: Bool

    var toActiveFactor: Double {
        activeMolecularWeight / molecularWeight
    }

    var toE2Factor: Double {
        toActiveFactor
    }

    private static let all: [Compound: CompoundInfo] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.compounds.map { compound, config in
            (
                compound,
                CompoundInfo(
                    compound: compound,
                    fullName: config.fullName,
                    hormone: config.hormone,
                    molecularWeight: config.molecularWeight,
                    activeMolecularWeight: config.activeMolecularWeight,
                    isProdrug: config.isProdrug
                )
            )
        }
    )

    nonisolated static func by(compound: Compound) -> CompoundInfo {
        all[compound]!
    }

    nonisolated static func by(ester: Compound) -> CompoundInfo {
        by(compound: ester)
    }
}

extension Compound {
    static func fallback(
        for category: MedicationCategory?,
        route: DoseEvent.Route,
        recordOnlyOralMedication: RecordOnlyOralMedication?
    ) -> Compound {
        if recordOnlyOralMedication != nil {
            return .E2
        }

        let resolvedCategory = category ?? .estradiol
        if let supportedCompound = CompoundSupport.availableCompounds(
            for: resolvedCategory,
            route: route
        ).first {
            return supportedCompound
        }

        switch resolvedCategory {
        case .estradiol, .antiAndrogen:
            return .E2
        case .testosterone:
            return .T
        }
    }
}

struct HormoneCoreParams: Sendable {
    let vdPerKG: Double
    let kClear: Double
    let kClearInjection: Double
    let depotK1Corr: Double
    let patchReleaseScale: Double
}

struct CorePK {
    static let byHormone: [SimulatedHormone: HormoneCoreParams] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.hormones.map { hormone, config in
            (
                hormone,
                HormoneCoreParams(
                    vdPerKG: config.vdPerKG,
                    kClear: config.kClear,
                    kClearInjection: config.kClearInjection,
                    depotK1Corr: config.depotK1Corr,
                    patchReleaseScale: config.patchReleaseScale
                )
            )
        }
    )

    nonisolated static func params(for hormone: SimulatedHormone) -> HormoneCoreParams {
        byHormone[hormone] ?? byHormone[.estradiol]!
    }

    static let vdPerKG: Double = byHormone[.estradiol]!.vdPerKG
    static let kClear: Double = byHormone[.estradiol]!.kClear
    static let kClearInjection: Double = byHormone[.estradiol]!.kClearInjection
    static let depotK1Corr: Double = byHormone[.estradiol]!.depotK1Corr
    static let patchReleaseScale: Double = byHormone[.estradiol]!.patchReleaseScale
}

struct TwoPartDepotParams: Sendable {
    let fracFast: Double
    let k1Fast: Double
    let k1Slow: Double
}

struct TwoPartDepotPK {
    static let params: [Compound: TwoPartDepotParams] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.twoPartDepot.map { compound, config in
            (compound, TwoPartDepotParams(fracFast: config.fracFast, k1Fast: config.k1Fast, k1Slow: config.k1Slow))
        }
    )

    nonisolated static func params(for compound: Compound) -> TwoPartDepotParams? {
        params[compound]
    }
}

struct InjectionPK {
    /// Effective formation / systemic fraction used by the simplified engine.
    static let formationFraction: [Compound: Double] = PKSharedCatalogResource.current.formationFraction
}

struct CompoundHydrolysisPK {
    static let k2: [Compound: Double] = PKSharedCatalogResource.current.hydrolysisK2
}

enum PatchRelease {
    case firstOrder(k1: Double)
    case zeroOrder(rateMGh: Double)
}

struct PatchPK {
    static let fallbackK1ByHormone: [SimulatedHormone: Double] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.hormones.map { ($0.key, $0.value.patchFallbackK1) }
    )

    nonisolated static func generic(for hormone: SimulatedHormone) -> PatchRelease {
        .firstOrder(k1: fallbackK1ByHormone[hormone] ?? 0.0075)
    }
}

struct TransdermalGelPK {
    static func parameters(doseMG: Double, areaCM2: Double, hormone: SimulatedHormone) -> (k1: Double, F: Double) {
        guard doseMG > 0 else { return (0, 0) }
        let config = PKSharedCatalogResource.current.hormones[hormone]
        return (config?.gelK1 ?? 0, config?.gelFmax ?? 0)
    }
}

struct OralPK {
    struct DualAbsorptionParams: Sendable {
        let fracFast: Double
        let kAbsFast: Double
        let kAbsSlow: Double
        let bioavailabilityFast: Double
        let bioavailabilitySlow: Double
        let kClear: Double
        let lagHoursFast: Double
        let lagHoursSlow: Double
    }

    static let kAbsByCompound: [Compound: Double] = PKSharedCatalogResource.current.oralKAbs
    static let bioavailabilityByCompound: [Compound: Double] = PKSharedCatalogResource.current.oralBioavailability
    static let dualAbsorptionByCompound: [Compound: DualAbsorptionParams] = Dictionary(
        uniqueKeysWithValues: PKSharedCatalogResource.current.oralDualAbsorption.map { compound, config in
            (
                compound,
                DualAbsorptionParams(
                    fracFast: config.fracFast,
                    kAbsFast: config.kAbsFast,
                    kAbsSlow: config.kAbsSlow,
                    bioavailabilityFast: config.bioavailabilityFast,
                    bioavailabilitySlow: config.bioavailabilitySlow,
                    kClear: config.kClear,
                    lagHoursFast: config.lagHoursFast,
                    lagHoursSlow: config.lagHoursSlow
                )
            )
        }
    )
    static let kAbsSL: Double = PKSharedCatalogResource.current.kAbsSL

    nonisolated static func kAbs(for compound: Compound) -> Double {
        kAbsByCompound[compound] ?? 0
    }

    nonisolated static func bioavailability(for compound: Compound) -> Double {
        bioavailabilityByCompound[compound] ?? 0
    }

    nonisolated static func dualAbsorption(for compound: Compound) -> DualAbsorptionParams? {
        dualAbsorptionByCompound[compound]
    }
}

enum SublingualTier: String, CaseIterable, Identifiable {
    case quick, casual, standard, strict
    var id: Self { self }
}

struct SublingualTheta {
    static let recommended: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualRecommendedTheta
    static let holdMinutes: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualHoldMinutes
    static let thetaRangeLow: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualThetaRangeLow
    static let thetaRangeHigh: [SublingualTier: Double] = PKSharedCatalogResource.current.sublingualThetaRangeHigh
}

enum CompoundSupport {
    static func availableCompounds(for category: MedicationCategory, route: DoseEvent.Route) -> [Compound] {
        switch category {
        case .antiAndrogen:
            return [.E2]
        case .estradiol:
            switch route {
            case .injection: return [.EB, .EV, .EC, .EN]
            case .patchApply, .patchRemove, .gel: return [.E2]
            case .oral, .sublingual: return [.E2, .EV]
            }
        case .testosterone:
            switch route {
            case .injection: return [.TC, .TE, .TU]
            case .patchApply, .patchRemove, .gel: return [.T]
            case .oral: return [.TU]
            case .sublingual: return []
            }
        }
    }
}
